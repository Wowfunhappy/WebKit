/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "WebTextIndicatorLayer.h"

#import "GeometryUtilities.h"
#import "GraphicsContext.h"
#import "NativeImage.h"
#import "PathUtilities.h"
#import "TextIndicator.h"
#import "WebActionDisablingCALayerDelegate.h"
#import <pal/spi/cg/CoreGraphicsSPI.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>

#if PLATFORM(MAC)
#import <pal/spi/mac/NSColorSPI.h>
#endif

constexpr CFTimeInterval bounceWithCrossfadeAnimationDuration = 0.3;
constexpr CFTimeInterval fadeInAnimationDuration = 0.15;
constexpr CFTimeInterval fadeOutAnimationDuration = 0.3;

constexpr CGFloat borderWidth = 0;
constexpr CGFloat cornerRadius = 3;
constexpr CGFloat dropShadowOffsetX = 0;
constexpr CGFloat dropShadowOffsetY = 1;
constexpr CGFloat lightBorderThickness = 1; // MAVERICKS_BACKPORT: 537 lightBorderThickness
constexpr CGFloat findIndicatorShadowBlurRadius = 3; // 537 shadowBlurRadius
constexpr CGFloat findIndicatorShadowAlpha = 204 / 255.; // 537 shadowAlpha

constexpr NSString * const textLayerKey = @"TextLayer";
constexpr NSString * const dropShadowLayerKey = @"DropShadowLayer";
constexpr NSString * const rimShadowLayerKey = @"RimShadowLayer";

@implementation WebTextIndicatorLayer

@synthesize fadingOut = _fadingOut;

static bool indicatorWantsContentCrossfade(const WebCore::TextIndicator& indicator)
{
    if (!indicator.data().contentImageWithHighlight)
        return false;

    switch (indicator.presentationTransition()) {
    case WebCore::TextIndicatorPresentationTransition::BounceAndCrossfade:
        return true;

    case WebCore::TextIndicatorPresentationTransition::Bounce:
    case WebCore::TextIndicatorPresentationTransition::FadeIn:
    case WebCore::TextIndicatorPresentationTransition::None:
        return false;
    }

    ASSERT_NOT_REACHED();
    return false;
}

static bool NODELETE indicatorWantsFadeIn(const WebCore::TextIndicator& indicator)
{
    switch (indicator.presentationTransition()) {
    case WebCore::TextIndicatorPresentationTransition::FadeIn:
        return true;

    case WebCore::TextIndicatorPresentationTransition::Bounce:
    case WebCore::TextIndicatorPresentationTransition::BounceAndCrossfade:
    case WebCore::TextIndicatorPresentationTransition::None:
        return false;
    }

    ASSERT_NOT_REACHED();
    return false;
}

