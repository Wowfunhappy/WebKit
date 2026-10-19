#include "config.h"
#import "WebBackdropLayerAquaWebKit.h"

#import "PlatformCALayer.h"
#import "TransformationMatrix.h"
#import "WebActionDisablingCALayerDelegate.h"
#import <objc/runtime.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <wtf/HashSet.h>
#import <wtf/Lock.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/RecursiveLockAdapter.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
#import <wtf/WeakObjCPtr.h>

@class WebBackdropLayerAquaWebKit;

// A layer keeps the layers that follow it through instances of this class. When another thread moves it, a mirror
// takes its geometry under its owner's update lock and a cropped layer recomputes its crop; when it displays, a mask
// copy takes its contents.
@interface WebBackdropLayerFollower : NSObject {
@public
    WeakObjCPtr<CALayer> layer;
    WeakObjCPtr<WebBackdropLayerAquaWebKit> owner;
}
@end

@implementation WebBackdropLayerFollower
@end

@interface WebBackdropLayerAquaWebKit ()
- (void)updateCrop;
- (NSArray *)colorBackgroundFilters;
- (CALayer *)maskForCoverage;
- (void)updateOpacityMask;
- (void)updateFilterClassification;
- (void)mirrorGeometryOf:(CALayer *)layer to:(CALayer *)mirror;
- (void)copyContentsOf:(CALayer *)layer to:(CALayer *)copy;
@end

static Lock followersLock;
static Lock layersAwaitingRootLock;
static char mirrorsKey;
static char contentsCopiesKey;
static char copiedContentsKey;
static char croppedLayersKey;
static char originalMaskKey;
static char copiedAnimationsKey;

static NSString * const cropAnimationKey = @"aquawebkitCrop";

// The layers whose crop met a sampling surface outside the host's tree, to crop again once the commit has built it.
static Vector<WeakObjCPtr<WebBackdropLayerAquaWebKit>>& layersAwaitingRoot() WTF_REQUIRES_LOCK(layersAwaitingRootLock)
{
    static NeverDestroyed<Vector<WeakObjCPtr<WebBackdropLayerAquaWebKit>>> layers;
    return layers.get();
}

static bool isTransformLayer(CALayer *layer)
{
    return [layer isKindOfClass:CATransformLayer.class];
}

static bool transformIsInvertible(const CATransform3D& t)
{
    double determinant =
        t.m11 * (t.m22 * (t.m33 * t.m44 - t.m34 * t.m43) - t.m23 * (t.m32 * t.m44 - t.m34 * t.m42) + t.m24 * (t.m32 * t.m43 - t.m33 * t.m42))
        - t.m12 * (t.m21 * (t.m33 * t.m44 - t.m34 * t.m43) - t.m23 * (t.m31 * t.m44 - t.m34 * t.m41) + t.m24 * (t.m31 * t.m43 - t.m33 * t.m41))
        + t.m13 * (t.m21 * (t.m32 * t.m44 - t.m34 * t.m42) - t.m22 * (t.m31 * t.m44 - t.m34 * t.m41) + t.m24 * (t.m31 * t.m42 - t.m32 * t.m41))
        - t.m14 * (t.m21 * (t.m32 * t.m43 - t.m33 * t.m42) - t.m22 * (t.m31 * t.m43 - t.m33 * t.m41) + t.m23 * (t.m31 * t.m42 - t.m32 * t.m41));
    return std::isfinite(determinant) && determinant != 0;
}

static bool layerIsNotRendered(CALayer *layer)
{
    return layer.hidden || !transformIsInvertible(layer.transform);
}

static CALayer *makeLayer(Class layerClass)
{
    CALayer *layer = [layerClass layer];
    layer.delegate = [WebActionDisablingCALayerDelegate shared];
    return layer;
}

// Adds or removes `follower` among the live followers `layer` keeps under `key`.
static void updateFollowers(CALayer *layer, const void* key, CALayer *follower, WebBackdropLayerAquaWebKit *owner, bool add)
{
    Locker locker { followersLock };
    NSArray *followers = objc_getAssociatedObject(layer, key);
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:followers.count + 1];
    for (WebBackdropLayerFollower *existing in followers) {
        RetainPtr existingLayer = existing->layer.get();
        if (existingLayer && existingLayer.get() != follower)
            [kept addObject:existing];
    }
    if (add) {
        RetainPtr entry = adoptNS([[WebBackdropLayerFollower alloc] init]);
        entry->layer = follower;
        entry->owner = owner;
        [kept addObject:entry.get()];
    }
    objc_setAssociatedObject(layer, key, kept.count ? kept : nil, OBJC_ASSOCIATION_RETAIN);
}

static void copyGeometry(CALayer *from, CALayer *to, bool includeSublayerGeometry)
{
    if (!CGPointEqualToPoint(from.position, to.position))
        to.position = from.position;
    if (!CGRectEqualToRect(from.bounds, to.bounds))
        to.bounds = from.bounds;
    if (!CGPointEqualToPoint(from.anchorPoint, to.anchorPoint))
        to.anchorPoint = from.anchorPoint;
    if (from.anchorPointZ != to.anchorPointZ)
        to.anchorPointZ = from.anchorPointZ;
    if (from.zPosition != to.zPosition)
        to.zPosition = from.zPosition;
    if (!CATransform3DEqualToTransform(from.transform, to.transform))
        to.transform = from.transform;
    if (!includeSublayerGeometry)
        return;
    if (!CATransform3DEqualToTransform(from.sublayerTransform, to.sublayerTransform))
        to.sublayerTransform = from.sublayerTransform;
    if (from.geometryFlipped != to.geometryFlipped)
        to.geometryFlipped = from.geometryFlipped;
}

static void setDoubleSided(CALayer *layer, bool doubleSided)
{
    if (layer.doubleSided != doubleSided)
        layer.doubleSided = doubleSided;
}

static void copyClip(CALayer *from, CALayer *to)
{
    if (from.masksToBounds != to.masksToBounds)
        to.masksToBounds = from.masksToBounds;
    if (from.cornerRadius != to.cornerRadius)
        to.cornerRadius = from.cornerRadius;
}

static void setOpacity(CALayer *layer, float opacity)
{
    if (layer.opacity != opacity)
        layer.opacity = opacity;
}

static bool keyPathMatches(NSString *keyPath, NSArray *prefixes)
{
    for (NSString *prefix in prefixes) {
        if ([keyPath hasPrefix:prefix])
            return true;
    }
    return false;
}

static NSArray *geometryKeyPaths()
{
    static NeverDestroyed<RetainPtr<NSArray>> keyPaths = @[ @"transform" ];
    return keyPaths.get().get();
}

static NSArray *groupKeyPaths()
{
    static NeverDestroyed<RetainPtr<NSArray>> keyPaths = @[ @"transform", @"opacity" ];
    return keyPaths.get().get();
}

static RetainPtr<CAAnimation> copyAnimationSelectingKeyPaths(CAAnimation *animation, NSString *(^mapKeyPath)(NSString *))
{
    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        RetainPtr<CAAnimationGroup> copy = adoptNS(static_cast<CAAnimationGroup *>([animation copy]));
        NSMutableArray *children = [NSMutableArray array];
        for (CAAnimation *child in static_cast<CAAnimationGroup *>(animation).animations) {
            if (RetainPtr selected = copyAnimationSelectingKeyPaths(child, mapKeyPath))
                [children addObject:selected.get()];
        }
        if (!children.count)
            return nil;
        copy.get().animations = children;
        return copy;
    }
    if (![animation isKindOfClass:CAPropertyAnimation.class])
        return nil;
    auto* propertyAnimation = static_cast<CAPropertyAnimation *>(animation);
    NSString *mappedKeyPath = mapKeyPath(propertyAnimation.keyPath);
    if (!mappedKeyPath)
        return nil;
    RetainPtr<CAPropertyAnimation> copy = adoptNS(static_cast<CAPropertyAnimation *>([animation copy]));
    copy.get().keyPath = mappedKeyPath;
    return copy;
}

// Sets the animations `to` derives from one source under keys tagged with `tag`, so several sources can feed one
// layer: `animations` maps each source key to a pair of the source animation and the animation `to` takes. A
// derived animation is replaced only when its source is; tagged keys no longer present are removed.
static void setTaggedAnimations(CALayer *to, NSDictionary *animations, NSString *tag)
{
    NSMutableDictionary *sources = objc_getAssociatedObject(to, &copiedAnimationsKey);
    if (!animations.count && !sources.count)
        return;
    NSMutableSet *keys = [NSMutableSet set];
    for (NSString *key in animations) {
        NSArray *pair = animations[key];
        NSString *taggedKey = [NSString stringWithFormat:@"%@:%@", tag, key];
        [keys addObject:taggedKey];
        if (sources[taggedKey] == pair[0] && [to animationForKey:taggedKey])
            continue;
        [to addAnimation:pair[1] forKey:taggedKey];
        if (!sources) {
            sources = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(to, &copiedAnimationsKey, sources, OBJC_ASSOCIATION_RETAIN);
        }
        sources[taggedKey] = pair[0];
    }
    NSString *tagPrefix = [tag stringByAppendingString:@":"];
    for (NSString *taggedKey in sources.allKeys) {
        if (![taggedKey hasPrefix:tagPrefix] || [keys containsObject:taggedKey])
            continue;
        [to removeAnimationForKey:taggedKey];
        [sources removeObjectForKey:taggedKey];
    }
}

// The animations of `from` whose key paths all begin with one of `prefixes` (all of them for nil), each paired with
// a copy without a delegate, so the original's owner hears of each animation once.
static NSDictionary *animationCopies(CALayer *from, NSArray *prefixes)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in from.animationKeys) {
        if ([key hasPrefix:cropAnimationKey])
            continue;
        CAAnimation *animation = [from animationForKey:key];
        if (!animation)
            continue;
        RetainPtr<CAAnimation> copy;
        if (prefixes) {
            copy = copyAnimationSelectingKeyPaths(animation, ^NSString *(NSString *keyPath) {
                return keyPathMatches(keyPath, prefixes) ? keyPath : nil;
            });
        } else
            copy = adoptNS(static_cast<CAAnimation *>([animation copy]));
        if (!copy)
            continue;
        [copy setDelegate:nil];
        result[key] = @[ animation, copy.get() ];
    }
    return result;
}

static void copyAnimations(CALayer *from, CALayer *to, NSArray *prefixes, NSString *tag)
{
    setTaggedAnimations(to, animationCopies(from, prefixes), tag);
}

// A mask's copy shows what the mask shows: the same contents or path, at the same geometry and opacity.
static Class maskCopyClass(CALayer *original)
{
    if ([original isKindOfClass:CAShapeLayer.class])
        return CAShapeLayer.class;
    return isTransformLayer(original) ? CATransformLayer.class : CALayer.class;
}

static CALayer *makeMaskCopy(CALayer *original)
{
    return makeLayer(maskCopyClass(original));
}

// A copy takes the original's contents again each time the original displays them.
static void followContents(CALayer *original, CALayer *copy, WebBackdropLayerAquaWebKit *owner)
{
    NSValue *followed = objc_getAssociatedObject(copy, &copiedContentsKey);
    if (followed.nonretainedObjectValue == original)
        return;
    objc_setAssociatedObject(copy, &copiedContentsKey, [NSValue valueWithNonretainedObject:original], OBJC_ASSOCIATION_RETAIN);
    updateFollowers(original, &contentsCopiesKey, copy, owner, true);
}

