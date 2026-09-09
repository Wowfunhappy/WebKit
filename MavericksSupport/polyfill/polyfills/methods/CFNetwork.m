// CFNetwork: the cookie SPI whose grammar is WebCore's. WebCore parses Set-Cookie for this port, so
// the implementation lives in the image this archive is force-loaded into, and the selector reaches
// both of its senders -- NetworkStorageSessionCocoa.mm in WebCore and WebCookieJarCocoa.mm in WebKit.

#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>

extern CFTypeRef WebCoreCookieCreateFromHTTPResponseField(CFStringRef, CFURLRef) CF_RETURNS_RETAINED;

WK_POLYFILL_ADD_METHODS(NSHTTPCookie)
+ (NSHTTPCookie *)_cookieForSetCookieString:(NSString *)field forURL:(NSURL *)url partition:(NSString *)partition
{
    // The build disables partitioned cookie storage, so its native representation is unpartitioned.
    (void)partition;
    if (!field.length || !url)
        return nil;
    return [(NSHTTPCookie *)WebCoreCookieCreateFromHTTPResponseField((CFStringRef)field, (CFURLRef)url) autorelease];
}
@end
