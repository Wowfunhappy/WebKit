// MAVERICKS_BACKPORT: minimal implementation of WebCoreCALayerExtras category.
#include "config.h"
#include "WebCoreCALayerExtras.h"

#import "TransformationMatrix.h"
// MAVERICKS_BACKPORT: include the public QuartzCore umbrella directly; the upstream
// PAL QuartzCoreSPI.h header pulls in newer-SDK-only CA SPI not present on 10.9.
#import <QuartzCore/QuartzCore.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

@implementation CALayer (WebCoreCALayerExtras)

// MAVERICKS_BACKPORT: explanatory note for the CALayerHost-based remote-layer hosting below.
// CALayerHost (private CoreAnimation class, declared in the force-included compat
// header / CA SPI) displays a layer tree rendered in another process: the
// WebContent process renders into a CAContext and sends its 32-bit contextId
// across; a CALayerHost with that contextId shows it here in the UI process.

+ (CALayer *)_web_renderLayerWithContextID:(uint32_t)contextID shouldPreserveFlip:(BOOL)preservesFlip
{
    // MAVERICKS_BACKPORT: the previous stub returned an empty [CALayer layer], ignoring
    // the contextID — so the WebContent process's rendered content was never shown
    // and the WKView painted blank. Host the remote CAContext for real.
    CALayerHost *layer = [CALayerHost layer];
    layer.contextId = contextID;
    UNUSED_PARAM(preservesFlip);
    return layer;
}

- (void)web_disableAllActions
{
    // MAVERICKS_BACKPORT: disable implicit animations via the layer's -actions map (10.9-native)
    // rather than the upstream -style/@"actions" nested dictionary; sets only properties
    // this build actually animates.
    self.actions = @{
        @"anchorPoint": [NSNull null],
        @"backgroundColor": [NSNull null],
        @"bounds": [NSNull null],
        @"contents": [NSNull null],
        @"contentsRect": [NSNull null],
        @"contentsScale": [NSNull null],
        @"hidden": [NSNull null],
        @"masksToBounds": [NSNull null],
        @"opacity": [NSNull null],
        @"position": [NSNull null],
        @"shadowColor": [NSNull null],
        @"sublayerTransform": [NSNull null],
        @"sublayers": [NSNull null],
        @"transform": [NSNull null],
        @"zPosition": [NSNull null],
    };
}

- (void)_web_setLayerBoundsOrigin:(CGPoint)origin
{
    // MAVERICKS_BACKPORT: bounds origin set via dot-syntax accessors (10.9-native CALayer geometry).
    CGRect bounds = self.bounds;
    bounds.origin = origin;
    self.bounds = bounds;
}

- (void)_web_setLayerTopLeftPosition:(CGPoint)position
{
    // MAVERICKS_BACKPORT: top-left position computed via dot-syntax accessors (no NaN
    // logging/assert path); all CALayer geometry properties used here are 10.9-native.
    CGRect bounds = self.bounds;
    CGPoint anchor = self.anchorPoint;
    self.position = CGPointMake(position.x + anchor.x * bounds.size.width,
                                position.y + anchor.y * bounds.size.height);
}

- (BOOL)_web_maskContainsPoint:(CGPoint)point
{
    if (!self.mask)
        return NO;

    CGPoint pointInMask = [self.mask convertPoint:point fromLayer:self];
    if (RetainPtr shapeMask = dynamic_objc_cast<CAShapeLayer>(self.mask)) {
        bool isEvenOddFill = [shapeMask.get().fillRule isEqualToString:kCAFillRuleEvenOdd];
        return CGPathContainsPoint(shapeMask.get().path, nullptr, pointInMask, isEvenOddFill);
    }

    return [self.mask containsPoint:pointInMask];
}

- (BOOL)_web_maskMayIntersectRect:(CGRect)rect
{
    if (!self.mask)
        return NO;

    CGRect rectInMask = [self.mask convertRect:rect fromLayer:self];
    if (RetainPtr shapeMask = dynamic_objc_cast<CAShapeLayer>(self.mask)) {
        CGRect pathBounds = CGPathGetPathBoundingBox(shapeMask.get().path);
        return CGRectIntersectsRect(pathBounds, rectInMask);
    }

    return CGRectIntersectsRect(self.mask.bounds, rectInMask);
}

