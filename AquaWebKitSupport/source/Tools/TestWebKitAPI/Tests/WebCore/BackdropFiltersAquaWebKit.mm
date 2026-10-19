#include "config.h"

#include "Helpers/Test.h"
#include <WebCore/FloatRoundedRect.h>
#include <WebCore/FilterOperations.h>
#include <WebCore/GraphicsLayer.h>
#include <WebCore/GraphicsLayerClient.h>
#include <WebCore/PlatformCAAnimation.h>
#include <WebCore/PlatformCAFilters.h>
#import <WebCore/WebBackdropLayerAquaWebKit.h>
#import <WebCore/WebCoreCALayerExtras.h>
#import <objc/runtime.h>
#include <set>

namespace TestWebKitAPI {
using namespace WebCore;

TEST(BackdropFiltersAquaWebKit, FiltersApplyToTheBackdrop)
{
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    RetainPtr foreground = adoptNS([[CALayer alloc] init]);
    FilterOperations blur { { BlurFilterOperation::create(8) } };
    PlatformCAFilters::setFiltersOnLayer(foreground.get(), blur, true);
    ASSERT_EQ(1U, [[foreground filters] count]);
    EXPECT_EQ(0U, [[foreground backgroundFilters] count]);

    // As on CABackdropLayer, filters set on the layer apply to the backdrop.
    [backdrop setFilters:[foreground filters]];
    EXPECT_EQ(0U, [[backdrop filters] count]);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), { }, true);
    EXPECT_EQ(0U, [[backdrop filters] count]);
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), blur, true);
    EXPECT_EQ(0U, [[backdrop filters] count]);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
}

TEST(BackdropFiltersAquaWebKit, HiddenLayerHasNoBackgroundFilters)
{
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    FilterOperations blur { { BlurFilterOperation::create(8) } };
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), blur, true);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);

    [backdrop setHidden:YES];
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);

    // Filters assigned while hidden take effect when the layer is shown.
    FilterOperations twoBlurs { { BlurFilterOperation::create(8), BlurFilterOperation::create(4) } };
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), twoBlurs, true);
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);
    [backdrop setHidden:NO];
    EXPECT_EQ(2U, [[backdrop backgroundFilters] count]);

    // Copies made by initWithLayer: carry the assigned filters and the same hidden behavior.
    RetainPtr visibleCopy = adoptNS([[WebBackdropLayerAquaWebKit alloc] initWithLayer:backdrop.get()]);
    EXPECT_EQ(2U, [[visibleCopy backgroundFilters] count]);

    [backdrop setHidden:YES];
    RetainPtr copyOfHidden = adoptNS([[WebBackdropLayerAquaWebKit alloc] initWithLayer:backdrop.get()]);
    EXPECT_EQ([copyOfHidden isHidden] ? 0U : 2U, [[copyOfHidden backgroundFilters] count]);
    [copyOfHidden setHidden:YES];
    EXPECT_EQ(0U, [[copyOfHidden backgroundFilters] count]);
    [copyOfHidden setHidden:NO];
    EXPECT_EQ(2U, [[copyOfHidden backgroundFilters] count]);
}

TEST(BackdropFiltersAquaWebKit, AnimationKeyPaths)
{
    auto foreground = PlatformCAAnimation::makeKeyPath(AnimatedProperty::Filter, FilterOperation::Type::Blur, 2);
    auto backdrop = PlatformCAAnimation::makeKeyPath(AnimatedProperty::WebkitBackdropFilter, FilterOperation::Type::Blur, 2);
    EXPECT_EQ("filters.filter_2.inputRadius"_s, foreground);
    EXPECT_EQ("backgroundFilters.filter_2.inputRadius"_s, backdrop);
    EXPECT_TRUE(PlatformCAAnimation::isValidKeyPath(foreground));
    EXPECT_TRUE(PlatformCAAnimation::isValidKeyPath(backdrop));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_.inputRadius"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_-1.inputRadius"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_0.invalidProperty"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters.filter_0.inputRadius.extra"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath("backgroundFilters"_s));
    EXPECT_FALSE(PlatformCAAnimation::isValidKeyPath(backdrop, PlatformCAAnimation::AnimationType::Group));
}

TEST(BackdropFiltersAquaWebKit, OpacityAloneLeavesNoBackgroundFilters)
{
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BasicComponentTransferFilterOperation::create(0.5, FilterOperation::Type::Opacity) } }, true);
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);
}

static RetainPtr<CALayer> makeLayer(Class layerClass, CGRect frame)
{
    RetainPtr layer = adoptNS([[layerClass alloc] init]);
    [layer setAnchorPoint:CGPointZero];
    [layer setFrame:frame];
    return layer;
}

static CABasicAnimation *translation(CGFloat x)
{
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
    animation.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    animation.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(x, 0, 0)];
    animation.beginTime = 1;
    animation.duration = 10;
    return animation;
}

TEST(BackdropFiltersAquaWebKit, SingularTransformOnThePathHasNoBackgroundFilters)
{
    RetainPtr surface = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr host = makeLayer(CATransformLayer.class, CGRectMake(30, 40, 200, 100));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    [host addSublayer:backdrop.get()];
    [surface addSublayer:host.get()];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);

    // A non-invertible transform on the layer or on a transform layer above it, up to the sampling surface.
    [host setTransform:CATransform3DMakeScale(1, 1, 0)];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);
    EXPECT_EQ(1U, [[backdrop assignedBackgroundFilters] count]);
    [host setTransform:CATransform3DIdentity];
    [backdrop setTransform:CATransform3DMakeScale(0, 1, 1)];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    EXPECT_EQ(0U, [[backdrop backgroundFilters] count]);

    // A copy made meanwhile takes the filters as set.
    RetainPtr copy = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [copy setBackgroundFilters:[backdrop assignedBackgroundFilters]];
    EXPECT_EQ(1U, [[copy backgroundFilters] count]);

    [backdrop setTransform:CATransform3DIdentity];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
}

