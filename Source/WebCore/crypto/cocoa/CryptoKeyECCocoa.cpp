/*
 * Copyright (C) 2017-2019 Apple Inc. All rights reserved.
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
#include "CryptoKeyEC.h"

#include "CommonCryptoDERUtilities.h"
#include "JsonWebKey.h"
#include <pal/PALSwift.h>
#include <wtf/text/Base64.h>

namespace WebCore {

static const unsigned char InitialOctetEC = 0x04; // Per Section 2.3.3 of http://www.secg.org/sec1-v2.pdf
// OID id-ecPublicKey 1.2.840.10045.2.1.
static constexpr auto IdEcPublicKey = std::to_array<unsigned char>({ 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 });
// OID secp256r1 1.2.840.10045.3.1.7.
static constexpr auto Secp256r1 = std::to_array<unsigned char>({ 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 });
// OID secp384r1 1.3.132.0.34
static constexpr auto Secp384r1 = std::to_array<unsigned char>({ 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22 });
// OID secp521r1 1.3.132.0.35
static constexpr auto Secp521r1 = std::to_array<unsigned char>({ 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23 });

// Version 1. Per https://tools.ietf.org/html/rfc5915#section-3
static constexpr std::array<uint8_t, 3> PrivateKeyVersion { 0x02, 0x01, 0x01 };
// Tagged type [1]
static const unsigned char TaggedType1 = 0xa1;

static constexpr size_t NODELETE sizeCeil(float f)
{
    auto s = static_cast<size_t>(f);
    return f > s ? s + 1 : s;
}

static constexpr size_t NODELETE keySizeInBitsFromNamedCurve(CryptoKeyEC::NamedCurve curve)
{
    switch (curve) {
    case CryptoKeyEC::NamedCurve::P256:
        return 256;
    case CryptoKeyEC::NamedCurve::P384:
        return 384;
    case CryptoKeyEC::NamedCurve::P521:
        return 521;
    }

    ASSERT_NOT_REACHED();
    return 0;
}

static constexpr size_t NODELETE keySizeInBytesFromNamedCurve(CryptoKeyEC::NamedCurve curve)
{
    return sizeCeil(keySizeInBitsFromNamedCurve(curve) / 8.);
}

// Per Section 2.3.4 of http://www.secg.org/sec1-v2.pdf
// We only support uncompressed point format.
static constexpr bool NODELETE doesUncompressedPointMatchNamedCurve(CryptoKeyEC::NamedCurve curve, size_t size)
{
    return (keySizeInBytesFromNamedCurve(curve) * 2 + 1) == size;
}

// Per Section 2.3.5 of http://www.secg.org/sec1-v2.pdf
static constexpr bool NODELETE doesFieldElementMatchNamedCurve(CryptoKeyEC::NamedCurve curve, size_t size)
{
    return keySizeInBytesFromNamedCurve(curve) == size;
}

size_t CryptoKeyEC::keySizeInBits() const
{
    return keySizeInBitsFromNamedCurve(m_curve);
}

bool CryptoKeyEC::platformSupportedCurve(NamedCurve curve)
{
    // 10.9 backport: enable NIST EC curves via our pal::ECKey109 wrapper around
    // CCECCryptor* (10.9+). All three NIST curves (P-256, P-384, P-521) are
    // supported by libcommonCrypto on 10.9. Other primitives like JWK import/
    // export still go through the Swift CryptoKit path (asserts) — only basic
    // generateKey + ECDH deriveBits work for now.
    UNUSED_PARAM(curve);
    return true;
}

#if defined(CLANG_WEBKIT_BRANCH)
static pal::ECCurve namedCurveTo109Curve(CryptoKeyEC::NamedCurve curve)
{
    switch (curve) {
    case CryptoKeyEC::NamedCurve::P256: return pal::ECCurve::p256();
    case CryptoKeyEC::NamedCurve::P384: return pal::ECCurve::p384();
    case CryptoKeyEC::NamedCurve::P521: return pal::ECCurve::p521();
    }
    return pal::ECCurve::p256();
}
#endif

#if !defined(CLANG_WEBKIT_BRANCH)

static pal::ECCurve namedCurveToCryptoKitCurve(CryptoKeyEC::NamedCurve curve)
{
    switch (curve) {
    case CryptoKeyEC::NamedCurve::P256:
        return pal::ECCurve::p256();
    case CryptoKeyEC::NamedCurve::P384:
        return pal::ECCurve::p384();
    case CryptoKeyEC::NamedCurve::P521:
        return pal::ECCurve::p521();
    }

    ASSERT_NOT_REACHED();
    return pal::ECCurve::p256();
}
static PlatformECKeyContainer toPlatformKey(pal::ECKey key)
{
    return makeUniqueRefWithoutFastMallocCheck<pal::ECKey>(key);
}

#endif

std::optional<CryptoKeyPair> CryptoKeyEC::platformGeneratePair(CryptoAlgorithmIdentifier identifier, NamedCurve curve, bool extractable, CryptoKeyUsageBitmap usages)
{
#if !defined(CLANG_WEBKIT_BRANCH)
    auto privateKey = CryptoKeyEC::create(identifier, curve, CryptoKeyType::Private, toPlatformKey(pal::ECKey::init(namedCurveToCryptoKitCurve(curve))), extractable, usages);
    auto publicKey = CryptoKeyEC::create(identifier, curve, CryptoKeyType::Public, toPlatformKey(privateKey->platformKey()->toPub()), true, usages);
    return CryptoKeyPair { WTF::move(publicKey), WTF::move(privateKey) };
#else
    // 10.9 backport: generate via CCECCryptorGeneratePair through pal::ECKey109 wrapper.
    auto privKey = pal::ECKey109::generate(namedCurveTo109Curve(curve));
    if (!privKey)
        return std::nullopt;
    auto pubKey = privKey->toPub();
    if (!pubKey)
        return std::nullopt;
    auto privateKey = CryptoKeyEC::create(identifier, curve, CryptoKeyType::Private, WTF::move(privKey), extractable, usages);
    auto publicKey = CryptoKeyEC::create(identifier, curve, CryptoKeyType::Public, WTF::move(pubKey), true, usages);
    return CryptoKeyPair { WTF::move(publicKey), WTF::move(privateKey) };
#endif
}

RefPtr<CryptoKeyEC> CryptoKeyEC::platformImportRaw(CryptoAlgorithmIdentifier identifier, NamedCurve curve, Vector<uint8_t>&& keyData, bool extractable, CryptoKeyUsageBitmap usages)
{
#if !defined(CLANG_WEBKIT_BRANCH)
    if (!doesUncompressedPointMatchNamedCurve(curve, keyData.size()))
        return nullptr;

    auto rv = pal::ECKey::importX963Pub(keyData.span(), namedCurveToCryptoKitCurve(curve));
    if (!rv.getErrorCode().isSuccess() || !rv.getKey())
        return nullptr;
    return create(identifier, curve, CryptoKeyType::Public, toPlatformKey(rv.getKey().get()), extractable, usages);
#else
    // 10.9 backport: import X9.63 uncompressed EC public key via pal::ECKey109.
    if (!doesUncompressedPointMatchNamedCurve(curve, keyData.size()))
        return nullptr;
    auto key = pal::ECKey109::importX963Pub(keyData.span(), namedCurveTo109Curve(curve));
    if (!key)
        return nullptr;
    return create(identifier, curve, CryptoKeyType::Public, WTF::move(key), extractable, usages);
#endif
}

Vector<uint8_t> CryptoKeyEC::platformExportRaw() const
{
#if !defined(CLANG_WEBKIT_BRANCH)
    size_t expectedSize = 2 * keySizeInBytes() + 1; // Per Section 2.3.4 of http://www.secg.org/sec1-v2.pdf
    auto rv = platformKey()->exportX963Pub();
    if (rv.errorCode != Cpp::ErrorCodes::Success)
        return { };
    if (rv.result.size() != expectedSize)
        return { };
    return WTF::move(rv.result);
#else
    // 10.9 backport: pal::ECKey109 has exportX963Pub via CCECCryptorExportKey,
    // so EC public-key export works. For a private key, derive the public first.
    auto exportPub = platformKey()->isPrivate() ? platformKey()->toPub() : nullptr;
    pal::ECKey109* keyToExport = exportPub ? exportPub.get() : platformKey().get();
    auto rv = keyToExport->exportX963Pub();
    if (!rv)
        return { };
    size_t expectedSize = 2 * keySizeInBytes() + 1;
    if (rv->size() != expectedSize)
        return { };
    return WTF::move(*rv);
#endif
}

RefPtr<CryptoKeyEC> CryptoKeyEC::platformImportJWKPublic(CryptoAlgorithmIdentifier identifier, NamedCurve curve, Vector<uint8_t>&& x, Vector<uint8_t>&& y, bool extractable, CryptoKeyUsageBitmap usages)
{
    if (!doesFieldElementMatchNamedCurve(curve, x.size()) || !doesFieldElementMatchNamedCurve(curve, y.size()))
        return nullptr;
    Vector<uint8_t> combined { InitialOctetEC };
    combined.appendVector(x);
    combined.appendVector(y);
    return platformImportRaw(identifier, curve, WTF::move(combined), extractable, usages);
}

RefPtr<CryptoKeyEC> CryptoKeyEC::platformImportJWKPrivate(CryptoAlgorithmIdentifier identifier, NamedCurve curve, Vector<uint8_t>&& x, Vector<uint8_t>&& y, Vector<uint8_t>&& d, bool extractable, CryptoKeyUsageBitmap usages)
{
#if !defined(CLANG_WEBKIT_BRANCH)
    if (!doesFieldElementMatchNamedCurve(curve, x.size()) || !doesFieldElementMatchNamedCurve(curve, y.size()) || !doesFieldElementMatchNamedCurve(curve, d.size()))
        return nullptr;

    // A hack to CommonCrypto since it doesn't provide API for creating private keys directly from x, y, d.
    // BinaryInput = InitialOctetEC + X + Y + D
    Vector<uint8_t> binaryInput;
    binaryInput.append(InitialOctetEC);
    binaryInput.appendVector(x);
    binaryInput.appendVector(y);
    binaryInput.appendVector(d);

    auto rv = pal::ECKey::importX963Private(binaryInput.span(), namedCurveToCryptoKitCurve(curve));
    if (!rv.getErrorCode().isSuccess() || !rv.getKey())
        return nullptr;
    return create(identifier, curve, CryptoKeyType::Private, toPlatformKey(rv.getKey().get()), extractable, usages);
#else
    // 10.9 backport: pal::ECKey109::importX963Private accepts the same encoding.
    if (!doesFieldElementMatchNamedCurve(curve, x.size()) || !doesFieldElementMatchNamedCurve(curve, y.size()) || !doesFieldElementMatchNamedCurve(curve, d.size()))
        return nullptr;
    Vector<uint8_t> binaryInput;
    binaryInput.append(InitialOctetEC);
    binaryInput.appendVector(x);
    binaryInput.appendVector(y);
    binaryInput.appendVector(d);
    auto key = pal::ECKey109::importX963Private(binaryInput.span(), namedCurveTo109Curve(curve));
    if (!key)
        return nullptr;
    return create(identifier, curve, CryptoKeyType::Private, WTF::move(key), extractable, usages);
#endif
}

bool CryptoKeyEC::platformAddFieldElements(JsonWebKey& jwk) const
{
#if !defined(CLANG_WEBKIT_BRANCH)
    size_t keySizeInBytes = this->keySizeInBytes();
    size_t publicKeySize = keySizeInBytes * 2 + 1; // 04 + X + Y per Section 2.3.4 of http://www.secg.org/sec1-v2.pdf
    size_t privateKeySize = keySizeInBytes * 3 + 1; // 04 + X + Y + D

    Vector<uint8_t> result(privateKeySize);
    switch (type()) {
    case CryptoKeyType::Public: {
        auto rv = platformKey()->exportX963Pub();
        if (rv.errorCode != Cpp::ErrorCodes::Success)
            return false;
        result = WTF::move(rv.result);
        break;
    }
    case CryptoKeyType::Private: {
        auto rv = platformKey()->exportX963Private();
        if (rv.errorCode != Cpp::ErrorCodes::Success)
            return false;
        result = WTF::move(rv.result);
        break;
    }
    case CryptoKeyType::Secret:
        ASSERT_NOT_REACHED();
        return false;
    }
    if ((result.size() != publicKeySize) && (result.size() != privateKeySize)) [[unlikely]]
        return false;
    jwk.x = base64URLEncodeToString(result.subspan(1, keySizeInBytes));
    jwk.y = base64URLEncodeToString(result.subspan(keySizeInBytes + 1, keySizeInBytes));
    if (result.size() > publicKeySize)
        jwk.d = base64URLEncodeToString(result.subspan(publicKeySize, keySizeInBytes));
    return true;
#else
    // 10.9 backport: implement JWK export via pal::ECKey109. Both public-key
    // (exportX963Pub) and private-key (exportX963Private) paths are available
    // through the CCECCryptor wrapper.
    size_t keySizeInBytes = this->keySizeInBytes();
    size_t publicKeySize = keySizeInBytes * 2 + 1;
    size_t privateKeySize = keySizeInBytes * 3 + 1;
    Vector<uint8_t> result;
    switch (type()) {
    case CryptoKeyType::Public: {
        auto exportPub = platformKey()->isPrivate() ? platformKey()->toPub() : nullptr;
        pal::ECKey109* keyToExport = exportPub ? exportPub.get() : platformKey().get();
        auto rv = keyToExport->exportX963Pub();
        if (!rv)
            return false;
        result = WTF::move(*rv);
        break;
    }
    case CryptoKeyType::Private: {
        auto rv = platformKey()->exportX963Private();
        if (!rv)
            return false;
        result = WTF::move(*rv);
        break;
    }
    case CryptoKeyType::Secret:
        ASSERT_NOT_REACHED();
        return false;
    }
    if (result.size() != publicKeySize && result.size() != privateKeySize) [[unlikely]]
        return false;
    jwk.x = base64URLEncodeToString(result.subspan(1, keySizeInBytes));
    jwk.y = base64URLEncodeToString(result.subspan(keySizeInBytes + 1, keySizeInBytes));
    if (result.size() > publicKeySize)
        jwk.d = base64URLEncodeToString(result.subspan(publicKeySize, keySizeInBytes));
    return true;
#endif
}

// 10.9 backport: hoist out of the !CLANG_WEBKIT_BRANCH guard so the backport
// SPKI parser can call getOID too.
static std::span<const uint8_t> getOID(CryptoKeyEC::NamedCurve curve)
{
    switch (curve) {
    case CryptoKeyEC::NamedCurve::P256:
        return Secp256r1;
    case CryptoKeyEC::NamedCurve::P384:
        return Secp384r1;
    case CryptoKeyEC::NamedCurve::P521:
        return Secp521r1;
    }
}

// Per https://www.ietf.org/rfc/rfc5280.txt
// SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
// AlgorithmIdentifier  ::= SEQUENCE { algorithm OBJECT IDENTIFIER, parameters ANY DEFINED BY algorithm OPTIONAL }
// Per https://www.ietf.org/rfc/rfc5480.txt
// id-ecPublicKey OBJECT IDENTIFIER ::= { iso(1) member-body(2) us(840) ansi-X9-62(10045) keyType(2) 1 }
// secp256r1 OBJECT IDENTIFIER      ::= { iso(1) member-body(2) us(840) ansi-X9-62(10045) curves(3) prime(1) 7 }
// secp384r1 OBJECT IDENTIFIER      ::= { iso(1) identified-organization(3) certicom(132) curve(0) 34 }
// secp521r1 OBJECT IDENTIFIER      ::= { iso(1) identified-organization(3) certicom(132) curve(0) 35 }
RefPtr<CryptoKeyEC> CryptoKeyEC::platformImportSpki(CryptoAlgorithmIdentifier identifier, NamedCurve curve, Vector<uint8_t>&& keyData, bool extractable, CryptoKeyUsageBitmap usages)
{
#if !defined(CLANG_WEBKIT_BRANCH)
    // The following is a loose check on the provided SPKI key, it aims to extract AlgorithmIdentifier, ECParameters, and Key.
    // Once the underlying crypto library is updated to accept SPKI EC Key, we should remove this hack.
    // <rdar://problem/30987628>
    size_t index = 1; // Read SEQUENCE
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 1; // Read length, SEQUENCE
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]); // Read length
    if (keyData.size() < index + sizeof(IdEcPublicKey))
        return nullptr;
    if (!spanHasPrefix(keyData.subspan(index), std::span { IdEcPublicKey }))
        return nullptr;
    index += std::size(IdEcPublicKey); // Read id-ecPublicKey
    auto oid = getOID(curve);
    if (keyData.size() < index + oid.size())
        return nullptr;
    if (!spanHasPrefix(keyData.subspan(index), oid))
        return nullptr;
    index += oid.size() + 1; // Read named curve OID, BIT STRING
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 1; // Read length
    if (doesUncompressedPointMatchNamedCurve(curve, keyData.size() - index))
        return platformImportRaw(identifier, curve, Vector<uint8_t>(keyData.subspan(index, keyData.size() - index)), extractable, usages);

    // CryptoKit can read pure compressed so no need for index++ here.
    auto rv = pal::ECKey::importCompressedPub(keyData.subspan(index, keyData.size() - index), namedCurveToCryptoKitCurve(curve));
    if (!rv.getErrorCode().isSuccess() || !rv.getKey())
        return nullptr;
    return create(identifier, curve, CryptoKeyType::Public, toPlatformKey(rv.getKey().get()), extractable, usages);
#else
    // 10.9 backport: port the same loose ASN.1 SPKI parser as the upstream
    // !CLANG_WEBKIT_BRANCH path, but use pal::ECKey109 for the final import.
    size_t index = 1; // Read SEQUENCE
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 1;
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]);
    if (keyData.size() < index + sizeof(IdEcPublicKey))
        return nullptr;
    if (!spanHasPrefix(keyData.subspan(index), std::span { IdEcPublicKey }))
        return nullptr;
    index += std::size(IdEcPublicKey);
    auto oid = getOID(curve);
    if (keyData.size() < index + oid.size())
        return nullptr;
    if (!spanHasPrefix(keyData.subspan(index), oid))
        return nullptr;
    index += oid.size() + 1; // Read named curve OID, BIT STRING
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 1; // Read length
    if (doesUncompressedPointMatchNamedCurve(curve, keyData.size() - index))
        return platformImportRaw(identifier, curve, Vector<uint8_t>(keyData.subspan(index, keyData.size() - index)), extractable, usages);
    auto key = pal::ECKey109::importCompressedPub(keyData.subspan(index, keyData.size() - index), namedCurveTo109Curve(curve));
    if (!key)
        return nullptr;
    return create(identifier, curve, CryptoKeyType::Public, WTF::move(key), extractable, usages);
#endif
}

Vector<uint8_t> CryptoKeyEC::platformExportSpki() const
{
#if !defined(CLANG_WEBKIT_BRANCH)
    size_t expectedKeySize = 2 * keySizeInBytes() + 1; // Per Section 2.3.4 of http://www.secg.org/sec1-v2.pdf
    Vector<uint8_t> keyBytes(expectedKeySize);
    size_t keySize = keyBytes.size();

    auto rv = platformKey()->exportX963Pub();
    if (rv.errorCode != Cpp::ErrorCodes::Success)
        return { };
    if (rv.result.size() != expectedKeySize)
        return { };
    keyBytes = WTF::move(rv.result);
    keySize = expectedKeySize;

    // The following adds SPKI header to a raw EC public key.
    // Once the underlying crypto library is updated to output SPKI EC Key, we should remove this hack.
    // <rdar://problem/30987628>
    auto oid = getOID(namedCurve());

    // SEQUENCE + length(1) + OID id-ecPublicKey + OID secp256r1/OID secp384r1/OID secp521r1 + BIT STRING + length(?) + InitialOctet + Key size
    size_t totalSize = sizeof(IdEcPublicKey) + oid.size() + bytesNeededForEncodedLength(keySize + 1) + keySize + 4;

    Vector<uint8_t> result;
    result.reserveInitialCapacity(totalSize + bytesNeededForEncodedLength(totalSize) + 1);
    result.append(SequenceMark);
    addEncodedASN1Length(result, totalSize);
    result.append(SequenceMark);
    addEncodedASN1Length(result, sizeof(IdEcPublicKey) + oid.size());
    result.append(std::span { IdEcPublicKey });
    result.append(oid);
    result.append(BitStringMark);
    addEncodedASN1Length(result, keySize + 1);
    result.append(InitialOctet);
    result.appendVector(keyBytes);

    return result;
#else
    // 10.9 backport: build SPKI by hand the same way upstream does, but pull
    // the raw public key from pal::ECKey109. For private keys, derive the
    // public first via toPub() (CCECCryptorRef-backed).
    size_t expectedKeySize = 2 * keySizeInBytes() + 1;
    auto exportPub = platformKey()->isPrivate() ? platformKey()->toPub() : nullptr;
    pal::ECKey109* keyToExport = exportPub ? exportPub.get() : platformKey().get();
    auto rv = keyToExport->exportX963Pub();
    if (!rv)
        return { };
    if (rv->size() != expectedKeySize)
        return { };
    Vector<uint8_t> keyBytes = WTF::move(*rv);
    size_t keySize = expectedKeySize;

    auto oid = getOID(namedCurve());
    size_t totalSize = sizeof(IdEcPublicKey) + oid.size() + bytesNeededForEncodedLength(keySize + 1) + keySize + 4;
    Vector<uint8_t> result;
    result.reserveInitialCapacity(totalSize + bytesNeededForEncodedLength(totalSize) + 1);
    result.append(SequenceMark);
    addEncodedASN1Length(result, totalSize);
    result.append(SequenceMark);
    addEncodedASN1Length(result, sizeof(IdEcPublicKey) + oid.size());
    result.append(std::span { IdEcPublicKey });
    result.append(oid);
    result.append(BitStringMark);
    addEncodedASN1Length(result, keySize + 1);
    result.append(InitialOctet);
    result.appendVector(keyBytes);
    return result;
#endif
}

// Per https://www.ietf.org/rfc/rfc5208.txt
// PrivateKeyInfo ::= SEQUENCE { version INTEGER, privateKeyAlgorithm AlgorithmIdentifier, privateKey OCTET STRING { ECPrivateKey } }
// Per https://www.ietf.org/rfc/rfc5915.txt
// ECPrivateKey ::= SEQUENCE { version INTEGER { ecPrivkeyVer1(1) }, privateKey OCTET STRING, parameters CustomECParameters, publicKey BIT STRING }
// OpenSSL uses custom ECParameters. We follow OpenSSL as a compatibility concern.
RefPtr<CryptoKeyEC> CryptoKeyEC::platformImportPkcs8(CryptoAlgorithmIdentifier identifier, NamedCurve curve, Vector<uint8_t>&& keyData, bool extractable, CryptoKeyUsageBitmap usages)
{
#if !defined(CLANG_WEBKIT_BRANCH)
    // The following is a loose check on the provided PKCS8 key, it aims to extract AlgorithmIdentifier, ECParameters, and Key.
    // Once the underlying crypto library is updated to accept PKCS8 EC Key, we should remove this hack.
    // <rdar://problem/30987628>
    size_t index = 1; // Read SEQUENCE
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 4; // Read length, version, SEQUENCE
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]); // Read length
    if (keyData.size() < index + sizeof(IdEcPublicKey))
        return nullptr;
    if (!spanHasPrefix(keyData.subspan(index), std::span { IdEcPublicKey }))
        return nullptr;
    index += std::size(IdEcPublicKey); // Read id-ecPublicKey
    auto oid = getOID(curve);
    if (keyData.size() < index + oid.size())
        return nullptr;
    if (!spanHasPrefix(keyData.subspan(index), oid))
        return nullptr;
    index += oid.size() + 1; // Read named curve OID, OCTET STRING
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 1; // Read length, SEQUENCE
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 4; // Read length, version, OCTET STRING
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]); // Read length

    size_t privateKeySize = keySizeInBytesFromNamedCurve(curve);
    if (keyData.size() < index + privateKeySize)
        return nullptr;
    size_t privateKeyPos = index;
    index += privateKeySize + 1; // Read privateKey, TaggedType1
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 1; // Read length, BIT STRING
    if (keyData.size() < index + 1)
        return nullptr;
    index += bytesUsedToEncodedLength(keyData[index]) + 1; // Read length, InitialOctet

    // KeyBinary = uncompressed point + private key
    auto keyBinary = keyData.subvector(index);
    if (!doesUncompressedPointMatchNamedCurve(curve, keyBinary.size()))
        return nullptr;
    keyBinary.append(keyData.subspan(privateKeyPos, privateKeySize));

    auto rv = pal::ECKey::importX963Private(keyBinary.span(), namedCurveToCryptoKitCurve(curve));
    if (!rv.getErrorCode().isSuccess() || !rv.getKey())
        return nullptr;
    return create(identifier, curve, CryptoKeyType::Private, toPlatformKey(rv.getKey().get()), extractable, usages);
#else
    UNUSED_PARAM(identifier);
    UNUSED_PARAM(curve);
    UNUSED_PARAM(keyData);
    UNUSED_PARAM(extractable);
    UNUSED_PARAM(usages);
    // 10.9 backport: returning the natural "failed" value here instead of
    // RELEASE_ASSERT_NOT_REACHED so a website using a Web Crypto API we don't
    // back fails the JS operation rather than crashing WebContent. See
    // [[project_ecdh_enabled_may17]] — only generateKey + ECDH deriveBits
    // are wired up via pal::ECKey109.
    return { };
#endif
}

Vector<uint8_t> CryptoKeyEC::platformExportPkcs8() const
{
#if !defined(CLANG_WEBKIT_BRANCH)
    size_t keySizeInBytes = this->keySizeInBytes();
    size_t expectedKeySize = keySizeInBytes * 3 + 1; // 04 + X + Y + D
    Vector<uint8_t> keyBytes(expectedKeySize);

    auto rv = platformKey()->exportX963Private();
    if (rv.errorCode != Cpp::ErrorCodes::Success)
        return { };
    if (rv.result.size() != expectedKeySize)
        return { };
    keyBytes = WTF::move(rv.result);

    // The following addes PKCS8 header to a raw EC private key.
    // Once the underlying crypto library is updated to output PKCS8 EC Key, we should remove this hack.
    // <rdar://problem/30987628>
    auto oid = getOID(namedCurve());

    // InitialOctet + 04 + X + Y
    size_t publicKeySize = keySizeInBytes * 2 + 2;
    // BIT STRING + length(?) + publicKeySize
    size_t taggedTypeSize = bytesNeededForEncodedLength(publicKeySize) + publicKeySize + 1;
    // VERSION + OCTET STRING + length(1) + private key + TaggedType1(1) + length(?) + BIT STRING + length(?) + publicKeySize
    size_t ecPrivateKeySize = sizeof(Version) + keySizeInBytes + bytesNeededForEncodedLength(taggedTypeSize) + bytesNeededForEncodedLength(publicKeySize) + publicKeySize + 4;
    // SEQUENCE + length(?) + ecPrivateKeySize
    size_t privateKeySize = bytesNeededForEncodedLength(ecPrivateKeySize) + ecPrivateKeySize + 1;
    // VERSION + SEQUENCE + length(1) + OID id-ecPublicKey + OID secp256r1/OID secp384r1/OID secp521r1 + OCTET STRING + length(?) + privateKeySize
    size_t totalSize = sizeof(Version) + sizeof(IdEcPublicKey) + oid.size() + bytesNeededForEncodedLength(privateKeySize) + privateKeySize + 3;

    Vector<uint8_t> result;
    result.reserveInitialCapacity(totalSize + bytesNeededForEncodedLength(totalSize) + 1);
    result.append(SequenceMark);
    addEncodedASN1Length(result, totalSize);
    result.append(std::span { Version });
    result.append(SequenceMark);
    addEncodedASN1Length(result, sizeof(IdEcPublicKey) + oid.size());
    result.append(std::span { IdEcPublicKey });
    result.append(oid);
    result.append(OctetStringMark);
    addEncodedASN1Length(result, privateKeySize);
    result.append(SequenceMark);
    addEncodedASN1Length(result, ecPrivateKeySize);
    result.append(std::span { PrivateKeyVersion });
    result.append(OctetStringMark);
    addEncodedASN1Length(result, keySizeInBytes);
    result.append(keyBytes.subspan(publicKeySize - 1, keySizeInBytes));
    result.append(TaggedType1);
    addEncodedASN1Length(result, taggedTypeSize);
    result.append(BitStringMark);
    addEncodedASN1Length(result, publicKeySize);
    result.append(InitialOctet);
    result.append(keyBytes.subspan(0, publicKeySize - 1));

    return result;
#else
    // 10.9 backport: returning the natural "failed" value here instead of
    // RELEASE_ASSERT_NOT_REACHED so a website using a Web Crypto API we don't
    // back fails the JS operation rather than crashing WebContent. See
    // [[project_ecdh_enabled_may17]] — only generateKey + ECDH deriveBits
    // are wired up via pal::ECKey109.
    return { };
#endif
}

} // namespace WebCore
