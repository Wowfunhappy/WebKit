// Core Animation classes supplied by the Aqua WebKit compatibility layer.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@interface CALayer (BackdropRenderSnapshot)
- (id)_initWithReference:(CALayer *)layer;
- (void *)_copyRenderLayer:(void *)context layerFlags:(unsigned)flags commitFlags:(unsigned *)commitFlags;
@end

// Stored backdrop filters produce a translucent dark fill; native properties carry the caller's color and contents.
WK_PRIV_CLASS(CABackdropLayer) @interface CABackdropLayer : CAGradientLayer {
    NSArray *_backdropFilters;
    BOOL _windowServerAware;
}
@property(nonatomic) BOOL windowServerAware;
@end

@implementation CABackdropLayer
@synthesize windowServerAware = _windowServerAware;

- (id)initWithLayer:(id)layer
{
    if ((self = [super initWithLayer:layer]) && [layer isKindOfClass:[CABackdropLayer class]]) {
        CABackdropLayer *other = layer;
        _backdropFilters = [other.filters copy];
        _windowServerAware = other->_windowServerAware;
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder])) {
        self.filters = [coder decodeObjectForKey:@"wkBackdropFilters"];
        _windowServerAware = [coder decodeBoolForKey:@"wkWindowServerAware"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    [coder encodeObject:self.filters forKey:@"wkBackdropFilters"];
    [coder encodeBool:_windowServerAware forKey:@"wkWindowServerAware"];
}

- (void)dealloc
{
    [_backdropFilters release];
    [super dealloc];
}

- (NSArray *)filters
{
    [CATransaction lock];
    NSArray *filters = [[_backdropFilters retain] autorelease];
    [CATransaction unlock];
    return filters;
}

- (void)setFilters:(NSArray *)filters
{
    NSArray *copy = [filters copy];
    [CATransaction lock];
    BOOL fillChanges = !!copy.count != !!_backdropFilters.count;
    [_backdropFilters release];
    _backdropFilters = copy;
    if (fillChanges) {
        CGColorRef color = copy.count ? CGColorCreateGenericGray(0, 0.15) : NULL;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [super setColors:color ? @[(id)color, (id)color] : nil];
        [CATransaction commit];
        if (color)
            CGColorRelease(color);
    }
    [CATransaction unlock];
}

// The immutable reference exposes native render properties independently of the logical filters getter.
- (void *)_copyRenderLayer:(void *)context layerFlags:(unsigned)flags commitFlags:(unsigned *)commitFlags
{
    CAGradientLayer *snapshot = [[CAGradientLayer alloc] _initWithReference:self];
    void *result = [snapshot _copyRenderLayer:context layerFlags:flags commitFlags:commitFlags];
    [snapshot release];
    return result;
}
@end
WK_PRIV_ALIAS(CABackdropLayer);

WK_PRIV_CLASS(CAPresentationModifier) @interface CAPresentationModifier : NSObject @end
@implementation CAPresentationModifier @end
WK_PRIV_ALIAS(CAPresentationModifier);