TEST(BackdropFiltersAquaWebKit, BlurIsCroppedToTheFootprint)
{
    RetainPtr surface = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr host = makeLayer(CATransformLayer.class, CGRectMake(30, 40, 200, 100));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    [backdrop setPosition:CGPointMake(10, 20)];
    [backdrop setMasksToBounds:YES];
    [host addSublayer:backdrop.get()];
    [surface addSublayer:host.get()];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);

    // Uncropped, neither edge mode reaches Core Animation.
    ASSERT_EQ(1U, [[backdrop backgroundFilters] count]);
    EXPECT_FALSE([[[[backdrop backgroundFilters] firstObject] valueForKey:@"inputHardEdges"] boolValue]);
    EXPECT_FALSE([[[[backdrop backgroundFilters] firstObject] valueForKey:@"inputNormalizeEdges"] boolValue]);

    // Cropped, the blur has hard edges and the bounds are the footprint in the surface; callers see the bounds and
    // clip they set.
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    ASSERT_EQ(1U, [[backdrop backgroundFilters] count]);
    EXPECT_TRUE([[[[backdrop backgroundFilters] firstObject] valueForKey:@"inputHardEdges"] boolValue]);
    EXPECT_TRUE(CGRectEqualToRect(CGRectMake(0, 0, 120, 60), [backdrop bounds]));
    EXPECT_TRUE([backdrop masksToBounds]);
    EXPECT_NULL([backdrop mask]);
    EXPECT_EQ(1, [[[[backdrop backgroundFilters] firstObject] valueForKey:@"inputEdgeSmoothing"] doubleValue]);
    CGPoint origin = [backdrop convertPoint:CGPointMake(39, 59) toLayer:host.get()];
    EXPECT_EQ(10, origin.x);
    EXPECT_EQ(20, origin.y);

    // Hard edges stay hard.
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, false);
    EXPECT_TRUE([[[[backdrop backgroundFilters] firstObject] valueForKey:@"inputHardEdges"] boolValue]);
    EXPECT_EQ(0, [[[[backdrop backgroundFilters] firstObject] valueForKey:@"inputEdgeSmoothing"] doubleValue]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);

    // A translation of the host moves the crop with it.
    [host addAnimation:translation(50) forKey:@"slide"];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    CABasicAnimation *crop = (CABasicAnimation *)[backdrop animationForKey:@"aquawebkitCrop"];
    ASSERT_NOT_NULL(crop);
    EXPECT_TRUE([crop.keyPath isEqualToString:@"bounds.origin"]);
    EXPECT_TRUE(crop.additive);
    EXPECT_EQ(50, [crop.toValue pointValue].x);
    EXPECT_EQ(1, crop.beginTime);

    // A rotation crops to the footprint's extent over the animation.
    CABasicAnimation *rotation = [CABasicAnimation animationWithKeyPath:@"transform"];
    rotation.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    rotation.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeRotation(M_PI / 2, 0, 0, 1)];
    rotation.duration = 10;
    [host removeAllAnimations];
    [host addAnimation:rotation forKey:@"spin"];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    EXPECT_NULL([backdrop animationForKey:@"aquawebkitCrop"]);
    EXPECT_TRUE([[[[backdrop backgroundFilters] firstObject] valueForKey:@"inputHardEdges"] boolValue]);
    CGPoint rotatedOrigin = [backdrop convertPoint:CGPointZero toLayer:host.get()];
    EXPECT_GT(rotatedOrigin.x, 10 - 39);
}

// The crop in the surface's coordinates: the backdrop layer's bounds as Core Animation holds them.
static CGRect cropOf(CALayer *backdrop, CALayer *host)
{
    CGPoint local = [backdrop convertPoint:CGPointZero toLayer:host];
    CGPoint origin = CGPointMake([backdrop position].x - local.x, [backdrop position].y - local.y);
    return { origin, [backdrop frame].size };
}