static void syncMaskCopy(CALayer *original, CALayer *copy, WebBackdropLayerAquaWebKit *owner)
{
    copyGeometry(original, copy, true);
    setDoubleSided(copy, original.doubleSided);
    if (!isTransformLayer(copy)) {
        copyClip(original, copy);
        setOpacity(copy, original.opacity);
        if (![original.filters isEqualToArray:copy.filters])
            copy.filters = original.filters;
        followContents(original, copy, owner);
        if (original.contents != copy.contents)
            copy.contents = original.contents;
        if (!CGRectEqualToRect(original.contentsRect, copy.contentsRect))
            copy.contentsRect = original.contentsRect;
        if (!CGRectEqualToRect(original.contentsCenter, copy.contentsCenter))
            copy.contentsCenter = original.contentsCenter;
        if (original.contentsScale != copy.contentsScale)
            copy.contentsScale = original.contentsScale;
        if (![original.contentsGravity isEqualToString:copy.contentsGravity])
            copy.contentsGravity = original.contentsGravity;
        if (!CGColorEqualToColor(original.backgroundColor, copy.backgroundColor))
            copy.backgroundColor = original.backgroundColor;
    }
    bool hidden = layerIsNotRendered(original);
    if (hidden != copy.hidden)
        copy.hidden = hidden;
    if ([original isKindOfClass:CAShapeLayer.class]) {
        auto* originalShape = static_cast<CAShapeLayer *>(original);
        auto* copyShape = static_cast<CAShapeLayer *>(copy);
        if (!CGPathEqualToPath(originalShape.path, copyShape.path))
            copyShape.path = originalShape.path;
        if (!CGColorEqualToColor(originalShape.fillColor, copyShape.fillColor))
            copyShape.fillColor = originalShape.fillColor;
        if (![originalShape.fillRule isEqualToString:copyShape.fillRule])
            copyShape.fillRule = originalShape.fillRule;
    }
    copyAnimations(original, copy, nil, @"mask");

    NSArray *originalSublayers = original.sublayers;
    NSArray *copySublayers = copy.sublayers;
    bool matches = originalSublayers.count == copySublayers.count;
    for (NSUInteger i = 0; matches && i < originalSublayers.count; ++i)
        matches = [copySublayers[i] class] == maskCopyClass(originalSublayers[i]);
    if (!matches) {
        NSMutableArray *sublayers = [NSMutableArray arrayWithCapacity:originalSublayers.count];
        for (CALayer *sublayer in originalSublayers)
            [sublayers addObject:makeMaskCopy(sublayer)];
        copy.sublayers = sublayers;
        copySublayers = copy.sublayers;
    }
    for (NSUInteger i = 0; i < originalSublayers.count; ++i)
        syncMaskCopy(originalSublayers[i], copySublayers[i], owner);
}

// Gives `node` a copy of `original`'s mask, replaced when the original layer's mask is. The node remembers which
// mask it copies without keeping it.
static void syncMask(CALayer *original, CALayer *node, WebBackdropLayerAquaWebKit *owner)
{
    CALayer *mask = original.mask;
    NSValue *copiedMask = objc_getAssociatedObject(node, &originalMaskKey);
    if (copiedMask.nonretainedObjectValue != mask || !node.mask != !mask) {
        objc_setAssociatedObject(node, &originalMaskKey, mask ? [NSValue valueWithNonretainedObject:mask] : nil, OBJC_ASSOCIATION_RETAIN);
        node.mask = mask ? makeMaskCopy(mask) : nil;
    }
    if (mask)
        syncMaskCopy(mask, node.mask, owner);
}

// One mirror node per layer between the boundary and the backdrop layer, and one for the boundary. Transform
// layers stay transform layers, so 3D geometry composes as it does in the layer tree; the others carry their
// clips, masks and group opacity.
static void syncPathNode(CALayer *original, CALayer *node, WebBackdropLayerAquaWebKit *owner)
{
    copyGeometry(original, node, true);
    setDoubleSided(node, original.doubleSided);
    bool hidden = layerIsNotRendered(original);
    if (hidden != node.hidden)
        node.hidden = hidden;
    if (isTransformLayer(node)) {
        copyAnimations(original, node, geometryKeyPaths(), @"layer");
        return;
    }
    copyClip(original, node);
    setOpacity(node, original.opacity);
    syncMask(original, node, owner);
    copyAnimations(original, node, groupKeyPaths(), @"layer");
}

// The backdrop layer's own shape: its bounds and corners, or its shape mask, which also carries its coverage. A
// single-sided transform layer culls its sublayers that face away; inside a mask only the leaf's own side does.
static void syncLeaf(CALayer *backdropLayer, CALayer *leaf, bool hasSingleSidedTransformLayerAncestor, WebBackdropLayerAquaWebKit *owner)
{
    copyGeometry(backdropLayer, leaf, true);
    setDoubleSided(leaf, backdropLayer.doubleSided && !hasSingleSidedTransformLayerAncestor);
    copyAnimations(backdropLayer, leaf, geometryKeyPaths(), @"layer");
    CALayer *mask = [(WebBackdropLayerAquaWebKit *)backdropLayer maskForCoverage];
    // Without a mask the background carries the shape; a rounded clip over it would cover the corners twice.
    bool clips = mask && backdropLayer.masksToBounds;
    if (leaf.masksToBounds != clips)
        leaf.masksToBounds = clips;
    if (leaf.cornerRadius != backdropLayer.cornerRadius)
        leaf.cornerRadius = backdropLayer.cornerRadius;
    CALayer *maskCopy = leaf.sublayers.firstObject;
    NSValue *copiedMask = objc_getAssociatedObject(leaf, &originalMaskKey);
    if (copiedMask.nonretainedObjectValue != mask || !maskCopy != !mask) {
        objc_setAssociatedObject(leaf, &originalMaskKey, mask ? [NSValue valueWithNonretainedObject:mask] : nil, OBJC_ASSOCIATION_RETAIN);
        maskCopy = mask ? makeMaskCopy(mask) : nil;
        leaf.sublayers = maskCopy ? @[ maskCopy ] : nil;
    }
    if (mask) {
        syncMaskCopy(mask, maskCopy, owner);
        if (leaf.backgroundColor)
            leaf.backgroundColor = nil;
    } else if (!leaf.backgroundColor)
        leaf.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
}

@interface CAFilter (WebBackdropLayerAquaWebKit)
@property (readonly) NSString *type;
@end

static bool isFilter(id filter, NSString *type)
{
    return [filter isKindOfClass:CAFilter.class] && [[static_cast<CAFilter *>(filter) type] isEqualToString:type];
}

template<typename T> static bool isAlphaOnlyColorMatrix(const T (&matrix)[20])
{
    static constexpr T identityRGBAndAlpha[] = {
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0
    };
    for (size_t i = 0; i < 20; ++i) {
        if (i == 18)
            continue;
        if (matrix[i] != identityRGBAndAlpha[i])
            return false;
    }
    return true;
}

static bool isAlphaOnlyColorMatrixValue(id value)
{
    if (![value isKindOfClass:NSValue.class])
        return false;
    NSUInteger size = 0;
    NSGetSizeAndAlignment([static_cast<NSValue *>(value) objCType], &size, nullptr);
    if (size == sizeof(float) * 20) {
        float matrix[20];
        [static_cast<NSValue *>(value) getValue:matrix];
        return isAlphaOnlyColorMatrix(matrix);
    }
    if (size == sizeof(double) * 20) {
        double matrix[20];
        [static_cast<NSValue *>(value) getValue:matrix];
        return isAlphaOnlyColorMatrix(matrix);
    }
    return false;
}

static bool filterKeyPathMatches(NSString *keyPath, NSString *prefix, NSString *name)
{
    NSArray *components = [keyPath componentsSeparatedByString:@"."];
    return components.count == 3 && [components[0] isEqualToString:prefix] && [components[1] isEqualToString:name]
        && [components[2] isEqualToString:@"inputColorMatrix"];
}

// Returns whether every value an animation supplies to one filter is alpha-only. Animations of other properties do
// not participate in that filter's classification.
static bool animationValuesAreAlphaOnly(CAAnimation *animation, NSString *prefix, NSString *name, bool& animatesFilter)
{
    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation *child in static_cast<CAAnimationGroup *>(animation).animations) {
            if (!animationValuesAreAlphaOnly(child, prefix, name, animatesFilter))
                return false;
        }
        return true;
    }
    if (![animation isKindOfClass:CAPropertyAnimation.class])
        return true;
    auto* propertyAnimation = static_cast<CAPropertyAnimation *>(animation);
    if (!filterKeyPathMatches(propertyAnimation.keyPath, prefix, name))
        return true;
    animatesFilter = true;
    if ([animation isKindOfClass:CAKeyframeAnimation.class]) {
        for (id value in static_cast<CAKeyframeAnimation *>(animation).values) {
            if (!isAlphaOnlyColorMatrixValue(value))
                return false;
        }
        return true;
    }
    if (![animation isKindOfClass:CABasicAnimation.class])
        return false;
    auto* basicAnimation = static_cast<CABasicAnimation *>(animation);
    NSNull *null = [NSNull null];
    for (id value in @[ basicAnimation.fromValue ?: null, basicAnimation.toValue ?: null, basicAnimation.byValue ?: null ]) {
        if (value != null && !isAlphaOnlyColorMatrixValue(value))
            return false;
    }
    return true;
}

static bool isAlphaOnlyFilter(id filter, NSDictionary *animations, NSString *prefix)
{
    if (!isFilter(filter, kCAFilterColorMatrix) || !isAlphaOnlyColorMatrixValue([filter valueForKey:@"inputColorMatrix"]))
        return false;
    NSString *name = [filter name];
    if (!name)
        return true;
    for (CAAnimation *animation in [animations allValues]) {
        bool animatesFilter = false;
        if (!animationValuesAreAlphaOnly(animation, prefix, name, animatesFilter))
            return false;
        NSString *otherPrefix = [prefix isEqualToString:@"filters"] ? @"backgroundFilters" : @"filters";
        if (!animationValuesAreAlphaOnly(animation, otherPrefix, name, animatesFilter))
            return false;
    }
    return true;
}

static bool isAlphaOnlyFilter(id filter, CALayer *layer, NSString *prefix)
{
    NSMutableDictionary *animations = [NSMutableDictionary dictionary];
    for (NSString *key in layer.animationKeys) {
        if (CAAnimation *animation = [layer animationForKey:key])
            animations[key] = animation;
    }
    return isAlphaOnlyFilter(filter, animations, prefix);
}

static id filterNamed(NSArray *filters, NSString *name)
{
    for (id filter in filters) {
        if ([[filter name] isEqualToString:name])
            return filter;
    }
    return nil;
}

static RetainPtr<CAAnimation> animationForOpacityFilters(CAAnimation *animation, NSArray *filters)
{
    return copyAnimationSelectingKeyPaths(animation, ^NSString *(NSString *keyPath) {
        NSArray *components = [keyPath componentsSeparatedByString:@"."];
        if (components.count != 3 || (![components[0] isEqualToString:@"backgroundFilters"] && ![components[0] isEqualToString:@"filters"])
            || ![components[2] isEqualToString:@"inputColorMatrix"] || !filterNamed(filters, components[1]))
            return nil;
        return [NSString stringWithFormat:@"filters.%@.inputColorMatrix", components[1]];
    });
}

static RetainPtr<CAAnimation> animationWithoutOpacityFilters(CAAnimation *animation, NSArray *filters)
{
    return copyAnimationSelectingKeyPaths(animation, ^NSString *(NSString *keyPath) {
        NSArray *components = [keyPath componentsSeparatedByString:@"."];
        if (components.count == 3 && ([components[0] isEqualToString:@"backgroundFilters"] || [components[0] isEqualToString:@"filters"])
            && [components[2] isEqualToString:@"inputColorMatrix"] && filterNamed(filters, components[1]))
            return nil;
        return keyPath;
    });
}

static bool animationTargetsFilterPrefix(CAAnimation *animation, NSString *prefix)
{
    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation *child in static_cast<CAAnimationGroup *>(animation).animations) {
            if (animationTargetsFilterPrefix(child, prefix))
                return true;
        }
        return false;
    }
    if (![animation isKindOfClass:CAPropertyAnimation.class])
        return false;
    return [static_cast<CAPropertyAnimation *>(animation).keyPath hasPrefix:[prefix stringByAppendingString:@"."]];
}

static bool hasEdgeMode(id filter, NSString *key)
{
    return isFilter(filter, kCAFilterGaussianBlur) && [[filter valueForKey:key] boolValue];
}

