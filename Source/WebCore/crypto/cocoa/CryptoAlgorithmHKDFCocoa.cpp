/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CryptoAlgorithmHKDF.h"

#include "CommonCryptoUtilities.h"
#include "CryptoAlgorithmHkdfParams.h"
#include "CryptoAlgorithmIdentifier.h"
#include "CryptoKeyRaw.h"
#include "CryptoUtilitiesCocoa.h"
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <pal/PALSwift.h>

#if !defined(CLANG_WEBKIT_BRANCH)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#include "PALSwift-Generated.h"
#pragma clang diagnostic pop
#endif // !defined(CLANG_WEBKIT_BRANCH)

namespace WebCore {

// 10.9 backport: pal::HKDF uses Swift CryptoKit (10.15+); implement HKDF
// (RFC 5869) using CCHmac (10.6+) directly. HKDF = HMAC-Extract + HMAC-Expand.
static std::optional<std::pair<CCHmacAlgorithm, size_t>> hmacAlgForHash(CryptoAlgorithmIdentifier id)
{
    switch (id) {
    case CryptoAlgorithmIdentifier::SHA_1:    return std::make_pair(kCCHmacAlgSHA1,   (size_t)CC_SHA1_DIGEST_LENGTH);
    case CryptoAlgorithmIdentifier::SHA_256:  return std::make_pair(kCCHmacAlgSHA256, (size_t)CC_SHA256_DIGEST_LENGTH);
    case CryptoAlgorithmIdentifier::SHA_384:  return std::make_pair(kCCHmacAlgSHA384, (size_t)CC_SHA384_DIGEST_LENGTH);
    case CryptoAlgorithmIdentifier::SHA_512:  return std::make_pair(kCCHmacAlgSHA512, (size_t)CC_SHA512_DIGEST_LENGTH);
    default: return std::nullopt;
    }
}

static ExceptionOr<Vector<uint8_t>> platformDeriveBitsCryptoKit(const CryptoAlgorithmHkdfParams& parameters, const CryptoKeyRaw& key, size_t length)
{
    if (!isValidHashParameter(parameters.hashIdentifier))
        return Exception { ExceptionCode::OperationError };
    auto algInfo = hmacAlgForHash(parameters.hashIdentifier);
    if (!algInfo)
        return Exception { ExceptionCode::OperationError };
    auto [alg, hashLen] = *algInfo;

    // length is in BITS per WebCrypto; convert to bytes.
    size_t lengthBytes = length / 8;

    auto keySpan = key.key().span();
    auto saltSpan = parameters.saltVector().span();
    auto infoSpan = parameters.infoVector().span();

    // Step 1: HKDF-Extract — PRK = HMAC(salt, IKM)
    // If salt is empty, use a string of HashLen zeros.
    Vector<uint8_t> defaultSalt;
    const uint8_t* effectiveSalt = saltSpan.data();
    size_t effectiveSaltLen = saltSpan.size();
    if (!effectiveSaltLen) {
        defaultSalt.fill(0, hashLen);
        effectiveSalt = defaultSalt.span().data();
        effectiveSaltLen = hashLen;
    }
    Vector<uint8_t> prk(hashLen);
    CCHmac(alg, effectiveSalt, effectiveSaltLen, keySpan.data(), keySpan.size(), prk.mutableSpan().data());

    // Step 2: HKDF-Expand — N = ceil(L / HashLen), output T(1) || ... || T(N)
    size_t N = (lengthBytes + hashLen - 1) / hashLen;
    if (N > 255)
        return Exception { ExceptionCode::OperationError };
    Vector<uint8_t> okm;
    okm.reserveCapacity(N * hashLen);
    Vector<uint8_t> T;
    for (size_t i = 1; i <= N; ++i) {
        // Tinput = T(i-1) || info || i
        Vector<uint8_t> Tinput;
        Tinput.appendVector(T);
        if (infoSpan.size())
            Tinput.append(infoSpan);
        uint8_t counter = (uint8_t)i;
        Tinput.append(counter);
        T.resize(hashLen);
        CCHmac(alg, prk.span().data(), prk.size(), Tinput.span().data(), Tinput.size(), T.mutableSpan().data());
        okm.appendVector(T);
    }
    okm.shrink(lengthBytes);
    return okm;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmHKDF::platformDeriveBits(const CryptoAlgorithmHkdfParams& parameters, const CryptoKeyRaw& key, size_t length)
{
    return platformDeriveBitsCryptoKit(parameters, key, length);
}
} // namespace WebCore
