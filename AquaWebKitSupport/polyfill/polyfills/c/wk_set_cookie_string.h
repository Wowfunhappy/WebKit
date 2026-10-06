// How 10.9's +[NSHTTPCookie cookiesWithResponseHeaderFields:forURL:] divides a Set-Cookie string that holds
// several cookies.
#pragma once

#include <CoreFoundation/CoreFoundation.h>

// The range of the first cookie the string holds, from its name to the end of its attributes; kCFNotFound
// when it holds none.
CFRange wk_setCookieStringFirstCookieRange(CFStringRef);
