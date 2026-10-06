// wk_image_marker.c — tags a binary as a WebKit image eligible for selector-scope rewriting.
//
// Force-loaded into every WebKit framework (WEBKIT_FRAMEWORK in WebKitMacros.cmake). The selref
// patcher in wk_selref_scope.m rewrites each image's __objc_selrefs ONLY when the image carries this
// __DATA,__wk_marker section, so the private-selector polyfills are scoped to WebKit's own binaries
// and never touch a host app that embeds WebKit. Pure data (no initializer, no AppKit) so it is safe
// even in a setuid process that loads only JavaScriptCore.
__attribute__((used, section("__DATA,__wk_marker")))
static const char wk_image_marker_[] = "WebKitPolyfillScope";
