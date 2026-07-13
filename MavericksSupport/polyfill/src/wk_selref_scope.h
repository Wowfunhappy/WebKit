// wk_selref_scope.h — WebKit-scoped ObjC-method polyfill registry (shared by the patcher and the
// polyfill list). See wk_selref_scope.m for the mechanism; add polyfills in wk_polyfills.m.
//
// To add a polyfill: in wk_polyfills.m, implement `- (T)wk_foo` (or `+`) as a category on the real
// class using the classic 10.9 API, then `WK_POLYFILL_SEL("foo", "wk_foo");`. Rebuild. The marker is
// already in every WebKit framework, so the call site may live anywhere in WebKit and reverts to
// pristine upstream (it sends `foo`, which is rewritten to `wk_foo` in WebKit images only).
#ifndef WK_SELREF_SCOPE_H
#define WK_SELREF_SCOPE_H

// A registry entry: public selector name -> private (wk_) selector name. Emitted into __DATA,__wk_selmap
// by WK_POLYFILL_SEL and read by the patcher (wk_collect) from every WebKit image at load.
struct wk_selmap_entry { const char *pub; const char *priv; };

#define WK_SELMAP_CAT_(a, b) a##b
#define WK_SELMAP_CAT(a, b) WK_SELMAP_CAT_(a, b)
#define WK_POLYFILL_SEL(PUB, PRIV) \
    __attribute__((used, section("__DATA,__wk_selmap"))) \
    static const struct wk_selmap_entry WK_SELMAP_CAT(wk_selmap_reg_, __LINE__) = { PUB, PRIV }

// CLASS-AWARE polyfilling for GENERIC (multi-class) selector names.
//
// The selref rewrite is by NAME: it rewrites every `foo` selref in a WebKit image to `wk_foo`, regardless
// of the receiver's class (a selref carries no class). That is fine when WebKit sends `foo` only to the one
// class we polyfill. But some names are sent to SEVERAL classes — e.g. `valueForHTTPHeaderField:` to both
// NSURLRequest (present on 10.9) and NSHTTPURLResponse (10.13+). The class whose `foo` is absent gets a
// wk_foo polyfill (WK_POLYFILL_SEL); the classes that already HAVE `foo` would otherwise receive `wk_foo`
// with no implementation -> unrecognized selector. WK_POLYFILL_ALIAS fixes that: at load it adds `wk_foo`
// to such a class as an ALIAS of the class's own real `foo` IMP, so `[obj wk_foo]` runs the exact same code
// as `[obj foo]`. (No forwarding/recursion: it shares the original IMP directly. Caveat: the aliased IMP
// runs with _cmd == wk_foo; harmless for the ~all methods that ignore _cmd.) The result is class-AWARE: the
// absent-method class dispatches the polyfill, every real-method class dispatches its own implementation.
//
// Host-safe: wk_foo is a private selector the host never probes, and the class already answered YES to
// respondsToSelector:@selector(foo) (it genuinely has foo), so nothing changes for the host.
//
// Use WK_POLYFILL_ALIAS for an instance method, WK_POLYFILL_ALIAS_CLASS for a class (+) method. CLS is the
// class name string; PUB the public selector; PRIV the wk_ selector (same PRIV as the WK_POLYFILL_SEL).
struct wk_aliasmap_entry { const char *cls; const char *pub; const char *priv; int is_class_method; };
#define WK_POLYFILL_ALIAS_(CLS, PUB, PRIV, ISCLS) \
    __attribute__((used, section("__DATA,__wk_aliasmap"))) \
    static const struct wk_aliasmap_entry WK_SELMAP_CAT(wk_aliasmap_reg_, __LINE__) = { CLS, PUB, PRIV, ISCLS }
#define WK_POLYFILL_ALIAS(CLS, PUB, PRIV)       WK_POLYFILL_ALIAS_(CLS, PUB, PRIV, 0)
#define WK_POLYFILL_ALIAS_CLASS(CLS, PUB, PRIV) WK_POLYFILL_ALIAS_(CLS, PUB, PRIV, 1)

#endif // WK_SELREF_SCOPE_H