- (void)updateWithFrame:(CGRect)frame textIndicator:(WebCore::TextIndicator*)textIndicator margin:(CGSize)margin offset:(CGPoint)offset updatingIndicator:(BOOL)updatingIndicator
{
    self.anchorPoint = CGPointZero;
    self.frame = frame;

    _textIndicator = textIndicator;
    _margin = margin;

    [self setDelegate:[WebActionDisablingCALayerDelegate shared]];

    RefPtr<WebCore::NativeImage> contentsImage;
    WebCore::FloatSize contentsImageLogicalSize { 1, 1 };
    if (RefPtr contentImage = _textIndicator->contentImage()) {
        contentsImageLogicalSize = contentImage->size();
        contentsImageLogicalSize.scale(1 / _textIndicator->contentImageScaleFactor());
        if (indicatorWantsContentCrossfade(*_textIndicator) && _textIndicator->contentImageWithHighlight())
            contentsImage = _textIndicator->contentImageWithHighlight()->nativeImage();
        else
            contentsImage = contentImage->nativeImage();
    }

    auto bounceLayers = adoptNS([[NSMutableArray alloc] init]);

    RetainPtr<CGColorRef> highlightColor;
    auto rimShadowColor = adoptCF(CGColorCreateGenericGray(0, 0.35));
    // MAVERICKS_BACKPORT: 537's shadow — opaque-ish black rather than upstream's 0.2 gray.
    // auto dropShadowColor = adoptCF(CGColorCreateGenericGray(0, 0.2));
    auto dropShadowColor = adoptCF(CGColorCreateGenericGray(0, findIndicatorShadowAlpha));
    auto borderColor = adoptCF(CGColorCreateSRGB(0.96, 0.9, 0, 1));
#if PLATFORM(MAC)
    // MAVERICKS_BACKPORT: 537's highlight gradient (242,239,0) -> (237,204,0). The flat
    // findHighlightColor below is the modern (10.13+) fill.
    auto highlightGradientTopColor = adoptCF(CGColorCreateSRGB(242 / 255., 239 / 255., 0, 1));
    auto highlightGradientBottomColor = adoptCF(CGColorCreateSRGB(237 / 255., 204 / 255., 0, 1));
    // highlightColor = [NSColor findHighlightColor].CGColor;
#else
    highlightColor = adoptCF(CGColorCreateSRGB(.99, .89, 0.22, 1.0));
#endif

    auto textRectsInBoundingRectCoordinates = _textIndicator->textRectsInBoundingRectCoordinates();

    auto paths = WebCore::PathUtilities::pathsWithShrinkWrappedRects(textRectsInBoundingRectCoordinates, cornerRadius);

    for (const auto& path : paths) {
        WebCore::FloatRect pathBoundingRect = path.boundingRect();

        WebCore::Path translatedPath;
        WebCore::AffineTransform transform;
        transform.translate(-pathBoundingRect.location());
        translatedPath.addPath(path, transform);

        WebCore::FloatRect offsetTextRect = pathBoundingRect;
        offsetTextRect.move(offset.x, offset.y);

        WebCore::FloatRect bounceLayerRect = offsetTextRect;
        bounceLayerRect.move(_margin.width, _margin.height);

        RetainPtr<CALayer> bounceLayer = adoptNS([[CALayer alloc] init]);
        [bounceLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        [bounceLayer setFrame:bounceLayerRect];
        if (updatingIndicator == NO)
            [bounceLayer setOpacity:0];
        [bounceLayers addObject:bounceLayer.get()];

        WebCore::FloatRect yellowHighlightRect(WebCore::FloatPoint(), bounceLayerRect.size());

#if PLATFORM(MAC)
        RetainPtr<CALayer> dropShadowLayer = adoptNS([[CALayer alloc] init]);
        [dropShadowLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        [dropShadowLayer setShadowColor:dropShadowColor.get()];
        // MAVERICKS_BACKPORT: 537's blur radius (3) rather than upstream's WebCore::dropShadowBlurRadius (2).
        // 537 drew the shadow with CGContextSetShadow, whose blur radius spans about twice a
        // CALayer shadowRadius, so halve it to land on the same spread.
        [dropShadowLayer setShadowRadius:findIndicatorShadowBlurRadius / 2];
        [dropShadowLayer setShadowOffset:CGSizeMake(dropShadowOffsetX, dropShadowOffsetY)];
        [dropShadowLayer setShadowPath:translatedPath.platformPath()];
        [dropShadowLayer setShadowOpacity:1];
        [dropShadowLayer setFrame:yellowHighlightRect];
        [bounceLayer addSublayer:dropShadowLayer.get()];
        [bounceLayer setValue:dropShadowLayer.get() forKey:dropShadowLayerKey];

        // MAVERICKS_BACKPORT: 537 cast a single shadow, so there is no rim shadow to draw. The
        // upstream rim-shadow layer is kept commented out; the crossfade animation looks it back up
        // by key and simply finds nothing.
        // RetainPtr<CALayer> rimShadowLayer = adoptNS([[CALayer alloc] init]);
        // [rimShadowLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        // [rimShadowLayer setFrame:yellowHighlightRect];
        // [rimShadowLayer setShadowColor:rimShadowColor.get()];
        // [rimShadowLayer setShadowRadius:WebCore::rimShadowBlurRadius];
        // [rimShadowLayer setShadowPath:translatedPath.platformPath()];
        // [rimShadowLayer setShadowOffset:CGSizeZero];
        // [rimShadowLayer setShadowOpacity:1];
        // [rimShadowLayer setFrame:yellowHighlightRect];
        // [bounceLayer addSublayer:rimShadowLayer.get()];
        // [bounceLayer setValue:rimShadowLayer.get() forKey:rimShadowLayerKey];

        // MAVERICKS_BACKPORT: 537 filled the outer rounded rect with the light border colour and
        // then filled the 1px-inset inner rect with a vertical gradient. Reproduce that as a
        // gradient layer masked to the shrink-wrapped path, plus a stroke of the same path on top:
        // the stroke is masked too, so only its inner half — one point — survives, which is the
        // light border. The text snapshot is layered over both.
        RetainPtr<CAGradientLayer> highlightLayer = adoptNS([[CAGradientLayer alloc] init]);
        [highlightLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        [highlightLayer setFrame:yellowHighlightRect];
        [highlightLayer setColors:@[ (__bridge id)highlightGradientTopColor.get(), (__bridge id)highlightGradientBottomColor.get() ]];
        [highlightLayer setStartPoint:CGPointMake(0.5, 0)];
        [highlightLayer setEndPoint:CGPointMake(0.5, 1)];
        RetainPtr<CAShapeLayer> highlightMaskLayer = adoptNS([[CAShapeLayer alloc] init]);
        [highlightMaskLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        [highlightMaskLayer setPath:translatedPath.platformPath()];
        [highlightLayer setMask:highlightMaskLayer.get()];
        [bounceLayer addSublayer:highlightLayer.get()];

        RetainPtr<CAShapeLayer> lightBorderLayer = adoptNS([[CAShapeLayer alloc] init]);
        [lightBorderLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        [lightBorderLayer setFrame:yellowHighlightRect];
        [lightBorderLayer setPath:translatedPath.platformPath()];
        [lightBorderLayer setFillColor:nil];
        [lightBorderLayer setStrokeColor:borderColor.get()];
        [lightBorderLayer setLineWidth:lightBorderThickness * 2];
        RetainPtr<CAShapeLayer> lightBorderMaskLayer = adoptNS([[CAShapeLayer alloc] init]);
        [lightBorderMaskLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        [lightBorderMaskLayer setPath:translatedPath.platformPath()];
        [lightBorderLayer setMask:lightBorderMaskLayer.get()];
        [bounceLayer addSublayer:lightBorderLayer.get()];
#endif // PLATFORM(MAC)

        RetainPtr<CALayer> textLayer = adoptNS([[CALayer alloc] init]);
        [textLayer setBackgroundColor:highlightColor.get()];
        [textLayer setBorderColor:borderColor.get()];
        [textLayer setBorderWidth:borderWidth];
        [textLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        if (contentsImage)
            [textLayer setContents:(__bridge id)contentsImage->platformImage().get()];

        RetainPtr<CAShapeLayer> maskLayer = adoptNS([[CAShapeLayer alloc] init]);
        [maskLayer setDelegate:[WebActionDisablingCALayerDelegate shared]];
        [maskLayer setPath:translatedPath.platformPath()];
        [textLayer setMask:maskLayer.get()];

        WebCore::FloatRect imageRect = pathBoundingRect;
        [textLayer setContentsRect:CGRectMake(imageRect.x() / contentsImageLogicalSize.width(), imageRect.y() / contentsImageLogicalSize.height(), imageRect.width() / contentsImageLogicalSize.width(), imageRect.height() / contentsImageLogicalSize.height())];
        [textLayer setContentsGravity:kCAGravityCenter];
        [textLayer setContentsScale:_textIndicator->contentImageScaleFactor()];
        [textLayer setFrame:yellowHighlightRect];
        [bounceLayer setValue:textLayer.get() forKey:textLayerKey];
        [bounceLayer addSublayer:textLayer.get()];
    }

    self.sublayers = bounceLayers.get();
    _bounceLayers = bounceLayers;

}

- (instancetype)initWithFrame:(CGRect)frame textIndicator:(RefPtr<WebCore::TextIndicator>)textIndicator margin:(CGSize)margin offset:(CGPoint)offset
{
    if (!(self = [super init]))
        return nil;

    self.name = @"WebTextIndicatorLayer";

    [self updateWithFrame:frame textIndicator:textIndicator.get() margin:margin offset:offset updatingIndicator:NO];

    return self;
}

static RetainPtr<CAKeyframeAnimation> createBounceAnimation(CFTimeInterval duration)
{
    RetainPtr bounceAnimation = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    [bounceAnimation setValues:@[
        [NSValue valueWithCATransform3D:CATransform3DIdentity],
        [NSValue valueWithCATransform3D:CATransform3DMakeScale(WebCore::midBounceScale, WebCore::midBounceScale, 1)],
        [NSValue valueWithCATransform3D:CATransform3DIdentity]
        ]];
    [bounceAnimation setDuration:duration];

    return bounceAnimation;
}

static RetainPtr<CABasicAnimation> createContentCrossfadeAnimation(CFTimeInterval duration, WebCore::TextIndicator& textIndicator)
{
    RetainPtr crossfadeAnimation = [CABasicAnimation animationWithKeyPath:@"contents"];
    RefPtr contentsImage = protect(textIndicator.contentImage())->nativeImage();
    [crossfadeAnimation setToValue:(__bridge id)contentsImage->platformImage().get()];
    [crossfadeAnimation setFillMode:kCAFillModeForwards];
    [crossfadeAnimation setRemovedOnCompletion:NO];
    [crossfadeAnimation setDuration:duration];

    return crossfadeAnimation;
}

static RetainPtr<CABasicAnimation> createShadowFadeAnimation(CFTimeInterval duration)
{
    RetainPtr<CABasicAnimation> fadeShadowInAnimation = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    [fadeShadowInAnimation setFromValue:@0];
    [fadeShadowInAnimation setToValue:@1];
    [fadeShadowInAnimation setFillMode:kCAFillModeForwards];
    [fadeShadowInAnimation setRemovedOnCompletion:NO];
    [fadeShadowInAnimation setDuration:duration];

    return fadeShadowInAnimation;
}

static RetainPtr<CABasicAnimation> createFadeInAnimation(CFTimeInterval duration)
{
    RetainPtr<CABasicAnimation> fadeInAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    [fadeInAnimation setFromValue:@0];
    [fadeInAnimation setToValue:@1];
    [fadeInAnimation setFillMode:kCAFillModeForwards];
    [fadeInAnimation setRemovedOnCompletion:NO];
    [fadeInAnimation setDuration:duration];

    return fadeInAnimation;
}

- (CFTimeInterval)_animationDuration
{
    if (_textIndicator->wantsBounce()) {
        if (indicatorWantsContentCrossfade(*_textIndicator))
            return bounceWithCrossfadeAnimationDuration;
        return WebCore::bounceAnimationDuration.value();
    }

    return fadeInAnimationDuration;
}

- (BOOL)hasCompletedAnimation
{
    return _hasCompletedAnimation;
}

- (void)present
{
    RefPtr textIndicator = _textIndicator;
    bool wantsBounce = textIndicator->wantsBounce();
    bool wantsCrossfade = indicatorWantsContentCrossfade(*textIndicator);
    bool wantsFadeIn = indicatorWantsFadeIn(*textIndicator);
    CFTimeInterval animationDuration = [self _animationDuration];

    _hasCompletedAnimation = false;

    RetainPtr<CAAnimation> presentationAnimation;
    if (wantsBounce)
        presentationAnimation = createBounceAnimation(animationDuration);
    else if (wantsFadeIn)
        presentationAnimation = createFadeInAnimation(animationDuration);

    RetainPtr<CABasicAnimation> crossfadeAnimation;
    RetainPtr<CABasicAnimation> fadeShadowInAnimation;
    if (wantsCrossfade) {
        crossfadeAnimation = createContentCrossfadeAnimation(animationDuration, *textIndicator);
        fadeShadowInAnimation = createShadowFadeAnimation(animationDuration);
    }

    [CATransaction begin];
    for (CALayer *bounceLayer in _bounceLayers.get()) {
        if (textIndicator->wantsManualAnimation())
            bounceLayer.speed = 0;

        if (!wantsFadeIn)
            bounceLayer.opacity = 1;

        if (presentationAnimation)
            [bounceLayer addAnimation:presentationAnimation.get() forKey:@"presentation"];

        if (wantsCrossfade) {
            [[bounceLayer valueForKey:textLayerKey] addAnimation:crossfadeAnimation.get() forKey:@"contentTransition"];
            [[bounceLayer valueForKey:dropShadowLayerKey] addAnimation:fadeShadowInAnimation.get() forKey:@"fadeShadowIn"];
            [[bounceLayer valueForKey:rimShadowLayerKey] addAnimation:fadeShadowInAnimation.get() forKey:@"fadeShadowIn"];
        }
    }
    [CATransaction commit];
}

- (void)hideWithCompletionHandler:(void(^)(void))completionHandler
{
    RetainPtr<CABasicAnimation> fadeAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    [fadeAnimation setFromValue:@1];
    [fadeAnimation setToValue:@0];
    [fadeAnimation setFillMode:kCAFillModeForwards];
    [fadeAnimation setRemovedOnCompletion:NO];
    [fadeAnimation setDuration:fadeOutAnimationDuration];

    [CATransaction begin];
    [CATransaction setCompletionBlock:completionHandler];
    [self addAnimation:fadeAnimation.get() forKey:@"fadeOut"];
    [CATransaction commit];
}

- (void)setAnimationProgress:(float)progress
{
    if (_hasCompletedAnimation)
        return;

    if (progress == 1) {
        _hasCompletedAnimation = true;

        for (CALayer *bounceLayer in _bounceLayers.get()) {
            // Continue the animation from wherever it had manually progressed to.
            CFTimeInterval beginTime = bounceLayer.timeOffset;
            bounceLayer.speed = 1;
            beginTime = [bounceLayer convertTime:CACurrentMediaTime() fromLayer:nil] - beginTime;
            bounceLayer.beginTime = beginTime;
        }
    } else {
        CFTimeInterval animationDuration = [self _animationDuration];
        for (CALayer *bounceLayer in _bounceLayers.get())
            bounceLayer.timeOffset = progress * animationDuration;
    }
}

@end
