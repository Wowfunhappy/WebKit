// QuartzCore: stubs of the Core Animation classes 10.9 does not have.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

// CABackdropLayer (absent on 10.9): a CALayer-backed backdrop/blur layer. 10.9 has no backdrop
// compositing, so this shadow is a plain CALayer subclass — visually identical to a bare CALayer — but a
// real distinct class, so PlatformCALayerCocoa / RemoteLayerTreeHost keep upstream's [CABackdropLayer class]
// and the isKindOfClass: / (CABackdropLayer *) casts behave as upstream. -setWindowServerAware: is the one
// method WebKit sends it (backdrop layers are marked not-window-server-aware); 10.9 has no such concept, so
// it is a faithful no-op.
WK_PRIV_CLASS(CABackdropLayer) @interface CABackdropLayer : CALayer
- (void)setWindowServerAware:(BOOL)aware;
@end
@implementation CABackdropLayer
- (void)setWindowServerAware:(BOOL)aware { (void)aware; }
@end
WK_PRIV_ALIAS(CABackdropLayer);
WK_PRIV_CLASS(CAPresentationModifier) @interface CAPresentationModifier : NSObject @end
@implementation CAPresentationModifier @end
WK_PRIV_ALIAS(CAPresentationModifier);
