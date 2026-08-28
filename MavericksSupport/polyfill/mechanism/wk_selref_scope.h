// wk_selref_scope.h — WebKit-scoped ObjC-method polyfill registry (shared by the patcher and the
// polyfill list). See wk_selref_scope.m for the mechanism; add polyfills in polyfills/methods/.
//
// To add a polyfill: in polyfills/methods/, implement `- (T)wk_foo` (or `+`) as a category on the real
// class using the classic 10.9 API, then `WK_POLYFILL_SEL("foo", "wk_foo");`. Rebuild. The marker is
// already in every WebKit framework, so the call site may live anywhere in WebKit and reverts to
// pristine upstream (it sends `foo`, which is rewritten to `wk_foo` in WebKit images only).
#ifndef WK_SELREF_SCOPE_H
#define WK_SELREF_SCOPE_H

// GAP_FILL is what WK_POLYFILL_SEL means: supply a method 10.9 LACKS; the body runs unconditionally,
// like WK_POLYFILL_ABSENT for a C symbol. REPLACES says this polyfill deliberately shadows a method
// 10.9 HAS. Both install the body (wk_alias_class in wk_selref_scope.m); the distinction is a
// build-gate concern — a GAP_FILL whose method 10.9 turns out to have fails the shadow gate in build-polyfill.sh,
// so verify absence on-host rather than declaring one blindly.
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

// The default, for a method 10.9 LACKS: the body runs. If 10.9 turns out to have the method, the build
// gate rejects it (delete it, or switch to WK_POLYFILL_SEL_REPLACES).
#define WK_POLYFILL_SEL(PUB, PRIV) WK_POLYFILL_SEL_(PUB, PRIV, WK_SELMAP_GAP_FILL)

// Use this to deliberately shadow a method 10.9 HAS, so the body wins by intent and the gate expects it.
#define WK_POLYFILL_SEL_REPLACES(PUB, PRIV) WK_POLYFILL_SEL_(PUB, PRIV, WK_SELMAP_REPLACES)

// HOW A REPLACES BODY CALLS THROUGH TO THE METHOD IT SHADOWS. Use these — do NOT hand-roll it as
// `objc_msgSend(self, sel_registerName("<public>"), …)`. That spelling re-resolves from the TOP of the
// receiver's chain, so if anything between the receiver and the body overrides the public selector in a
// WebKit image, the override runs again and its [super …] (rewritten to wk_) lands back in the body:
// unbounded recursion. These answer "what is one level below ME", derived from the BODY's class, and are
// resolver-free. See the long comment on wk_replaces_call_through_class in wk_selref_scope.m.
//
//   - (BOOL)wk_foo:(int)x
//   {
//       SEL pub = sel_registerName("foo:");
//       typedef BOOL (*Fn)(id, SEL, int);
//       Fn real = (Fn)wk_replaces_call_through_class(self, [MyClass class], _cmd, pub);
//       ...
//       return real(self, pub, x);
//   }
//
// Pass the class the polyfill CATEGORY is on; for a `+` body that is the METAclass, object_getClass([C class]).
// For a WK_POLYFILL_ADD_REPLACES body (a C function IMP on a runtime-named class) use the _imp form and
// pass the function itself, since one function may be registered for several classes.
#import <objc/objc.h>
#import <objc/runtime.h>
IMP wk_replaces_call_through_class(id receiver, Class bodyClass, SEL privateSelector, SEL publicSelector);
IMP wk_replaces_call_through_imp(id receiver, IMP bodyIMP, SEL privateSelector, SEL publicSelector);


// Add a NEW wk_ method to a RUNTIME-resolved class via a C-function IMP (no ObjC category).
//
// Needed for a class that MOVED frameworks between the build SDK and 10.9 (e.g. NSURLSessionTask:
// CFNetwork on the modern SDK, Foundation at 10.9 runtime). A compile-time `@interface C (…)` category in
// polyfills/methods/ emits an `_OBJC_CLASS_$_C` classref that binds to libpolyfill_classes.dylib via its
// framework reexport; if the class isn't actually in the reexported framework at runtime, dyld fails to
// load ("Symbol not found: _OBJC_CLASS_$_C") and the whole framework won't load. WK_POLYFILL_ADD sidesteps
// that: it stores (class NAME, sel, C-function IMP, type-encoding) in __DATA,__wk_addmap; at load
// `wk_install_added` does `class_addMethod(objc_getClass(NAME), sel_registerName(SEL), IMP, TYPES)` — the
// class is resolved by string at RUNTIME, so no compile-time classref exists. The IMP is a C function
// `RET fn(id self, SEL _cmd, ARGS…)`; TYPES is its ObjC type encoding (e.g. "f@:" / "v@:f"). Pair with a
// WK_POLYFILL_SEL so the public selector is rewritten to this wk_ one. (For a class that IS in the linked
// SDK framework, a plain category is simpler — use this only for the moved-framework case.)
// The intent field mirrors WK_POLYFILL_SEL / WK_POLYFILL_SEL_REPLACES, and for the same reason it
// exists there: a class that HAS the real method also gets its own implementation aliased under the
// wk_ name (wk_alias_class), and that aliasing runs BEFORE these entries are installed. class_addMethod
// then does nothing, so a GAP_FILL correctly leaves 10.9's real method in place — and a deliberate
// REPLACES would silently lose. WK_POLYFILL_ADD_REPLACES uses class_replaceMethod so the body wins,
// which is what "deliberately shadow a method 10.9 HAS" has to mean for a runtime-resolved class.
// (A REPLACES body reaches 10.9's implementation the same way a category-based one does: send the
// PUBLIC selector via sel_registerName, which is untouched on the class.)
struct wk_addmap_entry { const char *cls; const char *sel; void *imp; const char *types; int intent; };
#define WK_POLYFILL_ADD_(CLS, SEL, IMP, TYPES, INTENT) \
    __attribute__((used, section("__DATA,__wk_addmap"))) \
    static const struct wk_addmap_entry WK_SELMAP_CAT(wk_addmap_reg_, __LINE__) = { CLS, SEL, (void *)(IMP), TYPES, INTENT }
#define WK_POLYFILL_ADD(CLS, SEL, IMP, TYPES) WK_POLYFILL_ADD_(CLS, SEL, IMP, TYPES, WK_SELMAP_GAP_FILL)
#define WK_POLYFILL_ADD_REPLACES(CLS, SEL, IMP, TYPES) WK_POLYFILL_ADD_(CLS, SEL, IMP, TYPES, WK_SELMAP_REPLACES)

// Same, for a CLASS method: the '+' prefix tells wk_install_add_entry to resolve the METAclass, which is
// where a send to the class object looks the selector up. The IMP still takes (id self, SEL _cmd, ...),
// with self being the class.
#define WK_POLYFILL_ADD_CLASS_METHOD(CLS, SEL, IMP, TYPES) WK_POLYFILL_ADD_("+" CLS, SEL, IMP, TYPES, WK_SELMAP_GAP_FILL)
#define WK_POLYFILL_ADD_CLASS_METHOD_REPLACES(CLS, SEL, IMP, TYPES) WK_POLYFILL_ADD_("+" CLS, SEL, IMP, TYPES, WK_SELMAP_REPLACES)

#endif // WK_SELREF_SCOPE_H
