// 10.9 backport: minimal implementation of WebCoreCALayerExtras category.
#include "config.h"
#include "WebCoreCALayerExtras.h"

#import <QuartzCore/QuartzCore.h>

@implementation CALayer (WebCoreCALayerExtras)

+ (CALayer *)_web_renderLayerWithContextID:(uint32_t)contextID shouldPreserveFlip:(BOOL)preservesFlip
{
    UNUSED_PARAM(contextID);
    UNUSED_PARAM(preservesFlip);
    return [CALayer layer];
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

- (BOOL)_web_maskContainsPoint:(CGPoint)point
{
    UNUSED_PARAM(point);
    return YES;
}

- (BOOL)_web_maskMayIntersectRect:(CGRect)rect
{
    UNUSED_PARAM(rect);
    return YES;
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

void collectDescendantLayersAtPoint(Vector<LayerAndPoint, 16>&, CALayer*, CGPoint, const std::function<bool(CALayer*, CGPoint)>&)
{
}

Vector<LayerAndPoint, 16> layersAtPointToCheckForScrolling(std::function<bool(CALayer*, CGPoint)>, std::function<std::optional<ScrollingNodeID>(CALayer*)>, CALayer*, const FloatPoint&, bool& hasAnyNonInteractiveScrollingLayers)
{
    hasAnyNonInteractiveScrollingLayers = false;
    return { };
}

} // namespace WebCore