TEST(BackdropFiltersAquaWebKit, CropHoldsEveryAnimatedFootprint)
{
    RetainPtr surface = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr host = makeLayer(CATransformLayer.class, CGRectMake(30, 40, 200, 100));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    [backdrop setPosition:CGPointMake(10, 20)];
    [host addSublayer:backdrop.get()];
    [surface addSublayer:host.get()];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);

    // A rotation through half a turn, eased past its ends.
    CAKeyframeAnimation *rotation = [CAKeyframeAnimation animationWithKeyPath:@"transform"];
    rotation.values = @[ [NSValue valueWithCATransform3D:CATransform3DIdentity], [NSValue valueWithCATransform3D:CATransform3DMakeRotation(M_PI / 2, 0, 0, 1)], [NSValue valueWithCATransform3D:CATransform3DMakeRotation(M_PI * 0.999, 0, 0, 1)] ];
    rotation.timingFunctions = @[ [CAMediaTimingFunction functionWithControlPoints:0.3 :-0.4 :0.7 :1.4], [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear] ];
    rotation.duration = 10;
    [host addAnimation:rotation forKey:@"spin"];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    EXPECT_NULL([backdrop animationForKey:@"aquawebkitCrop"]);
    // The presented rectangle in the layer's coordinates, which follow the crop.
    auto presentedRect = [&] {
        CGPoint local = [backdrop convertPoint:CGPointZero toLayer:host.get()];
        return CGRectMake([backdrop position].x - local.x, [backdrop position].y - local.y, 120, 60);
    };
    CGRect crop = cropOf(backdrop.get(), host.get());
    CGRect presented = presentedRect();
    [host removeAllAnimations];
    for (int step = -25; step <= 127; ++step) {
        [host setTransform:CATransform3DMakeRotation(M_PI * step / 128, 0, 0, 1)];
        CGRect footprint = [backdrop convertRect:presented toLayer:surface.get()];
        EXPECT_TRUE(CGRectContainsRect(CGRectInset(crop, -1e-6, -1e-6), footprint));
    }

    // A translation value function moves the crop by the same amount.
    [host setTransform:CATransform3DIdentity];
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform"];
    slide.valueFunction = [CAValueFunction functionWithName:kCAValueFunctionTranslate];
    slide.fromValue = @[ @0, @0, @0 ];
    slide.toValue = @[ @50, @10, @0 ];
    slide.duration = 10;
    [host addAnimation:slide forKey:@"slide"];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    CABasicAnimation *crop2 = (CABasicAnimation *)[backdrop animationForKey:@"aquawebkitCrop"];
    ASSERT_NOT_NULL(crop2);
    EXPECT_EQ(50, [crop2.toValue pointValue].x);
    EXPECT_EQ(10, [crop2.toValue pointValue].y);
    [host removeAllAnimations];

    // A spring scales past its end value.
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"transform"];
    spring.valueFunction = [CAValueFunction functionWithName:kCAValueFunctionScale];
    spring.fromValue = @[ @1, @1, @1 ];
    spring.toValue = @[ @2, @2, @1 ];
    [spring setValue:@1 forKey:@"mass"];
    [spring setValue:@100 forKey:@"stiffness"];
    [spring setValue:@4 forKey:@"damping"];
    [spring setValue:@0 forKey:@"velocity"];
    spring.duration = 10;
    [host addAnimation:spring forKey:@"spring"];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    crop = cropOf(backdrop.get(), host.get());
    presented = presentedRect();
    [host removeAllAnimations];
    // The under-damped spring from 0 to 1, as WebCore's SpringSolver models it.
    double w0 = 10, zeta = 0.2, wd = w0 * std::sqrt(1 - zeta * zeta), b = zeta * w0 / wd;
    for (int step = 0; step <= 1000; ++step) {
        double t = step / 100.;
        double scale = 2 - std::exp(-t * zeta * w0) * (std::cos(wd * t) + b * std::sin(wd * t));
        [host setTransform:CATransform3DMakeScale(scale, scale, 1)];
        EXPECT_TRUE(CGRectContainsRect(CGRectInset(crop, -1e-6, -1e-6), [backdrop convertRect:presented toLayer:surface.get()]));
    }

    // An animation that replaces another's value holds only while it is active.
    [host setTransform:CATransform3DIdentity];
    CABasicAnimation *far = [CABasicAnimation animationWithKeyPath:@"transform"];
    far.fromValue = far.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(200, 0, 0)];
    far.duration = 10;
    CABasicAnimation *near = [CABasicAnimation animationWithKeyPath:@"transform"];
    near.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    near.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(10, 0, 0)];
    near.beginTime = 5;
    near.duration = 5;
    [host addAnimation:far forKey:@"far"];
    [host addAnimation:near forKey:@"near"];
    [backdrop setCropLayers:@[ host.get(), surface.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    crop = cropOf(backdrop.get(), host.get());
    presented = presentedRect();
    [host removeAllAnimations];
    for (CGFloat x : { 0., 5., 10., 200. }) {
        [host setTransform:CATransform3DMakeTranslation(x, 0, 0)];
        EXPECT_TRUE(CGRectContainsRect(CGRectInset(crop, -1e-6, -1e-6), [backdrop convertRect:presented toLayer:surface.get()]));
    }
}

TEST(BackdropFiltersAquaWebKit, OpacityFiltersAnimateCoverageIndependently)
{
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    RetainPtr mask = adoptNS([[CAShapeLayer alloc] init]);
    [backdrop setMask:mask.get()];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8), BasicComponentTransferFilterOperation::create(0.5, FilterOperation::Type::Opacity) } }, true);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    EXPECT_EQ(1, CGColorGetAlpha([mask fillColor]));
    CALayer *coverage = [mask superlayer];
    ASSERT_NOT_NULL(coverage);
    EXPECT_EQ(1U, [[coverage filters] count]);

    float from[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0.5, 0 };
    float to[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"backgroundFilters.filter_1.inputColorMatrix"];
    animation.fromValue = [NSValue valueWithBytes:from objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    animation.toValue = [NSValue valueWithBytes:to objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    animation.duration = 10;
    [backdrop addAnimation:animation forKey:@"fade"];
    CABasicAnimation *copy = (CABasicAnimation *)[coverage animationForKey:@"fade"];
    ASSERT_NOT_NULL(copy);
    EXPECT_TRUE([copy.keyPath isEqualToString:@"filters.filter_1.inputColorMatrix"]);
    EXPECT_TRUE([copy.fromValue isEqual:animation.fromValue]);
    EXPECT_TRUE([copy.toValue isEqual:animation.toValue]);

    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8),
        BasicComponentTransferFilterOperation::create(0.5, FilterOperation::Type::Opacity),
        BasicComponentTransferFilterOperation::create(0.25, FilterOperation::Type::Opacity) } }, true);
    CABasicAnimation *second = [animation copy];
    second.keyPath = @"backgroundFilters.filter_2.inputColorMatrix";
    [backdrop addAnimation:second forKey:@"second"];
    EXPECT_EQ(2U, [[coverage filters] count]);
    EXPECT_TRUE([[(CAPropertyAnimation *)[coverage animationForKey:@"fade"] keyPath] isEqualToString:@"filters.filter_1.inputColorMatrix"]);
    EXPECT_TRUE([[(CAPropertyAnimation *)[coverage animationForKey:@"second"] keyPath] isEqualToString:@"filters.filter_2.inputColorMatrix"]);
    [second release];
    EXPECT_NOT_NULL([backdrop animationForKey:@"fade"]);
    [backdrop removeAnimationForKey:@"fade"];
    EXPECT_NULL([coverage animationForKey:@"fade"]);
}

