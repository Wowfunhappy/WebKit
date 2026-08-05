// Objective-C garbage-collection support for the backported frameworks (github issue #118).
//
// 10.9's runtime still runs applications compiled -fobjc-gc -- Xcode 4 is one -- and such an
// application loads our frameworks into a collecting process. Apple built the 2013 system
// frameworks dual-mode, with compiler-emitted write barriers (objc_assign_global,
// objc_assign_ivar, auto_zone_root_write_barrier). Modern clang removed -fobjc-gc entirely,
// so our binaries contain no barriers at all, and this unit supplies -- at load time, and
// only in processes that actually collect -- what the missing barriers would have provided.
//
// MEASURED SEMANTICS OF 10.9's libauto (each verified on-host against a -finalize oracle,
// which is the only reliable liveness signal; auto_zone_is_valid_pointer and weak reads are
// NOT -- they report "alive" for already-collected memory):
//
//   * A plain store into a global is invisible to the collector. The object is freed at the
//     next cycle even though the global still points at it. libauto does NOT conservatively
//     scan image data; a global becomes a root only by going through a write barrier.
//   * auto_zone_register_datasegment does not change that -- it is weak-reference
//     bookkeeping, not scanning. (Tested: an object stored into a registered segment is
//     still collected.)
//   * auto_zone_add_root(zone, &slot, value) does two things: it WRITES value into the slot
//     (so the only safe value to pass is the one the slot already holds -- passing anything
//     else corrupts the static), and it registers the slot as a root.
//   * A slot registered while it holds NULL is not recorded at all: registration needs a real
//     collectable block, so a pass that runs at image load, when the statics are still zero,
//     protects nothing.
//   * Once a slot HAS been registered with a real value, it stays a root and is re-read on
//     every cycle -- a value stored into it much later is protected with no further calls.
//     (This is only true with the two collection modes below disabled; with them on, the slot
//     is bypassed entirely, which is what made an earlier round of these measurements read as
//     "add_root only pins the value passed in".)
//
// So: a sweeper thread walks our images' mutable data (__data, __bss, __common) and registers
// every slot that has become non-NULL since the last pass. Each slot is registered exactly
// once -- tracked in a per-region bitmap -- because from then on the collector re-reads it, so
// nothing is permanently pinned and no value leaks. Steady state is a linear scan of a few
// hundred KB against a bitmap.
//
// The sweep alone is not enough, because it can only protect a value it has already seen.
// Two collection modes free young objects too quickly for any sweep interval, and both are
// disabled here:
//
//   * The THREAD-LOCAL COLLECTOR frees young blocks whose escape from the allocating thread
//     no barrier reported -- and we report none, so it frees objects that are in fact stored
//     in globals. Its switch is Auto::Environment::thread_collections (the AUTO_USE_TLC
//     environment flag), which no exported call reaches; it is located by resolving that
//     symbol in /usr/lib/libauto.dylib's own symbol table at runtime (NOT a hardcoded
//     offset -- see wk_gc_libauto_thread_collections).
//   * GENERATIONAL collections trace only the write-barrier cards, which nobody fills in, so
//     a young object stored into an old one is missed. auto_collection_parameters()'s
//     disable_generational makes every cycle a full trace.
//
// BOTH ARE REQUIRED, measured against the real workload (a GC app driving WebView through
// several page loads with exhaustive collections between them): with both knobs the app
// completes 4/4 runs; with only the TLC knob 1/4; with only the generational knob 0/4; with
// neither 0/10. An earlier microbenchmark suggested both were useless -- it was wrong,
// because it drove an explicit full collection, which is not the path that frees these
// objects. Trust the integration test over the microbenchmark.
//
// Even with both, the sweep is a mitigation, not an equivalent of a barrier: the FIRST value
// ever stored into a given static can be collected if it becomes unreachable from everywhere
// else before the next pass registers that slot. Every later value in that slot is safe.
// WebKit's own Objective-C references are pinned deterministically, with no
// window at all, by RetainPtr's CFRetain-based paths (Source/WTF/wtf/RetainPtr.h) -- the sweep
// exists for the raw `static NSFoo *` globals RetainPtr does not cover, and a static whose
// value must never be lost is better pinned outright where it is created (see initWrapperCache
// in JSVirtualMachine.mm) than left to the sweeper.
//
// The OBJC_IMAGE_SUPPORTS_GC image flag that lets a collecting process load us at all is set
// at packaging time by MavericksSupport/scripts/set-objc-gc-supported.py.
//
// Everything libauto/libobjc is resolved through dlsym: the modern SDK stubs the GC API out
// of <objc/objc-auto.h> (objc_collectingEnabled inlines to NO), libauto is in no link line,
// and in a non-collecting process every probe fails closed and this unit does nothing.

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/fat.h>
#include <mach/machine.h>
#include <libkern/OSByteOrder.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct wk_auto_zone wk_auto_zone;