static CAFilter *opaqueFilter()
{
    static NeverDestroyed<RetainPtr<CAFilter>> filter = [] {
        CAFilter *filter = [CAFilter filterWithType:kCAFilterColorMatrix];
        CAColorMatrix matrix = { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1 };
        [filter setValue:[NSValue valueWithCAColorMatrix:matrix] forKey:@"inputColorMatrix"];
        [filter setName:@"aquawebkitOpaque"];
        return RetainPtr { filter };
    }();
    return filter.get().get();
}

#pragma mark - Footprints

namespace {

struct Geometry {
    CGPoint position { };
    CGFloat zPosition { 0 };
    CGRect bounds { };
    CGPoint anchorPoint { };
    CGFloat anchorPointZ { 0 };
    CATransform3D transform { CATransform3DIdentity };
    CATransform3D sublayerTransform { CATransform3DIdentity };
};

static Geometry geometryOf(CALayer *layer)
{
    return { layer.position, layer.zPosition, layer.bounds, layer.anchorPoint, layer.anchorPointZ, layer.transform, layer.sublayerTransform };
}

// Intervals bound the footprint over an animation: every value an animated property takes lies in its interval, and
// interval arithmetic over the chain bounds every corner the footprint takes.
struct Interval {
    double lo { 0 };
    double hi { 0 };
};

static Interval exactly(double value)
{
    return { value, value };
}

static Interval hull(Interval a, Interval b)
{
    return { std::min(a.lo, b.lo), std::max(a.hi, b.hi) };
}

static Interval operator+(Interval a, Interval b)
{
    return { a.lo + b.lo, a.hi + b.hi };
}

static Interval operator-(Interval a, Interval b)
{
    return { a.lo - b.hi, a.hi - b.lo };
}

static Interval operator*(Interval a, Interval b)
{
    double p[] = { a.lo * b.lo, a.lo * b.hi, a.hi * b.lo, a.hi * b.hi };
    return { *std::min_element(p, p + 4), *std::max_element(p, p + 4) };
}

// The values a linear interpolation from `a` to `b` takes over progress in `progress`.
static Interval lerp(double a, double b, Interval progress)
{
    return hull(exactly(a + (b - a) * progress.lo), exactly(a + (b - a) * progress.hi));
}

static Interval trigonometricRange(Interval angle, bool cosine)
{
    if (!std::isfinite(angle.lo) || !std::isfinite(angle.hi) || angle.hi - angle.lo >= 2 * M_PI)
        return { -1, 1 };
    auto value = [&](double angle) { return cosine ? std::cos(angle) : std::sin(angle); };
    Interval result = hull(exactly(value(angle.lo)), exactly(value(angle.hi)));
    auto containsExtremum = [&](double phase) {
        double lower = std::nextafter((angle.lo - phase) / (2 * M_PI), -INFINITY);
        double upper = std::nextafter((angle.hi - phase) / (2 * M_PI), INFINITY);
        return std::ceil(lower) <= std::floor(upper);
    };
    if (containsExtremum(cosine ? 0 : M_PI_2))
        result.hi = 1;
    if (containsExtremum(cosine ? M_PI : -M_PI_2))
        result.lo = -1;
    return result;
}

static Interval sinOver(Interval angle)
{
    return trigonometricRange(angle, false);
}

static Interval cosOver(Interval angle)
{
    return trigonometricRange(angle, true);
}

using IMatrix = std::array<Interval, 16>;

static IMatrix exactly(const CATransform3D& t)
{
    return { exactly(t.m11), exactly(t.m12), exactly(t.m13), exactly(t.m14), exactly(t.m21), exactly(t.m22), exactly(t.m23), exactly(t.m24),
        exactly(t.m31), exactly(t.m32), exactly(t.m33), exactly(t.m34), exactly(t.m41), exactly(t.m42), exactly(t.m43), exactly(t.m44) };
}

static IMatrix identityMatrix()
{
    return exactly(CATransform3DIdentity);
}

// a × b in the row-vector convention: a applies first, as in CATransform3DConcat(a, b).
static IMatrix concat(const IMatrix& a, const IMatrix& b)
{
    IMatrix result;
    for (int i = 0; i < 4; ++i) {
        for (int j = 0; j < 4; ++j) {
            Interval sum = exactly(0);
            for (int k = 0; k < 4; ++k)
                sum = sum + a[i * 4 + k] * b[k * 4 + j];
            result[i * 4 + j] = sum;
        }
    }
    return result;
}

static IMatrix hull(const IMatrix& a, const IMatrix& b)
{
    IMatrix result;
    for (int i = 0; i < 16; ++i)
        result[i] = hull(a[i], b[i]);
    return result;
}

static bool isIdentity(const IMatrix& m)
{
    IMatrix identity = identityMatrix();
    for (int i = 0; i < 16; ++i) {
        if (m[i].lo != identity[i].lo || m[i].hi != identity[i].hi)
            return false;
    }
    return true;
}

struct IPoint {
    Interval x;
    Interval y;
    Interval z;
};

static bool apply(const IMatrix& m, IPoint& p)
{
    Interval x = p.x * m[0] + p.y * m[4] + p.z * m[8] + m[12];
    Interval y = p.x * m[1] + p.y * m[5] + p.z * m[9] + m[13];
    Interval z = p.x * m[2] + p.y * m[6] + p.z * m[10] + m[14];
    Interval w = p.x * m[3] + p.y * m[7] + p.z * m[11] + m[15];
    if (w.lo <= 0)
        return false;
    Interval inverse { 1 / w.hi, 1 / w.lo };
    p = { x * inverse, y * inverse, z * inverse };
    return true;
}

struct IGeometry {
    Interval positionX, positionY, zPosition;
    Interval boundsX, boundsY, boundsWidth, boundsHeight;
    Interval anchorX, anchorY, anchorZ;
    IMatrix transform;
    IMatrix sublayerTransform;
};

static IGeometry exactly(const Geometry& g)
{
    return { exactly(g.position.x), exactly(g.position.y), exactly(g.zPosition), exactly(CGRectGetMinX(g.bounds)), exactly(CGRectGetMinY(g.bounds)),
        exactly(CGRectGetWidth(g.bounds)), exactly(CGRectGetHeight(g.bounds)), exactly(g.anchorPoint.x), exactly(g.anchorPoint.y), exactly(g.anchorPointZ),
        exactly(g.transform), exactly(g.sublayerTransform) };
}

static IGeometry hull(const IGeometry& a, const IGeometry& b)
{
    return { hull(a.positionX, b.positionX), hull(a.positionY, b.positionY), hull(a.zPosition, b.zPosition), hull(a.boundsX, b.boundsX), hull(a.boundsY, b.boundsY),
        hull(a.boundsWidth, b.boundsWidth), hull(a.boundsHeight, b.boundsHeight), hull(a.anchorX, b.anchorX), hull(a.anchorY, b.anchorY), hull(a.anchorZ, b.anchorZ),
        hull(a.transform, b.transform), hull(a.sublayerTransform, b.sublayerTransform) };
}

static bool mapToSuperlayer(const IGeometry& layer, const IGeometry& superlayer, IPoint& p)
{
    IPoint q { p.x - (layer.boundsX + layer.anchorX * layer.boundsWidth), p.y - (layer.boundsY + layer.anchorY * layer.boundsHeight), p.z - layer.anchorZ };
    if (!apply(layer.transform, q))
        return false;
    q = { q.x + layer.positionX, q.y + layer.positionY, q.z + layer.zPosition };
    if (!isIdentity(superlayer.sublayerTransform)) {
        Interval anchorX = superlayer.boundsX + superlayer.anchorX * superlayer.boundsWidth;
        Interval anchorY = superlayer.boundsY + superlayer.anchorY * superlayer.boundsHeight;
        q = { q.x - anchorX, q.y - anchorY, q.z };
        if (!apply(superlayer.sublayerTransform, q))
            return false;
        q = { q.x + anchorX, q.y + anchorY, q.z };
    }
    p = q;
    return true;
}

// Bounds of the footprint over the intervals, in the parent's and in the surface's coordinates.
static std::optional<std::pair<CGRect, CGRect>> footprintExtent(const Vector<IGeometry>& chain, size_t parentIndex, size_t surfaceIndex)
{
    Interval left = chain[0].boundsX, top = chain[0].boundsY;
    Interval right = chain[0].boundsX + chain[0].boundsWidth, bottom = chain[0].boundsY + chain[0].boundsHeight;
    std::array<IPoint, 4> quad { IPoint { left, top, exactly(0) }, IPoint { right, top, exactly(0) }, IPoint { right, bottom, exactly(0) }, IPoint { left, bottom, exactly(0) } };
    auto extent = [](const std::array<IPoint, 4>& points) {
        Interval x = points[0].x, y = points[0].y;
        for (auto& p : points) {
            x = hull(x, p.x);
            y = hull(y, p.y);
        }
        return CGRectMake(x.lo, y.lo, x.hi - x.lo, y.hi - y.lo);
    };
    CGRect inParent = CGRectNull;
    for (size_t i = 1; i <= surfaceIndex + 1; ++i) {
        for (auto& p : quad) {
            if (!mapToSuperlayer(chain[i - 1], chain[i], p))
                return std::nullopt;
        }
        if (i == parentIndex + 1)
            inParent = extent(quad);
    }
    return { { inParent, extent(quad) } };
}

// An animation of a layer's transform, with the time it starts in its layer's time. GraphicsLayerCA animates only the
// transform of a layer's geometry.
struct TransformAnimation {
    size_t chainIndex { 0 };
    RetainPtr<CAPropertyAnimation> animation;
    CFTimeInterval groupBeginTime { 0 };
};

static void collectTransformAnimations(CAAnimation *animation, CFTimeInterval groupBeginTime, size_t chainIndex, Vector<TransformAnimation>& result)
{
    if ([animation isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation *child in static_cast<CAAnimationGroup *>(animation).animations)
            collectTransformAnimations(child, groupBeginTime + animation.beginTime, chainIndex, result);
        return;
    }
    if ([animation isKindOfClass:CAPropertyAnimation.class] && [static_cast<CAPropertyAnimation *>(animation).keyPath isEqualToString:@"transform"])
        result.append({ chainIndex, static_cast<CAPropertyAnimation *>(animation), groupBeginTime });
}

// A value function's parameters: a number or an array of numbers.
static Vector<double> parameters(id value)
{
    if ([value isKindOfClass:NSNumber.class])
        return { [value doubleValue] };
    Vector<double> result;
    ASSERT([value isKindOfClass:NSArray.class]);
    for (id number in value)
        result.append([number doubleValue]);
    return result;
}

// The values of a transform animation as keyframes: each segment from one value to the next, and the progress values
// its timing reaches.
struct Keyframes {
    Vector<RetainPtr<id>> values;
    Vector<Interval> progress;
};

static Interval progressRange(CAMediaTimingFunction *function)
{
    if (!function)
        return { 0, 1 };
    float first[2], second[2];
    [function getControlPointAtIndex:1 values:first];
    [function getControlPointAtIndex:2 values:second];
    return { std::min({ 0.f, first[1], second[1] }), std::max({ 1.f, first[1], second[1] }) };
}

// A spring's progress is 1 - x(t), where x is a damped oscillator from 1 with velocity -v0. Its envelope bounds |x|.
static Interval springProgressRange(CASpringAnimation *spring)
{
    double mass = [[spring valueForKey:@"mass"] doubleValue];
    double stiffness = [[spring valueForKey:@"stiffness"] doubleValue];
    double damping = [[spring valueForKey:@"damping"] doubleValue];
    double velocity = [[spring valueForKey:@"velocity"] doubleValue];
    if (mass <= 0 || stiffness <= 0 || damping < 0)
        return { -std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity() };
    double w0 = std::sqrt(stiffness / mass);
    double zeta = damping / (2 * std::sqrt(stiffness * mass));
    // The bound holds for either sign convention of the velocity.
    auto envelopeFor = [&](double v0) {
        if (zeta < 1) {
            double wd = w0 * std::sqrt(1 - zeta * zeta);
            double b = (zeta * w0 - v0) / wd;
            return std::sqrt(1 + b * b);
        }
        if (zeta == 1) {
            // (1 + b t) e^(-w0 t) peaks at b / w0 e^(w0 / b - 1), within |b| / w0.
            double b = w0 - v0;
            return std::max(1.0, std::abs(b) / w0);
        }
        double root = w0 * std::sqrt(zeta * zeta - 1);
        double r1 = -zeta * w0 + root, r2 = -zeta * w0 - root;
        double c1 = (-v0 - r2) / (r1 - r2);
        return std::abs(c1) + std::abs(1 - c1);
    };
    double envelope = std::max(envelopeFor(velocity), envelopeFor(-velocity));
    return { 1 - envelope, 1 + envelope };
}

static Keyframes keyframesOf(CAPropertyAnimation *animation, id modelValue)
{
    Keyframes result;
    if ([animation isKindOfClass:CAKeyframeAnimation.class]) {
        auto* keyframe = static_cast<CAKeyframeAnimation *>(animation);
        for (id value in keyframe.values)
            result.values.append(value);
        NSArray *functions = keyframe.timingFunctions;
        for (size_t i = 0; i + 1 < result.values.size(); ++i)
            result.progress.append(progressRange(i < functions.count ? functions[i] : keyframe.timingFunction));
    } else {
        // A basic animation runs from its from value, or the model value, to its to value, or the model value.
        auto* basic = static_cast<CABasicAnimation *>(animation);
        result.values = { basic.fromValue ?: modelValue, basic.toValue ?: modelValue };
        result.progress = { [animation isKindOfClass:CASpringAnimation.class] ? springProgressRange(static_cast<CASpringAnimation *>(animation)) : progressRange(animation.timingFunction) };
    }
    if (result.values.size() == 1)
        result.values.append(result.values[0]);
    return result;
}

// The matrix of a value function at the parameter intervals.
static IMatrix valueFunctionMatrix(NSString *name, const Vector<Interval>& parameters)
{
    auto parameter = [&](size_t i, double fallback) {
        return i < parameters.size() ? parameters[i] : exactly(fallback);
    };
    IMatrix m = identityMatrix();
    auto rotation = [&](Interval angle, int axis) {
        Interval c = cosOver(angle), s = sinOver(angle), negativeS = exactly(0) - s;
        // CATransform3DMakeRotation about the x, y or z axis.
        if (axis == 0) {
            m[5] = c; m[6] = s; m[9] = negativeS; m[10] = c;
        } else if (axis == 1) {
            m[0] = c; m[2] = negativeS; m[8] = s; m[10] = c;
        } else {
            m[0] = c; m[1] = s; m[4] = negativeS; m[5] = c;
        }
    };
    if ([name isEqualToString:kCAValueFunctionTranslate]) {
        m[12] = parameter(0, 0); m[13] = parameter(1, 0); m[14] = parameter(2, 0);
    } else if ([name isEqualToString:kCAValueFunctionTranslateX])
        m[12] = parameter(0, 0);
    else if ([name isEqualToString:kCAValueFunctionTranslateY])
        m[13] = parameter(0, 0);
    else if ([name isEqualToString:kCAValueFunctionTranslateZ])
        m[14] = parameter(0, 0);
    else if ([name isEqualToString:kCAValueFunctionScale]) {
        m[0] = parameter(0, 1); m[5] = parameter(1, 1); m[10] = parameter(2, 1);
    } else if ([name isEqualToString:kCAValueFunctionScaleX])
        m[0] = parameter(0, 1);
    else if ([name isEqualToString:kCAValueFunctionScaleY])
        m[5] = parameter(0, 1);
    else if ([name isEqualToString:kCAValueFunctionScaleZ])
        m[10] = parameter(0, 1);
    else if ([name isEqualToString:kCAValueFunctionRotateX])
        rotation(parameter(0, 0), 0);
    else if ([name isEqualToString:kCAValueFunctionRotateY])
        rotation(parameter(0, 0), 1);
    else {
        ASSERT([name isEqualToString:kCAValueFunctionRotateZ]);
        rotation(parameter(0, 0), 2);
    }
    return m;
}

// A transform's decomposition, each component over an interval.
struct IDecomposed {
    Interval perspective[4];
    Interval translate[3];
    Interval scale[3];
    Interval skew[3];
    Interval quaternion[4];
};

// The matrices of the decompositions, recomposed in TransformationMatrix::recompose4's order.
static IMatrix recompose(const IDecomposed& d)
{
    IMatrix m = identityMatrix();
    m[3] = d.perspective[0];
    m[7] = d.perspective[1];
    m[11] = d.perspective[2];
    m[15] = d.perspective[3];

    IMatrix translation = identityMatrix();
    translation[12] = d.translate[0];
    translation[13] = d.translate[1];
    translation[14] = d.translate[2];
    m = concat(translation, m);

    IMatrix rotation = identityMatrix();
    Interval qx = d.quaternion[0], qy = d.quaternion[1], qz = d.quaternion[2], qw = d.quaternion[3];
    Interval two = exactly(2), one = exactly(1);
    rotation[0] = one - two * (qy * qy + qz * qz);
    rotation[1] = two * (qx * qy + qz * qw);
    rotation[2] = two * (qx * qz - qy * qw);
    rotation[4] = two * (qx * qy - qz * qw);
    rotation[5] = one - two * (qx * qx + qz * qz);
    rotation[6] = two * (qy * qz + qx * qw);
    rotation[8] = two * (qx * qz + qy * qw);
    rotation[9] = two * (qy * qz - qx * qw);
    rotation[10] = one - two * (qx * qx + qy * qy);
    m = concat(rotation, m);

    IMatrix skew = identityMatrix();
    skew[9] = d.skew[2];
    m = concat(skew, m);
    skew = identityMatrix();
    skew[8] = d.skew[1];
    m = concat(skew, m);
    skew = identityMatrix();
    skew[4] = d.skew[0];
    m = concat(skew, m);

    IMatrix scale = identityMatrix();
    scale[0] = d.scale[0];
    scale[5] = d.scale[1];
    scale[10] = d.scale[2];
    return concat(scale, m);
}

// The matrices an interpolation from `from` to `to` passes through: perspective, translation, scale and skew
// interpolate linearly, the rotation along the slerp of the two quaternions. Core Animation holds a transform that
// does not decompose until the segment ends.
static IMatrix segmentMatrix(const CATransform3D& from, const CATransform3D& to, Interval progress)
{
    WebCore::TransformationMatrix::Decomposed4Type a, b;
    if (!WebCore::TransformationMatrix(from).decompose4(a) || !WebCore::TransformationMatrix(to).decompose4(b))
        return hull(exactly(from), exactly(to));
    IDecomposed d;
    double perspectiveA[] = { a.perspectiveX, a.perspectiveY, a.perspectiveZ, a.perspectiveW };
    double perspectiveB[] = { b.perspectiveX, b.perspectiveY, b.perspectiveZ, b.perspectiveW };
    double translateA[] = { a.translateX, a.translateY, a.translateZ }, translateB[] = { b.translateX, b.translateY, b.translateZ };
    double scaleA[] = { a.scaleX, a.scaleY, a.scaleZ }, scaleB[] = { b.scaleX, b.scaleY, b.scaleZ };
    double skewA[] = { a.skewXY, a.skewXZ, a.skewYZ }, skewB[] = { b.skewXY, b.skewXZ, b.skewYZ };
    for (int i = 0; i < 4; ++i)
        d.perspective[i] = lerp(perspectiveA[i], perspectiveB[i], progress);
    for (int i = 0; i < 3; ++i) {
        d.translate[i] = lerp(translateA[i], translateB[i], progress);
        d.scale[i] = lerp(scaleA[i], scaleB[i], progress);
        d.skew[i] = lerp(skewA[i], skewB[i], progress);
    }

    // Quaternion::slerp: each component is qa sin((1 - t) w) / sin w + qb sin(t w) / sin w, which is
    // R sin(t w + phi) / sin w, with qa when the two share their axis and angle.
    auto qa = a.quaternion, qb = b.quaternion;
    double dot = qa.x * qb.x + qa.y * qb.y + qa.z * qb.z + qa.w * qb.w;
    if (dot < 0) {
        qa = { -qa.x, -qa.y, -qa.z, -qa.w };
        dot = -dot;
    }
    dot = std::min(dot, 1.0);
    double sinHalfAngle = std::sqrt(1 - dot * dot);
    double componentsA[] = { qa.x, qa.y, qa.z, qa.w }, componentsB[] = { qb.x, qb.y, qb.z, qb.w };
    if (sinHalfAngle < 1e-5) {
        double unflipped[] = { a.quaternion.x, a.quaternion.y, a.quaternion.z, a.quaternion.w };
        for (int i = 0; i < 4; ++i)
            d.quaternion[i] = exactly(unflipped[i]);
        return recompose(d);
    }
    double halfAngle = std::acos(dot);
    for (int i = 0; i < 4; ++i) {
        double cosine = componentsB[i] - componentsA[i] * dot;
        double sine = componentsA[i] * sinHalfAngle;
        double phase = std::atan2(sine, cosine);
        d.quaternion[i] = exactly(std::hypot(sine, cosine) / sinHalfAngle) * sinOver({ progress.lo * halfAngle + phase, progress.hi * halfAngle + phase });
    }
    return recompose(d);
}

// The matrices a transform animation's values pass through.
static IMatrix transformValuesMatrix(const Keyframes& keyframes, NSString *valueFunction)
{
    std::optional<IMatrix> result;
    for (size_t segment = 0; segment + 1 < keyframes.values.size(); ++segment) {
        IMatrix matrix;
        Interval progress = keyframes.progress[segment];
        if (valueFunction) {
            auto from = parameters(keyframes.values[segment].get());
            auto to = parameters(keyframes.values[segment + 1].get());
            Vector<Interval> intervals;
            for (size_t i = 0; i < std::min(from.size(), to.size()); ++i)
                intervals.append(lerp(from[i], to[i], progress));
            matrix = valueFunctionMatrix(valueFunction, intervals);
        } else {
            CATransform3D from = [keyframes.values[segment].get() CATransform3DValue];
            CATransform3D to = [keyframes.values[segment + 1].get() CATransform3DValue];
            matrix = CATransform3DEqualToTransform(from, to) ? exactly(from) : segmentMatrix(from, to, progress);
        }
        result = result ? hull(*result, matrix) : matrix;
    }
    return *result;
}

// Applies the interval of transforms an animation takes, after the animations before it on the same layer.
static void applyKeyframes(IGeometry& geometry, CAPropertyAnimation *animation, const Keyframes& keyframes)
{
    IMatrix values = transformValuesMatrix(keyframes, animation.valueFunction.name);
    // 10.9 Core Animation concatenates an additive transform onto the right of the value so far.
    geometry.transform = animation.additive ? concat(values, geometry.transform) : values;
}

static bool isAffine(const CATransform3D& t)
{
    return !t.m14 && !t.m24 && !t.m34 && t.m44 == 1;
}

// Whether a transform animation only translates its layer's content: a translation value function, or transforms that
// differ only in their translation.
static bool isTranslation(CAPropertyAnimation *animation, const Keyframes& keyframes)
{
    if (NSString *name = animation.valueFunction.name)
        return [name isEqualToString:kCAValueFunctionTranslate] || [name isEqualToString:kCAValueFunctionTranslateX] || [name isEqualToString:kCAValueFunctionTranslateY];
    CATransform3D first = [keyframes.values[0].get() CATransform3DValue];
    for (auto& value : keyframes.values) {
        CATransform3D t = [value.get() CATransform3DValue];
        if (t.m11 != first.m11 || t.m12 != first.m12 || t.m13 != first.m13 || t.m14 != first.m14 || t.m21 != first.m21 || t.m22 != first.m22 || t.m23 != first.m23 || t.m24 != first.m24
            || t.m31 != first.m31 || t.m32 != first.m32 || t.m33 != first.m33 || t.m34 != first.m34 || t.m43 != first.m43 || t.m44 != first.m44)
            return false;
    }
    return isAffine(first);
}

// The drawn volume in `layer`'s bounds coordinates, in its superlayer's, over its transform animations.
static std::optional<IPoint> mapExtentToSuperlayer(CALayer *layer, IPoint extent, CALayer *parent)
{
    Geometry model = geometryOf(layer);
    IGeometry geometry = exactly(model);
    Vector<TransformAnimation> animations;
    for (NSString *key in layer.animationKeys) {
        if (![key hasPrefix:cropAnimationKey])
            collectTransformAnimations([layer animationForKey:key], 0, 0, animations);
    }
    id modelTransform = [NSValue valueWithCATransform3D:model.transform];
    for (auto& animation : animations) {
        IGeometry applied = geometry;
        applyKeyframes(applied, animation.animation.get(), keyframesOf(animation.animation.get(), modelTransform));
        // Outside its active time an animation without fill leaves the model geometry.
        geometry = hull(geometry, applied);
    }
    IGeometry superlayer = exactly(parent ? geometryOf(parent) : Geometry { });
    if (!mapToSuperlayer(geometry, superlayer, extent))
        return std::nullopt;
    if (!std::isfinite(extent.x.lo) || !std::isfinite(extent.x.hi) || !std::isfinite(extent.y.lo) || !std::isfinite(extent.y.hi)
        || !std::isfinite(extent.z.lo) || !std::isfinite(extent.z.hi))
        return std::nullopt;
    return extent;
}

// Transform layers preserve their children's depth. Ordinary layers flatten their contents before their transform.
static std::optional<IPoint> extentInSuperlayer(CALayer *layer, unsigned depth, CALayer *parent)
{
    if (depth > 64 || layer.filters.count || layer.shadowOpacity > 0)
        return std::nullopt;
    CGRect bounds = layer.bounds;
    IPoint extent { { CGRectGetMinX(bounds), CGRectGetMaxX(bounds) }, { CGRectGetMinY(bounds), CGRectGetMaxY(bounds) }, exactly(0) };
    bool preservesDepth = isTransformLayer(layer);
    if (preservesDepth || !layer.masksToBounds) {
        for (CALayer *sublayer in layer.sublayers) {
            if (layerIsNotRendered(sublayer))
                continue;
            auto child = extentInSuperlayer(sublayer, depth + 1, layer);
            if (!child)
                return std::nullopt;
            extent = { hull(extent.x, child->x), hull(extent.y, child->y), hull(extent.z, child->z) };
        }
    }
    if (!preservesDepth)
        extent.z = exactly(0);
    return mapExtentToSuperlayer(layer, extent, parent);
}

// The pixels of its superlayer's surface that the background filters in `layer` read: those of the sampling surfaces
// it holds directly or through transform layers. Unknown when a backdrop layer there reads it without a known region.
static std::optional<CGRect> sampleRegionInSuperlayer(CALayer *layer, unsigned depth)
{
    if (layerIsNotRendered(layer))
        return CGRectNull;
    if (depth > 64)
        return std::nullopt;
    if ([layer isKindOfClass:WebBackdropLayerAquaWebKit.class]) {
        auto* backdrop = static_cast<WebBackdropLayerAquaWebKit *>(layer);
        if (!backdrop.backgroundFilters.count)
            return CGRectNull;
        CGRect region;
        if (![backdrop getSampleRegion:&region])
            return std::nullopt;
        return region;
    }
    // The layers in any other layer read that layer's surface; those in a transform layer read the same surface, so
    // their regions are already in its coordinates.
    if (!isTransformLayer(layer))
        return CGRectNull;
    CGRect region = CGRectNull;
    for (CALayer *sublayer in layer.sublayers) {
        auto sublayerRegion = sampleRegionInSuperlayer(sublayer, depth + 1);
        if (!sublayerRegion)
            return std::nullopt;
        region = CGRectUnion(region, *sublayerRegion);
    }
    return region;
}

} // namespace

