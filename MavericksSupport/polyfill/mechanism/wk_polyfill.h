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
// Linked as an ordinary archive (which is what this layer used to be), the same definition wins or
// loses depending on link order — see the force_load block in Source/cmake/WebKitMacros.cmake.
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
enum { WK_POLYFILL_GAP_FILL = 0, WK_POLYFILL_REPLACES = 1 };

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

#ifdef __cplusplus
}
#endif

#endif // WK_POLYFILL_H
