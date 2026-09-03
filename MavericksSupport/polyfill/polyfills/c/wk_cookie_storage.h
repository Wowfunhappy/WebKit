// The cookie change report c/CFNetwork.c makes from a cookie storage's mutation slots, and the storage
// identity it makes it under.
#ifndef WK_COOKIE_STORAGE_H
#define WK_COOKIE_STORAGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

// What a storage was told to do with a cookie, as its backend's mutation slots see it.
enum wk_cookie_change {
    WK_COOKIE_SET = 0,
    WK_COOKIE_DELETED = 1,
    WK_COOKIE_ALL_DELETED = 2,
};

// The backend object a CFHTTPCookieStorageRef's writes reach, which is what a change is reported
// against. Ends the process for anything but a cookie storage over one of the patched backends.
const void *wk_cookieStorageBackend(CFTypeRef storage);

// The accept policy 10.9 leaves the process's own cookie jar at, corrected to CFNetwork's documented
// default, once per handle. See the definition in c/CFNetwork.c for what is and is not corrected.
void wk_giveTheProcessCookieJarItsDefaultAcceptPolicy(CFTypeRef storage);

// Whether a caller outside the protocol layer may set or delete a cookie of this name, domain and path
// in |storage| -- an HttpOnly cookie there is not a public caller's to replace unless the cookie it
// offers is HttpOnly too. Defined in c/CFNetwork.c, where the CF entry points carry the same rule.
bool wk_publicCallerMayChangeCookie(CFTypeRef storage, CFStringRef name, CFStringRef domain, CFStringRef path, bool cookieIsHTTPOnly);

#endif
