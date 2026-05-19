/*
 * Copyright (C) 2023 Apple Inc. All rights reserved.
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
#include "CryptoAlgorithmEd25519.h"

#include "CryptoKeyOKP.h"
#include "ExceptionOr.h"
#include <pal/PALSwift.h>
#include <pal/spi/cocoa/CoreCryptoSPI.h>

#if !defined(CLANG_WEBKIT_BRANCH)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#include "PALSwift-Generated.h"
#pragma clang diagnostic pop
#endif // !defined(CLANG_WEBKIT_BRANCH)

namespace WebCore {

// 10.9 backport: pal::EdKey uses Swift CryptoKit (10.15+) and Ed25519 has no
// native pre-10.15 API on macOS. Return OperationError instead of crashing —
// sites that need Ed25519 will fail gracefully (auth/handshake error).
static ExceptionOr<Vector<uint8_t>> signEd25519CryptoKit(const Vector<uint8_t>& sk, const Vector<uint8_t>& data)
{
    UNUSED_PARAM(sk);
    UNUSED_PARAM(data);
    return Exception { ExceptionCode::OperationError };
}

static ExceptionOr<bool> verifyEd25519CryptoKit(const Vector<uint8_t>& pubKey, const Vector<uint8_t>& signature, const Vector<uint8_t>& data)
{
    UNUSED_PARAM(pubKey);
    UNUSED_PARAM(signature);
    UNUSED_PARAM(data);
    return false;
}

ExceptionOr<Vector<uint8_t>> CryptoAlgorithmEd25519::platformSign(const CryptoKeyOKP& key, const Vector<uint8_t>& data)
{
    return signEd25519CryptoKit(key.platformKey(), data);
}

ExceptionOr<bool> CryptoAlgorithmEd25519::platformVerify(const CryptoKeyOKP& key, const Vector<uint8_t>& signature, const Vector<uint8_t>& data)
{
    return verifyEd25519CryptoKit(key.platformKey(), signature, data);
}

} // namespace WebCore
