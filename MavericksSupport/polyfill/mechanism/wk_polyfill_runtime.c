// wk_polyfill_runtime.c — the machinery behind wk_polyfill.h. Add polyfills there, not here.
//
// Three jobs. The first two are driven by the __DATA,__wk_pfmap registry the macros emit:
//
//  1. Hand out 10.9's version of a symbol to a polyfill that wants it (WK_ORIGINAL), resolved on
//     first use so nothing is dlopen'd at launch that the process never touches.
//
//  2. Answer dlsym() for polyfilled names. WebKit's soft-linking (Source/WTF/wtf/cocoa/SoftLinking.h)
//     resolves framework constants and functions by dlsym on a framework handle, which by
//     construction cannot see a definition that lives in WebKit's own image. Without this, a
//     soft-linked symbol would ignore the polyfill layer and SOFT_LINK_CONSTANT would kill the
//     process on the RELEASE_ASSERT the moment it touched a constant 10.9 predates. Making dlsym
//     registry-aware gives soft-linked symbols the same answer as link-time ones and keeps
//     SoftLinking.h byte-identical to upstream.
//
//  3. Answer objc_getClass() for the class stubs in polyfills/classes.m, which SoftLinking.h
//     resolves by name and would otherwise never see, since each stub is registered under a private
//     runtime name to keep it out of the host app's way. Driven by the separate __DATA,__wk_clsmap
//     registry, because those stubs live in a different image -- see lookupPolyfillClass.
//
// Scope: this file ships in libpolyfill.a, which is linked only into WebKit's own binaries, so the
// overrides apply to WebKit's lookups alone. A host app loading WebKit is unaffected.

#include "wk_polyfill.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if __LP64__
typedef struct mach_header_64 wk_mach_header;
#else
typedef struct mach_header wk_mach_header;
#endif

static struct wk_polyfill_entry *entries;
static size_t entryCount;

// dlsym is defined below, so a plain call here would recurse. Take the real one straight out of
// libdyld's export table instead; NSLookupSymbolInImage is itself a libdyld export and is not
// shadowed, so it binds normally. This keeps libpolyfill.a self-contained (no helper dylib).
//
// Non-NULL from resolveSystemDlsym() onwards: not finding it is fatal there, so nothing below has to
// cope with its absence.
static void *(*systemDlsym)(void *, const char *);

// NSLookupSymbolInImage/NSAddressOfSymbol are the pre-dlopen dyld API, deprecated since 10.5 but
// present and working on 10.9. They are used here precisely BECAUSE they are not dlsym.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// Every dlsym() call made from this image goes through the override below, and the override has
// nothing to answer with but the real dlsym. So if the real one cannot be found there is no degraded
// mode to fall back to: every lookup in the image would return NULL with dlerror() unset, which
// surfaces far from here as SOFT_LINK_CONSTANT's RELEASE_ASSERT firing with a nonsense message while
// no constant is ever resolved. Say what actually happened, at the point it happens, and stop.
static void resolveSystemDlsym(void)
{
    if (systemDlsym)
        return;

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "libdyld.dylib"))
            continue;
        NSSymbol symbol = NSLookupSymbolInImage(_dyld_get_image_header(i), "_dlsym",
                                                NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR);
        if (!symbol)
            continue;   // this libdyld does not export it -- keep looking at the remaining images
        systemDlsym = (void *(*)(void *, const char *))NSAddressOfSymbol(symbol);
        if (systemDlsym)
            return;
    }

    fprintf(stderr, "[wk_polyfill] FATAL: no _dlsym export found in any libdyld.dylib image "
                    "(%u images searched with NSLookupSymbolInImage).\n"
                    "[wk_polyfill] This binary routes every dlsym() through the polyfill registry and "
                    "has no other way to reach the real one, so soft-linking would return NULL "
                    "process-wide with dlerror() unset. Aborting here rather than failing later as an "
                    "unrelated-looking assert.\n", imageCount);
    fflush(stderr);
    abort();
}

#pragma clang diagnostic pop