#pragma mark - WebBackdropLayerAquaWebKit

@implementation WebBackdropLayerAquaWebKit {
    // Changes run one at a time under _updateLock, from the main thread or the scrolling thread, and call into Core
    // Animation. The state Core Animation reads back through the getters during a commit is published under
    // _presentedLock, which is held only to copy it.
    RecursiveLock _updateLock;
    Lock _presentedLock;
    BOOL _presentedHidden;
    BOOL _pathToSurfaceNotRendered;
    RetainPtr<NSArray> _assignedBackgroundFilters;
    RetainPtr<NSArray> _backgroundFilters;
    RetainPtr<NSArray> _committedBackgroundFilters;
    RetainPtr<NSArray> _opacityFilters;
    RetainPtr<NSDictionary> _filterAnimations;
    RetainPtr<NSDictionary> _maskAnimations;
    RetainPtr<CALayer> _opacityMask;

    // The geometry callers see.
    CGRect _presentedBounds;
    RetainPtr<CALayer> _presentedMask;
    BOOL _presentedMasksToBounds;
    CGFloat _presentedCornerRadius;

    // The crop: the footprint's bounding box in the sampling surface, null when the blur is not cropped.
    CGRect _crop;
    // The pixels of its sampling surface its filters read, over its animations, when known.
    CGRect _sampleRegion;
    BOOL _sampleRegionKnown;
    BOOL _samplesBackdropRoot;
    RetainPtr<CALayer> _cropMask;
    RetainPtr<CALayer> _cropClip;
    RetainPtr<CAAnimation> _cropAnimation;
    Vector<WeakObjCPtr<CALayer>> _cropLayers;
    NSUInteger _cropParentIndex;
    WeakObjCPtr<WebBackdropLayerAquaWebKit> _cropBackdropLayer;

    WeakObjCPtr<CALayer> _treeBoundary;
    WeakObjCPtr<WebBackdropLayerAquaWebKit> _treeBackdropLayer;
    WeakObjCPtr<WebBackdropLayerAquaWebKit> _samplingBackdropLayer;
    RetainPtr<CALayer> _maskRoot;
    RetainPtr<CALayer> _boundaryNode;
    Vector<RetainPtr<CALayer>> _pathNodes;
    Vector<const void*> _pathIdentity;
    RetainPtr<CALayer> _leaf;
    RetainPtr<NSArray> _groupFiltersSource;
}

