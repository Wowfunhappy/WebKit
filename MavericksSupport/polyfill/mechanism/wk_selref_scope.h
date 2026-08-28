// wk_selref_scope.h — WebKit-scoped ObjC-method polyfills (shared by the patcher and the polyfill
// units). See wk_selref_scope.m for the mechanism; add polyfills in polyfills/methods/.
//
// A polyfill is written as an ordinary method, under its real name, inside a block that names the
// class it belongs to and says whether 10.9 LACKS the method (ADD) or HAS it and is being deliberately
// shadowed (REPLACE):
//
//   WK_POLYFILL_ADD_METHODS(NSGraphicsContext)
//   - (CGContextRef)CGContext { ... }
//   @end
//
//   WK_POLYFILL_REPLACE_METHODS(NSPopover)
//   - (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)edge
//   {
//       WK_ORIGINAL_METHOD(void, (NSRect, NSView *, NSRectEdge), rect, view, edge);
//       ...
//   }
//   @end
//
// The block is a subclass of the named class that nothing ever instantiates: the compiler checks each
// method's signature against the SDK's declaration, `self` is typed, and the class's own methods are
// callable. At load, the mechanism installs every method the block defines on the named class under a
// private selector and rewrites WebKit's own images to send that private selector, so WebKit's call
// sites stay byte-upstream while the public selector never appears on the class (a host app's
// respondsToSelector: keeps answering what the class really says). `+` methods install on the
// metaclass. Several blocks may name the same class.
//
// The _ON forms name the receiving classes by string, for a class the archive cannot link against —
// one that moved frameworks between the build SDK and 10.9 (NSURLSessionTask), a private class
// (DDActionsManager, NSColorPopoverController), or a class cluster whose instances belong to a private
// concrete class that must be listed alongside the public one (NSURLSession / __NSCFURLSession). The
// first argument is the compile-time superclass used only for typing; NSObject when nothing linkable
// fits. Installation waits for each named class to load.
//
//   WK_POLYFILL_ADD_METHODS_ON(NSObject, "NSURLSessionTask", "__NSCFURLSessionTask")
//   - (float)priority { ... }
//   @end
//
// A REPLACE body reaches the implementation it stands in for with WK_ORIGINAL_METHOD(RET, (ARG TYPES),
// args...), never by sending the public selector to self: that spelling re-resolves from the top of
// the receiver's chain, and an override of the public selector in a WebKit image would run again and
// land its [super ...] back in the body (see wk_original_of in wk_selref_scope.m).
//
// A polyfilled selector is rewritten by NAME across every WebKit image, so every class WebKit sends it
// to must answer the private selector. A class that implements the real method itself gets its own
// implementation aliased under the private name automatically (wk_alias_class); only a class that
// LACKS the method needs a block.
#ifndef WK_SELREF_SCOPE_H
#define WK_SELREF_SCOPE_H

#import <objc/objc.h>
#import <objc/runtime.h>

// ADD supplies a method 10.9 LACKS; REPLACE shadows one 10.9 HAS. Both install the body; the
// distinction decides how (class_addMethod vs class_replaceMethod), how the alias pass treats the
// class's subclasses, and what the shadow gate in build-polyfill.sh requires: an ADD whose method 10.9
// turns out to implement fails the build, so verify absence on-host rather than declaring one blindly.
enum { WK_METHODS_ADD = 0, WK_METHODS_REPLACE = 1 };

// One block. Emitted into __DATA,__wk_methods and read by the patcher from every WebKit image at load,
// and by the shadow gate out of the built archive. The placeholder is named rather than referenced so
// the record is plain constant data.
struct wk_methods_entry {
    const char *placeholder;       // the block's class; its own methods are the bodies
    const char *const *targets;    // NULL-terminated class names to install on
    int intent;                    // WK_METHODS_ADD / WK_METHODS_REPLACE
};

