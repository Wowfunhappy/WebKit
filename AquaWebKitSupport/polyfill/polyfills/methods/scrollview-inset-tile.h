// NSScrollView content insets (10.10+), shared as one static definition between the polyfill proper
// (methods/AppKit.m, which wires it to WebKit's -contentInsets / -setContentInsets: / -tile sends) and its
// proof, tests/behaviour/AppKit-scrollview-insets.m, so the probe exercises the very code WebKit runs.
//
// AppKit's contract (NSScrollView.h): the sibling views -tile lays out (scrollers, rulers, the header and
// the corner view) are inset as specified, and the content view is placed underneath them. The clip view
// keeps its tiled frame and the insets widen the range its bounds origin may take, so the document scrolls
// beneath the inset margins and reaches them only at the scroll extremes; at the leading edge the bounds
// origin is the document's origin minus the leading inset, so -documentVisibleRect includes the obscured
// margin. A view resting at the leading edge of an axis stays at that edge when the insets change.
//
// The insets are applied right after NSScrollView's own -tile, so a subclass's -tile override sees the
// inset siblings after its [super tile]. WebKit's sends, including a WebKit subclass's [super tile], reach
// the REPLACE body in AppKit.m. AppKit's own sends reach a dynamic subclass of the scroll view's concrete
// class; it applies the insets itself only when no WebKit subclass in its chain overrides -tile, since
// such an override's [super tile] reaches the REPLACE body. The REPLACE body in turn leaves the insets to
// the dynamic subclass when its call through lands there. The clip view's -constrainBoundsRect:, which
// AppKit sends itself, is overridden by a dynamic subclass the same way. Each override reaches its super
// through the parent of the prefixed class in the receiver's ancestry, so a KVO subclass stacked on top
// still lands on the concrete class's implementation, and the re-class guard walks the ancestry for the
// same reason.
#ifndef WK_SCROLLVIEW_INSET_TILE_H
#define WK_SCROLLVIEW_INSET_TILE_H

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdio.h>

static const char wkScrollViewInsetsKey;
static const char wkInsetScrollViewClassPrefix[] = "WKInsetScrollView_";
static const char wkInsetClipViewClassPrefix[] = "WKInsetClipView_";

static NSEdgeInsets wkScrollViewContentInsets(NSScrollView *scrollView)
{
    NSEdgeInsets insets = (NSEdgeInsets){ .top = 0, .left = 0, .bottom = 0, .right = 0 };
    NSValue *stored = objc_getAssociatedObject(scrollView, &wkScrollViewInsetsKey);
    if (stored)
        [stored getValue:&insets];
    return insets;
}

static BOOL wkEdgeInsetsAreZero(NSEdgeInsets insets)
{
    return !insets.top && !insets.left && !insets.bottom && !insets.right;
}

// The bounds-origin range of a clip view under the insets: the leading margins below the document's
// origin, the trailing margins past its far edge. The top inset leads in a flipped clip view.
static NSRect wkClipViewInsetBoundsOriginRange(NSClipView *clipView, NSSize boundsSize, NSEdgeInsets insets)
{
    NSRect documentFrame = [[clipView documentView] frame];
    BOOL flipped = [clipView isFlipped];
    CGFloat leadingY = flipped ? insets.top : insets.bottom;
    CGFloat trailingY = flipped ? insets.bottom : insets.top;
    CGFloat minX = NSMinX(documentFrame) - insets.left;
    CGFloat maxX = MAX(minX, NSMaxX(documentFrame) + insets.right - boundsSize.width);
    CGFloat minY = NSMinY(documentFrame) - leadingY;
    CGFloat maxY = MAX(minY, NSMaxY(documentFrame) + trailingY - boundsSize.height);
    return NSMakeRect(minX, minY, maxX - minX, maxY - minY);
}

static NSEdgeInsets wkClipViewEnclosingInsets(NSClipView *clipView)
{
    NSView *superview = [clipView superview];
    if (![superview isKindOfClass:[NSScrollView class]] || [(NSScrollView *)superview contentView] != clipView)
        return (NSEdgeInsets){ .top = 0, .left = 0, .bottom = 0, .right = 0 };
    return wkScrollViewContentInsets((NSScrollView *)superview);
}

// The parent of the prefixed dynamic subclass in the object's ancestry, or Nil if it has none.
static Class wkParentOfClassWithPrefix(id object, const char *prefix, size_t prefixLength)
{
    for (Class ancestor = object_getClass(object); ancestor; ancestor = class_getSuperclass(ancestor)) {
        if (!strncmp(class_getName(ancestor), prefix, prefixLength))
            return class_getSuperclass(ancestor);
    }
    return Nil;
}

