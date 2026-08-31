/*
 * Copyright (C) 2013-2017 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#import "config.h"
#import "WebCoreCALayerExtras.h"

#import "DynamicContentScalingTypes.h"
#import "TransformationMatrix.h"
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/cocoa/TypeCastsCocoa.h>

@implementation CALayer (WebCoreCALayerExtras)

- (void)web_disableAllActions
{
    NSNull *nullValue = [NSNull null];
    self.style = @{
        @"actions" : @{
            @"anchorPoint" : nullValue,
            @"anchorPointZ" : nullValue,
            @"backgroundColor" : nullValue,
            @"borderColor" : nullValue,
            @"borderWidth" : nullValue,
            @"bounds" : nullValue,
            @"contents" : nullValue,
            @"contentsRect" : nullValue,
            @"contentsScale" : nullValue,
            @"cornerRadius" : nullValue,
            @"opacity" : nullValue,
            @"position" : nullValue,
            @"shadowColor" : nullValue,
            @"sublayerTransform" : nullValue,
            @"sublayers" : nullValue,
            @"transform" : nullValue,
            @"zPosition" : nullValue
        }
    };
}

- (void)_web_setLayerBoundsOrigin:(CGPoint)origin
{
    CGRect bounds = [self bounds];
    bounds.origin = origin;
    [self setBounds:bounds];
}

- (void)_web_setLayerTopLeftPosition:(CGPoint)position
{
    CGSize layerSize = [self bounds].size;
    CGPoint anchorPoint = [self anchorPoint];
    CGPoint newPosition = CGPointMake(position.x + anchorPoint.x * layerSize.width, position.y + anchorPoint.y * layerSize.height);
    if (isnan(newPosition.x) || isnan(newPosition.y)) {
        WTFLogAlways("Attempt to call [CALayer setPosition] with NaN: newPosition=(%f, %f) position=(%f, %f) anchorPoint=(%f, %f)",
            newPosition.x, newPosition.y, position.x, position.y, anchorPoint.x, anchorPoint.y);
        ASSERT_NOT_REACHED();
        return;
    }
    
    [self setPosition:newPosition];
}

+ (CALayer *)_web_renderLayerWithContextID:(uint32_t)contextID shouldPreserveFlip:(BOOL)preservesFlip
{
    CALayerHost *layerHost = [CALayerHost layer];
#ifndef NDEBUG
    [layerHost setName:@"Hosting layer"];
#endif
    layerHost.contextId = contextID;
    layerHost.preservesFlip = preservesFlip;
    return layerHost;
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
    self.contentsOpaque = NO;

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
    [self _web_clearDynamicContentScalingDisplayListIfNeeded];
#endif

#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    self.contentsHeadroom = 0;
#endif
}

#if ENABLE(RE_DYNAMIC_CONTENT_SCALING)
- (void)_web_clearDynamicContentScalingDisplayListIfNeeded
{
    if (![self valueForKeyPath:WKDynamicContentScalingContentsKey])
        return;
    [self setValue:nil forKeyPath:WKDynamicContentScalingContentsKey];
    [self setValue:nil forKeyPath:WKDynamicContentScalingPortsKey];
    [self setValue:@NO forKeyPath:WKDynamicContentScalingEnabledKey];
    [self setValue:@NO forKeyPath:WKDynamicContentScalingBifurcationEnabledKey];
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
    // MAVERICKS_BACKPORT: own the transaction this traversal would otherwise orphan.
    // -[CALayer presentationLayer] (read below for animating layers) is the one CALayer accessor that
    // lazily BEGINS an implicit CATransaction. 10.9's CA commits a thread's implicit transaction from an
    // observer it installs on that thread's run loop, so a thread that never runs one never commits:
    // this hit-test runs on the EventDispatcher thread (a WorkQueue worker, CFRunLoopCopyCurrentMode ==
    // NULL), which leaves the transaction open until the thread is torn down -- logged by CA as
    // "deleted thread with uncommitted CATransaction" and observed as an intermittent scroll freeze over
    // animating content.
    //
    // An explicit transaction around the WHOLE traversal is the fix rather than a flush inside the read:
    // committing between reads detaches the presentation snapshots, after which
    // -convertPoint:fromLayer: returns unconverted points and the hit-test silently changes results
    // (measured). Bracketing instead keeps every snapshot attached for the traversal, and ends the
    // transaction deterministically at a point this code controls, on any thread.
    // Only when this thread has no run loop. CA installs its commit observer on any thread that RUNS one
    // and commits that thread's implicit transaction from it, so on such a thread ending the transaction
    // is CA's job and committing here would race its observer. That includes the UI-process main thread,
    // which reaches this same hit-test through RemoteScrollingCoordinatorProxy::handleWheelEvent ->
    // RemoteScrollingTreeMac::scrollingNodeForPoint inside AppKit event handling. The orphan only happens
    // on a thread with NO run loop — the EventDispatcher WorkQueue worker, where
    // CFRunLoopCopyCurrentMode() is NULL — so that is the only thread this brackets.
    RetainPtr<CFStringRef> runLoopMode = adoptCF(CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()));
    bool ownTransaction = !runLoopMode;
    if (ownTransaction)
        [CATransaction begin];
    collectDescendantLayersAtPoint(layersAtPoint, layer, point, [&] (auto layer, auto point) {
        if (layerEventRegionContainsPoint(layer, point))
            return true;
        if (scrollingNodeIDForLayer(layer)) {
            hasAnyNonInteractiveScrollingLayers = true;
            return true;
        }
        return false;
    });
    // MAVERICKS_BACKPORT: closes the transaction opened above, ending it on this thread rather than
    // leaving it for a run-loop observer that a WorkQueue worker never reaches.
    if (ownTransaction)
        [CATransaction commit];
    // Hit-test front to back.
    layersAtPoint.reverse();
    return layersAtPoint;
}

} // namespace WebCore
