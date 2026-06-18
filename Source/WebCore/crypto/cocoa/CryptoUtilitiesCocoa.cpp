/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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
#include "CryptoUtilitiesCocoa.h"

#include "CryptoAlgorithmAESCTR.h"
#include <CommonCrypto/CommonCrypto.h>
#include <pal/spi/cocoa/CommonCryptoSPI.h>

namespace WebCore {

ExceptionOr<Vector<uint8_t>> transformAESCTR(CCOperation operation, const Vector<uint8_t>& counter, size_t counterLength, const Vector<uint8_t>& key, std::span<const uint8_t> data)
{
    // FIXME: We should remove the following hack once <rdar://problem/31361050> is fixed.
    // counter = nonce + counter
    // CommonCrypto currently can neither reset the counter nor detect overflow once the counter reaches its max value restricted
    // by the counterLength. It then increments the nonce which should stay same for the whole operation. To remedy this issue,
    // we detect the overflow ahead and divide the operation into two parts.
    size_t numberOfBlocks = data.size() % kCCBlockSizeAES128 ? data.size() / kCCBlockSizeAES128 + 1 : data.size() / kCCBlockSizeAES128;

    // Detect loop
    if (counterLength < sizeof(size_t) * 8 && numberOfBlocks > (static_cast<size_t>(1) << counterLength))
        return Exception { ExceptionCode::OperationError };

    // Calculate capacity before overflow
    CryptoAlgorithmAESCTR::CounterBlockHelper counterBlockHelper(counter, counterLength);
    size_t capacity = counterBlockHelper.countToOverflowSaturating();

    // Divide data into two parts if necessary.
    size_t headSize = data.size();
    if (capacity < numberOfBlocks)
        headSize = capacity * kCCBlockSizeAES128;

    // first part: compute the first n=capacity blocks of data if capacity is insufficient. Otherwise, return the result.
    CCCryptorRef cryptor;
    CCCryptorStatus status = CCCryptorCreateWithMode(operation, kCCModeCTR, kCCAlgorithmAES128, ccNoPadding, counter.span().data(), key.span().data(), key.size(), 0, 0, 0, kCCModeOptionCTR_BE, &cryptor);
    if (status)
        return Exception { ExceptionCode::OperationError };

    Vector<uint8_t> head(CCCryptorGetOutputLength(cryptor, headSize, true));

    size_t bytesWritten;
    status = CCCryptorUpdate(cryptor, data.data(), headSize, head.mutableSpan().data(), head.size(), &bytesWritten);
    if (status)
        return Exception { ExceptionCode::OperationError };

    auto p = head.mutableSpan().subspan(bytesWritten);
    status = CCCryptorFinal(cryptor, p.data(), p.size(), &bytesWritten);
    skip(p, bytesWritten);
    if (status)
        return Exception { ExceptionCode::OperationError };

    head.shrink(head.size() - p.size());

    CCCryptorRelease(cryptor);

    if (capacity >= numberOfBlocks)
        return WTF::move(head);

    // second part: compute the remaining data and append them to the head.
    // reset counter
    Vector<uint8_t> remainingCounter = counterBlockHelper.counterVectorAfterOverflow();
    status = CCCryptorCreateWithMode(operation, kCCModeCTR, kCCAlgorithmAES128, ccNoPadding, remainingCounter.span().data(), key.span().data(), key.size(), 0, 0, 0, kCCModeOptionCTR_BE, &cryptor);
    if (status)
        return Exception { ExceptionCode::OperationError };

    size_t tailSize = data.size() - headSize;
    Vector<uint8_t> tail(CCCryptorGetOutputLength(cryptor, tailSize, true));

    auto dataAfterHeader = data.subspan(headSize);
    status = CCCryptorUpdate(cryptor, dataAfterHeader.data(), dataAfterHeader.size(), tail.mutableSpan().data(), tail.size(), &bytesWritten);
    if (status)
        return Exception { ExceptionCode::OperationError };

    p = tail.mutableSpan().subspan(bytesWritten);
    status = CCCryptorFinal(cryptor, p.data(), p.size(), &bytesWritten);
    skip(p, bytesWritten);
    if (status)
        return Exception { ExceptionCode::OperationError };

    tail.shrink(tail.size() - p.size());

    CCCryptorRelease(cryptor);

    head.appendVector(tail);
    return WTF::move(head);
}

#if PLATFORM(MAC)
// MAVERICKS_BACKPORT: CCKDFParametersCreateHkdf + CCDeriveKey are runtime-absent
// on 10.9 (10.10+). The polyfill stub returns 0 = kCCSuccess but leaves the output
// buffer untouched, silently breaking WebCrypto HKDF (derived key = stale buffer
// contents). Implement RFC 5869 HKDF directly via CCHmac, which exists on 10.9.
static unsigned hmacOutputSize(CCDigestAlgorithm digest)
{
    switch (digest) {
    case kCCDigestSHA1:   return CC_SHA1_DIGEST_LENGTH;
    case kCCDigestSHA256: return CC_SHA256_DIGEST_LENGTH;
    case kCCDigestSHA384: return CC_SHA384_DIGEST_LENGTH;
    case kCCDigestSHA512: return CC_SHA512_DIGEST_LENGTH;
    case DeprecatedCCDigestSHA224: return CC_SHA224_DIGEST_LENGTH;
    default: return 0;
    }
}

static CCHmacAlgorithm ccHmacAlgFromDigest(CCDigestAlgorithm digest)
{
    switch (digest) {
    case kCCDigestSHA1:   return kCCHmacAlgSHA1;
    case kCCDigestSHA256: return kCCHmacAlgSHA256;
    case kCCDigestSHA384: return kCCHmacAlgSHA384;
    case kCCDigestSHA512: return kCCHmacAlgSHA512;
    case DeprecatedCCDigestSHA224: return kCCHmacAlgSHA224;
    default: return kCCHmacAlgSHA256;
    }
}

CCStatus keyDerivationHMAC(CCDigestAlgorithm digest, std::span<const uint8_t> keyDerivationKey, std::span<const uint8_t> context, std::span<const uint8_t> salt, Vector<uint8_t>& derivedKey)
{
    unsigned hashLen = hmacOutputSize(digest);
    if (!hashLen)
        return -1;

    CCHmacAlgorithm hmacAlg = ccHmacAlgFromDigest(digest);

    // HKDF-Extract: PRK = HMAC(salt, IKM). If salt is empty, RFC 5869 says use
    // a string of HashLen zeros.
    Vector<uint8_t> prk(hashLen);
    if (salt.empty()) {
        Vector<uint8_t> zeroSalt(hashLen, 0);
        CCHmac(hmacAlg, zeroSalt.span().data(), zeroSalt.size(), keyDerivationKey.data(), keyDerivationKey.size(), prk.mutableSpan().data());
    } else
        CCHmac(hmacAlg, salt.data(), salt.size(), keyDerivationKey.data(), keyDerivationKey.size(), prk.mutableSpan().data());

    // HKDF-Expand: T(1) = HMAC(PRK, info || 0x01)
    //              T(i) = HMAC(PRK, T(i-1) || info || i)
    // OKM = T(1) || T(2) || ... truncated to L bytes.
    size_t L = derivedKey.size();
    size_t N = (L + hashLen - 1) / hashLen;
    if (N > 255)
        return -1; // RFC 5869 limits N to 255

    Vector<uint8_t> T;
    T.reserveCapacity(hashLen);
    size_t outOffset = 0;
    for (size_t i = 1; i <= N; ++i) {
        Vector<uint8_t> input;
        input.reserveCapacity(T.size() + context.size() + 1);
        input.append(T.span());
        input.append(context);
        input.append(static_cast<uint8_t>(i));

        T.resize(hashLen);
        CCHmac(hmacAlg, prk.span().data(), prk.size(), input.span().data(), input.size(), T.mutableSpan().data());

        size_t copyLen = std::min<size_t>(hashLen, L - outOffset);
        memcpy(derivedKey.mutableSpan().data() + outOffset, T.span().data(), copyLen);
        outOffset += copyLen;
    }

    return kCCSuccess;
}
#else
CCStatus keyDerivationHMAC(CCDigestAlgorithm digest, std::span<const uint8_t> keyDerivationKey, std::span<const uint8_t> context, std::span<const uint8_t> salt, Vector<uint8_t>& derivedKey)
{
    CCKDFParametersRef params;
    CCStatus rv = CCKDFParametersCreateHkdf(&params, salt.data(), salt.size(), context.data(), context.size());
    if (rv != kCCSuccess)
        return rv;

    rv = CCDeriveKey(params, digest, keyDerivationKey.data(), keyDerivationKey.size(), derivedKey.mutableSpan().data(), derivedKey.size());
    CCKDFParametersDestroy(params);

    return rv;
}
#endif

ExceptionOr<Vector<uint8_t>> deriveHDKFBits(CCDigestAlgorithm digestAlgorithm, std::span<const uint8_t> key, std::span<const uint8_t> salt, std::span<const uint8_t> info, size_t length)
{
    Vector<uint8_t> result(length / 8);

    // <rdar://problem/32439455> Currently, when key data is empty, CCKeyDerivationHMac will bail out.
    if (keyDerivationHMAC(digestAlgorithm, key, info, salt, result) != kCCSuccess)
        return Exception { ExceptionCode::OperationError };

    return WTF::move(result);
}

ExceptionOr<Vector<uint8_t>> deriveHDKFSHA256Bits(std::span<const uint8_t> key, std::span<const uint8_t> salt, std::span<const uint8_t> info, size_t length)
{
    return deriveHDKFBits(kCCDigestSHA256, key, salt, info, length);
}

Vector<uint8_t> calculateHMACSignature(CCHmacAlgorithm algorithm, const Vector<uint8_t>& key, std::span<const uint8_t> data)
{
    size_t digestLength;
    switch (algorithm) {
    case kCCHmacAlgSHA1:
        digestLength = CC_SHA1_DIGEST_LENGTH;
        break;
    case kCCHmacAlgSHA224:
        // MAVERICKS_BACKPORT: SHA-224 graceful-fail (policy choice). Upstream traps;
        // return empty instead of crashing WebContent.
        return Vector<uint8_t>();
    case kCCHmacAlgSHA256:
        digestLength = CC_SHA256_DIGEST_LENGTH;
        break;
    case kCCHmacAlgSHA384:
        digestLength = CC_SHA384_DIGEST_LENGTH;
        break;
    case kCCHmacAlgSHA512:
        digestLength = CC_SHA512_DIGEST_LENGTH;
        break;
    default:
        ASSERT_NOT_REACHED();
        return Vector<uint8_t>();
    }

    Vector<uint8_t> result(digestLength);
    CCHmac(algorithm, key.span().data(), key.size(), data.data(), data.size(), result.mutableSpan().data());
    return result;
}

Vector<uint8_t> calculateSHA256Signature(const Vector<uint8_t>& key, std::span<const uint8_t> data)
{
    return calculateHMACSignature(kCCHmacAlgSHA256, key, data);
}

} // namespace WebCore
