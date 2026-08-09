// wk_polyfill.h — how to declare a C function or data constant polyfill.
//
// Write a polyfill only for a symbol 10.9 genuinely LACKS (or, deliberately, one it HAS but that
// misbehaves — WK_POLYFILL_REPLACES). The body always runs: the runtime does what you declared, with
// no forwarding to 10.9. If you are wrong and 10.9 already has the symbol, the BUILD catches it —
// scripts/check-polyfill-shadows.sh asks this machine whether any symbol the layer defines is one
// 10.9 already provides, and fails unless it is declared WK_POLYFILL_REPLACES. So verify absence
// on-host; never ship a polyfill over a working system symbol.
//
//   WK_POLYFILL_ABSENT("CoreText", CTFontRef, CTFontCreateForCharactersWithLanguageAndOption,
//       (CTFontRef font, const UTF16Char *chars, CFIndex length, CFStringRef language,
//        unsigned long options, CFIndex *coveredLength))
//   {
//       return CTFontCreateForCharactersWithLanguage(font, chars, length, language, coveredLength);
//   }
//
//   WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontManagerCreateFontDescriptorFromData,
//       (CFDataRef data))
//   {
//       // always runs; 10.9's version is still reachable
//       if (WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData))
//           return WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)(data);
//       return NULL;
//   }
//
//   WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedRange,
//                     CFSTR("kCGColorSpaceExtendedRange"));
//
// WK_POLYFILL_ABSENT and WK_POLYFILL_REPLACES take a single parameter list and run the body directly
// (no generated forwarding call), so a variadic function is fine either way — the body handles its own
// varargs.
//
// WHY THE POLYFILL WINS. libpolyfill.a is force-loaded into every shipped WebKit binary, so its
// definitions are image-local object code, and a Mach-O image always binds its own references to
// its own definition in preference to importing one from a dylib. That holds no matter where the
// system frameworks land on the link line, and no matter whether the reference is a weak import.
// Linked as an ordinary archive, the same definition would win or lose depending on link order —
// see the force_load block in Source/cmake/WebKitMacros.cmake.
//
// WHY IT ONLY AFFECTS WEBKIT. The archive is static and goes only into WebKit's own binaries, so a
// host app that loads WebKit keeps binding to the system's symbols. Nothing here is exported
// (build-polyfill.sh compiles with -fvisibility=hidden).
//
// The first argument names who owns the symbol on 10.9 — used by the build gate to ask whether 10.9
// has it there, and to resolve WK_ORIGINAL: a framework name ("CoreText"), an absolute path
// ("/usr/lib/libsqlite3.dylib"), or NULL to search the whole process (right for libSystem/libc symbols).
//
// ObjC methods use a different mechanism, since dispatch keys on the selector rather than on a
// linker symbol — see wk_selref_scope.h.

#ifndef WK_POLYFILL_H
#define WK_POLYFILL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { WK_POLYFILL_FUNCTION = 0, WK_POLYFILL_CONSTANT = 1 };
// GAP_FILL defers to 10.9 when 10.9 has the symbol; REPLACES deliberately wins over it.
// UNAVAILABLE is a definition that exists only to satisfy a weak-linked reference and aborts if it
// runs: the dlsym override never answers one, so a soft-link probe for it reports the symbol missing
// and its caller takes the absent-API path instead of being routed into the abort.
enum { WK_POLYFILL_GAP_FILL = 0, WK_POLYFILL_REPLACES = 1, WK_POLYFILL_UNAVAILABLE = 2 };

// The handle dlopen hands back for a framework this system does not ship at all but whose symbols the
// registry supplies. Keyed by the canonical framework PATH, the one thing both minting sites hold:
// dlopen sees only the path, and a registry provider is spelled either as a bare framework name or as
// an absolute path. Returns NULL for a path no registered provider resolves to. See wk_polyfill_runtime.c.
void *wk_polyfill_absent_provider_token(const char *frameworkPath);
int wk_polyfill_is_absent_provider_token(void *handle);

struct wk_polyfill_entry {
    const char *name;
    const char *provider;
    void *address;              // our definition: the function itself, or the constant's storage
    unsigned short kind;
    unsigned short intent;
    void *original;             // 10.9's version; NULL when 10.9 lacks it
    int resolved;
};

// 10.9's version of an entry's symbol, resolved on first use. NULL when 10.9 lacks it.
void *wk_polyfill_original(struct wk_polyfill_entry *);

// Resolve an arbitrary 10.9 function by name, caching the result in *cache.
void *wk_polyfill_system_symbol(const char *provider, const char *name, void **cache);

