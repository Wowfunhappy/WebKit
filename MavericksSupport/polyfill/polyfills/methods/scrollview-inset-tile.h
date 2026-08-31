// The NSScrollView contentInsets APPLICATION mechanism, shared (as one static definition) between the
// polyfill proper (methods/AppKit.m, which wires it to WebKit's -contentInsets / -setContentInsets: sends) and
// its proof, tests/behaviour/AppKit-scrollview-insets.m — so the probe exercises the very code WebKit runs.
//
// wkScrollViewSetContentInsets stores the insets and re-classes the scroll view (at first non-zero set)
// into a dynamic subclass whose -tile — the one AppKit layout pass that places the clip view, rerun on
// every resize and scroller change — insets the clip view's frame by the stored insets after the
// standard layout.
//
// The -tile override coexists with KVO's own isa-swizzling (proven by the reclass→addObserver→tile
// probe): its super-dispatch is anchored at the class that DEFINES the override — each dynamic
// subclass's IMP is a block closing over that subclass's parent — never derived from
// object_getClass(self), which names whatever (e.g. an NSKVONotifying_ subclass) is stacked on the
// instance at call time and would send the message back to itself, recursing without bound. The
// re-class guard walks the ancestry for the same reason: with KVO stacked on top, the concrete class
// name no longer starts with the marker prefix, and re-classing again would stack a second inset
// subclass that applies the padding twice.
#ifndef WK_SCROLLVIEW_INSET_TILE_H
#define WK_SCROLLVIEW_INSET_TILE_H

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdio.h>

static const char wkScrollViewInsetsKey;
static const char wkInsetTileClassPrefix[] = "WKMavPolyfillInsetTile_";

static NSEdgeInsets wkScrollViewContentInsets(NSScrollView *scrollView)
{
    NSEdgeInsets insets = (NSEdgeInsets){ .top = 0, .left = 0, .bottom = 0, .right = 0 };
    NSValue *stored = objc_getAssociatedObject(scrollView, &wkScrollViewInsetsKey);
    if (stored)
        [stored getValue:&insets];
    return insets;
}

static void wkScrollViewApplyStoredContentInsets(NSScrollView *scrollView)
{
    NSEdgeInsets insets = wkScrollViewContentInsets(scrollView);
    if (insets.top == 0 && insets.left == 0 && insets.bottom == 0 && insets.right == 0)
        return;

    NSClipView *clipView = [scrollView contentView];
    if (!clipView)
        return;
    NSRect frame = [clipView frame];
    frame.origin.x += insets.left;
    frame.origin.y += [scrollView isFlipped] ? insets.top : insets.bottom;
    frame.size.width = MAX(0, frame.size.width - insets.left - insets.right);
    frame.size.height = MAX(0, frame.size.height - insets.top - insets.bottom);
    [clipView setFrame:frame];
}

static void wkScrollViewSetContentInsets(NSScrollView *scrollView, NSEdgeInsets contentInsets)
{
    objc_setAssociatedObject(scrollView, &wkScrollViewInsetsKey,
        [NSValue valueWithBytes:&contentInsets objCType:@encode(NSEdgeInsets)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Re-class into the tile-insetting subclass the first time a non-zero inset arrives (the zero-inset
    // fast path in wkScrollViewApplyStoredContentInsets keeps an already-re-classed view correct if the
    // inset is later cleared). The guard is ancestry-wide, not a check of the concrete class name — see
    // the KVO-coexistence note above. One dynamic subclass exists per concrete scroll-view class
    // encountered.
    BOOL hasInset = contentInsets.top != 0 || contentInsets.left != 0 || contentInsets.bottom != 0 || contentInsets.right != 0;
    BOOL alreadyReclassed = NO;
    for (Class ancestor = object_getClass(scrollView); ancestor; ancestor = class_getSuperclass(ancestor)) {
        if (strncmp(class_getName(ancestor), wkInsetTileClassPrefix, sizeof(wkInsetTileClassPrefix) - 1) == 0) {
            alreadyReclassed = YES;
            break;
        }
    }
    if (hasInset && !alreadyReclassed) {
        Class parentClass = object_getClass(scrollView);
        char subclassName[256];
        snprintf(subclassName, sizeof(subclassName), "%s%s", wkInsetTileClassPrefix, class_getName(parentClass));
        Class subclass = objc_getClass(subclassName);
        if (!subclass) {
            subclass = objc_allocateClassPair(parentClass, subclassName, 0);
            if (subclass) {
                // Anchored super-dispatch: the block closes over the defining subclass's parent, so the
                // super send starts above the definition no matter what is stacked on the instance later.
                IMP tileImplementation = imp_implementationWithBlock(^(NSScrollView *tiledScrollView) {
                    struct objc_super superContext = { tiledScrollView, parentClass };
                    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superContext, @selector(tile));
                    wkScrollViewApplyStoredContentInsets(tiledScrollView);
                });
                class_addMethod(subclass, @selector(tile), tileImplementation, "v@:");
                objc_registerClassPair(subclass);
            }
        }
        if (subclass)
            object_setClass(scrollView, subclass);
    }
    [scrollView tile];
}

#endif // WK_SCROLLVIEW_INSET_TILE_H