- (instancetype)init
{
    if (!(self = [super init]))
        return nil;
    _crop = CGRectNull;
    _sampleRegion = CGRectNull;
    return self;
}

- (instancetype)initWithLayer:(id)layer
{
    if (!(self = [super initWithLayer:layer]))
        return nil;
    _crop = CGRectNull;
    _sampleRegion = CGRectNull;
    if ([layer isKindOfClass:WebBackdropLayerAquaWebKit.class]) {
        auto* other = static_cast<WebBackdropLayerAquaWebKit *>(layer);
        Locker locker { other->_presentedLock };
        _assignedBackgroundFilters = other->_assignedBackgroundFilters;
        _backgroundFilters = other->_backgroundFilters;
        _committedBackgroundFilters = other->_committedBackgroundFilters;
        _opacityFilters = other->_opacityFilters;
        _filterAnimations = other->_filterAnimations;
        _maskAnimations = other->_maskAnimations;
        _opacityMask = other->_opacityMask;
        _presentedBounds = other->_presentedBounds;
        _presentedMask = other->_presentedMask;
        _presentedMasksToBounds = other->_presentedMasksToBounds;
        _presentedCornerRadius = other->_presentedCornerRadius;
        _crop = other->_crop;
        _pathToSurfaceNotRendered = other->_pathToSurfaceNotRendered;
    }
    _presentedHidden = [super isHidden];
    return self;
}

#pragma mark Presented geometry

- (CGRect)bounds
{
    Locker locker { _presentedLock };
    return _presentedBounds;
}

- (void)setBounds:(CGRect)bounds
{
    Locker locker { _updateLock };
    {
        Locker presentedLocker { _presentedLock };
        _presentedBounds = bounds;
    }
    [self applyGeometry];
}

- (CALayer *)mask
{
    RetainPtr<CALayer> mask;
    {
        Locker locker { _presentedLock };
        mask = _presentedMask;
    }
    return mask.autorelease();
}

- (void)setMask:(CALayer *)mask
{
    Locker locker { _updateLock };
    if (_presentedMask && _presentedMask.get() != mask && (_presentedMask.get().superlayer == _cropClip.get() || _presentedMask.get().superlayer == _opacityMask.get()))
        [_presentedMask removeFromSuperlayer];
    {
        Locker presentedLocker { _presentedLock };
        _presentedMask = mask;
    }
    [self updateOpacityMask];
}

- (CALayer *)maskForCoverage
{
    RetainPtr<CALayer> mask;
    {
        Locker locker { _presentedLock };
        mask = _opacityMask ? _opacityMask : _presentedMask;
    }
    return mask.autorelease();
}

- (BOOL)masksToBounds
{
    Locker locker { _presentedLock };
    return _presentedMasksToBounds;
}

- (void)setMasksToBounds:(BOOL)masksToBounds
{
    Locker locker { _updateLock };
    {
        Locker presentedLocker { _presentedLock };
        _presentedMasksToBounds = masksToBounds;
    }
    [self applyGeometry];
}

- (CGFloat)cornerRadius
{
    Locker locker { _presentedLock };
    return _presentedCornerRadius;
}

- (void)setCornerRadius:(CGFloat)cornerRadius
{
    Locker locker { _updateLock };
    {
        Locker presentedLocker { _presentedLock };
        _presentedCornerRadius = cornerRadius;
    }
    [self applyGeometry];
}

// Uncropped, the layer is what it presents. Cropped, its bounds are the crop and its mask, at the crop's origin,
// carries the presented bounds, corners and mask.
- (void)applyGeometry
{
    Locker locker { _updateLock };
    bool cropping = !CGRectIsNull(_crop);
    CGRect bounds = cropping ? _crop : _presentedBounds;
    CALayer *coverage = _opacityMask ? _opacityMask.get() : _presentedMask.get();
    if (_opacityMask) {
        if (!CGRectEqualToRect([_opacityMask bounds], _presentedBounds))
            [_opacityMask setBounds:_presentedBounds];
        if (!CGPointEqualToPoint([_opacityMask position], _presentedBounds.origin))
            [_opacityMask setPosition:_presentedBounds.origin];
    }
    if (!CGRectEqualToRect([super bounds], bounds))
        [super setBounds:bounds];
    if (!cropping) {
        if (coverage.superlayer)
            [coverage removeFromSuperlayer];
        if ([super mask] != coverage)
            [super setMask:coverage];
        if ([super masksToBounds] != _presentedMasksToBounds)
            [super setMasksToBounds:_presentedMasksToBounds];
        if ([super cornerRadius] != _presentedCornerRadius)
            [super setCornerRadius:_presentedCornerRadius];
        return;
    }
    // A mask's own clip is ignored; the clip lies on its sublayer.
    if (!_cropMask) {
        _cropMask = makeLayer(CALayer.class);
        [_cropMask setAnchorPoint:CGPointZero];
        _cropClip = makeLayer(CALayer.class);
        [_cropClip setAnchorPoint:CGPointZero];
        [_cropMask addSublayer:_cropClip.get()];
    }
    CALayer *mask = _cropMask.get();
    CALayer *clip = _cropClip.get();
    if (!CGRectEqualToRect(mask.bounds, _presentedBounds))
        mask.bounds = _presentedBounds;
    if (!CGPointEqualToPoint(mask.position, _crop.origin))
        mask.position = _crop.origin;
    if (!CGRectEqualToRect(clip.bounds, _presentedBounds))
        clip.bounds = _presentedBounds;
    if (!CGPointEqualToPoint(clip.position, _presentedBounds.origin))
        clip.position = _presentedBounds.origin;
    if (clip.cornerRadius != _presentedCornerRadius)
        clip.cornerRadius = _presentedCornerRadius;
    // Without coverage the background carries the shape; a rounded clip over it would cover the corners twice.
    BOOL clips = coverage && (_presentedMasksToBounds || _presentedCornerRadius);
    if (clip.masksToBounds != clips)
        clip.masksToBounds = clips;
    if (coverage) {
        if (clip.backgroundColor)
            clip.backgroundColor = nil;
        if ([super mask] == coverage)
            [super setMask:nil];
        if (coverage.superlayer != clip)
            clip.sublayers = @[ coverage ];
    } else {
        if (!clip.backgroundColor)
            clip.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        if (clip.sublayers.count)
            clip.sublayers = nil;
    }
    if ([super mask] != mask)
        [super setMask:mask];
    if ([super masksToBounds])
        [super setMasksToBounds:NO];
    if ([super cornerRadius])
        [super setCornerRadius:0];
}