static wk_auto_zone *(*wk_objc_collectableZone)(void);
static void (*wk_auto_zone_add_root)(wk_auto_zone *, void *root, void *value);
static int (*wk_auto_zone_is_valid_pointer)(wk_auto_zone *, const void *);
static wk_auto_zone *wk_gc_zone;

// WK_GC_REPORT=1 in the environment prints what engaged and what each sweep registered.
static int wk_gc_report;

// How often the sweeper looks for newly-populated statics. This interval IS the exposure
// window for a static's first value, so it is short; the work per pass after warmup is a
// linear scan over a few hundred KB against a bitmap, with no allocation and no libauto calls.
#define WK_GC_SWEEP_INTERVAL_US 10000

// ---------------------------------------------------------------------------
// The regions to sweep: our images' mutable data sections, captured as images load.

#define WK_GC_MAX_REGIONS 512

struct wk_gc_region {
    void **start;
    uint64_t count;        // in pointer-sized slots
    unsigned char *seen;   // one bit per slot: already registered as a root
};

static struct wk_gc_region wk_gc_regions[WK_GC_MAX_REGIONS];
static unsigned wk_gc_region_count;
static pthread_mutex_t wk_gc_regions_lock = PTHREAD_MUTEX_INITIALIZER;

// ---------------------------------------------------------------------------

static const struct segment_command_64 *wk_gc_find_segment(const struct mach_header_64 *mh, const char *segname)
{
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (!strcmp(seg->segname, segname))
                return seg;
        }
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    return NULL;
}

// Match by path so the whole shipped tree is covered wherever it is rooted: the nested
// WebCore, the polyfill dylibs and the GStreamer stack all live inside these three bundles.
static int wk_gc_path_is_ours(const char *name)
{
    return strstr(name, "/WebKit.framework/") || strstr(name, "/JavaScriptCore.framework/")
        || strstr(name, "/WebKit2.framework/");
}

static void wk_gc_add_regions_for_image(const struct mach_header *mh, intptr_t slide)
{
    const char *name = NULL;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == mh) {
            name = _dyld_get_image_name(i);
            break;
        }
    }
    if (!name || !wk_gc_path_is_ours(name))
        return;
    const struct mach_header_64 *mh64 = (const struct mach_header_64 *)mh;
    if (mh64->magic != MH_MAGIC_64)
        return;

    // __DATA holds the ordinary statics; __DATA_DIRTY (present in some of our binaries)
    // holds the ones the linker knows are written, which is exactly what we care about.
    static const char *segments[] = { "__DATA", "__DATA_DIRTY" };
    pthread_mutex_lock(&wk_gc_regions_lock);
    for (unsigned s = 0; s < sizeof(segments) / sizeof(segments[0]); s++) {
        const struct segment_command_64 *seg = wk_gc_find_segment(mh64, segments[s]);
        if (!seg)
            continue;
        const struct section_64 *sects = (const struct section_64 *)(seg + 1);
        for (uint32_t i = 0; i < seg->nsects; i++) {
            const struct section_64 *sect = &sects[i];
            if (strcmp(sect->sectname, "__data") && strcmp(sect->sectname, "__bss")
                && strcmp(sect->sectname, "__common"))
                continue;
            if (wk_gc_region_count >= WK_GC_MAX_REGIONS) {
                fprintf(stderr, "WebKit GC support: region table full; %s not swept\n", name);
                break;
            }
            uint64_t slots = sect->size / sizeof(void *);
            // calloc failure is survivable: a region with no bitmap is simply re-registered
            // every pass, which is correct, just not free.
            wk_gc_regions[wk_gc_region_count].start = (void **)(sect->addr + slide);
            wk_gc_regions[wk_gc_region_count].count = slots;
            wk_gc_regions[wk_gc_region_count].seen = (unsigned char *)calloc((size_t)(slots + 7) / 8, 1);
            wk_gc_region_count++;
        }
    }
    pthread_mutex_unlock(&wk_gc_regions_lock);
    if (wk_gc_report)
        fprintf(stderr, "WebKit GC support: sweeping %s\n", name);
}