TEST(BackdropFiltersAquaWebKit, IdentityColorFilterKeepsItsColorAnimation)
{
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    RetainPtr mask = adoptNS([[CAShapeLayer alloc] init]);
    [backdrop setMask:mask.get()];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8),
        BasicComponentTransferFilterOperation::create(1, FilterOperation::Type::Brightness) } }, true);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    EXPECT_NE(backdrop.get(), [mask superlayer]);
    float from[20] = { 0.5, 0, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 1, 0 };
    float to[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"backgroundFilters.filter_1.inputColorMatrix"];
    animation.fromValue = [NSValue valueWithBytes:from objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    animation.toValue = [NSValue valueWithBytes:to objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    animation.duration = 10;
    [backdrop addAnimation:animation forKey:@"brighten"];
    EXPECT_EQ(2U, [[backdrop backgroundFilters] count]);
    EXPECT_EQ(backdrop.get(), [mask superlayer]);
    EXPECT_TRUE([[(CAPropertyAnimation *)[backdrop animationForKey:@"brighten"] keyPath] isEqualToString:animation.keyPath]);

    [backdrop removeAnimationForKey:@"brighten"];
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    EXPECT_NE(backdrop.get(), [mask superlayer]);
}

static CAAnimation *nativeAnimationForKey(CALayer *layer, NSString *key)
{
    SEL selector = sel_registerName("animationForKey:");
    IMP implementation = class_getMethodImplementation(CALayer.class, selector);
    return ((CAAnimation *(*)(id, SEL, NSString *))implementation)(layer, selector, key);
}

static CALayer *nativeMask(CALayer *layer)
{
    SEL selector = sel_registerName("mask");
    IMP implementation = class_getMethodImplementation(CALayer.class, selector);
    return ((CALayer *(*)(id, SEL))implementation)(layer, selector);
}

TEST(BackdropFiltersAquaWebKit, BackdropFilterAnimationGroupsAreSplitByTarget)
{
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { {
        BlurFilterOperation::create(8),
        BasicComponentTransferFilterOperation::create(0.5, FilterOperation::Type::Opacity),
        BasicComponentTransferFilterOperation::create(1, FilterOperation::Type::Brightness)
    } }, true);

    float alphaFrom[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0.5, 0 };
    float alphaTo[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0.25, 0 };
    auto alphaAnimation = [CABasicAnimation animationWithKeyPath:@"backgroundFilters.filter_1.inputColorMatrix"];
    alphaAnimation.fromValue = [NSValue valueWithBytes:alphaFrom objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    alphaAnimation.toValue = [NSValue valueWithBytes:alphaTo objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    alphaAnimation.duration = 10;

    float colorFrom[20] = { 0.5, 0, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 1, 0 };
    float colorTo[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    auto colorAnimation = [CABasicAnimation animationWithKeyPath:@"backgroundFilters.filter_2.inputColorMatrix"];
    colorAnimation.fromValue = [NSValue valueWithBytes:colorFrom objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    colorAnimation.toValue = [NSValue valueWithBytes:colorTo objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    colorAnimation.duration = 10;

    auto layerOpacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
    layerOpacity.fromValue = @1;
    layerOpacity.toValue = @0.5;
    layerOpacity.duration = 10;
    auto mixedGroup = [CAAnimationGroup animation];
    mixedGroup.animations = @[ alphaAnimation, colorAnimation, layerOpacity ];
    mixedGroup.duration = 10;
    [backdrop addAnimation:mixedGroup forKey:@"mixed"];

    EXPECT_EQ(2U, [[backdrop backgroundFilters] count]);
    CALayer *coverage = nativeMask(backdrop.get());
    ASSERT_NOT_NULL(coverage);
    EXPECT_EQ(1U, [[coverage filters] count]);
    CAAnimationGroup *maskCopy = (CAAnimationGroup *)[coverage animationForKey:@"mixed"];
    ASSERT_TRUE([maskCopy isKindOfClass:CAAnimationGroup.class]);
    ASSERT_EQ(1U, maskCopy.animations.count);
    EXPECT_TRUE([static_cast<CAPropertyAnimation *>(maskCopy.animations[0]).keyPath isEqualToString:@"filters.filter_1.inputColorMatrix"]);
    CAAnimationGroup *backdropCopy = (CAAnimationGroup *)nativeAnimationForKey(backdrop.get(), @"mixed");
    ASSERT_TRUE([backdropCopy isKindOfClass:CAAnimationGroup.class]);
    EXPECT_EQ(2U, backdropCopy.animations.count);

    [backdrop removeAnimationForKey:@"mixed"];
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    EXPECT_EQ(2U, [[nativeMask(backdrop.get()) filters] count]);
}

TEST(BackdropFiltersAquaWebKit, SamplingSurfaceFollowsBoundary)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr clip = makeLayer(CALayer.class, CGRectMake(20, 30, 200, 100));
    [clip setMasksToBounds:YES];
    [clip setCornerRadius:12];
    RetainPtr host = makeLayer(CATransformLayer.class, CGRectMake(10, 10, 120, 60));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    [host addSublayer:backdrop.get()];
    [clip addSublayer:host.get()];
    RetainPtr surface = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [root setSublayers:@[ surface.get(), clip.get() ]];

    // The sampling-surface layer covers the backdrop's footprint in the boundary's superlayer, with the backdrop's
    // filters cropped there, and a mask that mirrors the boundary and the layers down to the backdrop layer.
    [surface updateSamplingSurfaceWithBoundary:clip.get() path:@[ host.get() ] backdropLayer:backdrop.get()];
    [surface setCropLayers:@[ host.get(), clip.get(), root.get() ] parentIndex:2 backdropLayer:backdrop.get()];
    EXPECT_TRUE(CGPointEqualToPoint(CGPointMake(30, 40), [surface position]));
    EXPECT_TRUE(CGRectEqualToRect(CGRectMake(0, 0, 120, 60), [surface bounds]));
    CGPoint cropOrigin = [surface convertPoint:CGPointMake(29, 39) toLayer:root.get()];
    EXPECT_EQ(30, cropOrigin.x);
    EXPECT_EQ(40, cropOrigin.y);
    ASSERT_EQ(1U, [[surface backgroundFilters] count]);
    EXPECT_TRUE([[[[surface backgroundFilters] firstObject] valueForKey:@"inputHardEdges"] boolValue]);
    CALayer *maskRoot = [[surface mask] sublayers].firstObject;
    ASSERT_NOT_NULL(maskRoot);
    EXPECT_TRUE(CGRectEqualToRect(CGRectMake(30, 40, 120, 60), [maskRoot bounds]));
    EXPECT_TRUE([maskRoot masksToBounds]);
    CALayer *boundaryNode = [maskRoot sublayers].firstObject;
    EXPECT_TRUE(CGRectEqualToRect([clip frame], [boundaryNode frame]));
    EXPECT_EQ(12, [boundaryNode cornerRadius]);

    // Scrolled bounds reach it without an update.
    [clip setBounds:CGRectMake(0, 40, 200, 100)];
    WebBackdropLayerAquaWebKitGeometryDidChange(clip.get());
    EXPECT_TRUE(CGRectEqualToRect([clip bounds], [boundaryNode bounds]));
    EXPECT_TRUE(CGPointEqualToPoint(CGPointMake(30, 0), [surface position]));

    // It is hidden with the backdrop layer.
    [backdrop setHidden:YES];
    [surface updateSamplingSurfaceWithBoundary:clip.get() path:@[ host.get() ] backdropLayer:backdrop.get()];
    EXPECT_EQ(0U, [[surface backgroundFilters] count]);
}

TEST(BackdropFiltersAquaWebKit, ScrollingThreadGeometryReachesTheSamplingSurface)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr clip = makeLayer(CALayer.class, CGRectMake(20, 30, 200, 100));
    [clip setMasksToBounds:YES];
    RetainPtr host = makeLayer(CATransformLayer.class, CGRectMake(10, 10, 120, 60));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    [host addSublayer:backdrop.get()];
    [clip addSublayer:host.get()];
    RetainPtr surface = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [root setSublayers:@[ surface.get(), clip.get() ]];
    [surface updateSamplingSurfaceWithBoundary:clip.get() path:@[ host.get() ] backdropLayer:backdrop.get()];
    [surface setCropLayers:@[ host.get(), clip.get(), root.get() ] parentIndex:2 backdropLayer:backdrop.get()];
    CALayer *boundaryNode = [[[surface mask] sublayers].firstObject sublayers].firstObject;
    CALayer *hostNode = [boundaryNode sublayers].firstObject;
    ASSERT_NOT_NULL(hostNode);

    // The scrolling thread moves layers through these, with no layer tree commit on the main thread.
    dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [clip _web_setLayerBoundsOrigin:CGPointMake(0, 40)];
        [host _web_setLayerTopLeftPosition:CGPointMake(10, 60)];
    });
    EXPECT_TRUE(CGRectEqualToRect([clip bounds], [boundaryNode bounds]));
    EXPECT_TRUE(CGPointEqualToPoint([host position], [hostNode position]));
    EXPECT_TRUE(CGPointEqualToPoint(CGPointMake(30, 50), [surface position]));
}

TEST(BackdropFiltersAquaWebKit, MaskCopiesTakeDisplayedContents)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr boundary = makeLayer(CALayer.class, CGRectMake(20, 30, 200, 100));
    RetainPtr mask = makeLayer(CALayer.class, CGRectMake(0, 0, 200, 100));
    RetainPtr first = adoptCF(CGImageCreate(1, 1, 8, 32, 4, adoptCF(CGColorSpaceCreateDeviceRGB()).get(), kCGImageAlphaPremultipliedLast, adoptCF(CGDataProviderCreateWithCFData((__bridge CFDataRef)[NSData dataWithBytes:"\xff\xff\xff\xff" length:4])).get(), nullptr, false, kCGRenderingIntentDefault));
    RetainPtr second = adoptCF(CGImageCreate(1, 1, 8, 32, 4, adoptCF(CGColorSpaceCreateDeviceRGB()).get(), kCGImageAlphaPremultipliedLast, adoptCF(CGDataProviderCreateWithCFData((__bridge CFDataRef)[NSData dataWithBytes:"\0\0\0\0" length:4])).get(), nullptr, false, kCGRenderingIntentDefault));
    [mask setContents:(__bridge id)first.get()];
    [boundary setMask:mask.get()];
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 200, 100)];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    [boundary addSublayer:backdrop.get()];
    RetainPtr surface = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [root setSublayers:@[ surface.get(), boundary.get() ]];
    [surface updateSamplingSurfaceWithBoundary:boundary.get() path:@[ ] backdropLayer:backdrop.get()];
    CALayer *boundaryNode = [[[surface mask] sublayers].firstObject sublayers].firstObject;
    CALayer *maskCopy = [boundaryNode mask];
    ASSERT_NOT_NULL(maskCopy);
    EXPECT_EQ((__bridge id)first.get(), [maskCopy contents]);

    // Contents the mask displays later reach the copy without an update.
    [mask setContents:(__bridge id)second.get()];
    WebBackdropLayerAquaWebKitContentsDidChange(mask.get());
    EXPECT_EQ((__bridge id)second.get(), [maskCopy contents]);
}

