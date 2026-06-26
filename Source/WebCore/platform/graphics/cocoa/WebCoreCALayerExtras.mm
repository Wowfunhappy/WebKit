// MAVERICKS_BACKPORT: minimal implementation of WebCoreCALayerExtras category.
#include "config.h"
#include "WebCoreCALayerExtras.h"

#import "TransformationMatrix.h"
#import <QuartzCore/QuartzCore.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

// CALayerHost (private CoreAnimation class, declared in the force-included compat
// header / CA SPI) displays a layer tree rendered in another process: the
// WebContent process renders into a CAContext and sends its 32-bit contextId
// across; a CALayerHost with that contextId shows it here in the UI process.

@implementation CALayer (WebCoreCALayerExtras)

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
    CGRect bounds = self.bounds;
    bounds.origin = origin;
    self.bounds = bounds;
}

- (void)_web_setLayerTopLeftPosition:(CGPoint)position
{
    CGRect bounds = self.bounds;
    CGPoint anchor = self.anchorPoint;
    self.position = CGPointMake(position.x + anchor.x * bounds.size.width,
                                position.y + anchor.y * bounds.size.height);
}

// MAVERICKS_BACKPORT: the only consumer of these two mask hit-test methods is the
// iOS RemoteLayerTree path (RemoteLayerTreeViews.mm, guarded #if PLATFORM(IOS_FAMILY)),
// so they are never invoked on this Mac build. They are kept at the upstream bodies
// (CAShapeLayer / CGPathContainsPoint / CGRectIntersectsRect — all 10.9-native) rather
// than a blanket "return YES", which would be a wrong-answer landmine if ever reached.
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
}

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
- (void)_web_clearDynamicContentScalingDisplayListIfNeeded
{
}
#endif

@end

namespace WebCore {

void collectDescendantLayersAtPoint(Vector<LayerAndPoint, 16>& layersAtPoint, CALayer *parent, CGPoint point, const std::function<bool(CALayer *, CGPoint)>& pointInLayerFunction)
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
            collectDescendantLayersAtPoint(layersAtPoint, layer, subviewPoint, pointInLayerFunction);
    };
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
