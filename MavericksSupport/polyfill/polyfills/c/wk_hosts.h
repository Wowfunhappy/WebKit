// Host names, as the cookie rules read them: the public-suffix question RFC 6265 5.3 asks and the
// registrable domain WebCore compares two URLs by.

#ifndef WK_HOSTS_H
#define WK_HOSTS_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// A host that is an IP literal domain-matches only itself (RFC 6265 5.1.3) and is no public suffix.
bool wk_hostIsIPAddress(CFStringRef host);

// |name| with its A-labels turned back into Unicode, which is the form _CFHostIsDomainTopLevel answers
// on, as PublicSuffixStoreCocoa's decodeHostName does. The caller owns the result.
CFStringRef wk_copyDecodedHostName(CFStringRef name);

// The public-suffix oracle WebCore's PublicSuffixStore asks on Cocoa.
bool wk_domainIsPublicSuffix(CFStringRef domain);

// |host|'s registrable domain, read the way RegistrableDomain reads it: its top privately controlled
// domain, or the host itself when it has none. An empty host has none at all, and gets the same
// stand-in RegistrableDomain gives it, which matches only another empty host. The caller owns it.
CFStringRef wk_copyRegistrableDomain(CFStringRef host);

// Whether |host| is covered by the registrable domain |registrableDomain| -- RegistrableDomain::matches.
bool wk_registrableDomainMatchesHost(CFStringRef registrableDomain, CFStringRef host);

#ifdef __cplusplus
}
#endif

#endif // WK_HOSTS_H
