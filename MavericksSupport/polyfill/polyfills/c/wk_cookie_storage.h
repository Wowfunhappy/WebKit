// Native cookie-storage handle initialization.
#ifndef WK_COOKIE_STORAGE_H
#define WK_COOKIE_STORAGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

// The accept policy 10.9 leaves the process's own cookie jar at, corrected to CFNetwork's documented
// default, once per handle. See the definition in c/CFNetwork.c for what is and is not corrected.
void wk_giveTheProcessCookieJarItsDefaultAcceptPolicy(CFTypeRef storage);


#endif