// Calling a 10.9 function from inside a polyfill body.
//
// A plain call would emit an undefined symbol, which every image force-loading this archive then has
// to satisfy -- even one that never uses the polyfill. That is not hypothetical: force-loading a
// CoreGraphics/sqlite/vImage polyfill into JavaScriptCore made JSC fail to link on IOMasterPort,
// sqlite3_bind_blob and vImage*, because JSC has no reason to link IOKit, libsqlite3 or Accelerate.
// The alternative -- adding those libraries to JSC's link line -- would make the setuid JSC path load
// three frameworks to satisfy polyfills it never calls.
//
// So resolve the target at first use instead, which keeps libpolyfill.a self-contained and lets one
// archive be force-loaded everywhere:
//
//   WK_SYSTEM_FN("IOKit", kern_return_t, IOMasterPort, (mach_port_t, mach_port_t *));
//   ... WK_SYSTEM(IOMasterPort)(bootstrapPort, mainPort)
//
// WK_SYSTEM(NAME) is NULL if the function is missing, so check it when that is possible.
#define WK_SYSTEM_FN(PROVIDER, RET, NAME, PARAMS)                                      \
    typedef RET (*wk_sysfn_type_##NAME) PARAMS;                                        \
    static void *wk_sysfn_cache_##NAME;                                                \
    static inline wk_sysfn_type_##NAME wk_sysfn_get_##NAME(void)                       \
    {                                                                                  \
        return (wk_sysfn_type_##NAME)wk_polyfill_system_symbol(PROVIDER, #NAME,        \
                                                               &wk_sysfn_cache_##NAME); \
    }

#define WK_SYSTEM(NAME) wk_sysfn_get_##NAME()

// Taking &NAME for a symbol the modern SDK marks as introduced after our deployment target is the
// point of this layer, so silence the availability warning it necessarily produces. The trailing
// incomplete-struct declaration exists only to consume the caller's semicolon, so that the pragma
// can be popped after the entry.
#define WK_PF_ENTRY(NAME, PROVIDER, ADDRESS, KIND, INTENT)               \
    _Pragma("clang diagnostic push")                                      \
    _Pragma("clang diagnostic ignored \"-Wunguarded-availability-new\"")  \
    __attribute__((used, section("__DATA,__wk_pfmap")))                   \
    static struct wk_polyfill_entry wk_pf_entry_##NAME =                  \
        { #NAME, PROVIDER, (void *)(ADDRESS), KIND, INTENT, NULL, 0 };    \
    _Pragma("clang diagnostic pop")                                       \
    struct wk_pf_swallow_semicolon_##NAME

#define WK_ORIGINAL(NAME) ((wk_pf_fn_##NAME)wk_polyfill_original(&wk_pf_entry_##NAME))

// WK_POLYFILL_ABSENT and WK_POLYFILL_REPLACES install the body as the symbol itself; it always runs.
// They are ONE mechanism, differing only in the intent the registry records — which the build gate
// reads: a gap-fill 10.9 turns out to have fails the build, a replacement asserts 10.9 has it. The
// runtime does what you declared; it never re-decides at a call.
#define WK_PF_FUNCTION(PROVIDER, RET, NAME, PARAMS, INTENT)                             \
    RET NAME PARAMS;                                                                    \
    typedef RET (*wk_pf_fn_##NAME) PARAMS;                                              \
    WK_PF_ENTRY(NAME, PROVIDER, &NAME, WK_POLYFILL_FUNCTION, INTENT);                   \
    RET NAME PARAMS

#define WK_POLYFILL_ABSENT(PROVIDER, RET, NAME, PARAMS) \
    WK_PF_FUNCTION(PROVIDER, RET, NAME, PARAMS, WK_POLYFILL_GAP_FILL)

#define WK_POLYFILL_REPLACES(PROVIDER, RET, NAME, PARAMS) \
    WK_PF_FUNCTION(PROVIDER, RET, NAME, PARAMS, WK_POLYFILL_REPLACES)

// A definition for a symbol this OS cannot serve at all, present so the weak-linked reference has an
// address. The body aborts, and the dlsym override withholds the entry so no soft-link probe can
// route a caller here.
#define WK_POLYFILL_ABSENT_FATAL(PROVIDER, RET, NAME, PARAMS) \
    WK_PF_FUNCTION(PROVIDER, RET, NAME, PARAMS, WK_POLYFILL_UNAVAILABLE)

// Data constants. The declared value IS the value — 10.9 lacks the symbol (a gap-fill), or has it and
// is being deliberately overridden (WK_POLYFILL_CONST_REPLACES). There is no load-time mirroring of
// 10.9's value; if 10.9 turns out to export a gap-fill constant, that is a mistake the build gate
// rejects. (The gate replaces the old mirroring, which existed to stop a token-valued placeholder
// shadowing a key the system interprets — the EXIF and proxy-key regressions. Caught at build now.)
#define WK_POLYFILL_CONST_(PROVIDER, TYPE, NAME, VALUE, INTENT)                     \
    const TYPE NAME = VALUE;                                                        \
    WK_PF_ENTRY(NAME, PROVIDER, &NAME, WK_POLYFILL_CONSTANT, INTENT)

#define WK_POLYFILL_CONST(PROVIDER, TYPE, NAME, VALUE) \
    WK_POLYFILL_CONST_(PROVIDER, TYPE, NAME, VALUE, WK_POLYFILL_GAP_FILL)
#define WK_POLYFILL_CONST_REPLACES(PROVIDER, TYPE, NAME, VALUE) \
    WK_POLYFILL_CONST_(PROVIDER, TYPE, NAME, VALUE, WK_POLYFILL_REPLACES)

// An absent ObjC CLASS, stubbed in polyfills/classes.m, that WebKit reaches by NAME.
//
// A stub is registered in the runtime under a private name and the system name is exported as an
// alias to it (WK_PRIV_CLASS / WK_PRIV_ALIAS in classes.m), so a compiled `[UTType ...]` classref
// binds to the stub while objc_getClass("UTType") still answers NULL — which is what keeps the stub
// out of the host app's way. But SoftLinking.h resolves a soft-linked class with
// objc_getClass(auditedClassName) (SOFT_LINK_CLASS_FOR_SOURCE_INTERNAL), by name and not by
// classref, so for those classes the private name is the whole problem: a required soft-link
// RELEASE_ASSERTs and an optional one hands WebKit nil, with the stub sitting right there.
//
// Registering the stub here fixes that the same way the registry already fixes soft-linked constants
// and functions: the objc_getClass override in wk_polyfill_runtime.c answers registered names out of
// this section. It is opt-in per class, because for some stubs a NULL answer IS the right one —
// NSVisualEffectView and _NSScrollingMomentumCalculator are probed so WebKit can take its
// pre-10.10 path, and a stub that cannot do the job would be the wrong answer. Register a class only
// where WebKit soft-links it and the stub can actually serve the caller.
//
// Scope is the same as every other override here: libpolyfill.a goes only into WebKit's own
// binaries, so a host app's objc_getClass is untouched and keeps seeing the system name as free.
struct wk_polyfill_class_entry {
    const char *name;       // the system class name WebKit asks objc_getClass for
    const char *provider;   // framework that owns it on a modern OS; the build gate asks 10.9 there
    void *cls;              // the privately-named stub in classes.m
    void *(*resolve)(void); // ... or, when cls is NULL, builds it on first ask
};

// Emitted into its own section rather than __wk_pfmap: the class stubs live in
// libpolyfill_classes.dylib, a DIFFERENT image from the libpolyfill.a copy that runs the override,
// so unlike a function entry this one has to be found by scanning loaded images (see
// lookupPolyfillClass). Keeping them in separate sections keeps that scan off the hot registry.
#define WK_POLYFILL_CLASS(PROVIDER, NAME)                                     \
    extern char OBJC_CLASS_$_WKMavPolyfillPriv_##NAME;                        \
    __attribute__((used, section("__DATA,__wk_clsmap")))                      \
    static struct wk_polyfill_class_entry wk_pf_class_##NAME =                \
        { #NAME, PROVIDER, &OBJC_CLASS_$_WKMavPolyfillPriv_##NAME, NULL };    \
    struct wk_pf_swallow_semicolon_class_##NAME

// A stub that cannot be written as an @implementation because its superclass lives in a framework
// classes.m deliberately does not link -- linking it would put that framework on the load commands of
// a dylib every WebKit binary carries, dragging it into JavaScriptCore, the NetworkProcess and every
// host app. Such a stub is built with objc_allocateClassPair at the moment WebKit asks for it, which
// is also the moment its superclass's framework is guaranteed loaded: PAL soft-links the FRAMEWORK
// before it soft-links the class. RESOLVER returns the Class and must be idempotent.
#define WK_POLYFILL_CLASS_RESOLVED(PROVIDER, NAME, RESOLVER)                  \
    static void *RESOLVER(void);                                              \
    __attribute__((used, section("__DATA,__wk_clsmap")))                      \
    static struct wk_polyfill_class_entry wk_pf_class_##NAME =                \
        { #NAME, PROVIDER, NULL, RESOLVER };                                  \
    struct wk_pf_swallow_semicolon_class_##NAME

#ifdef __cplusplus
}
#endif

#endif // WK_POLYFILL_H
