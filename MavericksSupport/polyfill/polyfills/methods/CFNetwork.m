// CFNetwork: the cookie SPI whose grammar is WebCore's. WebCore parses Set-Cookie for this port, so
// the implementation lives in the image this archive is force-loaded into, and the selector reaches
// both of its senders -- NetworkStorageSessionCocoa.mm in WebCore and WebCookieJarCocoa.mm in WebKit.

#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>

#include "wk_set_cookie_string.h"

extern CFTypeRef WebCoreCookieCreateFromHTTPResponseField(CFStringRef, CFURLRef) CF_RETURNS_RETAINED;

WK_POLYFILL_ADD_METHODS(NSHTTPCookie)
+ (NSHTTPCookie *)_cookieForSetCookieString:(NSString *)field forURL:(NSURL *)url partition:(NSString *)partition
{
    // The build disables partitioned cookie storage, so its native representation is unpartitioned.
    (void)partition;
    if (!field.length || !url)
        return nil;
    // The SPI answers the first cookie of a string that holds several, divided as 10.9's parser divides them.
    CFRange first = wk_setCookieStringFirstCookieRange((CFStringRef)field);
    if (first.location == kCFNotFound)
        return nil;
    NSString *cookie = [field substringWithRange:NSMakeRange((NSUInteger)first.location, (NSUInteger)first.length)];
    return [(NSHTTPCookie *)WebCoreCookieCreateFromHTTPResponseField((CFStringRef)cookie, (CFURLRef)url) autorelease];
}
@end