#pragma mark Filters

// Core Animation renders the filters this returns. 10.9 applies the background filters of a hidden layer, and of one
// inside hidden transform layers, to the sampling surface, so there are none while this layer, or a layer from its
// superlayer to that surface, is not rendered.
- (NSArray *)backgroundFilters
{
    RetainPtr<NSArray> filters;
    {
        Locker locker { _presentedLock };
        if (!_presentedHidden && !_pathToSurfaceNotRendered)
            filters = _committedBackgroundFilters;
    }
    return filters.autorelease();
}

- (NSArray *)assignedBackgroundFilters
{
    RetainPtr<NSArray> filters;
    {
        Locker locker { _presentedLock };
        filters = _assignedBackgroundFilters;
    }
    return filters.autorelease();
}

// The backdrop filters other than the alpha-only ones, before this layer adapts their edges.
- (NSArray *)colorBackgroundFilters
{
    RetainPtr<NSArray> filters;
    {
        Locker locker { _presentedLock };
        filters = _backgroundFilters;
    }
    return filters.autorelease();
}

// As on CABackdropLayer, the filters apply to the backdrop.
- (void)setFilters:(NSArray *)filters
{
    [self setBackgroundFilters:filters];
}

- (void)setBackgroundFilters:(NSArray *)backgroundFilters
{
    Locker locker { _updateLock };
    {
        Locker presentedLocker { _presentedLock };
        _assignedBackgroundFilters = adoptNS([backgroundFilters copy]);
    }
    [self updateFilterClassification];
    if (!_cropLayers.isEmpty())
        [self updateCrop];
}

- (void)updateFilterClassification
{
    Locker locker { _updateLock };
    RetainPtr colorFilters = adoptNS([[NSMutableArray alloc] initWithCapacity:[_assignedBackgroundFilters count]]);
    RetainPtr opacityFilters = adoptNS([[NSMutableArray alloc] init]);
    for (id filter in _assignedBackgroundFilters.get()) {
        if (isAlphaOnlyFilter(filter, _filterAnimations.get(), @"backgroundFilters"))
            [opacityFilters addObject:filter];
        else
            [colorFilters addObject:filter];
    }

    for (NSString *key in _filterAnimations.get()) {
        [super removeAnimationForKey:key];
        [_opacityMask removeAnimationForKey:key];
    }
    {
        Locker presentedLocker { _presentedLock };
        _backgroundFilters = colorFilters.get();
        _opacityFilters = opacityFilters.get();
        _maskAnimations = nil;
    }
    [self updateCommittedBackgroundFilters];
    [self updateOpacityMask];

    RetainPtr maskAnimations = adoptNS([[NSMutableDictionary alloc] init]);
    for (NSString *key in _filterAnimations.get()) {
        CAAnimation *animation = [_filterAnimations objectForKey:key];
        RetainPtr opacityAnimation = animationForOpacityFilters(animation, _opacityFilters.get());
        RetainPtr backdropAnimation = animationWithoutOpacityFilters(animation, _opacityFilters.get());
        if (opacityAnimation && backdropAnimation)
            [opacityAnimation setDelegate:nil];
        if (opacityAnimation) {
            [maskAnimations setObject:opacityAnimation.get() forKey:key];
            [_opacityMask addAnimation:opacityAnimation.get() forKey:key];
        }
        if (backdropAnimation)
            [super addAnimation:backdropAnimation.get() forKey:key];
    }
    {
        Locker presentedLocker { _presentedLock };
        _maskAnimations = adoptNS([maskAnimations copy]);
    }
}

- (void)setHidden:(BOOL)hidden
{
    Locker locker { _updateLock };
    {
        Locker presentedLocker { _presentedLock };
        _presentedHidden = hidden;
    }
    [super setHidden:hidden];
    [super setBackgroundFilters:self.backgroundFilters];
}

// A blur with hard or normalized edges reads only the crop: 10.9's hard edges extend the crop's edge pixels, and
// its edge smoothing on top of them weighs only the pixels inside, as normalized edges do. Uncropped, the blur
// reads the surface. Normalized edges are for an opaque backdrop root, whose backdrop the filters leave opaque; 10.9's
// cropped blur leaves it 1/255 translucent, and the layer sampling the root's surface restores its opacity.
- (void)updateCommittedBackgroundFilters
{
    Locker locker { _updateLock };
    bool cropping = !CGRectIsNull(_crop);
    bool normalizesCroppedEdges = false;
    RetainPtr filters = adoptNS([[NSMutableArray alloc] initWithCapacity:[_backgroundFilters count]]);
    for (id filter in _backgroundFilters.get()) {
        bool normalizesEdges = hasEdgeMode(filter, @"inputNormalizeEdges");
        if (!normalizesEdges && !hasEdgeMode(filter, @"inputHardEdges")) {
            [filters addObject:filter];
            continue;
        }
        RetainPtr<CAFilter> blur = adoptNS([filter copy]);
        [blur setValue:@NO forKey:@"inputNormalizeEdges"];
        [blur setValue:@(cropping) forKey:@"inputHardEdges"];
        [blur setValue:@(cropping && normalizesEdges ? 1 : 0) forKey:@"inputEdgeSmoothing"];
        [filters addObject:blur.get()];
        normalizesCroppedEdges |= cropping && normalizesEdges;
    }
    if (normalizesCroppedEdges && _samplesBackdropRoot)
        [filters addObject:opaqueFilter()];
    {
        Locker presentedLocker { _presentedLock };
        _committedBackgroundFilters = [filters count] ? filters.get() : nil;
    }
    [super setBackgroundFilters:self.backgroundFilters];
}

// Alpha-only filters act on the coverage mask, so their independent animated values multiply without changing
// the backdrop's colors or the shape's own fill and opacity.
- (void)updateOpacityMask
{
    Locker locker { _updateLock };
    if ([_opacityFilters count]) {
        bool created = !_opacityMask;
        if (created) {
            RetainPtr mask = makeLayer(CALayer.class);
            [mask setAnchorPoint:CGPointZero];
            Locker presentedLocker { _presentedLock };
            _opacityMask = WTF::move(mask);
        }
        if (![[_opacityMask filters] isEqualToArray:_opacityFilters.get()])
            [_opacityMask setFilters:_opacityFilters.get()];
        if (_presentedMask) {
            if ([_opacityMask backgroundColor])
                [_opacityMask setBackgroundColor:nil];
            if (_presentedMask.get().superlayer != _opacityMask.get())
                [_opacityMask setSublayers:@[ _presentedMask.get() ]];
        } else {
            [_opacityMask setSublayers:nil];
            [_opacityMask setBackgroundColor:CGColorGetConstantColor(kCGColorBlack)];
        }
        if (created) {
            for (NSString *key in _maskAnimations.get())
                [_opacityMask addAnimation:[_maskAnimations objectForKey:key] forKey:key];
        }
    } else if (_opacityMask) {
        [_presentedMask removeFromSuperlayer];
        Locker presentedLocker { _presentedLock };
        _opacityMask = nil;
    }
    [self applyGeometry];
}

- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key
{
    Locker locker { _updateLock };
    bool replacesFilterAnimation = !![_filterAnimations objectForKey:key];
    if (!animationTargetsFilterPrefix(animation, @"backgroundFilters") && !(replacesFilterAnimation && animationTargetsFilterPrefix(animation, @"filters"))) {
        [super addAnimation:animation forKey:key];
        return;
    }
    RetainPtr animations = adoptNS([_filterAnimations mutableCopy] ?: [[NSMutableDictionary alloc] init]);
    [animations setObject:animation forKey:key];
    {
        Locker presentedLocker { _presentedLock };
        _filterAnimations = adoptNS([animations copy]);
    }
    [self updateFilterClassification];
}

- (CAAnimation *)animationForKey:(NSString *)key
{
    RetainPtr<NSDictionary> filterAnimations;
    RetainPtr<NSDictionary> maskAnimations;
    RetainPtr<CALayer> mask;
    {
        Locker locker { _presentedLock };
        filterAnimations = _filterAnimations;
        maskAnimations = _maskAnimations;
        mask = _opacityMask;
    }
    if (CAAnimation *animation = [filterAnimations objectForKey:key])
        return animation;
    if (CAAnimation *maskAnimation = [maskAnimations objectForKey:key])
        return [mask animationForKey:key] ?: maskAnimation;
    return [super animationForKey:key];
}

- (void)removeAnimationForKey:(NSString *)key
{
    Locker locker { _updateLock };
    if ([_filterAnimations objectForKey:key]) {
        [super removeAnimationForKey:key];
        [_opacityMask removeAnimationForKey:key];
        RetainPtr animations = adoptNS([_filterAnimations mutableCopy]);
        [animations removeObjectForKey:key];
        {
            Locker presentedLocker { _presentedLock };
            _filterAnimations = adoptNS([animations copy]);
        }
        [self updateFilterClassification];
        return;
    }
    [super removeAnimationForKey:key];
}

- (void)removeAllAnimations
{
    Locker locker { _updateLock };
    for (NSString *key in _maskAnimations.get())
        [_opacityMask removeAnimationForKey:key];
    {
        Locker presentedLocker { _presentedLock };
        _filterAnimations = nil;
        _maskAnimations = nil;
    }
    [super removeAllAnimations];
    [self updateFilterClassification];
    _cropAnimation = nil;
    [_cropMask removeAnimationForKey:cropAnimationKey];
}

#pragma mark Crop

- (void)setSamplesBackdropRoot:(BOOL)samplesBackdropRoot
{
    Locker locker { _updateLock };
    if (_samplesBackdropRoot == samplesBackdropRoot)
        return;
    _samplesBackdropRoot = samplesBackdropRoot;
    [self updateCommittedBackgroundFilters];
}

- (void)setCropLayers:(NSArray *)layers parentIndex:(NSUInteger)parentIndex backdropLayer:(WebBackdropLayerAquaWebKit *)backdropLayer
{
    Locker locker { _updateLock };
    bool same = layers.count == _cropLayers.size() && _cropBackdropLayer.get().get() == backdropLayer;
    for (NSUInteger i = 0; same && i < layers.count; ++i)
        same = _cropLayers[i].get().get() == layers[i];
    if (!same) {
        for (auto& layer : _cropLayers) {
            if (RetainPtr previous = layer.get(); previous && ![layers containsObject:previous.get()])
                updateFollowers(previous.get(), &croppedLayersKey, self, self, false);
        }
        _cropLayers.clear();
        for (CALayer *layer in layers) {
            _cropLayers.append(layer);
            updateFollowers(layer, &croppedLayersKey, self, self, true);
        }
        _cropBackdropLayer = backdropLayer;
    }
    _cropParentIndex = parentIndex;
    [self updateCrop];
}