// mayLoad=0 means: answer only from what is ALREADY loaded.
//
// Resolving a provider must never drag a framework into a process that had no other reason to load
// it. The registry lives in every image that carries polyfills, and its providers span AppKit,
// CoreUI, CoreMedia, VideoToolbox and more -- so loading them here would pull the whole UI stack
// into JavaScriptCore, the NetworkProcess and every host app that links WebKit. JavaScriptCore in
// particular is kept clear of AppKit on purpose, for the dyld-restricted setuid program that loads
// only it (see Source/JavaScriptCore/CMakeLists.txt). So the presence probes (handleCanSeeProvider and
// the WK_POLYFILL_REPORT diagnostic) pass mayLoad=0 and see only providers already loaded; only a
// polyfill body that is actually executing may load its provider, and by then the process is already
// using that API.
static void *providerHandle(const char *provider, int mayLoad)
{
    if (!provider)
        return RTLD_DEFAULT;

    char path[512];
    if (provider[0] == '/')
        snprintf(path, sizeof path, "%s", provider);
    else
        snprintf(path, sizeof path, "/System/Library/Frameworks/%s.framework/%s", provider, provider);

    void *handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
    if (!handle && mayLoad)
        handle = dlopen(path, RTLD_LAZY);
    return handle;
}

// Is this address inside one of our own images? Every image that carries polyfills also carries the
// registry section, which makes it a reliable self-identifier.
//
// This matters because each shipped framework force-loads the archive and so has its OWN copy of
// every polyfill. A lookup for a symbol 10.9 genuinely lacks can therefore land on a SIBLING
// framework's copy of the very same polyfill -- at a different address, so comparing against this
// entry alone does not catch it. Left unchecked, WK_ORIGINAL (and the WK_POLYFILL_REPORT probe) would
// take that sibling copy for 10.9's real symbol -- a REPLACES body calling through would re-enter a
// sibling's copy of itself instead of reaching 10.9.
static int addressIsOurs(void *address)
{
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fbase)
        return 0;
    unsigned long size = 0;
    return getsectiondata((const wk_mach_header *)info.dli_fbase, "__DATA", "__wk_pfmap", &size) != NULL;
}

static void *resolveOriginal(struct wk_polyfill_entry *entry, int mayLoad)
{
    resolveSystemDlsym();   // no-op once resolved; fatal if the real dlsym is unreachable

    void *handle = providerHandle(entry->provider, mayLoad);
    void *original = handle ? systemDlsym(handle, entry->name) : NULL;
    if (!original && handle != RTLD_DEFAULT)
        original = systemDlsym(RTLD_DEFAULT, entry->name);

    if (!original || original == entry->address || addressIsOurs(original))
        return NULL;   // 10.9 does not have this; only our own definition answered
    return original;
}

// Also called from a running polyfill body, so loading the provider is already paid for.
void *wk_polyfill_system_symbol(const char *provider, const char *name, void **cache)
{
    if (!*cache) {
        resolveSystemDlsym();
        void *handle = providerHandle(provider, 1);
        if (handle)
            *cache = systemDlsym(handle, name);
    }
    return *cache;
}

// Called from a polyfill body that is running, so the process is already using this API and loading
// the provider costs nothing it has not already paid for.
void *wk_polyfill_original(struct wk_polyfill_entry *entry)
{
    if (!entry->resolved) {
        entry->original = resolveOriginal(entry, 1);
        entry->resolved = 1;
    }
    return entry->original;
}

// Every polyfilled symbol, whether or not it was reached by a link-time reference. Returns the entry
// rather than just its address because answering a dlsym takes the provider and the intent too. A
// linear scan over a section-resident array: this runs while a process soft-links at startup, so it
// stays allocation-free and touches nothing but memory the image already has mapped.
static struct wk_polyfill_entry *lookup(const char *name)
{
    for (size_t i = 0; i < entryCount; i++) {
        if (!strcmp(entries[i].name, name))
            return &entries[i];
    }
    return NULL;
}

