// CoreServices (LaunchServices): stubs of the LS* classes 10.9 does not have.
#import "wk_priv_class.h"
#import <Foundation/Foundation.h>

WK_PRIV_CLASS(LSDatabaseContext) @interface LSDatabaseContext : NSObject @end
@implementation LSDatabaseContext @end
WK_PRIV_ALIAS(LSDatabaseContext);

// LSAppLink / _LSOpenConfiguration (10.10+ LaunchServices): "app links" hand a user-initiated web
// navigation to a native app that has claimed the URL's domain. 10.9's LaunchServices has no app-link
// registry, so no URL on this OS ever has a claiming app — which in this API's own terms is the
// completion firing with success:NO. Both of WebKit's call sites (NavigationState's
// tryInterceptNavigation, WebFrameLoaderClient's policy decision) treat that as "carry on as a normal
// web navigation". The handler fires asynchronously on the main queue like the real (IPC-backed) API,
// so neither call site sees a re-entrant policy decision.
WK_PRIV_CLASS(_LSOpenConfiguration) @interface _LSOpenConfiguration : NSObject {
    NSURL *_referrerURL;
}
@property (nonatomic, copy) NSURL *referrerURL;
@end
@implementation _LSOpenConfiguration
@synthesize referrerURL = _referrerURL;
- (void)dealloc { [_referrerURL release]; [super dealloc]; }
@end
WK_PRIV_ALIAS(_LSOpenConfiguration);
WK_PRIV_CLASS(LSAppLink) @interface LSAppLink : NSObject
+ (void)openWithURL:(NSURL *)url configuration:(_LSOpenConfiguration *)configuration completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
@end
@implementation LSAppLink
+ (void)openWithURL:(NSURL *)url configuration:(_LSOpenConfiguration *)configuration completionHandler:(void (^)(BOOL success, NSError *error))completionHandler
{
    (void)url;
    (void)configuration;
    if (!completionHandler)
        return;
    void (^handler)(BOOL, NSError *) = [[completionHandler copy] autorelease];
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(NO, nil);
    });
}
@end
WK_PRIV_ALIAS(LSAppLink);

// NOTE: WebFullScreenController is intentionally NOT stubbed here — it is a REAL class implemented by
// WebKitLegacy (Source/WebKitLegacy/mac/WebView/WebFullScreenController.mm). No other framework references
// it, so a polyfill stub would only duplicate the real class. Leave it to WebKitLegacy.
WK_PRIV_CLASS(LSBundleProxy) @interface LSBundleProxy : NSObject @end
@implementation LSBundleProxy @end
WK_PRIV_ALIAS(LSBundleProxy);