// The crop is the bounding box of the backdrop layer's footprint in this layer's sampling surface, over every value
// the chain's geometry animations take. A translation of the footprint moves the crop and the mask with it instead.
// A footprint behind the viewer under a perspective leaves the blur uncropped.
- (void)updateCrop
{
    Locker locker { _updateLock };
    RetainPtr backdropLayer = _cropBackdropLayer.get();
    Vector<RetainPtr<CALayer>> layers;
    for (auto& weakLayer : _cropLayers) {
        RetainPtr layer = weakLayer.get();
        if (!layer)
            break;
        layers.append(WTF::move(layer));
    }
    size_t parentIndex = _cropParentIndex;
    if (parentIndex == NSNotFound) {
        parentIndex = layers.findIf([&](auto& layer) {
            return layer.get() == self.superlayer;
        });
    }
    size_t surfaceIndex = notFound;
    for (size_t i = parentIndex; backdropLayer && parentIndex != notFound && i < layers.size() && surfaceIndex == notFound; ++i) {
        if (!isTransformLayer(layers[i].get()))
            surfaceIndex = i;
    }
    bool pathToSurfaceNotRendered = !transformIsInvertible(self.transform);
    for (size_t i = parentIndex; parentIndex != notFound && i < layers.size() && !pathToSurfaceNotRendered; ++i) {
        pathToSurfaceNotRendered = layerIsNotRendered(layers[i].get());
        if (!isTransformLayer(layers[i].get()))
            break;
    }

    // Only a blur with hard or normalized edges reads a crop.
    bool readsCrop = false;
    for (id filter in _backgroundFilters.get())
        readsCrop |= hasEdgeMode(filter, @"inputNormalizeEdges") || hasEdgeMode(filter, @"inputHardEdges");

    std::optional<CGRect> crop;
    std::optional<CGRect> footprintInParent;
    std::optional<CGRect> sweptCrop;
    bool sampleRegionKnown = false;
    RetainPtr<CAPropertyAnimation> cropAnimation;
    if (surfaceIndex != notFound) {
        Vector<Geometry> model;
        model.append(geometryOf(backdropLayer.get()));
        for (size_t i = 0; i <= surfaceIndex; ++i)
            model.append(geometryOf(layers[i].get()));

        // The transform animations of the chain, in the order they apply on each layer, with their values.
        Vector<TransformAnimation> animations;
        for (size_t i = 0; i <= surfaceIndex; ++i) {
            CALayer *layer = i ? layers[i - 1].get() : backdropLayer.get();
            for (NSString *key in layer.animationKeys) {
                if (![key hasPrefix:cropAnimationKey])
                    collectTransformAnimations([layer animationForKey:key], 0, i, animations);
            }
        }
        Vector<Keyframes> keyframes;
        Vector<size_t> varying;
        for (size_t i = 0; i < animations.size(); ++i) {
            keyframes.append(keyframesOf(animations[i].animation.get(), [NSValue valueWithCATransform3D:model[animations[i].chainIndex].transform]));
            auto& values = keyframes.last().values;
            bool constant = true;
            for (auto& value : values)
                constant &= [value.get() isEqual:values[0].get()];
            if (!constant)
                varying.append(i);
        }

        // The chain over every value its animations take, or with the one at `index` at `value` or left out.
        auto chainWith = [&](std::optional<size_t> index, id value, bool leaveOut) {
            Vector<IGeometry> chain;
            for (auto& geometry : model)
                chain.append(exactly(geometry));
            for (size_t i = 0; i < animations.size(); ++i) {
                if (index && *index == i && leaveOut)
                    continue;
                Keyframes single;
                const Keyframes* values = &keyframes[i];
                if (index && *index == i) {
                    single.values = { value, value };
                    single.progress = { { 0, 1 } };
                    values = &single;
                }
                IGeometry& geometry = chain[animations[i].chainIndex];
                IGeometry applied = geometry;
                applyKeyframes(applied, animations[i].animation.get(), *values);
                // Outside its active time an animation without fill leaves the geometry as it was.
                geometry = index ? applied : hull(geometry, applied);
            }
            return chain;
        };
        // Whether an animation leaves its layer's model transform as it is, active or not.
        auto leavesModel = [&](size_t i) {
            IGeometry before = exactly(model[animations[i].chainIndex]);
            IGeometry after = before;
            applyKeyframes(after, animations[i].animation.get(), keyframes[i]);
            for (size_t entry = 0; entry < 16; ++entry) {
                if (before.transform[entry].lo != after.transform[entry].lo || before.transform[entry].hi != after.transform[entry].hi)
                    return false;
            }
            return true;
        };

        if (auto extent = footprintExtent(chainWith(std::nullopt, nil, false), parentIndex, surfaceIndex)) {
            crop = extent->second;
            sweptCrop = crop;
            footprintInParent = extent->first;
        }
        sampleRegionKnown = !!sweptCrop;

        // A single translation of the footprint, through affine layers: the crop's origin follows it by the same amounts.
        bool affineAbove = crop && varying.size() == 1;
        for (size_t i = varying.size() == 1 ? animations[varying[0]].chainIndex : 0; affineAbove && i < model.size(); ++i)
            affineAbove = isAffine(model[i].transform) && isAffine(model[i].sublayerTransform);
        for (size_t i = 0; affineAbove && i < animations.size(); ++i) {
            if (i != varying[0])
                affineAbove = leavesModel(i);
        }
        if (crop && affineAbove && isTranslation(animations[varying[0]].animation.get(), keyframes[varying[0]])) {
            auto& animation = animations[varying[0]];
            auto& values = keyframes[varying[0]].values;
            auto baseExtent = footprintExtent(chainWith(varying[0], nil, true), parentIndex, surfaceIndex);
            Vector<CGPoint> offsets;
            for (auto& value : values) {
                auto extent = footprintExtent(chainWith(varying[0], value.get(), false), parentIndex, surfaceIndex);
                if (!extent || !baseExtent) {
                    offsets.clear();
                    break;
                }
                offsets.append(CGPointMake(CGRectGetMinX(extent->second) - CGRectGetMinX(baseExtent->second), CGRectGetMinY(extent->second) - CGRectGetMinY(baseExtent->second)));
            }
            if (!offsets.isEmpty()) {
                crop = baseExtent->second;
                cropAnimation = adoptNS(static_cast<CAPropertyAnimation *>([animation.animation copy]));
                [cropAnimation setDelegate:nil];
                [cropAnimation setKeyPath:@"bounds.origin"];
                [cropAnimation setValueFunction:nil];
                [cropAnimation setAdditive:YES];
                if (animation.groupBeginTime)
                    [cropAnimation setBeginTime:animation.groupBeginTime + [cropAnimation beginTime]];
                auto offsetValue = [&](size_t k) {
                    return [NSValue valueWithPoint:NSPointFromCGPoint(offsets[k])];
                };
                if ([cropAnimation isKindOfClass:CAKeyframeAnimation.class]) {
                    NSMutableArray *offsetValues = [NSMutableArray arrayWithCapacity:offsets.size()];
                    for (size_t k = 0; k < offsets.size(); ++k)
                        [offsetValues addObject:offsetValue(k)];
                    static_cast<CAKeyframeAnimation *>(cropAnimation.get()).values = offsetValues;
                } else {
                    auto* basic = static_cast<CABasicAnimation *>(cropAnimation.get());
                    basic.fromValue = offsetValue(0);
                    basic.toValue = offsetValue(1);
                }
            }
        }
    }

    // A sampling surface presents the backdrop layer's footprint in its superlayer; its mask lies in the
    // superlayer's coordinates, bounded by that footprint.
    if (_maskRoot) {
        CGRect footprint = footprintInParent.value_or(self.superlayer ? self.superlayer.bounds : CGRectZero);
        if (!CGPointEqualToPoint([super position], footprint.origin))
            [super setPosition:footprint.origin];
        CGRect presentedBounds = CGRectMake(0, 0, CGRectGetWidth(footprint), CGRectGetHeight(footprint));
        if (!CGRectEqualToRect(_presentedBounds, presentedBounds)) {
            Locker presentedLocker { _presentedLock };
            _presentedBounds = presentedBounds;
        }
        if (!CGRectEqualToRect([_presentedMask bounds], presentedBounds))
            [_presentedMask setBounds:presentedBounds];
        if (!CGRectEqualToRect([_maskRoot bounds], footprint))
            [_maskRoot setBounds:footprint];
    }

    // A sampling surface has no pixels outside the root layer its host presents, so the crop ends at the root's edges,
    // where the blur's edges apply as they do at the backdrop's own. A WebKit layer at the top is not in the host's
    // tree yet. Animations from the surface up move the root's edges in it.
    if (crop && !cropAnimation && surfaceIndex != notFound) {
        CALayer *surface = layers[surfaceIndex].get();
        CALayer *root = surface;
        bool animated = surface.animationKeys.count;
        while (root.superlayer) {
            root = root.superlayer;
            animated |= !!root.animationKeys.count;
        }
        if (WebCore::PlatformCALayer::platformCALayerForLayer((__bridge void*)root)) {
            Locker awaitingLocker { layersAwaitingRootLock };
            layersAwaitingRoot().append(self);
        } else if (!animated && root != surface) {
            CGRect window = [surface convertRect:root.bounds fromLayer:root];
            if (CGRect visible = CGRectIntersection(*crop, window); !CGRectIsEmpty(visible)) {
                crop = visible;
                sweptCrop = CGRectIntersection(*sweptCrop, window);
            }
        }
    }

    // Hard edges read the crop less its outermost device pixels.
    if (crop && surfaceIndex != notFound) {
        CGFloat pixel = 1 / std::max<CGFloat>(1, layers[surfaceIndex].get().contentsScale);
        crop = CGRectInset(*crop, -pixel, -pixel);
        sweptCrop = CGRectInset(*sweptCrop, -pixel, -pixel);
    }

    // The filters read the crop, or without one the footprint, from the sampling surface; its swept bounding box
    // holds both.
    CGRect sampleRegion = sweptCrop.value_or(CGRectNull);
    if (!CGRectEqualToRect(sampleRegion, _sampleRegion) || sampleRegionKnown != _sampleRegionKnown) {
        Locker presentedLocker { _presentedLock };
        _sampleRegion = sampleRegion;
        _sampleRegionKnown = sampleRegionKnown;
    }
    CGRect newCrop = readsCrop ? crop.value_or(CGRectNull) : CGRectNull;
    if (!readsCrop)
        cropAnimation = nil;
    bool croppingChanged = CGRectIsNull(newCrop) != CGRectIsNull(_crop);
    bool renderingChanged = pathToSurfaceNotRendered != _pathToSurfaceNotRendered;
    {
        Locker presentedLocker { _presentedLock };
        _crop = newCrop;
        _pathToSurfaceNotRendered = pathToSurfaceNotRendered;
    }
    [self applyGeometry];
    if (croppingChanged)
        [self updateCommittedBackgroundFilters];
    else if (renderingChanged)
        [super setBackgroundFilters:self.backgroundFilters];

    if (![cropAnimation isEqual:_cropAnimation.get()]) {
        _cropAnimation = cropAnimation;
        if (cropAnimation) {
            RetainPtr<CAPropertyAnimation> maskAnimation = adoptNS(static_cast<CAPropertyAnimation *>([cropAnimation copy]));
            [maskAnimation setKeyPath:@"position"];
            [super addAnimation:cropAnimation.get() forKey:cropAnimationKey];
            [_cropMask addAnimation:maskAnimation.get() forKey:cropAnimationKey];
        } else {
            [super removeAnimationForKey:cropAnimationKey];
            [_cropMask removeAnimationForKey:cropAnimationKey];
        }
    }
}

#pragma mark Sampling surfaces

- (BOOL)getSampleRegion:(CGRect *)region
{
    Locker locker { _presentedLock };
    *region = _sampleRegion;
    return _sampleRegionKnown;
}

- (WebBackdropLayerAquaWebKit *)samplingSurfaceBackdropLayer
{
    RetainPtr<WebBackdropLayerAquaWebKit> backdropLayer;
    {
        Locker locker { _presentedLock };
        backdropLayer = _samplingBackdropLayer.get();
    }
    return backdropLayer.autorelease();
}