// Would a real dlsym on THIS handle have reached the image the entry names as the symbol's owner?
//
// RTLD_DEFAULT is a whole-process search, which is the same scope a link-time reference resolves in,
// so a registered name belongs there. Otherwise the handle has to BE the provider's: dlsym on a
// handle searches that library, and nothing makes libz vend a Security symbol -- answering one would
// be inventing an export the caller could never have observed. The provider is looked up with
// RTLD_NOLOAD, so a provider this process never loaded matches nothing (it cannot be the handle the
// caller is holding), and nothing is dragged in just to compare.
//
// RTLD_NEXT and RTLD_SELF are excluded outright. They do not name a library at all; they ask "the
// definition after the caller's image" and "the caller's own image", questions about link order that
// this layer has no standing to answer. They can never equal a dlopen handle, but they are rejected
// by name so that reading the code does not require knowing that.
static int handleCanSeeProvider(void *handle, struct wk_polyfill_entry *entry)
{
    if (handle == RTLD_NEXT || handle == RTLD_SELF)
        return 0;
    if (handle == RTLD_DEFAULT)
        return 1;
    // A NULL provider means "libSystem/the whole process", which providerHandle reports as
    // RTLD_DEFAULT -- and handle is not RTLD_DEFAULT here, so such an entry matches no handle.
    // The provider==NULL test also keeps a caller's NULL handle (a library that failed to dlopen,
    // which SOFT_LINK_*_OPTIONAL passes straight through) from matching an unloaded provider.
    void *provider = providerHandle(entry->provider, 0);
    return provider != NULL && handle == provider;
}

// dlsym for WebKit's own binaries (see the header comment: the archive is linked nowhere else).
//
// A registered name resolves to OUR definition -- the same one a link-time reference binds under
// force_load -- so soft-linking (SOFT_LINK_CONSTANT/FUNCTION) and link-time references give the same
// answer, which is the whole point of this override. Gap-fill vs replacement makes no difference here:
// the body always runs either way, and the build gate guarantees a gap-fill's symbol is one 10.9
// lacks, so there is nothing on 10.9 for it to shadow. (Were a gap-fill to defer to 10.9 here while
// the link-time reference bound ours, the same name would resolve two ways.)
//
// An answer comes out of the registry only where a real dlsym could plausibly have produced one: the
// handle has to be able to see the provider (above). The system's answer is taken first, so a
// non-registered name passes straight through.
//
// Declared through the registry like any other polyfill, so WK_POLYFILL_REPORT names it and the shadow
// check sees a stated intent. Registering it recurses nowhere: lookup() is a scan over this image's own
// __wk_pfmap section, and the real dlsym is reached through systemDlsym (from NSLookupSymbolInImage) --
// which is also why the body uses systemDlsym rather than WK_ORIGINAL: it must work before anything has
// read the registry.
WK_POLYFILL_REPLACES(NULL, void *, dlsym, (void *handle, const char *symbol))
{
    resolveSystemDlsym();   // no-op once resolved; fatal if the real dlsym is unreachable

    void *systemAnswer = systemDlsym(handle, symbol);
    if (!symbol)
        return systemAnswer;

    struct wk_polyfill_entry *entry = lookup(symbol);
    if (!entry || !handleCanSeeProvider(handle, entry))
        return systemAnswer;

    // The failed lookup above left an error pending; from the caller's side this call succeeded, so
    // do not leave a stale "symbol not found" for its next dlerror() to pick up.
    if (!systemAnswer)
        dlerror();
    return entry->address;
}

// The class stubs live in libpolyfill_classes.dylib, not in this image, so their registry cannot be
// read out of our own __wk_pfmap the way wk_polyfill_init reads the function/constant one. Walk the
// loaded images for the __wk_clsmap section instead. This runs only when the system has no class of
// that name -- a soft-link's one-shot dispatch_once for a class 10.9 lacks -- so a linear walk costs
// nothing measurable and, like lookup(), it allocates nothing and touches only mapped memory.
//
// No caching: an image carrying stubs can arrive at any time (libpolyfill_classes.dylib is loaded
// with the framework that pulled it in, and the frameworks load in whatever order the host app
// causes), so a cache built on the first miss could be built before the answer exists.
static void *lookupPolyfillClass(const char *name)
{
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const wk_mach_header *header = (const wk_mach_header *)_dyld_get_image_header(i);
        if (!header)
            continue;
        unsigned long size = 0;
        uint8_t *section = getsectiondata(header, "__DATA", "__wk_clsmap", &size);
        if (!section)
            continue;
        struct wk_polyfill_class_entry *classEntries = (struct wk_polyfill_class_entry *)section;
        size_t count = size / sizeof(*classEntries);
        for (size_t j = 0; j < count; j++) {
            if (strcmp(classEntries[j].name, name))
                continue;
            if (classEntries[j].cls)
                return classEntries[j].cls;
            return classEntries[j].resolve ? classEntries[j].resolve() : NULL;
        }
    }
    return NULL;
}

