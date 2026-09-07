// The single-field NSHTTPCookie SPI uses WebCore's curl grammar and Cocoa acceptance rules.
#import <Foundation/Foundation.h>
#import "wk_selref_scope.h"

extern "C" CFTypeRef WebCoreCookieCreateFromHTTPResponseField(CFStringRef, CFURLRef);

WK_POLYFILL_ADD_METHODS(NSHTTPCookie)
+ (NSHTTPCookie *)_cookieForSetCookieString:(NSString *)field forURL:(NSURL *)url partition:(NSString *)partition
{
    // The build disables partitioned cookie storage, so its native representation is unpartitioned.
    (void)partition;
    if (!field.length || !url)
        return nil;
    return CFBridgingRelease(WebCoreCookieCreateFromHTTPResponseField((__bridge CFStringRef)field, (__bridge CFURLRef)url));
}
@end