// Register every slot that has become non-NULL since the last pass. Slots are read while
// other threads write them; a torn or stale read is harmless because every candidate is
// validated by the collector first, and the value read is the one written back.
static void wk_gc_sweep(void)
{
    unsigned regionCount;
    pthread_mutex_lock(&wk_gc_regions_lock);
    regionCount = wk_gc_region_count;
    pthread_mutex_unlock(&wk_gc_regions_lock);

    unsigned long registered = 0;
    for (unsigned r = 0; r < regionCount; r++) {
        void **slots = wk_gc_regions[r].start;
        unsigned char *seen = wk_gc_regions[r].seen;
        uint64_t n = wk_gc_regions[r].count;
        for (uint64_t i = 0; i < n; i++) {
            if (seen && (seen[i / 8] & (1 << (i % 8))))
                continue;   // already a root; the collector re-reads it from here on
            // Read once: another thread may be storing into this slot concurrently, and the
            // value handed to add_root must be the one written back into it.
            void *value = slots[i];
            if (!value || ((uintptr_t)value & 0x7))
                continue;
            if (!wk_auto_zone_is_valid_pointer(wk_gc_zone, value))
                continue;
            wk_auto_zone_add_root(wk_gc_zone, &slots[i], value);
            if (seen)
                seen[i / 8] |= (unsigned char)(1 << (i % 8));
            registered++;
        }
    }
    if (wk_gc_report && registered)
        fprintf(stderr, "WebKit GC support: registered %lu newly-populated slot(s)\n", registered);
}

static void *wk_gc_sweeper(void *unused)
{
    (void)unused;
    for (;;) {
        wk_gc_sweep();
        usleep(WK_GC_SWEEP_INTERVAL_US);
    }
    return NULL;
}

static void wk_gc_image_added(const struct mach_header *mh, intptr_t slide)
{
    wk_gc_add_regions_for_image(mh, slide);
}

// auto_collection_control_t: version (unsigned long, holds sizeof == 104 on 10.9.5), five
// callback pointers, log (uint32) at 0x30, disable_generational (uint32) at 0x34 -- the field
// AUTO_DISABLE_GENERATIONAL=YES sets, identified by diffing the struct with and without that
// environment variable. The version field is checked before the write, so a libauto with a
// different layout simply keeps generational collections.
#define WK_CONTROL_EXPECTED_VERSION 104UL
#define WK_CONTROL_DISABLE_GENERATIONAL_OFFSET 0x34