TEST(BackdropFiltersAquaWebKit, SamplingTheBackdropRootKeepsItOpaque)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr host = makeLayer(CATransformLayer.class, CGRectMake(10, 10, 120, 60));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    [host addSublayer:backdrop.get()];
    [root addSublayer:host.get()];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    [backdrop setCropLayers:@[ host.get(), root.get() ] parentIndex:0 backdropLayer:backdrop.get()];
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);

    // Normalized edges, cropped, over the backdrop root's surface: the filters end opaque.
    [backdrop setSamplesBackdropRoot:YES];
    ASSERT_EQ(2U, [[backdrop backgroundFilters] count]);
    EXPECT_NOT_NULL([[[backdrop backgroundFilters] lastObject] valueForKey:@"inputColorMatrix"]);

    // Hard edges are for a transparent backdrop root.
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, false);
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    EXPECT_EQ(2U, [[backdrop backgroundFilters] count]);
    [backdrop setSamplesBackdropRoot:NO];
    EXPECT_EQ(1U, [[backdrop backgroundFilters] count]);
}

TEST(BackdropFiltersAquaWebKit, GroupOpacityRidesTheMirror)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr group = makeLayer(CALayer.class, CGRectMake(20, 30, 200, 100));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    [group addSublayer:backdrop.get()];
    PlatformCAFilters::setFiltersOnLayer(group.get(), FilterOperations { { BasicComponentTransferFilterOperation::create(0.5, FilterOperation::Type::Opacity) } }, false);
    RetainPtr surface = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [root setSublayers:@[ surface.get(), group.get() ]];

    // Native opacity and each opacity() filter keep separate animation targets on the coverage mirror.
    float from[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0.5, 0 };
    float to[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0.25, 0 };
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputColorMatrix"];
    fade.fromValue = [NSValue valueWithBytes:from objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    fade.toValue = [NSValue valueWithBytes:to objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    fade.duration = 10;
    [group addAnimation:fade forKey:@"fade"];
    [group setOpacity:0.6];
    CABasicAnimation *groupFade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    groupFade.fromValue = @1;
    groupFade.toValue = @0.2;
    groupFade.duration = 10;
    [group addAnimation:groupFade forKey:@"nativeFade"];
    [surface updateSamplingSurfaceWithBoundary:group.get() path:@[ ] backdropLayer:backdrop.get()];
    EXPECT_EQ(1U, [[surface backgroundFilters] count]);
    CALayer *boundaryNode = [[[surface mask] sublayers].firstObject sublayers].firstObject;
    EXPECT_EQ(0.6f, [boundaryNode opacity]);
    EXPECT_EQ(1U, [[boundaryNode filters] count]);
    EXPECT_TRUE([[(CAPropertyAnimation *)[boundaryNode animationForKey:@"layer:nativeFade"] keyPath] isEqualToString:@"opacity"]);
    CABasicAnimation *opacity = (CABasicAnimation *)[boundaryNode animationForKey:@"groupFilter:fade"];
    ASSERT_NOT_NULL(opacity);
    EXPECT_TRUE([opacity.keyPath isEqualToString:@"filters.filter_0.inputColorMatrix"]);
    EXPECT_TRUE([opacity.toValue isEqual:fade.toValue]);
}

TEST(BackdropFiltersAquaWebKit, GroupFilterAnimationGroupsAreSplitByTarget)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 400, 300));
    RetainPtr group = makeLayer(CALayer.class, CGRectMake(20, 30, 200, 100));
    RetainPtr backdrop = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [backdrop setAnchorPoint:CGPointZero];
    [backdrop setBounds:CGRectMake(0, 0, 120, 60)];
    PlatformCAFilters::setFiltersOnLayer(backdrop.get(), FilterOperations { { BlurFilterOperation::create(8) } }, true);
    [group addSublayer:backdrop.get()];
    PlatformCAFilters::setFiltersOnLayer(group.get(), FilterOperations { {
        BasicComponentTransferFilterOperation::create(0.5, FilterOperation::Type::Opacity),
        BasicComponentTransferFilterOperation::create(1, FilterOperation::Type::Brightness)
    } }, false);
    RetainPtr surface = adoptNS([[WebBackdropLayerAquaWebKit alloc] init]);
    [root setSublayers:@[ surface.get(), group.get() ]];

    float alphaFrom[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0.5, 0 };
    float alphaTo[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0.25, 0 };
    auto alphaAnimation = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputColorMatrix"];
    alphaAnimation.fromValue = [NSValue valueWithBytes:alphaFrom objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    alphaAnimation.toValue = [NSValue valueWithBytes:alphaTo objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    alphaAnimation.duration = 10;
    auto pureAlphaGroup = [CAAnimationGroup animation];
    pureAlphaGroup.animations = @[ alphaAnimation ];
    pureAlphaGroup.duration = 10;
    [group addAnimation:pureAlphaGroup forKey:@"pure"];

    float colorFrom[20] = { 0.5, 0, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 0.5, 0, 0, 0, 0, 0, 1, 0 };
    float colorTo[20] = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 };
    auto colorAnimation = [CABasicAnimation animationWithKeyPath:@"filters.filter_1.inputColorMatrix"];
    colorAnimation.fromValue = [NSValue valueWithBytes:colorFrom objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    colorAnimation.toValue = [NSValue valueWithBytes:colorTo objCType:"{CAColorMatrix=ffffffffffffffffffff}"];
    colorAnimation.duration = 10;
    auto nativeOpacity = [CABasicAnimation animationWithKeyPath:@"opacity"];
    nativeOpacity.fromValue = @1;
    nativeOpacity.toValue = @0.5;
    nativeOpacity.duration = 10;
    auto mixedGroup = [CAAnimationGroup animation];
    mixedGroup.animations = @[ alphaAnimation, colorAnimation, nativeOpacity ];
    mixedGroup.duration = 10;
    [group addAnimation:mixedGroup forKey:@"mixed"];

    [surface updateSamplingSurfaceWithBoundary:group.get() path:@[ ] backdropLayer:backdrop.get()];
    EXPECT_EQ(2U, [[surface backgroundFilters] count]);
    CALayer *boundaryNode = [[[surface mask] sublayers].firstObject sublayers].firstObject;
    EXPECT_EQ(1U, [[boundaryNode filters] count]);

    CAAnimationGroup *pureCopy = (CAAnimationGroup *)[boundaryNode animationForKey:@"groupFilter:pure"];
    ASSERT_TRUE([pureCopy isKindOfClass:CAAnimationGroup.class]);
    ASSERT_EQ(1U, pureCopy.animations.count);
    EXPECT_TRUE([static_cast<CAPropertyAnimation *>(pureCopy.animations[0]).keyPath isEqualToString:@"filters.filter_0.inputColorMatrix"]);

    CAAnimationGroup *opacityCopy = (CAAnimationGroup *)[boundaryNode animationForKey:@"groupFilter:mixed"];
    ASSERT_TRUE([opacityCopy isKindOfClass:CAAnimationGroup.class]);
    ASSERT_EQ(1U, opacityCopy.animations.count);
    EXPECT_TRUE([static_cast<CAPropertyAnimation *>(opacityCopy.animations[0]).keyPath isEqualToString:@"filters.filter_0.inputColorMatrix"]);

    CAAnimationGroup *geometryCopy = (CAAnimationGroup *)[boundaryNode animationForKey:@"layer:mixed"];
    ASSERT_TRUE([geometryCopy isKindOfClass:CAAnimationGroup.class]);
    ASSERT_EQ(1U, geometryCopy.animations.count);
    EXPECT_TRUE([static_cast<CAPropertyAnimation *>(geometryCopy.animations[0]).keyPath isEqualToString:@"opacity"]);

    CAAnimationGroup *colorCopy = (CAAnimationGroup *)[surface animationForKey:@"group:0:mixed"];
    ASSERT_TRUE([colorCopy isKindOfClass:CAAnimationGroup.class]);
    ASSERT_EQ(1U, colorCopy.animations.count);
    EXPECT_TRUE([static_cast<CAPropertyAnimation *>(colorCopy.animations[0]).keyPath hasPrefix:@"backgroundFilters.aquawebkitGroupFilter"]);
}

TEST(BackdropFiltersAquaWebKit, PlacementBoundsPreserveTransformLayerDepth)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 600, 400));
    RetainPtr parent = makeLayer(CATransformLayer.class, CGRectMake(0, 0, 100, 100));
    RetainPtr child = makeLayer(CALayer.class, CGRectMake(0, 0, 80, 60));
    [parent setTransform:CATransform3DMakeRotation(M_PI_2, 0, 1, 0)];
    [child setZPosition:200];
    [parent addSublayer:child.get()];
    [root addSublayer:parent.get()];
    CGRect extent;
    ASSERT_TRUE(WebBackdropLayerAquaWebKitExtentInSamplingSurface(parent.get(), @[ root.get() ], &extent));
    CGRect actual = [child convertRect:[child bounds] toLayer:root.get()];
    EXPECT_TRUE(CGRectContainsRect(CGRectInset(extent, -1e-6, -1e-6), actual));
}