static void wkReclass(id object, const char *prefix, size_t prefixLength, SEL selector, IMP implementation)
{
    if (wkParentOfClassWithPrefix(object, prefix, prefixLength))
        return;
    Class parentClass = object_getClass(object);
    char subclassName[256];
    snprintf(subclassName, sizeof(subclassName), "%s%s", prefix, class_getName(parentClass));
    Class subclass = objc_getClass(subclassName);
    if (!subclass) {
        subclass = objc_allocateClassPair(parentClass, subclassName, 0);
        class_addMethod(subclass, selector, implementation, method_getTypeEncoding(class_getInstanceMethod(parentClass, selector)));
        objc_registerClassPair(subclass);
    }
    object_setClass(object, subclass);
}

static NSRect wkInsetClipViewConstrainBoundsRect(NSClipView *self, SEL _cmd, NSRect proposedBounds)
{
    struct objc_super superContext = { self, wkParentOfClassWithPrefix(self, wkInsetClipViewClassPrefix, sizeof(wkInsetClipViewClassPrefix) - 1) };
    NSRect constrained = ((NSRect (*)(struct objc_super *, SEL, NSRect))objc_msgSendSuper_stret)(&superContext, _cmd, proposedBounds);
    NSEdgeInsets insets = wkClipViewEnclosingInsets(self);
    if (wkEdgeInsetsAreZero(insets) || ![self documentView])
        return constrained;
    NSRect range = wkClipViewInsetBoundsOriginRange(self, proposedBounds.size, insets);
    constrained.origin.x = MIN(MAX(proposedBounds.origin.x, NSMinX(range)), NSMaxX(range));
    constrained.origin.y = MIN(MAX(proposedBounds.origin.y, NSMinY(range)), NSMaxY(range));
    return constrained;
}

typedef enum { WKInsetAnchorMin, WKInsetAnchorMax, WKInsetAnchorSpan } WKInsetAnchor;

// Moves a frame tiled in the scroll view's bounds to where tiling in the inset rectangle puts it: a view
// anchored to an edge moves in by that edge's inset, and a view spanning the axis loses both.
static NSRect wkInsetFrame(NSRect frame, WKInsetAnchor anchorX, CGFloat minXInset, CGFloat maxXInset, WKInsetAnchor anchorY, CGFloat minYInset, CGFloat maxYInset)
{
    if (anchorX == WKInsetAnchorMax)
        frame.origin.x -= maxXInset;
    else
        frame.origin.x += minXInset;
    if (anchorX == WKInsetAnchorSpan)
        frame.size.width = MAX(0, frame.size.width - minXInset - maxXInset);
    if (anchorY == WKInsetAnchorMax)
        frame.origin.y -= maxYInset;
    else
        frame.origin.y += minYInset;
    if (anchorY == WKInsetAnchorSpan)
        frame.size.height = MAX(0, frame.size.height - minYInset - maxYInset);
    return frame;
}

static void wkInsetSibling(NSView *view, NSScrollView *scrollView, NSEdgeInsets insets, WKInsetAnchor anchorX, WKInsetAnchor anchorY)
{
    if (!view || [view superview] != scrollView)
        return;
    BOOL flipped = [scrollView isFlipped];
    [view setFrame:wkInsetFrame([view frame], anchorX, insets.left, insets.right,
        anchorY, flipped ? insets.top : insets.bottom, flipped ? insets.bottom : insets.top)];
}

// The edge of the scroll view a view along one side of it sits against.
static WKInsetAnchor wkInsetSideAnchorX(NSView *view, NSScrollView *scrollView)
{
    return NSMidX([view frame]) > NSMidX([scrollView bounds]) ? WKInsetAnchorMax : WKInsetAnchorMin;
}

static void wkScrollViewInsetSiblings(NSScrollView *scrollView, NSEdgeInsets insets)
{
    WKInsetAnchor top = [scrollView isFlipped] ? WKInsetAnchorMin : WKInsetAnchorMax;
    WKInsetAnchor bottom = top == WKInsetAnchorMin ? WKInsetAnchorMax : WKInsetAnchorMin;

    if ([scrollView hasVerticalScroller]) {
        NSScroller *scroller = [scrollView verticalScroller];
        wkInsetSibling(scroller, scrollView, insets, wkInsetSideAnchorX(scroller, scrollView), WKInsetAnchorSpan);
    }
    if ([scrollView hasHorizontalScroller])
        wkInsetSibling([scrollView horizontalScroller], scrollView, insets, WKInsetAnchorSpan, bottom);
    if ([scrollView rulersVisible]) {
        if ([scrollView hasHorizontalRuler])
            wkInsetSibling([scrollView horizontalRulerView], scrollView, insets, WKInsetAnchorSpan, top);
        if ([scrollView hasVerticalRuler]) {
            NSRulerView *ruler = [scrollView verticalRulerView];
            wkInsetSibling(ruler, scrollView, insets, wkInsetSideAnchorX(ruler, scrollView), WKInsetAnchorSpan);
        }
    }
    NSView *documentView = [scrollView documentView];
    if ([documentView isKindOfClass:[NSTableView class]]) {
        wkInsetSibling([[(NSTableView *)documentView headerView] superview], scrollView, insets, WKInsetAnchorSpan, top);
        NSView *cornerView = [(NSTableView *)documentView cornerView];
        if (cornerView)
            wkInsetSibling(cornerView, scrollView, insets, wkInsetSideAnchorX(cornerView, scrollView), top);
    }
}