- (void)_web_clearContents
{
    self.contents = nil;
    // MAVERICKS_BACKPORT: just drop the contents; the upstream contentsOpaque reset, the
    // RE_DYNAMIC_CONTENT_SCALING display-list clear, and the SUPPORT_HDR_DISPLAY_APIS
    // contentsHeadroom reset all rely on newer-SDK CALayer surface not present on 10.9.
    // MAVERICKS_BACKPORT: end _web_clearContents (the newer-SDK resets above are intentionally dropped).
}

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
- (void)_web_clearDynamicContentScalingDisplayListIfNeeded
{
    // MAVERICKS_BACKPORT: no-op; the WKDynamicContentScaling* CALayer key paths it would
    // clear do not exist on 10.9 (dynamic content scaling is unsupported on this build).
}
#endif

@end

namespace WebCore {

static void collectDescendantLayersAtPointRecursive(Vector<LayerAndPoint, 16>& layersAtPoint, CALayer *parent, CGPoint point, const std::function<bool(CALayer *, CGPoint)>& pointInLayerFunction)
{
    if (parent.masksToBounds && ![parent containsPoint:point])
        return;

    if (parent.mask && ![parent _web_maskContainsPoint:point])
        return;

    RetainPtr sublayers = adoptNS([[parent sublayers] copy]);
    for (CALayer* layer : sublayers.get()) {
        RetainPtr layerWithResolvedAnimations = layer;

        if ([[layer animationKeys] count])
            layerWithResolvedAnimations = [layer presentationLayer];

        auto transform = TransformationMatrix { [layerWithResolvedAnimations transform] };
        if (!transform.isInvertible())
            continue;

        CGPoint subviewPoint = [layerWithResolvedAnimations convertPoint:point fromLayer:parent];

        auto handlesEvent = [&] {
            if (CGRectIsEmpty([layerWithResolvedAnimations frame]))
                return false;

            if (![layerWithResolvedAnimations containsPoint:subviewPoint])
                return false;

            if (pointInLayerFunction)
                return pointInLayerFunction(layer, subviewPoint);

            return true;
        }();

        if (handlesEvent)
            layersAtPoint.append(std::make_pair(layer, subviewPoint));

        if ([layer sublayers])
            collectDescendantLayersAtPointRecursive(layersAtPoint, layer, subviewPoint, pointInLayerFunction);
    };
}

// MAVERICKS_BACKPORT: bracket the whole layer-tree hit-test in an explicit CATransaction at this
// shared choke point. The traversal reads -[CALayer presentationLayer] for animated layers, which
// lazily begins an implicit CATransaction on the calling thread. WebKit runs this hit-test off the
// main thread — the EventDispatcher / scrolling thread, via ScrollingTreeMac and (UI-side
// compositing) RemoteScrollingTreeMac — where there is no run loop or CA commit observer, so on
// 10.9 the implicit transaction is never committed: it lingers holding CA's transaction lock,
// deadlocks against the main thread's render commit (intermittent scroll freeze), and logs
// "deleted thread with uncommitted CATransaction" when the thread is torn down. Modern CA cleans up
// secondary-thread transactions itself; 10.9 does not. Scoping one explicit transaction here
// commits it on the calling thread instead of orphaning it, and covers every off-main caller by
// construction. The hit-test only reads layer geometry, so the commit has nothing to flush (and the
// lone main-thread caller merely nests a no-op commit).
void collectDescendantLayersAtPoint(Vector<LayerAndPoint, 16>& layersAtPoint, CALayer *parent, CGPoint point, const std::function<bool(CALayer *, CGPoint)>& pointInLayerFunction)
{
    [CATransaction begin];
    collectDescendantLayersAtPointRecursive(layersAtPoint, parent, point, pointInLayerFunction);
    [CATransaction commit];
}

Vector<LayerAndPoint, 16> layersAtPointToCheckForScrolling(std::function<bool(CALayer*, CGPoint)> layerEventRegionContainsPoint, std::function<std::optional<ScrollingNodeID>(CALayer*)> scrollingNodeIDForLayer, CALayer* layer, const FloatPoint& point, bool& hasAnyNonInteractiveScrollingLayers)
{
    Vector<LayerAndPoint, 16> layersAtPoint;
    collectDescendantLayersAtPoint(layersAtPoint, layer, point, [&] (auto layer, auto point) {
        if (layerEventRegionContainsPoint(layer, point))
            return true;
        if (scrollingNodeIDForLayer(layer)) {
            hasAnyNonInteractiveScrollingLayers = true;
            return true;
        }
        return false;
    });
    // Hit-test front to back.
    layersAtPoint.reverse();
    return layersAtPoint;
}

} // namespace WebCore
