#ifndef CommonCrypto_CommonCryptoError_h
#define CommonCrypto_CommonCryptoError_h

/* On macOS 10.9, CCCryptorStatus and most enum values are in CommonCryptor.h */
#include <CommonCrypto/CommonCryptor.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/* kCCRNGFailure was added after 10.9 */
#ifndef kCCRNGFailure
enum { kCCRNGFailure = -4307 };
#endif

typedef int32_t CCStatus;

#if defined(__cplusplus)
}
#endif

#endif