TEST(BackdropFiltersAquaWebKit, PlacementBoundsHoldLargeRotationRanges)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 600, 400));
    RetainPtr rotating = makeLayer(CALayer.class, CGRectMake(0, 0, 80, 60));
    [root addSublayer:rotating.get()];
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform"];
    spin.valueFunction = [CAValueFunction functionWithName:kCAValueFunctionRotateZ];
    spin.fromValue = @0;
    spin.toValue = @1e300;
    spin.duration = 10;
    [rotating addAnimation:spin forKey:@"spin"];
    CGRect extent;
    ASSERT_TRUE(WebBackdropLayerAquaWebKitExtentInSamplingSurface(rotating.get(), @[ root.get() ], &extent));
    EXPECT_TRUE(CGRectContainsRect(extent, CGRectMake(-100, -100, 200, 200)));
}

TEST(BackdropFiltersAquaWebKit, PlacementBoundsUseSamplingSurfaceCoordinates)
{
    RetainPtr root = makeLayer(CALayer.class, CGRectMake(0, 0, 600, 400));
    RetainPtr host = makeLayer(CATransformLayer.class, CGRectMake(0, 0, 100, 100));
    RetainPtr child = makeLayer(CALayer.class, CGRectMake(0, 0, 20, 30));
    [host setPosition:CGPointMake(170, 80)];
    [host setTransform:CATransform3DMakeScale(2, 3, 1)];
    [root addSublayer:host.get()];
    [host addSublayer:child.get()];
    CGRect extent;
    ASSERT_TRUE(WebBackdropLayerAquaWebKitExtentInSamplingSurface(child.get(), @[host.get(), root.get()], &extent));
    CGRect actual = [child convertRect:[child bounds] toLayer:root.get()];
    EXPECT_TRUE(CGRectContainsRect(CGRectInset(extent, -1e-6, -1e-6), actual));
    EXPECT_NEAR(extent.size.width, 40, 1e-6);
    EXPECT_NEAR(extent.size.height, 90, 1e-6);

    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform"];
    slide.valueFunction = [CAValueFunction functionWithName:kCAValueFunctionTranslateX];
    slide.fromValue = @0;
    slide.toValue = @200;
    slide.duration = 10;
    [host addAnimation:slide forKey:@"slide"];
    ASSERT_TRUE(WebBackdropLayerAquaWebKitExtentInSamplingSurface(child.get(), @[host.get(), root.get()], &extent));
    [host removeAnimationForKey:@"slide"];
    for (unsigned i = 0; i <= 10; ++i) {
        [host setTransform:CATransform3DMakeTranslation(20 * i, 0, 0)];
        actual = [child convertRect:[child bounds] toLayer:root.get()];
        EXPECT_TRUE(CGRectContainsRect(CGRectInset(extent, -1e-6, -1e-6), actual));
    }
    [host removeFromSuperlayer];
    EXPECT_FALSE(WebBackdropLayerAquaWebKitExtentInSamplingSurface(child.get(), @[host.get()], &extent));
    ASSERT_TRUE(WebBackdropLayerAquaWebKitExtentInSamplingSurface(child.get(), @[host.get(), root.get()], &extent));
    [root addSublayer:host.get()];
    actual = [child convertRect:[child bounds] toLayer:root.get()];
    EXPECT_NEAR(extent.origin.x, actual.origin.x, 1e-6);
    EXPECT_NEAR(extent.origin.y, actual.origin.y, 1e-6);
    EXPECT_NEAR(extent.size.width, actual.size.width, 1e-6);
    EXPECT_NEAR(extent.size.height, actual.size.height, 1e-6);
}