// objc_getClass for WebKit's own binaries, the class-shaped counterpart of the dlsym override above.
//
// SoftLinking.h resolves a soft-linked class by name through objc_getClass, so a class the polyfill
// layer supplies is invisible to it: classes.m registers each stub under a private runtime name on
// purpose, which is what keeps the system name free for the host app. Without this, a required
// soft-link of an absent class RELEASE_ASSERTs and an optional one yields nil -- in both cases
// ignoring a stub that is loaded and able to answer, which is the same failure the dlsym override
// exists to prevent for constants and functions.
//
// The system is asked first, so this can only ever answer where 10.9 has no such class, and only for
// a name classes.m explicitly registered. A host app is unaffected: it calls libobjc's objc_getClass,
// not this one.
WK_POLYFILL_REPLACES("/usr/lib/libobjc.A.dylib", Class, objc_getClass, (const char *name))
{
    wk_pf_fn_objc_getClass systemGetClass = WK_ORIGINAL(objc_getClass);
    if (!systemGetClass) {
        // Same reasoning as resolveSystemDlsym: every objc_getClass call in this image comes here,
        // and there is nothing to answer with but libobjc's. Silently returning NULL would surface
        // far away as classes that exist appearing not to.
        fprintf(stderr, "[wk_polyfill] FATAL: libobjc.A.dylib does not export objc_getClass, so this "
                        "image cannot look up any class by name.\n");
        fflush(stderr);
        abort();
    }

    Class systemAnswer = systemGetClass(name);
    if (systemAnswer || !name)
        return systemAnswer;
    return (Class)lookupPolyfillClass(name);
}

static void report(void);

// Exposed so the self-test can drive report(), which is otherwise static.
void wk_polyfill_report_for_testing(void);
void wk_polyfill_report_for_testing(void) { report(); }

static void report(void)
{
    const char *mode = getenv("WK_POLYFILL_REPORT");
    if (!mode)
        return;

    int falsePremises = 0;
    fprintf(stderr, "[wk_polyfill] %zu entries\n", entryCount);
    for (size_t i = 0; i < entryCount; i++) {
        struct wk_polyfill_entry *entry = &entries[i];
        // Probe presence read-only for a constant (mayLoad=0, no caching, no side effects); a function
        // may load its provider to answer, which for a REPLACES is the point of asking.
        int present = entry->kind == WK_POLYFILL_CONSTANT
            ? resolveOriginal(entry, 0) != NULL
            : wk_polyfill_original(entry) != NULL;
        int replaces = entry->intent == WK_POLYFILL_REPLACES;

        // A replacement whose target does not exist means the premise behind it ("10.9 has this but
        // it misbehaves") is wrong -- worth knowing, because such a polyfill is usually carrying a
        // workaround for a bug that is not there.
        if (replaces && !present)
            falsePremises++;

        fprintf(stderr, "[wk_polyfill]   %-56s %-8s 10.9:%-7s -> %s\n", entry->name,
                entry->kind == WK_POLYFILL_CONSTANT ? "constant" : "function",
                present ? "present" : "absent",
                replaces ? "polyfill (replaces)" : (present ? "10.9" : "polyfill"));
    }
    if (falsePremises)
        fprintf(stderr, "[wk_polyfill] %d replacement(s) target a symbol 10.9 does not have\n", falsePremises);
    if (falsePremises && !strcmp(mode, "abort"))
        abort();
}

// Ahead of the image's other initializers, so the registry is populated before any soft-link lookup
// reaches the dlsym override above. (Numbers below 101 are reserved for the implementation.)
__attribute__((constructor(101)))
static void wk_polyfill_init(void)
{
    resolveSystemDlsym();

    Dl_info info;
    if (!dladdr((void *)&wk_polyfill_init, &info) || !info.dli_fbase)
        return;

    unsigned long size = 0;
    uint8_t *section = getsectiondata((const wk_mach_header *)info.dli_fbase,
                                      "__DATA", "__wk_pfmap", &size);
    if (!section)
        return;   // an image that links the archive without pulling in any polyfill

    entries = (struct wk_polyfill_entry *)section;
    entryCount = size / sizeof(struct wk_polyfill_entry);

    report();
}
