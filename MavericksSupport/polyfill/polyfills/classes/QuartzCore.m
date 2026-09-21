// Core Animation classes supplied by the Mavericks compatibility layer.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

static CAAnimation *copyBackdropAnimation(CAAnimation *animation)
{
    CAAnimation *mapped = [animation copy];
    if ([mapped isKindOfClass:[CAAnimationGroup class]]) {
        NSMutableArray *children = [NSMutableArray array];
        for (CAAnimation *child in [(CAAnimationGroup *)mapped animations]) {
            CAAnimation *copy = copyBackdropAnimation(child);
            [children addObject:copy];
            [copy release];
        }
        [(CAAnimationGroup *)mapped setAnimations:children];
    } else if ([mapped isKindOfClass:[CAPropertyAnimation class]]) {
        CAPropertyAnimation *property = (CAPropertyAnimation *)mapped;
        if ([property.keyPath hasPrefix:@"filters."])
            property.keyPath = [@"backgroundFilters." stringByAppendingString:[property.keyPath substringFromIndex:8]];
        else if ([property.keyPath isEqualToString:@"filters"])
            property.keyPath = @"backgroundFilters";
    }
    return mapped;
}

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
    CAAnimation *mapped = copyBackdropAnimation(animation);
    [super addAnimation:mapped forKey:key];
    [mapped release];
}
@end
WK_PRIV_ALIAS(CABackdropLayer);
WK_PRIV_CLASS(CAPresentationModifier) @interface CAPresentationModifier : NSObject @end
@implementation CAPresentationModifier @end
WK_PRIV_ALIAS(CAPresentationModifier);
