// The cookie change report c/CFNetwork.c makes from a cookie storage's mutation slots, and the storage
// identity it makes it under.
#ifndef WK_COOKIE_STORAGE_H
#define WK_COOKIE_STORAGE_H

#include <CoreFoundation/CoreFoundation.h>

// What a storage was told to do with a cookie, as its backend's mutation slots see it.
enum wk_cookie_change {
    WK_COOKIE_SET = 0,
    WK_COOKIE_DELETED = 1,
    WK_COOKIE_ALL_DELETED = 2,
};

// The backend object a CFHTTPCookieStorageRef's writes reach, which is what a change is reported
// against. Ends the process for anything but a cookie storage over one of the patched backends.
const void *wk_cookieStorageBackend(CFTypeRef storage);

#endif