// Runs after NSScrollView's own -tile.
static void wkScrollViewApplyStoredContentInsets(NSScrollView *scrollView)
{
    NSEdgeInsets insets = wkScrollViewContentInsets(scrollView);
    NSClipView *clipView = [scrollView contentView];
    if (!wkEdgeInsetsAreZero(insets)) {
        wkScrollViewInsetSiblings(scrollView, insets);
        wkReclass(clipView, wkInsetClipViewClassPrefix, sizeof(wkInsetClipViewClassPrefix) - 1, @selector(constrainBoundsRect:), (IMP)wkInsetClipViewConstrainBoundsRect);
    }
    if (!wkParentOfClassWithPrefix(clipView, wkInsetClipViewClassPrefix, sizeof(wkInsetClipViewClassPrefix) - 1))
        return;
    NSRect bounds = [clipView bounds];
    NSRect constrained = [clipView constrainBoundsRect:bounds];
    if (!NSEqualPoints(constrained.origin, bounds.origin)) {
        [clipView setBoundsOrigin:constrained.origin];
        [scrollView reflectScrolledClipView:clipView];
    }
}

static void wkInsetScrollViewTile(NSScrollView *self, SEL _cmd)
{
    struct objc_super superContext = { self, wkParentOfClassWithPrefix(self, wkInsetScrollViewClassPrefix, sizeof(wkInsetScrollViewClassPrefix) - 1) };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superContext, _cmd);
    wkScrollViewApplyStoredContentInsets(self);
}

static void wkInsetScrollViewTileThroughWebKitOverride(NSScrollView *self, SEL _cmd)
{
    struct objc_super superContext = { self, wkParentOfClassWithPrefix(self, wkInsetScrollViewClassPrefix, sizeof(wkInsetScrollViewClassPrefix) - 1) };
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superContext, _cmd);
}

// The dynamic subclass's -tile for a scroll view of this class. In this image @selector(tile) names the
// REPLACE body's selector, which a WebKit subclass overriding -tile answers with its own implementation.
static IMP wkInsetScrollViewTileFor(Class scrollViewClass)
{
    BOOL hasWebKitOverride = class_getMethodImplementation(scrollViewClass, @selector(tile))
        != class_getMethodImplementation([NSScrollView class], @selector(tile));
    return hasWebKitOverride ? (IMP)wkInsetScrollViewTileThroughWebKitOverride : (IMP)wkInsetScrollViewTile;
}

// The bounds origin a clip view rests at on each axis's leading edge (the left edge, and the top edge)
// under the given insets.
static NSPoint wkClipViewLeadingOrigin(NSClipView *clipView, NSEdgeInsets insets)
{
    NSRect range = wkClipViewInsetBoundsOriginRange(clipView, [clipView bounds].size, insets);
    return NSMakePoint(NSMinX(range), [clipView isFlipped] ? NSMinY(range) : NSMaxY(range));
}

static void wkScrollViewSetContentInsets(NSScrollView *scrollView, NSEdgeInsets contentInsets)
{
    NSClipView *clipView = [scrollView contentView];
    BOOL hasDocument = [clipView documentView] != nil;
    NSPoint oldLeading = hasDocument ? wkClipViewLeadingOrigin(clipView, wkScrollViewContentInsets(scrollView)) : NSZeroPoint;
    NSPoint origin = [clipView bounds].origin;
    BOOL wasAtLeadingX = hasDocument && origin.x <= oldLeading.x;
    BOOL wasAtLeadingY = hasDocument && ([clipView isFlipped] ? origin.y <= oldLeading.y : origin.y >= oldLeading.y);

    objc_setAssociatedObject(scrollView, &wkScrollViewInsetsKey,
        [NSValue valueWithBytes:&contentInsets objCType:@encode(NSEdgeInsets)],
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // AppKit's own -tile, named by string: the polyfill rewrites @selector(tile) to the REPLACE body's selector.
    if (!wkEdgeInsetsAreZero(contentInsets))
        wkReclass(scrollView, wkInsetScrollViewClassPrefix, sizeof(wkInsetScrollViewClassPrefix) - 1, sel_registerName("tile"), wkInsetScrollViewTileFor(object_getClass(scrollView)));
    [scrollView tile];

    clipView = [scrollView contentView];
    if (!wasAtLeadingX && !wasAtLeadingY)
        return;
    NSPoint leading = wkClipViewLeadingOrigin(clipView, contentInsets);
    NSPoint pinned = [clipView bounds].origin;
    if (wasAtLeadingX)
        pinned.x = leading.x;
    if (wasAtLeadingY)
        pinned.y = leading.y;
    if (!NSEqualPoints(pinned, [clipView bounds].origin)) {
        [clipView setBoundsOrigin:pinned];
        [scrollView reflectScrolledClipView:clipView];
    }
}

#endif // WK_SCROLLVIEW_INSET_TILE_H
