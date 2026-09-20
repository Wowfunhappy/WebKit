// CSS 3D rendering contexts on Core Animation's transform-only layer implementation.

#import "wk_selref_scope.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface CALayer (WKDepthSorting)
@property BOOL sortsSublayers;
@property BOOL usesWebKitBehavior;
@end

static const char usesWebKitBehaviorKey;
static const char depthSortingContainerKey;

// Public selectors reach CA's physical tree; WebKit's scoped selectors expose its logical tree.
static NSArray *nativeSublayers(CALayer *layer)
{
    return ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("sublayers"));
}

static CALayer *nativeSuperlayer(CALayer *layer)
{
    return ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("superlayer"));
}

static void nativeRemoveFromSuperlayer(CALayer *layer)
{
    ((void (*)(id, SEL))objc_msgSend)(layer, sel_registerName("removeFromSuperlayer"));
}

@interface WKDepthSortingContainer : CALayer
@end

@implementation WKDepthSortingContainer
- (id<CAAction>)actionForKey:(NSString *)key
{
    (void)key;
    return nil;
}

- (void)dealloc
{
    for (CALayer *child in nativeSublayers(self)) {
        if (objc_getAssociatedObject(child, &depthSortingContainerKey) == self)
            objc_setAssociatedObject(child, &depthSortingContainerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [super dealloc];
}
@end

static CALayer *physicalLayer(CALayer *layer)
{
    CALayer *container = objc_getAssociatedObject(layer, &depthSortingContainerKey);
    return container ?: layer;
}

static CALayer *logicalLayer(CALayer *layer)
{
    return [layer isKindOfClass:[WKDepthSortingContainer class]] ? [nativeSublayers(layer) firstObject] : layer;
}

static void updateContainerGeometry(CALayer *container, CALayer *parent)
{
    CGRect bounds = parent.bounds;
    CGPoint anchor = parent.anchorPoint;
    container.bounds = bounds;
    container.anchorPoint = anchor;
    container.anchorPointZ = parent.anchorPointZ;
    container.position = CGPointMake(bounds.origin.x + anchor.x * bounds.size.width,
        bounds.origin.y + anchor.y * bounds.size.height);
    container.zPosition = parent.anchorPointZ;
    // The sorting boundary occupies the parent's plane. Its perspective acts inside the
    // boundary, where the transform-only descendants still carry their depth coordinates.
    CATransform3D perspective = parent.sublayerTransform;
    container.transform = CATransform3DInvert(perspective);
    container.sublayerTransform = perspective;
}

static void updateChildContainerGeometry(CALayer *parent)
{
    for (CALayer *child in nativeSublayers(parent)) {
        if ([child isKindOfClass:[WKDepthSortingContainer class]])
            updateContainerGeometry(child, parent);
    }
}

static void detachContainer(CALayer *layer)
{
    CALayer *container = objc_getAssociatedObject(layer, &depthSortingContainerKey);
    if (!container)
        return;
    [[layer retain] autorelease];
    [[container retain] autorelease];
    objc_setAssociatedObject(layer, &depthSortingContainerKey, nil, OBJC_ASSOCIATION_ASSIGN);
    nativeRemoveFromSuperlayer(layer);
    nativeRemoveFromSuperlayer(container);
}

static CALayer *prepareSublayer(CALayer *parent, CALayer *child)
{
    BOOL needsContainer = [objc_getAssociatedObject(parent, &usesWebKitBehaviorKey) boolValue]
        && ![parent isKindOfClass:[CATransformLayer class]] && !parent.sortsSublayers
        && [child isKindOfClass:[CATransformLayer class]];
    CALayer *container = objc_getAssociatedObject(child, &depthSortingContainerKey);
    if (needsContainer && container && nativeSuperlayer(container) == parent)
        return container;
    detachContainer(child);
    if (!needsContainer)
        return child;
    container = [[[WKDepthSortingContainer alloc] init] autorelease];
    updateContainerGeometry(container, parent);
    ((void (*)(id, SEL, id))objc_msgSend)(container, sel_registerName("addSublayer:"), child);
    // The physical parent owns the container; the container owns its child.
    objc_setAssociatedObject(child, &depthSortingContainerKey, container, OBJC_ASSOCIATION_ASSIGN);
    return container;
}

WK_POLYFILL_ADD_METHODS(CALayer)
- (void)setUsesWebKitBehavior:(BOOL)value
{
    objc_setAssociatedObject(self, &usesWebKitBehaviorKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.sublayers = self.sublayers;
}

- (BOOL)usesWebKitBehavior
{
    return [objc_getAssociatedObject(self, &usesWebKitBehaviorKey) boolValue];
}
@end

WK_POLYFILL_REPLACE_METHODS(CALayer)
- (void)setSortsSublayers:(BOOL)value
{
    WK_ORIGINAL_METHOD(void, (BOOL), value);
    self.sublayers = self.sublayers;
}

- (NSArray *)sublayers
{
    NSArray *layers = WK_ORIGINAL_METHOD(NSArray *, ());
    BOOL containsContainer = NO;
    for (CALayer *layer in layers)
        containsContainer |= [layer isKindOfClass:[WKDepthSortingContainer class]];
    if (!containsContainer)
        return layers;
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:layers.count];
    for (CALayer *layer in layers)
        [result addObject:logicalLayer(layer)];
    return result;
}

- (CALayer *)superlayer
{
    CALayer *parent = WK_ORIGINAL_METHOD(CALayer *, ());
    return [parent isKindOfClass:[WKDepthSortingContainer class]] ? nativeSuperlayer(parent) : parent;
}

- (void)setSublayers:(NSArray *)layers
{
    layers = [NSArray arrayWithArray:layers ?: @[]];
    NSMutableArray *physical = [NSMutableArray arrayWithCapacity:layers.count];
    for (CALayer *layer in layers)
        [physical addObject:prepareSublayer(self, layer)];
    WK_ORIGINAL_METHOD(void, (NSArray *), physical);
}

- (void)addSublayer:(CALayer *)layer
{
    WK_ORIGINAL_METHOD(void, (CALayer *), prepareSublayer(self, layer));
}

- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned)index
{
    WK_ORIGINAL_METHOD(void, (CALayer *, unsigned), prepareSublayer(self, layer), index);
}

- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling
{
    CALayer *reference = physicalLayer(sibling);
    WK_ORIGINAL_METHOD(void, (CALayer *, CALayer *), prepareSublayer(self, layer), reference);
}

- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling
{
    CALayer *reference = physicalLayer(sibling);
    WK_ORIGINAL_METHOD(void, (CALayer *, CALayer *), prepareSublayer(self, layer), reference);
}

- (void)replaceSublayer:(CALayer *)layer with:(CALayer *)replacement
{
    CALayer *oldLayer = physicalLayer(layer);
    WK_ORIGINAL_METHOD(void, (CALayer *, CALayer *), oldLayer, prepareSublayer(self, replacement));
}

- (void)removeFromSuperlayer
{
    detachContainer(self);
    WK_ORIGINAL_METHOD(void, ());
}

- (void)setBounds:(CGRect)bounds
{
    WK_ORIGINAL_METHOD(void, (CGRect), bounds);
    updateChildContainerGeometry(self);
}

- (void)setFrame:(CGRect)frame
{
    WK_ORIGINAL_METHOD(void, (CGRect), frame);
    updateChildContainerGeometry(self);
}

- (void)setAnchorPoint:(CGPoint)point
{
    WK_ORIGINAL_METHOD(void, (CGPoint), point);
    updateChildContainerGeometry(self);
}

- (void)setAnchorPointZ:(CGFloat)z
{
    WK_ORIGINAL_METHOD(void, (CGFloat), z);
    updateChildContainerGeometry(self);
}

- (void)setSublayerTransform:(CATransform3D)transform
{
    WK_ORIGINAL_METHOD(void, (CATransform3D), transform);
    updateChildContainerGeometry(self);
}
@end
