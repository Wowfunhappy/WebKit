/*
 * Copyright (C) 2023 Igalia S.L.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"
#include "CryptoAlgorithmX25519.h"

#include "CryptoKeyOKP.h"
#include <pal/PALSwift.h>
#include <pal/spi/cocoa/CoreCryptoSPI.h>

#if !defined(CLANG_WEBKIT_BRANCH)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#include "PALSwift-Generated.h"
#pragma clang diagnostic pop
#endif // !defined(CLANG_WEBKIT_BRANCH)

namespace WebCore {

// 10.9 backport: pal::EdKey uses Swift CryptoKit (10.15+) and X25519 has no
// native pre-10.15 API on macOS. Return nullopt instead of crashing.
static std::optional<Vector<uint8_t>> deriveBitsCryptoKit(const Vector<uint8_t>& baseKey, const Vector<uint8_t>& publicKey)
{
    UNUSED_PARAM(baseKey);
    UNUSED_PARAM(publicKey);
    return std::nullopt;
}

std::optional<Vector<uint8_t>> CryptoAlgorithmX25519::platformDeriveBits(const CryptoKeyOKP& baseKey, const CryptoKeyOKP& publicKey)
{
    return deriveBitsCryptoKit(baseKey.platformKey(), publicKey.platformKey());
}
} // namespace WebCore
