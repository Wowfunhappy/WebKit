// wk_selref_scope.h — WebKit-scoped ObjC-method polyfill registry (shared by the patcher and the
// polyfill list). See wk_selref_scope.m for the mechanism; add polyfills in polyfills/methods.m.
//
// To add a polyfill: in polyfills/methods.m, implement `- (T)wk_foo` (or `+`) as a category on the real
// class using the classic 10.9 API, then `WK_POLYFILL_SEL("foo", "wk_foo");`. Rebuild. The marker is
// already in every WebKit framework, so the call site may live anywhere in WebKit and reverts to
// pristine upstream (it sends `foo`, which is rewritten to `wk_foo` in WebKit images only).
#ifndef WK_SELREF_SCOPE_H
#define WK_SELREF_SCOPE_H

// GAP_FILL is what WK_POLYFILL_SEL means: supply the method, and if 10.9 turns out to have it after all,
// forward to 10.9's and leave the body unused. REPLACES says this polyfill deliberately wins over 10.9's
// method — the same distinction WK_POLYFILL_ABSENT vs WK_POLYFILL_REPLACES draws for a C symbol. The
// forwarding happens in the patcher (wk_alias_class in wk_selref_scope.m), so a GAP_FILL declaration is
// presence-agnostic: writing one for a method 10.9 already has is harmless, and you never have to know.
enum { WK_SELMAP_GAP_FILL = 0, WK_SELMAP_REPLACES = 1 };

// A registry entry: public selector name -> private (wk_) selector name, plus which of the two above it
// is. Emitted into __DATA,__wk_selmap by WK_POLYFILL_SEL and read by the patcher (wk_collect) from every
// WebKit image at load, and by the shadow gate out of the built archive.
struct wk_selmap_entry { const char *pub; const char *priv; int intent; };

#define WK_SELMAP_CAT_(a, b) a##b
#define WK_SELMAP_CAT(a, b) WK_SELMAP_CAT_(a, b)
#define WK_POLYFILL_SEL_(PUB, PRIV, INTENT) \
    __attribute__((used, section("__DATA,__wk_selmap"))) \
    static const struct wk_selmap_entry WK_SELMAP_CAT(wk_selmap_reg_, __LINE__) = { PUB, PRIV, INTENT }

// The default. Declaring one for a method 10.9 turns out to have is harmless: the patcher forwards to
// 10.9's method and the body goes unused, so you do not need to know whether 10.9 has it.
#define WK_POLYFILL_SEL(PUB, PRIV) WK_POLYFILL_SEL_(PUB, PRIV, WK_SELMAP_GAP_FILL)

// Use this when replacing 10.9's method is the point, so the body wins even where 10.9 has the method.
#define WK_POLYFILL_SEL_REPLACES(PUB, PRIV) WK_POLYFILL_SEL_(PUB, PRIV, WK_SELMAP_REPLACES)


// Add a NEW wk_ method to a RUNTIME-resolved class via a C-function IMP (no ObjC category).
//
// Needed for a class that MOVED frameworks between the build SDK and 10.9 (e.g. NSURLSessionTask:
// CFNetwork on the modern SDK, Foundation at 10.9 runtime). A compile-time `@interface C (…)` category in
// polyfills/methods.m emits an `_OBJC_CLASS_$_C` classref that binds to libpolyfill_classes.dylib via its
// framework reexport; if the class isn't actually in the reexported framework at runtime, dyld fails to
// load ("Symbol not found: _OBJC_CLASS_$_C") and the whole framework won't load. WK_POLYFILL_ADD sidesteps
// that: it stores (class NAME, sel, C-function IMP, type-encoding) in __DATA,__wk_addmap; at load
// `wk_install_added` does `class_addMethod(objc_getClass(NAME), sel_registerName(SEL), IMP, TYPES)` — the
// class is resolved by string at RUNTIME, so no compile-time classref exists. The IMP is a C function
// `RET fn(id self, SEL _cmd, ARGS…)`; TYPES is its ObjC type encoding (e.g. "f@:" / "v@:f"). Pair with a
// WK_POLYFILL_SEL so the public selector is rewritten to this wk_ one. (For a class that IS in the linked
// SDK framework, a plain category is simpler — use this only for the moved-framework case.)
struct wk_addmap_entry { const char *cls; const char *sel; void *imp; const char *types; };
#define WK_POLYFILL_ADD(CLS, SEL, IMP, TYPES) \
    __attribute__((used, section("__DATA,__wk_addmap"))) \
    static const struct wk_addmap_entry WK_SELMAP_CAT(wk_addmap_reg_, __LINE__) = { CLS, SEL, (void *)(IMP), TYPES }

#endif // WK_SELREF_SCOPE_H
