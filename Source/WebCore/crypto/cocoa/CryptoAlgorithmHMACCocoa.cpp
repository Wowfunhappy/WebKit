/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
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
#include "CryptoAlgorithmHMAC.h"

#include "CryptoKeyHMAC.h"
#include "CryptoUtilitiesCocoa.h"
#include "CryptoAlgorithmIdentifier.h"
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <pal/PALSwift.h>
#include <wtf/CryptographicUtilities.h>

namespace WebCore {

// 10.9 backport: pal::HMAC::sign/verify use Swift CryptoKit (10.15+) which
// crashes on 10.9. Use CommonCrypto's CCHmac (10.6+) directly.
static std::optional<CCHmacAlgorithm> ccHmacAlgorithmForHashIdentifier(CryptoAlgorithmIdentifier id, size_t& outLen)
{
    switch (id) {
    case CryptoAlgorithmIdentifier::SHA_1:    outLen = CC_SHA1_DIGEST_LENGTH;   return kCCHmacAlgSHA1;
    case CryptoAlgorithmIdentifier::SHA_256:  outLen = CC_SHA256_DIGEST_LENGTH; return kCCHmacAlgSHA256;
    case CryptoAlgorithmIdentifier::SHA_384:  outLen = CC_SHA384_DIGEST_LENGTH; return kCCHmacAlgSHA384;
    case CryptoAlgorithmIdentifier::SHA_512:  outLen = CC_SHA512_DIGEST_LENGTH; return kCCHmacAlgSHA512;
    default: return std::nullopt;
    }
}

static ExceptionOr<Vector<uint8_t>> platformSignCryptoKit(const CryptoKeyHMAC& key, const Vector<uint8_t>& data)
{
    if (!isValidHashParameter(key.hashAlgorithmIdentifier()))
        return Exception { ExceptionCode::OperationError };
    size_t outLen = 0;
    auto alg = ccHmacAlgorithmForHashIdentifier(key.hashAlgorithmIdentifier(), outLen);
    if (!alg)
        return Exception { ExceptionCode::OperationError };
    Vector<uint8_t> result(outLen);
    auto keySpan = key.key().span();
    auto dataSpan = data.span();
    auto resultSpan = result.mutableSpan();
    CCHmac(*alg, keySpan.data(), keySpan.size(), dataSpan.data(), dataSpan.size(), resultSpan.data());
    return result;
}

static ExceptionOr<bool> platformVerifyCryptoKit(const CryptoKeyHMAC& key, const Vector<uint8_t>& signature, const Vector<uint8_t>& data)
{
    auto signResult = platformSignCryptoKit(key, data);
    if (signResult.hasException())
        return signResult.releaseException();
    auto computed = signResult.releaseReturnValue();
    if (computed.size() != signature.size())
        return false;
    // constant-time compare
    uint8_t diff = 0;
    for (size_t i = 0; i < computed.size(); ++i)
        diff |= computed[i] ^ signature[i];
    return diff == 0;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmHMAC::platformSign(const CryptoKeyHMAC& key, const Vector<uint8_t>& data)
{
    return platformSignCryptoKit(key, data);
}

ExceptionOr<bool> CryptoAlgorithmHMAC::platformVerify(const CryptoKeyHMAC& key, const Vector<uint8_t>& signature, const Vector<uint8_t>& data)
{
    return platformVerifyCryptoKit(key, signature, data);
}
} // namespace WebCore
