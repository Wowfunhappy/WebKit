// wk_polyfill_runtime.c — the machinery behind wk_polyfill.h. Add polyfills there, not here.
//
// Three jobs, all driven by the __DATA,__wk_pfmap registry the macros emit:
//
//  1. Copy 10.9's real value over a polyfilled CONSTANT when 10.9 turns out to export it. This is
//     what makes a gap-fill safe to declare without first checking presence: a constant whose value
//     the system actually interprets keeps the system's value, and only a genuinely absent one keeps
//     ours. Runs from a constructor, before the rest of the image initializes.
//
//  2. Hand out 10.9's version of a symbol to a polyfill that wants it (WK_ORIGINAL), resolved on
//     first use so nothing is dlopen'd at launch that the process never touches.
//
//  3. Answer dlsym() for polyfilled names. WebKit's soft-linking (Source/WTF/wtf/cocoa/SoftLinking.h)
//     resolves framework constants and functions by dlsym on a framework handle, which by
//     construction cannot see a definition that lives in WebKit's own image. Without this, a
//     soft-linked symbol would ignore the polyfill layer and SOFT_LINK_CONSTANT would kill the
//     process on the RELEASE_ASSERT the moment it touched a constant 10.9 predates. Making dlsym
//     registry-aware gives soft-linked symbols the same answer as link-time ones and keeps
//     SoftLinking.h byte-identical to upstream.
//
// Scope: this file ships in libpolyfill.a, which is linked only into WebKit's own binaries, so the
// dlsym override applies to WebKit's lookups alone. A host app loading WebKit is unaffected.

#include "wk_polyfill.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
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
// only it (see Source/JavaScriptCore/CMakeLists.txt). Constant mirroring therefore runs with
// mayLoad=0 and is retried as images arrive; only a polyfill body that is actually executing may
// load its provider, and by then the process is already using that API.
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
// entry alone does not catch it. Left unchecked, a gap-fill would report itself "present on 10.9",
// defer to that sibling copy, and the two images would forward to each other.
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
// The system's answer always comes first, and always wins when there is one. A gap-fill exists for
// the case where 10.9 has nothing; if 10.9 does export the name, deferring is what makes declaring
// the polyfill safe without checking presence -- and it gives a soft-linked symbol the same answer
// the link-time reference gets, which is the whole point of this override. Only a REPLACES entry,
// whose entire premise is that 10.9's version is there and wrong, keeps winning here; anything else
// would mean the same name resolved to the polyfill when linked and to 10.9 when soft-linked.
//
// And an answer comes out of the registry only where a real dlsym could plausibly have produced one:
// the handle has to be able to see the provider (above), and for a gap-fill the lookup on that very
// handle has to have come back empty.
//
// Declared through the registry like any other deliberate override of a working 10.9 symbol, so that
// WK_POLYFILL_REPORT names it and the shadow check sees a stated intent rather than an exemption.
// Registering it recurses nowhere: lookup() is a scan over this image's own __wk_pfmap section, and the
// real dlsym is reached through systemDlsym, which comes from NSLookupSymbolInImage. (Which is also why
// the body uses systemDlsym rather than WK_ORIGINAL: it has to work before anything has read the
// registry, and wk_polyfill_original resolves through systemDlsym in the end anyway.)
WK_POLYFILL_REPLACES(NULL, void *, dlsym, (void *handle, const char *symbol))
{
    resolveSystemDlsym();   // no-op once resolved; fatal if the real dlsym is unreachable

    void *systemAnswer = systemDlsym(handle, symbol);
    if (!symbol)
        return systemAnswer;

    struct wk_polyfill_entry *entry = lookup(symbol);
    if (!entry || (systemAnswer && entry->intent != WK_POLYFILL_REPLACES))
        return systemAnswer;
    if (!handleCanSeeProvider(handle, entry))
        return systemAnswer;

    // The failed lookup above left an error pending; from the caller's side this call succeeded, so
    // do not leave a stale "symbol not found" for its next dlerror() to pick up.
    if (!systemAnswer)
        dlerror();
    return entry->address;
}

static void report(void);

// Exposed for the self-test, which checks that reporting leaves constant mirroring alone.
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
        // Reporting must not change what the process does. wk_polyfill_original() marks an entry
        // resolved, and mirrorConstants() skips resolved entries -- so asking it about a constant
        // whose provider is not loaded yet would retire that constant from mirroring for the life of
        // the process, leaving the placeholder token in place. Read the mirrored state instead, and
        // probe read-only when there is none yet.
        int present = entry->kind == WK_POLYFILL_CONSTANT
            ? (entry->resolved ? entry->original != NULL : resolveOriginal(entry, 0) != NULL)
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

// Copy 10.9's real value over every gap-fill constant whose provider is already loaded. Entries stay
// unresolved until their provider shows up, so this is safe to run repeatedly.
static void mirrorConstants(void)
{
    for (size_t i = 0; i < entryCount; i++) {
        struct wk_polyfill_entry *entry = &entries[i];
        if (entry->kind != WK_POLYFILL_CONSTANT || entry->intent == WK_POLYFILL_REPLACES
            || entry->resolved)
            continue;

        // The ONLY retryable state is "the provider is not loaded, so we cannot look yet". Once it
        // is loaded its answer is final: a symbol that is not in it never will be.
        //
        // Distinguishing those two is what keeps this cheap. This runs from every image load, and
        // the vast majority of entries are constants 10.9 genuinely lacks -- so treating "absent"
        // as retryable meant re-probing ~190 symbols on every dlopen for the life of the process,
        // each probe taking dyld's lock and then scanning every loaded image. That is a launch that
        // crawls until image loading quiesces and then appears to heal itself.
        void *handle = providerHandle(entry->provider, 0);
        if (!handle)
            continue;   // provider not loaded yet -- the one case worth revisiting

        void *original = systemDlsym(handle, entry->name);
        if (original && (original == entry->address || addressIsOurs(original)))
            original = NULL;   // only our own definition answered; see resolveOriginal
        if (original)
            memcpy(entry->address, original, entry->size);
        entry->original = original;
        entry->resolved = 1;   // answered either way; never probe this entry again
    }
}

static void imageAdded(const struct mach_header *header, intptr_t slide)
{
    (void)header; (void)slide;
    mirrorConstants();
}

// Ahead of the image's other initializers, so a constant is never read before it is mirrored.
// (Numbers below 101 are reserved for the implementation.)
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

    mirrorConstants();
    // A provider that is not loaded yet cannot be read now, and we will not load it just to look.
    // Retry as images arrive, which covers every provider this process ever actually uses.
    _dyld_register_func_for_add_image(imageAdded);

    report();
}
