// Native cookie metadata and the policy reads used by NSHTTPCookieStorage's modern SPI.
// Mavericks stores SameSite, precise creation time and SetInJavaScript in the persisted Comment field.
#ifndef WK_SAMESITE_H
#define WK_SAMESITE_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    WK_SAME_SITE_NONE = 0,
    WK_SAME_SITE_LAX,
    WK_SAME_SITE_STRICT,
} wk_same_site_policy;

#define WK_MAXIMUM_COOKIE_LIFETIME_SECONDS (400 * 24 * 60 * 60)
CFStringRef wk_cookieBlobCreate(CFStringRef sameSite, CFStringRef created, CFStringRef setInJavaScript, CFStringRef comment);
CFStringRef wk_cookieBlobCopyCreated(CFStringRef comment);
CFStringRef wk_cookieBlobCopySetInJavaScript(CFStringRef comment);
CFStringRef wk_sameSiteCopyValue(CFStringRef comment);
CFStringRef wk_sameSiteCopyServerComment(CFStringRef comment);
wk_same_site_policy wk_sameSitePolicyOfComment(CFStringRef comment);
wk_same_site_policy wk_sameSitePolicyOfValue(CFStringRef value);
bool wk_sameSiteAllows(wk_same_site_policy policy, bool isSameSite, bool isTopLevelNavigation, bool isSafeMethod);
bool wk_sameSiteURLsAreSameSite(CFURLRef siteForCookies, CFURLRef url);
bool wk_cookiePathSortsFirst(CFStringRef path, CFStringRef otherPath);
bool wk_cookiePathMatchesRequestPath(CFStringRef cookiePath, CFStringRef requestPath);
CFStringRef wk_requestPathCreate(CFURLRef url);
#ifdef __cplusplus
}
#endif
#endif
