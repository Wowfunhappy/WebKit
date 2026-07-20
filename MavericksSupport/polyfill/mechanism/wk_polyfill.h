// wk_polyfill.h — how to declare a C function or data constant polyfill.
//
// Write the polyfill; do not reason about whether 10.9 already has the symbol. Declaring a
// gap-fill for a symbol 10.9 turns out to ship is harmless: at runtime it forwards to 10.9's
// version, so being wrong about presence costs nothing.
//
//   WK_POLYFILL_ABSENT("CoreText", CTFontRef, CTFontCreateForCharactersWithLanguageAndOption,
//       (CTFontRef font, const UTF16Char *chars, CFIndex length, CFStringRef language,
//        unsigned long options, CFIndex *coveredLength),
//       (font, chars, length, language, options, coveredLength))
//   {
//       // runs only when 10.9 lacks the symbol
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
// The parameter list is written twice for WK_POLYFILL_ABSENT (types, then names) because the
// forward-to-10.9 call is generated for you.
//
// DO NOT use WK_POLYFILL_ABSENT for a VARIADIC function: the generated call can only pass the named
// parameters, so it would silently drop the varargs if 10.9 did turn out to have the symbol. Use
// WK_POLYFILL_REPLACES for those and forward by hand (e.g. via the v-suffixed form), or keep the
// body self-contained.
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
// The first argument names who owns the symbol on 10.9, used to find the implementation being
// replaced: a framework name ("CoreText"), an absolute path ("/usr/lib/libsqlite3.dylib"), or NULL
// to search the whole process (right for libSystem/libc symbols).
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
    unsigned int size;          // constants only
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
//
// The anchor pointer exists so that an object carrying a registry entry cannot be linked without the
// runtime that services it. The entry itself references nothing outside its own object, so on the
// plain-archive path (build tools, anything not force-loading) the __DATA,__wk_pfmap section could
// link in while wk_polyfill_runtime.o -- which owns the constructor that mirrors 10.9's real values
// over gap-fill constants -- was never pulled: a placeholder token would then stay live and shadow a
// value the system actually interprets. Naming wk_polyfill_original leaves an undefined symbol in
// every such object, so the runtime member is always dragged in and the constructor is always there.
// It survives -dead_strip because archive members are selected during symbol resolution, before any
// stripping, and a constructor is a dead-strip root once its member is in.
#define WK_PF_ENTRY(NAME, PROVIDER, ADDRESS, KIND, INTENT, SIZE)          \
    _Pragma("clang diagnostic push")                                      \
    _Pragma("clang diagnostic ignored \"-Wunguarded-availability-new\"")  \
    __attribute__((used, section("__DATA,__wk_pfmap")))                   \
    static struct wk_polyfill_entry wk_pf_entry_##NAME =                  \
        { #NAME, PROVIDER, (void *)(ADDRESS), KIND, INTENT, SIZE, NULL, 0 }; \
    _Pragma("clang diagnostic pop")                                       \
    __attribute__((used))                                                 \
    static void *(*const wk_pf_anchor_##NAME)(struct wk_polyfill_entry *) \
        = wk_polyfill_original;                                           \
    struct wk_pf_swallow_semicolon_##NAME

#define WK_ORIGINAL(NAME) ((wk_pf_fn_##NAME)wk_polyfill_original(&wk_pf_entry_##NAME))

#define WK_POLYFILL_ABSENT(PROVIDER, RET, NAME, PARAMS, ARGS)                           \
    RET NAME PARAMS;                                                                    \
    typedef RET (*wk_pf_fn_##NAME) PARAMS;                                              \
    static RET wk_pf_impl_##NAME PARAMS;                                                \
    WK_PF_ENTRY(NAME, PROVIDER, &NAME, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL, 0);  \
    RET NAME PARAMS {                                                                   \
        wk_pf_fn_##NAME original = WK_ORIGINAL(NAME);                                   \
        return original ? original ARGS : wk_pf_impl_##NAME ARGS;                       \
    }                                                                                   \
    static RET wk_pf_impl_##NAME PARAMS

#define WK_POLYFILL_REPLACES(PROVIDER, RET, NAME, PARAMS)                               \
    RET NAME PARAMS;                                                                    \
    typedef RET (*wk_pf_fn_##NAME) PARAMS;                                              \
    WK_PF_ENTRY(NAME, PROVIDER, &NAME, WK_POLYFILL_FUNCTION, WK_POLYFILL_REPLACES, 0);  \
    RET NAME PARAMS

// Data constants. When 10.9 exports the symbol its real value is copied over this storage at load,
// so a token-valued gap-fill can never shadow a value the system actually interprets — the bug
// behind the EXIF and proxy-key regressions this layer used to hit. Hence the storage sits in a
// writable section rather than __DATA,__const.
//
// Caveat: a read of one of these from INSIDE the translation unit that defines it can be
// constant-folded to the pre-mirror value. Consumers live in other images, so this only matters if
// a polyfill in this directory reads a constant polyfilled in the same file.
#define WK_POLYFILL_CONST_(PROVIDER, TYPE, NAME, VALUE, INTENT)                     \
    const TYPE NAME __attribute__((section("__DATA,__wk_pfconst"))) = VALUE;        \
    WK_PF_ENTRY(NAME, PROVIDER, &NAME, WK_POLYFILL_CONSTANT, INTENT, sizeof(TYPE))

#define WK_POLYFILL_CONST(PROVIDER, TYPE, NAME, VALUE) \
    WK_POLYFILL_CONST_(PROVIDER, TYPE, NAME, VALUE, WK_POLYFILL_GAP_FILL)
#define WK_POLYFILL_CONST_REPLACES(PROVIDER, TYPE, NAME, VALUE) \
    WK_POLYFILL_CONST_(PROVIDER, TYPE, NAME, VALUE, WK_POLYFILL_REPLACES)

#ifdef __cplusplus
}
#endif

#endif // WK_POLYFILL_H
