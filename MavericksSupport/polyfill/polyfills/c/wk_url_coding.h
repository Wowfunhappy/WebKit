// Shared between CFNetwork.c and methods/Foundation.m: the CFNetwork side of the property-list coders
// -[NSURLProtectionSpace _webKitPropertyListData] / -_initWithWebKitPropertyListData: and their
// NSURLCredential twins stand on. Hidden visibility, like the rest of the archive.

#ifndef WK_URL_CODING_H
#define WK_URL_CODING_H

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A CFURLProtectionSpace carrying every field a protection space has, including the two
// CFURLProtectionSpaceCreate cannot take: |distinguishedNames| (CFData elements) and |trust|, which
// the space carries as a trust of its own asking the question |trust| asks. Retained; NULL when the
// space cannot be built.
CFTypeRef wk_createProtectionSpace(CFStringRef host, int port, int serverType, CFStringRef realm,
    int authenticationScheme, CFArrayRef distinguishedNames, SecTrustRef trust);

// The kind of a CFURLCredential, as CFNetwork numbers them (kURLCredentialInternetPassword ...), and the
// trust a server-trust credential was created with (borrowed). -1 / NULL when |credential| is not a
// credential laid out as 10.9.5's are.
int wk_credentialKind(CFTypeRef credential);
SecTrustRef wk_credentialServerTrust(CFTypeRef credential);

// Foundation's NSURLRequest dictionary bit positions for explicitly assigned CFNetwork properties.
uint16_t wk_requestExplicitFlags(CFTypeRef request);
void wk_requestSetExplicitFlags(CFTypeRef request, uint16_t flags);

#ifdef __cplusplus
}
#endif

#endif // WK_URL_CODING_H