TEST(BackdropFiltersAquaWebKit, NestedReflectionSamplingSurfaceAssociations)
{
    class Client final : public GraphicsLayerClient {
    public:
        bool cssUnprefixedBackdropFilterEnabled() const final { return true; }
    } client;
    auto root = GraphicsLayer::create(nullptr, client);
    auto outer = GraphicsLayer::create(nullptr, client);
    auto inner = GraphicsLayer::create(nullptr, client);
    auto panel = GraphicsLayer::create(nullptr, client);
    auto innerReplica = GraphicsLayer::create(nullptr, client);
    auto outerReplica = GraphicsLayer::create(nullptr, client);
    root->setSize({ 460, 240 });
    outer->setSize({ 200, 200 });
    inner->setSize({ 100, 60 });
    panel->setSize({ 100, 60 });
    panel->setBackdropFilters(FilterOperations { { BasicComponentTransferFilterOperation::create(1, FilterOperation::Type::Invert) } });
    panel->setBackdropFiltersRect(FloatRoundedRect { FloatRect { 0, 0, 100, 60 } });
    inner->addChild(panel.copyRef());
    outer->addChild(inner.copyRef());
    root->addChild(outer.copyRef());
    root->flushCompositingState({ });

    inner->setReplicatedByLayer(RefPtr<GraphicsLayer> { innerReplica.ptr() });
    root->flushCompositingState({ });
    outer->setReplicatedByLayer(RefPtr<GraphicsLayer> { outerReplica.ptr() });
    root->flushCompositingState({ });

    Vector<CALayer*> layers { outer->platformLayer() };
    Vector<WebBackdropLayerAquaWebKit*> backdropLayers;
    for (size_t i = 0; i < layers.size(); ++i) {
        CALayer *layer = layers[i];
        if ([layer isKindOfClass:[WebBackdropLayerAquaWebKit class]])
            backdropLayers.append((WebBackdropLayerAquaWebKit *)layer);
        for (CALayer *child in [layer sublayers])
            layers.append(child);
    }

    std::set<WebBackdropLayerAquaWebKit*> targets;
    unsigned surfaceCount = 0;
    for (WebBackdropLayerAquaWebKit *backdrop : backdropLayers) {
        WebBackdropLayerAquaWebKit *target = [backdrop samplingSurfaceBackdropLayer];
        if (!target)
            continue;
        ++surfaceCount;
        EXPECT_TRUE(backdropLayers.contains(target));
        EXPECT_NULL([target samplingSurfaceBackdropLayer]);
        targets.insert(target);
    }
    EXPECT_EQ(7U, surfaceCount);
    EXPECT_EQ(4U, targets.size());
}

} // namespace TestWebKitAPI
