/*
 * Copyright (C) 2011 Google Inc. All rights reserved.
 * Copyright (C) 2015-2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include <wtf/SHA1.h>

#include <cstddef>
#include <wtf/Assertions.h>
#include <wtf/HexNumber.h>
#include <wtf/text/CString.h>
#include <wtf/text/WTFString.h>

#if USE(CF)
#include <wtf/cf/VectorCF.h>
#endif

namespace WTF {

#if PLATFORM(COCOA)

// On macOS 10.9, CC_SHA1_Update crashes inside ccdigest_update at memmove(0x40,...)
// because libcorecrypto's internal context layout differs from the public CC_SHA1_CTX
// shape. Use a built-in reference implementation that stores its state directly inside
// the existing CC_SHA1_CTX bytes (sizeof = 96 bytes, exactly enough for: 64-byte block
// buffer + 8-byte total counter + 20 bytes for the 5 hash words + 4 bytes for cursor).
// This avoids changing sizeof(SHA1) so the header layout stays compatible.
//
// Note: we don't touch CC_SHA1_Init/Update/Final at all — the bytes of m_context are
// reinterpreted via the layout below.

namespace {

struct SHA1State {
    std::array<uint8_t, 64> buffer;            // bytes  0-63
    uint64_t totalBytes;                       // bytes 64-71
    std::array<uint32_t, 5> hash;              // bytes 72-91
    uint32_t cursor;                           // bytes 92-95
};
static_assert(sizeof(SHA1State) <= sizeof(CC_SHA1_CTX),
    "SHA1State must fit inside CC_SHA1_CTX bytes");

inline uint32_t refF(int t, uint32_t b, uint32_t c, uint32_t d)
{
    if (t < 20) return (b & c) | ((~b) & d);
    if (t < 40) return b ^ c ^ d;
    if (t < 60) return (b & c) | (b & d) | (c & d);
    return b ^ c ^ d;
}

inline uint32_t refK(int t)
{
    if (t < 20) return 0x5a827999;
    if (t < 40) return 0x6ed9eba1;
    if (t < 60) return 0x8f1bbcdc;
    return 0xca62c1d6;
}

inline uint32_t refRotateLeft(int n, uint32_t x) { return (x << n) | (x >> (32 - n)); }

void refProcessBlock(SHA1State& s)
{
    uint32_t w[80];
    for (int t = 0; t < 16; ++t) {
        w[t] = uint32_t(s.buffer[t * 4 + 0]) << 24
             | uint32_t(s.buffer[t * 4 + 1]) << 16
             | uint32_t(s.buffer[t * 4 + 2]) << 8
             | uint32_t(s.buffer[t * 4 + 3]);
    }
    for (int t = 16; t < 80; ++t)
        w[t] = refRotateLeft(1, w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]);

    uint32_t a = s.hash[0], b = s.hash[1], c = s.hash[2], d = s.hash[3], e = s.hash[4];
    for (int t = 0; t < 80; ++t) {
        uint32_t temp = refRotateLeft(5, a) + refF(t, b, c, d) + e + w[t] + refK(t);
        e = d; d = c; c = refRotateLeft(30, b); b = a; a = temp;
    }
    s.hash[0] += a; s.hash[1] += b; s.hash[2] += c; s.hash[3] += d; s.hash[4] += e;
    s.cursor = 0;
}

void refReset(SHA1State& s)
{
    s.cursor = 0;
    s.totalBytes = 0;
    s.hash = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
}

inline SHA1State& stateOf(CC_SHA1_CTX& ctx)
{
    return *std::bit_cast<SHA1State*>(&ctx);
}

}

SHA1::SHA1()
{
    refReset(stateOf(m_context));
}

void SHA1::addBytes(std::span<const std::byte> input)
{
    auto& s = stateOf(m_context);
    for (auto byte : input) {
        s.buffer[s.cursor++] = std::to_integer<uint8_t>(byte);
        ++s.totalBytes;
        if (s.cursor == 64)
            refProcessBlock(s);
    }
}

void SHA1::computeHash(Digest& digest)
{
    auto& s = stateOf(m_context);
    s.buffer[s.cursor++] = 0x80;
    if (s.cursor > 56) {
        while (s.cursor < 64)
            s.buffer[s.cursor++] = 0x00;
        refProcessBlock(s);
    }
    for (size_t i = s.cursor; i < 56; ++i)
        s.buffer[i] = 0x00;
    uint64_t bits = s.totalBytes * 8;
    for (int i = 0; i < 8; ++i) {
        s.buffer[56 + (7 - i)] = bits & 0xFF;
        bits >>= 8;
    }
    s.cursor = 64;
    refProcessBlock(s);

    for (size_t i = 0; i < 5; ++i) {
        uint32_t hashValue = s.hash[i];
        for (int j = 0; j < 4; ++j) {
            digest[4 * i + (3 - j)] = hashValue & 0xFF;
            hashValue >>= 8;
        }
    }
    refReset(s);
}

#else

// A straightforward SHA-1 implementation based on RFC 3174.
// http://www.ietf.org/rfc/rfc3174.txt
// The names of functions and variables (such as "a", "b", and "f") follow notations in RFC 3174.

static inline uint32_t f(int t, uint32_t b, uint32_t c, uint32_t d)
{
    ASSERT(t >= 0 && t < 80);
    if (t < 20)
        return (b & c) | ((~b) & d);
    if (t < 40)
        return b ^ c ^ d;
    if (t < 60)
        return (b & c) | (b & d) | (c & d);
    return b ^ c ^ d;
}

static inline uint32_t k(int t)
{
    ASSERT(t >= 0 && t < 80);
    if (t < 20)
        return 0x5a827999;
    if (t < 40)
        return 0x6ed9eba1;
    if (t < 60)
        return 0x8f1bbcdc;
    return 0xca62c1d6;
}

static inline uint32_t rotateLeft(int n, uint32_t x)
{
    ASSERT(n >= 0 && n < 32);
    return (x << n) | (x >> (32 - n));
}

SHA1::SHA1()
{
    reset();
}

void SHA1::addBytes(std::span<const std::byte> input)
{
    for (auto byte : input) {
        ASSERT(m_cursor < 64);
        m_buffer[m_cursor++] = std::to_integer<uint8_t>(byte);
        ++m_totalBytes;
        if (m_cursor == 64)
            processBlock();
    }
}

void SHA1::computeHash(Digest& digest)
{
    finalize();

    for (size_t i = 0; i < 5; ++i) {
        // Treat hashValue as a big-endian value.
        uint32_t hashValue = m_hash[i];
        for (int j = 0; j < 4; ++j) {
            digest[4 * i + (3 - j)] = hashValue & 0xFF;
            hashValue >>= 8;
        }
    }

    reset();
}

void SHA1::finalize()
{
    ASSERT(m_cursor < 64);
    m_buffer[m_cursor++] = 0x80;
    if (m_cursor > 56) {
        // Pad out to next block.
        while (m_cursor < 64)
            m_buffer[m_cursor++] = 0x00;
        processBlock();
    }

    for (size_t i = m_cursor; i < 56; ++i)
        m_buffer[i] = 0x00;

    // Write the length as a big-endian 64-bit value.
    uint64_t bits = m_totalBytes * 8;
    for (int i = 0; i < 8; ++i) {
        m_buffer[56 + (7 - i)] = bits & 0xFF;
        bits >>= 8;
    }
    m_cursor = 64;
    processBlock();
}

void SHA1::processBlock()
{
    ASSERT(m_cursor == 64);

    std::array <uint32_t, 80> w { };
    for (int t = 0; t < 16; ++t)
        w[t] = (m_buffer[t * 4] << 24) | (m_buffer[t * 4 + 1] << 16) | (m_buffer[t * 4 + 2] << 8) | m_buffer[t * 4 + 3];
    for (int t = 16; t < 80; ++t)
        w[t] = rotateLeft(1, w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]);

    uint32_t a = m_hash[0];
    uint32_t b = m_hash[1];
    uint32_t c = m_hash[2];
    uint32_t d = m_hash[3];
    uint32_t e = m_hash[4];

    for (int t = 0; t < 80; ++t) {
        uint32_t temp = rotateLeft(5, a) + f(t, b, c, d) + e + w[t] + k(t);
        e = d;
        d = c;
        c = rotateLeft(30, b);
        b = a;
        a = temp;
    }

    m_hash[0] += a;
    m_hash[1] += b;
    m_hash[2] += c;
    m_hash[3] += d;
    m_hash[4] += e;

    m_cursor = 0;
}

void SHA1::reset()
{
    m_cursor = 0;
    m_totalBytes = 0;
    m_hash[0] = 0x67452301;
    m_hash[1] = 0xefcdab89;
    m_hash[2] = 0x98badcfe;
    m_hash[3] = 0x10325476;
    m_hash[4] = 0xc3d2e1f0;

    // Clear the buffer after use in case it's sensitive.
    m_buffer.fill(0);
}

#endif

void SHA1::addUTF8Bytes(StringView string)
{
    if (string.containsOnlyASCII()) {
        if (string.is8Bit())
            addBytes(string.span8());
        else
            addBytes(String::make8Bit(string.span16()).span8());
    } else
        addBytes(string.utf8().span());
}

#if USE(CF)
void SHA1::addUTF8Bytes(CFStringRef string)
{
    if (auto characters = CFStringGetASCIICStringSpan(string); characters.data()) {
        addBytes(byteCast<uint8_t>(characters));
        return;
    }

    constexpr size_t bufferSize = 1024;
    if (size_t length = CFStringGetLength(string); length <= bufferSize) {
        std::array<UInt8, bufferSize> buffer;
        CFIndex usedBufferLength = 0;
        CFStringGetBytes(string, CFRangeMake(0, length), kCFStringEncodingASCII, 0, false, buffer.data(), buffer.size(), &usedBufferLength);
        if (length == static_cast<size_t>(usedBufferLength)) {
            addBytes(std::span { buffer }.first(length));
            return;
        }
    }

    addUTF8Bytes(String(string));
}
#endif // USE(CF)

CString SHA1::hexDigest(const Digest& digest)
{
    return toHexCString(digest);
}

CString SHA1::computeHexDigest()
{
    Digest digest;
    computeHash(digest);
    return hexDigest(digest);
}

} // namespace WTF
