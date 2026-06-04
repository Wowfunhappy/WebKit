// 10.9 backport: WebCrypto switched from CommonCrypto to libgcrypt.
// CCRandomGenerateBytes (and the rest of CC*) is unavailable in our build.
// Use gcry_randomize so the rest of the WebCrypto stack — which is the
// gcrypt impl now — uses the same RNG.

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
