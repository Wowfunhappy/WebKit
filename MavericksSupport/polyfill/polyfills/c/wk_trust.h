// Shared between Security.c and CFNetwork.c. Hidden visibility, like the rest of the archive.

#ifndef WK_TRUST_H
#define WK_TRUST_H

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#ifdef __cplusplus
extern "C" {
#endif

// The certificates |trust| was created with, read without evaluating it; NULL when the trust does not
// hold them where 10.9.5's Security keeps them. Borrowed from the trust, not retained.
CFArrayRef wk_trustInputCertificates(SecTrustRef trust);

#ifdef __cplusplus
}
#endif

#endif // WK_TRUST_H
