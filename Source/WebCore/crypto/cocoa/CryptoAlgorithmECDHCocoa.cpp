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
#include "CryptoAlgorithmECDH.h"

#include "CommonCryptoUtilities.h"
#include "CryptoKeyEC.h"
#include <pal/PALSwift.h>

#if !defined(CLANG_WEBKIT_BRANCH)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#include "PALSwift-Generated.h"
#pragma clang diagnostic pop
#endif // !defined(CLANG_WEBKIT_BRANCH)

namespace WebCore {

// 10.9 backport: route ECDH derive through pal::ECKey109::sharedSecret which
// uses CCECCryptorComputeSharedSecret (10.9+).
static std::optional<Vector<uint8_t>> platformDeriveBitsCryptoKit(const CryptoKeyEC& baseKey, const CryptoKeyEC& publicKey)
{
    const auto& privKey = baseKey.platformKey();   // unique_ptr<pal::ECKey109>
    const auto& pubKey = publicKey.platformKey();
    if (!privKey || !pubKey)
        return std::nullopt;
    return privKey->sharedSecret(*pubKey);
}

std::optional<Vector<uint8_t>> CryptoAlgorithmECDH::platformDeriveBits(const CryptoKeyEC& baseKey, const CryptoKeyEC& publicKey)
{
    return platformDeriveBitsCryptoKit(baseKey, publicKey);
}

} // namespace WebCore
