// The first cookie of a Set-Cookie string that holds several: wk_setCookieStringFirstCookieRange against 10.9's
// own +[NSHTTPCookie cookiesWithResponseHeaderFields:forURL:], which reads the whole string.
#include "../../polyfills/c/wk_set_cookie_string.h"

#import <Foundation/Foundation.h>
#include <stdio.h>

static NSString *describeFirst(NSArray *cookies)
{
    NSHTTPCookie *cookie = cookies.firstObject;
    if (!cookie)
        return @"(none)";
    return [NSString stringWithFormat:@"%@=%@ path=%@ %@", cookie.name, cookie.value, cookie.path, cookie.expiresDate ? @"persistent" : @"session"];
}

int main(void)
{
    @autoreleasepool {
    NSURL *url = [NSURL URLWithString:@"http://h.test/"];
    NSArray *strings = @[@"samesite-unspecified=0;, samesite-lax=1; SameSite=Lax, samesite-strict=2; SameSite=Strict, samesite-none=3; SameSite=None; Secure",
   @"a=0;, b=1; SameSite=Lax, c=2", @"a=1, b=2", @"a=1,b=2", @"a=1,  b=2", @"a=\"x, y=2\"", @"a=1, b", @"a=1, =2", @"a=1; expires=Wed, 09 Jun 2021 10:18:14 GMT", @"a=1, b c=2", @"a=1, b;c=2",
   @"a=hello, world", @"a=hello, world=1", @"a=1, b=2; SameSite=Lax", @"a=1 , b=2", @"a=1;, b=2", @"a=1,\tb=2", @"a=x\"y, b=2", @"a=1; Path=/x, y", @"a=1; Path=/x, y=2", @"a=1, b=\"2, c=3\"", @"a=1, b =2", @"a=1; Expires=Wed, 09 Jun 2031 10:18:14 GMT, b=2", @"a=1; Expires=Wed, 09 Jun 2031 10:18:14 GMT", @"a=1, b\"c=2", @"a=1, ,b=2", @"a=1, , b=2",
   @"a=1, 2b=3", @"a=Wed, 09=1", @"a=\"x\"y, b=2", @"a=1; Path=\"/x, y=2\"", @"a=1; Expires=\"Wed, 09 Jun 2031 10:18:14 GMT\", b=2", @"a=1; Max-Age=10, b=2", @"a=1; expires=Wed, 09 Jun 2031 10:18:14 GMT; path=/, b=2", @"a=1; Foo=Wed, 09 Jun, b=2", @"a=1, expires=Wed, 09 Jun 2031", @"a=Wed, 09 Jun 2031 10:18:14 GMT", @"a=1; expires=Wed, b=2", @"a=1; expires=Wednesday, 09-Jun-31 10:18:14 GMT, b=2", @"a=1,, b=2", @"a=1,\nb=2", @"a=\"1, b=2", @"a=1;expires=Wed,  09 Jun 2031 10:18:14 GMT, b=2", @"a=1; EXPIRES=Wed, 09 Jun 2031 10:18:14 GMT, b=2", @"a=1; expires = Wed, 09 Jun 2031 10:18:14 GMT, b=2", @"a=1; b=Wed, 09 Jun 2031, c=2", @"expires=Wed, 09 Jun 2031, b=2",
   @"a=1 ,, b=2", @"a=1,,  b=2", @"a=b,c, d=2", @"a=1, b=2,, c=3", @"a=1,  , b=2", @"a=1, \"b=2\"", @"a=1; Path=/x\", y=2", @"a=x,, y, b=2", @"a=,, b=2", @"a=1;,, b=2", @"a=1; p=x,, b=2", @"a=1,; b=2", @"a=\"1\", b=2", @"a=1; Path=\"/x\", y=2",
   @"b, a=1", @"=1, a=2", @" a=1", @"a=1,  b=2; path=/p", @"a=1 , b=2; path=/p", @"a=1; path=/q, b=2", @"a=1;path=/q,b=2", @"a=1, b=2, c=3", @"a=x,, b=2", @"a=,x, b=2", @"a=1; p=,, b=2", @"a=1; ,, b=2", @",, a=1", @", a=1", @"a=\"x\", b=2", @"a=\"x, y\", b=2", @"a=1; q=\"x, y\", b=2", @"a=1; q=\"x, y, b=2", @"a=1; expires=Wed, 09 Jun 2031 10:18:14 GMT, b=2; path=/p", @"a=1; expires=Wed, b=2; path=/p", @"a=1; expires=Wed, 09, b=2; path=/p", @"a=1; expiresx=Wed, b=2", @"a=1; max-age=Wed, b=2", @"a=1; Expires = Wed, b=2", @"a=1; expires=, b=2", @"a=1; expires=\"Wed\", b=2", @"a=1; expires=W\"ed, b=2", @"a=1; domain=h.test, b=2", @"a=b=c, d=e", @"a b=1, c=2", @"a=1, b=2;", @"a=1,\r\n b=2", @"a=1, \"b\"=2", @"a=1, b\"=2", @"a=1,  , , b=2", @"a=,b, c=2", @"a=,, ,b=2",
   @"a=1; expires=Foo, b=2; path=/p", @"a=1; expires=W1d, b=2; path=/p", @"a=1; expires=We d, b=2; path=/p", @"a=1; expires=Wed , b=2; path=/p", @"a=1; expires=Wed,, b=2; path=/p", @"a=1; expires=123, b=2; path=/p", @"a=1; expires=W-d, b=2; path=/p", @"a=1; expires=Wed,09 Jun 2031 10:18:14 GMT, b=2; path=/p", @"a=1; expires=x, 09, 10, b=2; path=/p", @"a=1,\t b=2; path=/p", @"a=1, \tb=2; path=/p", @"a=1,\tb=2; path=/p", @"a=1, b=2,\tc=3", @"a=1; path=/x; expires=Wed, 09 Jun 2031 10:18:14 GMT, b=2", @"a=, b=2", @"a=1; Expires=Wed, 09 Jun 2031 10:18:14 GMT; Max-Age=5, b=2", @"a=1; ex=Wed, b=2", @"a=1; expires=\"Wed, b=2; path=/p", @"a=\"1,\" b=2",
   @"a;b=2", @"a;b=2, c=3", @"a\nb=1", @"x", @"=v", @"", @"a=1; expires=Wed, 09 Jun 2031 10:18:14 GMT, b=2, c=3"];
    int failures = 0;
    for (NSString *string in strings) {
        NSString *native = describeFirst([NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": string } forURL:url]);
        CFRange range = wk_setCookieStringFirstCookieRange((CFStringRef)string);
        NSString *first = range.location == kCFNotFound ? nil : [string substringWithRange:NSMakeRange((NSUInteger)range.location, (NSUInteger)range.length)];
        NSString *polyfill = first ? describeFirst([NSHTTPCookie cookiesWithResponseHeaderFields:@{ @"Set-Cookie": first } forURL:url]) : @"(none)";
        if ([native isEqualToString:polyfill])
            continue;
        printf("  FAIL: {%s}: native %s, polyfill %s\n", [[string stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String], native.UTF8String, polyfill.UTF8String);
        ++failures;
    }
    if (failures)
        printf("  %d FAILED\n", failures);
    else
        printf("  ok\n");
    return failures ? 1 : 0;
    }
}
