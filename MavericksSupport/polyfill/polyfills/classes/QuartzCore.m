// Core Animation classes supplied by the Mavericks compatibility layer.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

static NSString * const backdropOriginalKeyPath = @"WKBackdropOriginalKeyPath";

@interface WKPolyfillBackdropAnimationDelegate : NSObject {
    id _originalDelegate;
}
@property(readonly) id originalDelegate;
- (id)initWithDelegate:(id)delegate;
@end

static CAAnimation *copyBackdropAnimation(CAAnimation *animation, BOOL toNative)
{
    CAAnimation *mapped = [animation copy];
    if ([mapped isKindOfClass:[CAAnimationGroup class]]) {
        NSMutableArray *children = [NSMutableArray array];
        for (CAAnimation *child in [(CAAnimationGroup *)mapped animations]) {
            CAAnimation *copy = copyBackdropAnimation(child, toNative);
            [children addObject:copy];
            [copy release];
        }
        [(CAAnimationGroup *)mapped setAnimations:children];
    } else if ([mapped isKindOfClass:[CAPropertyAnimation class]]) {
        CAPropertyAnimation *property = (CAPropertyAnimation *)mapped;
        if (toNative) {
            NSString *keyPath = property.keyPath;
            if ([keyPath hasPrefix:@"filters."]) {
                [property setValue:keyPath forKey:backdropOriginalKeyPath];
                property.keyPath = [@"backgroundFilters." stringByAppendingString:[keyPath substringFromIndex:8]];
            } else if ([keyPath isEqualToString:@"filters"]) {
                [property setValue:keyPath forKey:backdropOriginalKeyPath];
                property.keyPath = @"backgroundFilters";
            }
        } else {
            NSString *keyPath = [property valueForKey:backdropOriginalKeyPath];
            if (keyPath) {
                property.keyPath = keyPath;
                [property setValue:nil forKey:backdropOriginalKeyPath];
            }
        }
    }
    if (toNative && mapped.delegate)
        mapped.delegate = [[[WKPolyfillBackdropAnimationDelegate alloc] initWithDelegate:mapped.delegate] autorelease];
    else if (!toNative && [mapped.delegate isKindOfClass:[WKPolyfillBackdropAnimationDelegate class]])
        mapped.delegate = [(WKPolyfillBackdropAnimationDelegate *)mapped.delegate originalDelegate];
    return mapped;
}

@implementation WKPolyfillBackdropAnimationDelegate
@synthesize originalDelegate = _originalDelegate;
- (id)initWithDelegate:(id)delegate
{
    if ((self = [super init]))
        _originalDelegate = [delegate retain];
    return self;
}
- (void)dealloc
{
    [_originalDelegate release];
    [super dealloc];
}
- (BOOL)respondsToSelector:(SEL)selector
{
    if (selector == @selector(animationDidStart:) || selector == @selector(animationDidStop:finished:))
        return [_originalDelegate respondsToSelector:selector];
    return [super respondsToSelector:selector];
}
- (void)animationDidStart:(CAAnimation *)animation
{
    [_originalDelegate animationDidStart:[copyBackdropAnimation(animation, NO) autorelease]];
}
- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished
{
    [_originalDelegate animationDidStop:[copyBackdropAnimation(animation, NO) autorelease] finished:finished];
}
@end

// Mavericks samples the enclosing render group's background through backgroundFilters.
// WebKit supplies a transform-only host for backdrop layers without group effects.
WK_PRIV_CLASS(CABackdropLayer) @interface CABackdropLayer : CALayer
- (void)setWindowServerAware:(BOOL)aware;
@end
@implementation CABackdropLayer
- (void)setWindowServerAware:(BOOL)aware { (void)aware; }
- (NSArray *)filters { return [super backgroundFilters]; }
- (void)setFilters:(NSArray *)filters { [super setBackgroundFilters:filters]; }

- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key
{
    CAAnimation *mapped = copyBackdropAnimation(animation, YES);
    [super addAnimation:mapped forKey:key];
    [mapped release];
}

- (CAAnimation *)animationForKey:(NSString *)key
{
    return [copyBackdropAnimation([super animationForKey:key], NO) autorelease];
}
@end
WK_PRIV_ALIAS(CABackdropLayer);
WK_PRIV_CLASS(CAPresentationModifier) @interface CAPresentationModifier : NSObject @end
@implementation CAPresentationModifier @end
WK_PRIV_ALIAS(CAPresentationModifier);
