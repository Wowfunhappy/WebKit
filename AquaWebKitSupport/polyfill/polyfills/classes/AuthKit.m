// AuthKit: stub of the one AuthKit class WebKit names, from a framework 10.9 does not ship at all.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>

// AuthKit's AKAuthorizationController. This stub exists ONLY to satisfy a link-time reference, and
// its one method is not reachable on this OS.
//
// The link-time reference: PlatformMac.cmake drops upstream's -framework AuthKit (no AuthKit.framework
// on 10.9 and none in the build SDK), while SOAuthorizationCoordinator.mm still names the class as a
// literal, which emits _OBJC_CLASS_$_AKAuthorizationController. The alias below supplies it.
//
// Why the method cannot run: its sole call site (SOAuthorizationCoordinator::tryAuthorize, the
// subframe check) sits inside the canAuthorize completion after `if (!result) return;`, and
// canAuthorize completes false immediately whenever m_hasAppSSO is false. m_hasAppSSO is
// !!getSOAuthorizationClassSingleton(), soft-linked from AppSSO.framework — which does not exist on
// 10.9 either. Upstream handles exactly this case itself (its "base system, which doesn't have
// AppSSO.framework" early return), so no gate is being bent here; the whole feature is inert.
//
// The verdict is therefore unobservable, and it is also not computable: "Apple-owned domain" is a
// registry AuthKit ships, and nothing on 10.9 vends it (no framework in /System/Library exports any
// AppleOwnedDomain symbol). NO is what the absent framework's absence means — there is no
// Apple-first-party authorization on this OS — not a claim about any particular URL.
WK_PRIV_CLASS(AKAuthorizationController) @interface AKAuthorizationController : NSObject
+ (BOOL)isURLFromAppleOwnedDomain:(NSURL *)url;
@end
@implementation AKAuthorizationController
+ (BOOL)isURLFromAppleOwnedDomain:(NSURL *)url { (void)url; return NO; }
@end
WK_PRIV_ALIAS(AKAuthorizationController);