// The block's class is named from the compile unit (WK_POLYFILL_UNIT, set by build-polyfill.sh per
// source file), the typing superclass and the line, so blocks never collide across files and a crash
// log names the file a body came from.
#ifndef WK_POLYFILL_UNIT
#error "WK_POLYFILL_UNIT must name this compile unit (build-polyfill.sh passes -DWK_POLYFILL_UNIT=<file>)"
#endif
#define WK_METHODS_CAT_(a, b) a##b
#define WK_METHODS_CAT(a, b) WK_METHODS_CAT_(a, b)
#define WK_METHODS_CAT4(a, b, c, d) WK_METHODS_CAT(WK_METHODS_CAT(a, b), WK_METHODS_CAT(c, d))
#define WK_METHODS_PLACEHOLDER(SUPER) \
    WK_METHODS_CAT4(WKPolyfill_, WK_POLYFILL_UNIT, WK_METHODS_CAT(_, SUPER), WK_METHODS_CAT(_, __LINE__))

#define WK_POLYFILL_METHODS_(SUPER, INTENT, ...) \
    _Pragma("clang diagnostic push") \
    _Pragma("clang diagnostic ignored \"-Wunguarded-availability\"") \
    _Pragma("clang diagnostic ignored \"-Wunguarded-availability-new\"") \
    @interface WK_METHODS_PLACEHOLDER(SUPER) : SUPER @end \
    _Pragma("clang diagnostic pop") \
    static const char *const WK_METHODS_CAT(wk_methods_targets_, __LINE__)[] = { __VA_ARGS__, NULL }; \
    __attribute__((used, section("__DATA,__wk_methods"))) \
    static const struct wk_methods_entry WK_METHODS_CAT(wk_methods_reg_, __LINE__) = { \
        WK_METHODS_STR(WK_METHODS_PLACEHOLDER(SUPER)), WK_METHODS_CAT(wk_methods_targets_, __LINE__), INTENT }; \
    @implementation WK_METHODS_PLACEHOLDER(SUPER)
#define WK_METHODS_STR_(x) #x
#define WK_METHODS_STR(x) WK_METHODS_STR_(x)

// Methods 10.9 LACKS on CLASS (a linkable class; also the typing superclass). Close with @end.
#define WK_POLYFILL_ADD_METHODS(CLASS) WK_POLYFILL_METHODS_(CLASS, WK_METHODS_ADD, #CLASS)
// Methods 10.9 HAS on CLASS, deliberately shadowed. Close with @end.
#define WK_POLYFILL_REPLACE_METHODS(CLASS) WK_POLYFILL_METHODS_(CLASS, WK_METHODS_REPLACE, #CLASS)
// The same, installed on the classes named by string; SUPER is the typing superclass only.
#define WK_POLYFILL_ADD_METHODS_ON(SUPER, ...) WK_POLYFILL_METHODS_(SUPER, WK_METHODS_ADD, __VA_ARGS__)
#define WK_POLYFILL_REPLACE_METHODS_ON(SUPER, ...) WK_POLYFILL_METHODS_(SUPER, WK_METHODS_REPLACE, __VA_ARGS__)

// THE CALL-THROUGH FOR A REPLACE BODY: the implementation this body stands in for, with the public
// selector it expects as _cmd. Derived from the body's class and the receiver's chain; see
// wk_original_of in wk_selref_scope.m. Usable only inside a REPLACE body (it reads self and _cmd).
struct wk_original { IMP imp; SEL sel; };
struct wk_original wk_original_of(id receiver, SEL privateSelector);
#define WK_METHODS_ARGLIST(...) , ##__VA_ARGS__
#define WK_ORIGINAL_METHOD(RET, ARGTYPES, ...) ({ \
    struct wk_original wk_orig_ = wk_original_of(self, _cmd); \
    ((RET (*)(id, SEL WK_METHODS_ARGLIST ARGTYPES))wk_orig_.imp)(self, wk_orig_.sel, ##__VA_ARGS__); })

#endif // WK_SELREF_SCOPE_H
