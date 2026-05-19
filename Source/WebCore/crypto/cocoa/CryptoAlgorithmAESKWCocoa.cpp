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
#include "CryptoAlgorithmAESKW.h"

#include "CryptoKeyAES.h"
#include <CommonCrypto/CommonCrypto.h>
#include <pal/PALSwift.h>

#if !defined(CLANG_WEBKIT_BRANCH)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#include "PALSwift-Generated.h"
#pragma clang diagnostic pop
#endif // !defined(CLANG_WEBKIT_BRANCH)

namespace WebCore {

// 10.9 backport: pal::AesKw uses Swift CryptoKit (10.15+); use CommonCrypto's
// CCSymmetricKeyWrap/Unwrap (10.7+) which implements the same RFC 3394 standard.
static ExceptionOr<Vector<uint8_t>> wrapKeyAESKWCryptoKit(const Vector<uint8_t>& key, const Vector<uint8_t>& data)
{
    size_t wrappedSize = CCSymmetricWrappedSize(kCCWRAPAES, data.size());
    Vector<uint8_t> result(wrappedSize);
    size_t outSize = wrappedSize;
    auto keySpan = key.span();
    auto dataSpan = data.span();
    auto resultSpan = result.mutableSpan();
    int status = CCSymmetricKeyWrap(kCCWRAPAES, CCrfc3394_iv, CCrfc3394_ivLen, keySpan.data(), keySpan.size(), dataSpan.data(), dataSpan.size(), resultSpan.data(), &outSize);
    if (status != kCCSuccess)
        return Exception { ExceptionCode::OperationError };
    result.shrink(outSize);
    return result;
}

static ExceptionOr<Vector<uint8_t>> unwrapKeyAESKWCryptoKit(const Vector<uint8_t>& key, const Vector<uint8_t>& data)
{
    size_t unwrappedSize = CCSymmetricUnwrappedSize(kCCWRAPAES, data.size());
    Vector<uint8_t> result(unwrappedSize);
    size_t outSize = unwrappedSize;
    auto keySpan = key.span();
    auto dataSpan = data.span();
    auto resultSpan = result.mutableSpan();
    int status = CCSymmetricKeyUnwrap(kCCWRAPAES, CCrfc3394_iv, CCrfc3394_ivLen, keySpan.data(), keySpan.size(), dataSpan.data(), dataSpan.size(), resultSpan.data(), &outSize);
    if (status != kCCSuccess)
        return Exception { ExceptionCode::OperationError };
    result.shrink(outSize);
    return result;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmAESKW::platformWrapKey(const CryptoKeyAES& key, const Vector<uint8_t>& data)
{
    return wrapKeyAESKWCryptoKit(key.key(), data);
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmAESKW::platformUnwrapKey(const CryptoKeyAES& key, const Vector<uint8_t>& data)
{
    return unwrapKeyAESKWCryptoKit(key.key(), data);
}

} // namespace WebCore
