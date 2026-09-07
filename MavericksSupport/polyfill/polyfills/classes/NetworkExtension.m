// NetworkExtension: stub of the one class WebKit names, from a framework 10.9 does not ship.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>

// NEFilterSource, the parental-controls filter provider WebCore reaches through
// NetworkExtensionContentFilter. This stub answers the one question that decides whether the rest of
// the class is ever used, and nothing else on this OS can reach the rest.
//
// The link-time reference: WebCorePlatformMavericks.cmake withholds upstream's ${NETWORKEXTENSION_LIBRARY}
// (no NetworkExtension.framework on 10.9 and none in the build SDK), while
// NetworkExtensionContentFilter.mm names the class as a literal, which emits
// _OBJC_CLASS_$_NEFilterSource. The alias below supplies it.
//
// Why NO is the true answer: +filterRequired asks whether a NetworkExtension content-filter provider
// is configured for this system. Providers arrive through NEFilterProviderConfiguration, which is the
// framework 10.9 does not have, so no provider can exist here -- the same answer modern macOS gives
// when nothing is configured. Every NetworkExtensionContentFilter entry point tests enabled()
// (isRequired() -> +filterRequired) before it does anything, and its initialize() -- the only code that
// allocates an NEFilterSource instance -- sits past that test, so no instance is ever made and no
// other method on this class is reachable. Content filtering itself is not disabled by this: the
// parental-controls filter beside it runs against 10.9's own WebContentAnalysis.framework.
WK_PRIV_CLASS(NEFilterSource) @interface NEFilterSource : NSObject
+ (BOOL)filterRequired;
@end
@implementation NEFilterSource
+ (BOOL)filterRequired { return NO; }
@end
WK_PRIV_ALIAS(NEFilterSource);