static void wk_gc_disable_generational(void)
{
    unsigned char *(*parameters)(wk_auto_zone *) =
        (unsigned char *(*)(wk_auto_zone *))dlsym(RTLD_DEFAULT, "auto_collection_parameters");
    if (!parameters) {
        fprintf(stderr, "WebKit GC support: auto_collection_parameters missing; generational "
            "collections stay on and collectable statics may be freed early\n");
        return;
    }
    unsigned char *control = parameters(wk_gc_zone);
    if (!control || *(unsigned long *)control != WK_CONTROL_EXPECTED_VERSION) {
        fprintf(stderr, "WebKit GC support: unexpected auto_collection_control_t version; "
            "generational collections stay on\n");
        return;
    }
    *(uint32_t *)(control + WK_CONTROL_DISABLE_GENERATIONAL_OFFSET) = 1;
    if (wk_gc_report)
        fprintf(stderr, "WebKit GC support: generational collections disabled\n");
}

// Locate Auto::Environment::thread_collections in the LOADED libauto by reading the symbol
// table of the on-disk /usr/lib/libauto.dylib: the symbol is a file-local one (the shared
// cache does not export it, and dlsym cannot see it), so we take its address relative to
// libauto's __DATA segment from the file and apply that to the mapped image. Deriving the
// offset instead of hardcoding it means a libauto other than 10.9.5's is handled correctly
// rather than having an arbitrary byte overwritten.
#define WK_LIBAUTO_PATH "/usr/lib/libauto.dylib"
#define WK_LIBAUTO_TC_SYMBOL "__ZN4Auto11Environment18thread_collectionsE"

// Returns the symbol's offset from the start of libauto's __DATA segment, or 0 if the file
// does not yield it.
static uint64_t wk_gc_thread_collections_data_offset(void)
{
    uint64_t result = 0;
    FILE *f = fopen(WK_LIBAUTO_PATH, "rb");
    if (!f)
        return 0;
    if (fseek(f, 0, SEEK_END)) {
        fclose(f);
        return 0;
    }
    long size = ftell(f);
    if (size <= 0 || fseek(f, 0, SEEK_SET)) {
        fclose(f);
        return 0;
    }
    unsigned char *buf = (unsigned char *)malloc((size_t)size);
    if (!buf) {
        fclose(f);
        return 0;
    }
    size_t got = fread(buf, 1, (size_t)size, f);
    fclose(f);
    if (got != (size_t)size) {
        free(buf);
        return 0;
    }

    // /usr/lib/libauto.dylib ships fat (x86_64 + i386); find our 64-bit slice. Fat headers
    // are big-endian.
    size_t base = 0;
    if (got >= sizeof(struct fat_header)
        && OSSwapBigToHostInt32(((const struct fat_header *)buf)->magic) == FAT_MAGIC) {
        uint32_t nfat = OSSwapBigToHostInt32(((const struct fat_header *)buf)->nfat_arch);
        const struct fat_arch *arches = (const struct fat_arch *)(buf + sizeof(struct fat_header));
        size_t found = 0;
        for (uint32_t i = 0; i < nfat; i++) {
            if ((size_t)(sizeof(struct fat_header) + (i + 1) * sizeof(struct fat_arch)) > got)
                break;
            if (OSSwapBigToHostInt32((uint32_t)arches[i].cputype) == (uint32_t)CPU_TYPE_X86_64) {
                found = OSSwapBigToHostInt32(arches[i].offset);
                break;
            }
        }
        if (!found || found >= got) {
            free(buf);
            return 0;
        }
        base = found;
    }

    const struct mach_header_64 *mh = (const struct mach_header_64 *)(buf + base);
    if (got < base + sizeof(*mh) || mh->magic != MH_MAGIC_64) {
        free(buf);
        return 0;
    }

    uint64_t dataVMAddr = 0;
    int haveData = 0;
    const struct symtab_command *symtab = NULL;
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (!strcmp(seg->segname, "__DATA")) {
                dataVMAddr = seg->vmaddr;
                haveData = 1;
            }
        } else if (lc->cmd == LC_SYMTAB)
            symtab = (const struct symtab_command *)lc;
        lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
    }
    if (haveData && symtab && symtab->symoff && symtab->stroff) {
        const struct nlist_64 *syms = (const struct nlist_64 *)(buf + base + symtab->symoff);
        const char *strings = (const char *)(buf + base + symtab->stroff);
        for (uint32_t i = 0; i < symtab->nsyms; i++) {
            uint32_t strx = syms[i].n_un.n_strx;
            if (!strx || strx >= symtab->strsize)
                continue;
            if (strcmp(strings + strx, WK_LIBAUTO_TC_SYMBOL))
                continue;
            if (syms[i].n_value >= dataVMAddr)
                result = syms[i].n_value - dataVMAddr;
            break;
        }
    }
    free(buf);
    return result;
}

