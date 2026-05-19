#ifndef _COMMON_RANDOM_H_
#define _COMMON_RANDOM_H_

#include <CommonCrypto/CommonCryptoError.h>
#include <stddef.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef void *CCRandomRef;
extern const CCRandomRef kCCRandomDefault;

typedef CCStatus CCRNGStatus;
CCRNGStatus CCRandomGenerateBytes(void *bytes, size_t count);

#if defined(__cplusplus)
}
#endif

#endif /* _COMMON_RANDOM_H_ */
