// MAVERICKS_BACKPORT: WebCrypto runs on libgcrypt (USE_GCRYPT=TRUE), not the
// cocoa CommonCrypto path. CCRandomGenerateBytes (and the rest of CC*) is not the
// active backend here. Use gcry_randomize so CryptoKey::randomData shares the same
// RNG as the rest of the gcrypt WebCrypto stack.

#include "config.h"
#include "CryptoKey.h"

#include <gcrypt.h>

namespace WebCore {

Vector<uint8_t> CryptoKey::randomData(size_t size)
{
    Vector<uint8_t> result(size);
    gcry_randomize(result.mutableSpan().data(), result.size(), GCRY_STRONG_RANDOM);
    return result;
}

} // namespace WebCore