// The sampling-surface layer lies just before the boundary, in the boundary's superlayer. Its mask root lies in
// that superlayer's coordinates, with a mirror of the boundary and of the layers down to the backdrop layer.
- (void)updateSamplingSurfaceWithBoundary:(CALayer *)boundary path:(NSArray *)path backdropLayer:(WebBackdropLayerAquaWebKit *)backdropLayer
{
    Locker locker { _updateLock };
    if (!_maskRoot) {
        self.delegate = [WebActionDisablingCALayerDelegate shared];
        self.anchorPoint = CGPointZero;
        // A mask's own clip is ignored, so the mask root that clips to the footprint is a sublayer of the mask.
        CALayer *mask = makeLayer(CALayer.class);
        mask.anchorPoint = CGPointZero;
        _maskRoot = makeLayer(CALayer.class);
        [_maskRoot setAnchorPoint:CGPointZero];
        [_maskRoot setMasksToBounds:YES];
        [mask addSublayer:_maskRoot.get()];
        _boundaryNode = makeLayer(CALayer.class);
        [_maskRoot addSublayer:_boundaryNode.get()];
        self.mask = mask;
    }
    {
        Locker presentedLocker { _presentedLock };
        _samplingBackdropLayer = backdropLayer;
    }

    Vector<const void*> pathIdentity;
    for (CALayer *layer in path)
        pathIdentity.append((__bridge const void*)layer);
    pathIdentity.append((__bridge const void*)boundary);
    pathIdentity.append((__bridge const void*)backdropLayer);
    if (pathIdentity != _pathIdentity || !_leaf) {
        _pathIdentity = WTF::move(pathIdentity);
        _pathNodes.clear();
        CALayer *parent = _boundaryNode.get();
        parent.sublayers = nil;
        for (CALayer *layer in path) {
            CALayer *node = makeLayer(isTransformLayer(layer) ? CATransformLayer.class : CALayer.class);
            [parent addSublayer:node];
            _pathNodes.append(node);
            parent = node;
        }
        _leaf = makeLayer(CALayer.class);
        [parent addSublayer:_leaf.get()];

        // The layers another thread moves carry their mirrors along.
        updateFollowers(boundary, &mirrorsKey, _boundaryNode.get(), self, true);
        for (NSUInteger i = 0; i < path.count; ++i)
            updateFollowers(path[i], &mirrorsKey, _pathNodes[i].get(), self, true);
        updateFollowers(backdropLayer, &mirrorsKey, _leaf.get(), self, true);
    }

    // Group color filters follow the backdrop filters; alpha-only filters act on the group's coverage mirror.
    NSArray *groups = [[path reverseObjectEnumerator].allObjects arrayByAddingObject:boundary];
    NSArray *backdropFilters = [backdropLayer colorBackgroundFilters];
    NSMutableArray *source = [NSMutableArray arrayWithObject:backdropFilters ?: [NSNull null]];
    for (CALayer *group in groups)
        [source addObject:group.filters ?: [NSNull null]];
    NSMapTable *groupOpacityFilters = [NSMapTable strongToStrongObjectsMapTable];
    NSMapTable *groupFilterNames = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray *filters = [NSMutableArray array];
    for (id filter in backdropFilters)
        [filters addObject:filter];
    for (CALayer *group in groups) {
        NSMutableDictionary *opacities = [NSMutableDictionary dictionary];
        NSMutableDictionary *names = [NSMutableDictionary dictionary];
        for (id filter in group.filters) {
            NSString *name = [filter name];
            if (isAlphaOnlyFilter(filter, group, @"filters")) {
                if (name)
                    opacities[name] = filter;
                continue;
            }
            NSString *copyName = [NSString stringWithFormat:@"aquawebkitGroupFilter%lu", (unsigned long)filters.count];
            if (name)
                names[name] = copyName;
            RetainPtr<CAFilter> copy = adoptNS([filter copy]);
            [copy setName:copyName];
            [filters addObject:copy.get()];
        }
        [groupOpacityFilters setObject:opacities forKey:group];
        [groupFilterNames setObject:names forKey:group];
    }
    if (![source isEqualToArray:_groupFiltersSource.get()]) {
        _groupFiltersSource = source;
        [self setBackgroundFilters:filters];
    }
    // The mirror of the boundary carries its geometry, clip, opacity and mask.
    copyGeometry(boundary, _boundaryNode.get(), true);
    copyClip(boundary, _boundaryNode.get());
    setOpacity(_boundaryNode.get(), boundary.opacity);
    syncMask(boundary, _boundaryNode.get(), self);
    if (boundary.hidden != [_boundaryNode isHidden])
        [_boundaryNode setHidden:boundary.hidden];
    copyAnimations(boundary, _boundaryNode.get(), groupKeyPaths(), @"layer");
    bool hasSingleSidedTransformLayerAncestor = false;
    for (NSUInteger i = 0; i < path.count; ++i) {
        syncPathNode(path[i], _pathNodes[i].get(), self);
        hasSingleSidedTransformLayerAncestor |= isTransformLayer(path[i]) && ![path[i] isDoubleSided];
    }
    syncLeaf(backdropLayer, _leaf.get(), hasSingleSidedTransformLayerAncestor, self);

    // Alpha-only filter animations stay on their mirror filters; color-filter animations follow the renamed copies.
    NSMutableDictionary *groupFilterAnimations = [NSMutableDictionary dictionary];
    for (NSUInteger g = 0; g < groups.count; ++g) {
        CALayer *group = groups[g];
        CALayer *node = group == boundary ? _boundaryNode.get() : _pathNodes[path.count - 1 - g].get();
        if (isTransformLayer(node))
            continue;
        NSDictionary *opacities = [groupOpacityFilters objectForKey:group];
        NSArray *opacityFilters = [opacities allValues];
        if (![node.filters isEqualToArray:opacityFilters])
            node.filters = opacityFilters;
        NSDictionary *names = [groupFilterNames objectForKey:group];
        NSMutableDictionary *opacityAnimations = [NSMutableDictionary dictionary];
        for (NSString *key in group.animationKeys) {
            CAAnimation *animation = [group animationForKey:key];
            RetainPtr opacityCopy = copyAnimationSelectingKeyPaths(animation, ^NSString *(NSString *keyPath) {
                NSArray *components = [keyPath componentsSeparatedByString:@"."];
                if (components.count != 3 || ![components[0] isEqualToString:@"filters"] || !opacities[components[1]])
                    return nil;
                return keyPath;
            });
            if (opacityCopy) {
                [opacityCopy setDelegate:nil];
                opacityAnimations[key] = @[ animation, opacityCopy.get() ];
            }
            RetainPtr colorCopy = copyAnimationSelectingKeyPaths(animation, ^NSString *(NSString *keyPath) {
                NSArray *components = [keyPath componentsSeparatedByString:@"."];
                if (components.count < 3 || ![components[0] isEqualToString:@"filters"])
                    return nil;
                NSString *copyName = names[components[1]];
                if (!copyName)
                    return nil;
                NSArray *rest = [components subarrayWithRange:NSMakeRange(2, components.count - 2)];
                return [NSString stringWithFormat:@"backgroundFilters.%@.%@", copyName, [rest componentsJoinedByString:@"."]];
            });
            if (colorCopy) {
                [colorCopy setDelegate:nil];
                groupFilterAnimations[[NSString stringWithFormat:@"%lu:%@", (unsigned long)g, key]] = @[ animation, colorCopy.get() ];
            }
        }
        setTaggedAnimations(node, opacityAnimations, @"groupFilter");
    }
    setTaggedAnimations(self, animationCopies(backdropLayer, @[ @"backgroundFilters" ]), @"backdrop");
    setTaggedAnimations(self, groupFilterAnimations, @"group");

    bool hidden = layerIsNotRendered(backdropLayer) || layerIsNotRendered(boundary);
    for (CALayer *layer in path)
        hidden |= layerIsNotRendered(layer);
    if (hidden != self.hidden)
        self.hidden = hidden;
}

- (void)updateSamplingSurfaceWithBoundary:(CALayer *)boundary backdropLayer:(WebBackdropLayerAquaWebKit *)backdropLayer
{
    Locker locker { _updateLock };
    _treeBoundary = boundary;
    _treeBackdropLayer = backdropLayer;
    [self updateSamplingSurfaceFromLayerTree];
}

- (void)updateSamplingSurfaceFromLayerTree
{
    Locker locker { _updateLock };
    RetainPtr boundary = _treeBoundary.get();
    RetainPtr backdropLayer = _treeBackdropLayer.get();
    if (!boundary || !backdropLayer)
        return;
    NSMutableArray *path = [NSMutableArray array];
    CALayer *layer = [backdropLayer superlayer];
    for (; layer && layer != boundary.get(); layer = layer.superlayer)
        [path insertObject:layer atIndex:0];
    if (!layer)
        return;
    [self updateSamplingSurfaceWithBoundary:boundary.get() path:path backdropLayer:backdropLayer.get()];
    [self updateCrop];
}

- (void)mirrorGeometryOf:(CALayer *)layer to:(CALayer *)mirror
{
    Locker locker { _updateLock };
    copyGeometry(layer, mirror, true);
}

- (void)copyContentsOf:(CALayer *)layer to:(CALayer *)copy
{
    Locker locker { _updateLock };
    if ([objc_getAssociatedObject(copy, &copiedContentsKey) nonretainedObjectValue] != layer)
        return;
    if (copy.contents != layer.contents)
        copy.contents = layer.contents;
    else
        [copy reloadValueForKeyPath:@"contents"];
}

@end

bool WebBackdropLayerAquaWebKitExtentInSamplingSurface(CALayer *layer, NSArray *ancestors, CGRect* extent)
{
    if (layerIsNotRendered(layer)) {
        *extent = CGRectNull;
        return true;
    }
    if (!ancestors.count)
        return false;
    auto result = extentInSuperlayer(layer, 0, ancestors[0]);
    for (NSUInteger i = 0; result && isTransformLayer(ancestors[i]); ++i) {
        CALayer *host = ancestors[i];
        if (i >= 64 || i + 1 >= ancestors.count || host.filters.count || host.shadowOpacity > 0)
            return false;
        result = mapExtentToSuperlayer(host, *result, ancestors[i + 1]);
    }
    if (result)
        *extent = CGRectMake(result->x.lo, result->y.lo, result->x.hi - result->x.lo, result->y.hi - result->y.lo);
    return !!result;
}

bool WebBackdropLayerAquaWebKitSampleRegionInSuperlayer(CALayer *layer, CGRect* region)
{
    auto result = sampleRegionInSuperlayer(layer, 0);
    if (result)
        *region = *result;
    return !!result;
}

void WebBackdropLayerAquaWebKitLayerTreeDidCommit()
{
    Vector<WeakObjCPtr<WebBackdropLayerAquaWebKit>> layers;
    {
        Locker locker { layersAwaitingRootLock };
        layers = std::exchange(layersAwaitingRoot(), { });
    }
    HashSet<void*> cropped;
    for (auto& weakLayer : layers) {
        if (RetainPtr layer = weakLayer.get(); layer && cropped.add((__bridge void*)layer.get()).isNewEntry)
            [layer updateCrop];
    }
}

void WebBackdropLayerAquaWebKitContentsDidChange(CALayer *layer)
{
    @autoreleasepool {
        for (WebBackdropLayerFollower *follower in (NSArray *)objc_getAssociatedObject(layer, &contentsCopiesKey)) {
            RetainPtr copy = follower->layer.get();
            RetainPtr owner = follower->owner.get();
            if (copy && owner)
                [owner copyContentsOf:layer to:copy.get()];
        }
    }
}

void WebBackdropLayerAquaWebKitGeometryDidChange(CALayer *layer)
{
    @autoreleasepool {
        for (WebBackdropLayerFollower *follower in (NSArray *)objc_getAssociatedObject(layer, &mirrorsKey)) {
            RetainPtr mirror = follower->layer.get();
            RetainPtr owner = follower->owner.get();
            if (mirror && owner)
                [owner mirrorGeometryOf:layer to:mirror.get()];
        }
        for (WebBackdropLayerFollower *follower in (NSArray *)objc_getAssociatedObject(layer, &croppedLayersKey)) {
            if (RetainPtr cropped = follower->layer.get())
                [static_cast<WebBackdropLayerAquaWebKit *>(cropped.get()) updateCrop];
        }
    }
}
