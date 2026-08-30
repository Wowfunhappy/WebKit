// SameSite on 10.9.
//
// 10.9 loses the attribute at three points and enforces it at none. Its cookie parser discards an
// unknown attribute; its cookie record has fifteen fields and no spare (the jar lives in cookied, a
// separate daemon with its own copy of that table, so the record cannot grow); and -[NSHTTPCookie
// sameSitePolicy] does not exist. Comment and CommentURL are the only fields that survive the parser,
// the properties dictionary, the daemon and a relaunch while never reaching the wire, so the attribute
// travels with the cookie in Comment, encoded so that a comment the server sent is handed back to
// every reader untouched.
//
// This header is the encoding and the rule. CFNetworkSameSite.c encodes what a network response
// stores and withholds what a network request may not carry; methods/Foundation.m does the same for a
// script's cookie and keeps the encoded form out of every accessor.

#ifndef WK_SAMESITE_H
#define WK_SAMESITE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Read the way CookieCocoa's coreSameSitePolicy reads it: a value the modern constants do not name is
// unspecified, and unspecified is permissive (RFC 6265bis 5.3.7).
typedef enum {
    WK_SAME_SITE_NONE = 0,
    WK_SAME_SITE_LAX,
    WK_SAME_SITE_STRICT,
} wk_same_site_policy;

// The Comment text carrying |sameSite| -- the attribute's value as the server wrote it, NULL for a
// cookie that has none -- alongside |comment|, the comment the server sent. NULL when the pair cannot
// be carried, which is the caller's signal to refuse the cookie: a cookie stored without a restriction
// it was given reads as permissive. The caller owns the result.
CFStringRef wk_sameSiteCommentCreate(CFStringRef sameSite, CFStringRef comment);

// The attribute's value inside |comment|, or NULL when it carries none. The caller owns the result.
CFStringRef wk_sameSiteCopyValue(CFStringRef comment);

// The comment the server sent, which is |comment| itself when that is not an encoded one. The caller
// owns the result.
CFStringRef wk_sameSiteCopyServerComment(CFStringRef comment);

// |comment| read as a policy, without allocating: this runs once per cookie per request.
wk_same_site_policy wk_sameSitePolicyOfComment(CFStringRef comment);

// RFC 6265bis 5.5: a Strict cookie rides only same-site requests; a Lax cookie additionally rides a
// cross-site top-level navigation made with a safe method.
bool wk_sameSiteAllows(wk_same_site_policy policy, bool isSameSite, bool isTopLevelNavigation, bool isSafeMethod);

// GET, HEAD, OPTIONS and TRACE (RFC 9110 9.2.1), the methods a Lax cookie rides cross-site.
bool wk_sameSiteMethodIsSafe(CFStringRef method);

// Whether |siteForCookies| and |url| have the same registrable domain -- the comparison
// ResourceRequestCocoa's doUpdateResourceRequest makes to decide a request's SameSite disposition, and
// the one that has to be made again at every hop because CFNetwork carries the request's cookie-policy
// properties across an internal redirect verbatim while the URL changes host.
bool wk_sameSiteURLsAreSameSite(CFURLRef siteForCookies, CFURLRef url);

// What a Set-Cookie header field becomes on its way into the jar.
typedef enum {
    // No attribute anywhere in it: the header is already what should be parsed.
    WK_SAMESITE_HEADER_UNCHANGED,
    // *rewritten (owned by the caller) is the header to parse in its place.
    WK_SAMESITE_HEADER_REWRITTEN,
    // The attribute could not be carried onto the cookies that were given it. Store nothing: storing
    // the header as it stands would store those cookies without their restriction.
    WK_SAMESITE_HEADER_REFUSED,
} wk_samesite_header_disposition;

wk_samesite_header_disposition wk_sameSiteRewriteSetCookieHeader(CFStringRef header, CFURLRef url, CFStringRef *rewritten);

#ifdef __cplusplus
}
#endif

#endif // WK_SAMESITE_H
