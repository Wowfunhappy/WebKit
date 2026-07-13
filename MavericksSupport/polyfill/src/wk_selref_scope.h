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

#endif // WK_SELREF_SCOPE_H