static void wk_gc_disable_thread_local_collector(void)
{
    uint64_t offset = wk_gc_thread_collections_data_offset();
    if (!offset) {
        fprintf(stderr, "WebKit GC support: could not locate " WK_LIBAUTO_TC_SYMBOL " in "
            WK_LIBAUTO_PATH "; the thread-local collector stays on and collectable statics "
            "may be freed early\n");
        return;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strcmp(name, WK_LIBAUTO_PATH))
            continue;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (mh->magic != MH_MAGIC_64)
            break;
        const struct segment_command_64 *seg = wk_gc_find_segment(mh, "__DATA");
        if (!seg)
            break;
        unsigned char *tc = (unsigned char *)(seg->vmaddr + _dyld_get_image_vmaddr_slide(i) + offset);
        if (*tc > 1) {
            fprintf(stderr, "WebKit GC support: " WK_LIBAUTO_TC_SYMBOL " does not hold a "
                "boolean; the thread-local collector stays on\n");
            break;
        }
        *tc = 0;
        if (wk_gc_report)
            fprintf(stderr, "WebKit GC support: thread-local collector disabled "
                "(__DATA+0x%llx)\n", (unsigned long long)offset);
        break;
    }
}

// Priority 101, matching WTF's GC-flag initializer: the sweeper is running before every
// default-priority initializer in the image can create the statics it protects.
__attribute__((constructor(101))) static void wk_objc_gc_support_init(void)
{
    signed char (*collectingEnabled)(void) =
        (signed char (*)(void))dlsym(RTLD_DEFAULT, "objc_collectingEnabled");
    if (!collectingEnabled || !collectingEnabled())
        return;
    wk_gc_report = getenv("WK_GC_REPORT") != NULL;

    wk_objc_collectableZone = (wk_auto_zone *(*)(void))dlsym(RTLD_DEFAULT, "objc_collectableZone");
    wk_auto_zone_add_root = (void (*)(wk_auto_zone *, void *, void *))dlsym(RTLD_DEFAULT, "auto_zone_add_root");
    wk_auto_zone_is_valid_pointer = (int (*)(wk_auto_zone *, const void *))dlsym(RTLD_DEFAULT, "auto_zone_is_valid_pointer");
    if (!wk_objc_collectableZone || !wk_auto_zone_add_root || !wk_auto_zone_is_valid_pointer) {
        fprintf(stderr, "WebKit GC support: libauto entry points unresolved; "
            "statics are not protected from collection\n");
        return;
    }
    wk_gc_zone = wk_objc_collectableZone();
    if (!wk_gc_zone)
        return;
    if (wk_gc_report)
        fprintf(stderr, "WebKit GC support: engaged (zone %p)\n", (void *)wk_gc_zone);

    // Both are required; see the header note. Each reports loudly if it cannot engage,
    // because without them the sweeper cannot keep up with the collector.
    wk_gc_disable_generational();
    wk_gc_disable_thread_local_collector();

    // Fires immediately for every image already loaded, then for each later dlopen. Images
    // are never unregistered: our frameworks are not unloadable, and a stale region would
    // only be read, never written.
    _dyld_register_func_for_add_image(wk_gc_image_added);

    pthread_t sweeper;
    if (pthread_create(&sweeper, NULL, wk_gc_sweeper, NULL))
        fprintf(stderr, "WebKit GC support: sweeper thread failed to start; "
            "statics are not protected from collection\n");
    else
        pthread_detach(sweeper);
}
