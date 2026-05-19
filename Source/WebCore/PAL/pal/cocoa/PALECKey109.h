/*
 * macOS 10.9 backport: minimal C++ pal::ECKey109 wrapping CCECCryptor*.
 * The real pal::ECKey is Swift CryptoKit (10.15+). This header provides
 * an equivalent C++ API for the EC key operations WebCrypto needs:
 *   - Generate keypair
 *   - Import X9.63 uncompressed public/private
 *   - Import SEC1 compressed public
 *   - Export X9.63 public/private
 *   - Extract public from private
 *   - ECDH shared secret computation
 *
 * Uses CCECCryptor* primitives which exist on 10.9 in libcommonCrypto.dylib.
 *
 * The class is movable (transfers CCECCryptorRef ownership), not copyable,
 * to match std::unique_ptr semantics used by PlatformECKeyContainer.
 */
#pragma once

#if PLATFORM(MAC)

#include <CommonCrypto/CommonCrypto.h>
#include <pal/spi/cocoa/CommonCryptoSPI.h>
#include <wtf/Vector.h>
#include <memory>
#include <optional>
#include <span>

namespace pal {

class ECCurve {
public:
    static ECCurve p256() { return ECCurve(256); }
    static ECCurve p384() { return ECCurve(384); }
    static ECCurve p521() { return ECCurve(521); }
    size_t keySizeInBits() const { return m_bits; }
    size_t coordinateSizeInBytes() const { return (m_bits + 7) / 8; }
private:
    explicit ECCurve(size_t bits) : m_bits(bits) {}
    size_t m_bits;
};

// Move-only wrapper around a CCECCryptorRef.
class ECKey109 {
public:
    ECKey109(CCECCryptorRef cryptor, ECCurve curve, bool isPrivate)
        : m_cryptor(cryptor), m_curve(curve), m_isPrivate(isPrivate) {}

    ~ECKey109()
    {
        if (m_cryptor)
            CCECCryptorRelease(m_cryptor);
    }

    // Move only.
    ECKey109(ECKey109&& other) noexcept
        : m_cryptor(other.m_cryptor), m_curve(other.m_curve), m_isPrivate(other.m_isPrivate)
    {
        other.m_cryptor = nullptr;
    }
    ECKey109& operator=(ECKey109&& other) noexcept
    {
        if (this != &other) {
            if (m_cryptor) CCECCryptorRelease(m_cryptor);
            m_cryptor = other.m_cryptor;
            m_curve = other.m_curve;
            m_isPrivate = other.m_isPrivate;
            other.m_cryptor = nullptr;
        }
        return *this;
    }
    ECKey109(const ECKey109&) = delete;
    ECKey109& operator=(const ECKey109&) = delete;

    CCECCryptorRef cryptor() const { return m_cryptor; }
    ECCurve curve() const { return m_curve; }
    bool isPrivate() const { return m_isPrivate; }

    // Generate fresh keypair, return the PRIVATE key (caller can derive public via toPub()).
    static std::unique_ptr<ECKey109> generate(ECCurve curve)
    {
        CCECCryptorRef pubKey = nullptr;
        CCECCryptorRef privKey = nullptr;
        if (CCECCryptorGeneratePair(curve.keySizeInBits(), &pubKey, &privKey))
            return nullptr;
        if (pubKey)
            CCECCryptorRelease(pubKey); // we only return the private key; pub is derivable
        return std::make_unique<ECKey109>(privKey, curve, true);
    }

    // Import X9.63 uncompressed public key (0x04 || X || Y).
    static std::unique_ptr<ECKey109> importX963Pub(std::span<const uint8_t> bytes, ECCurve curve)
    {
        CCECCryptorRef k = nullptr;
        if (CCECCryptorImportKey(kCCImportKeyBinary, bytes.data(), bytes.size(), ccECKeyPublic, &k))
            return nullptr;
        return std::make_unique<ECKey109>(k, curve, false);
    }

    // Import X9.63 private key (typically 0x04 || X || Y || D).
    static std::unique_ptr<ECKey109> importX963Private(std::span<const uint8_t> bytes, ECCurve curve)
    {
        CCECCryptorRef k = nullptr;
        if (CCECCryptorImportKey(kCCImportKeyBinary, bytes.data(), bytes.size(), ccECKeyPrivate, &k))
            return nullptr;
        return std::make_unique<ECKey109>(k, curve, true);
    }

    // Import SEC1 compressed public point (0x02/0x03 || X).
    static std::unique_ptr<ECKey109> importCompressedPub(std::span<const uint8_t> bytes, ECCurve curve)
    {
        CCECCryptorRef k = nullptr;
        if (CCECCryptorImportKey(kCCImportKeyCompact, bytes.data(), bytes.size(), ccECKeyPublic, &k))
            return nullptr;
        return std::make_unique<ECKey109>(k, curve, false);
    }

    // Extract public key from a private key (returns a new ECKey109 holding a separate CCECCryptorRef).
    std::unique_ptr<ECKey109> toPub() const
    {
        // Export X9.63 from us, then re-import the first (1 + 2*coordBytes) bytes as public.
        size_t coordLen = m_curve.coordinateSizeInBytes();
        size_t pubLen = 1 + 2 * coordLen;
        Vector<uint8_t> buf(pubLen + coordLen);
        size_t bufLen = buf.size();
        CCECKeyType srcType = m_isPrivate ? ccECKeyPrivate : ccECKeyPublic;
        if (CCECCryptorExportKey(kCCImportKeyBinary, buf.mutableSpan().data(), &bufLen, srcType, m_cryptor))
            return nullptr;
        // First pubLen bytes are the X9.63 public point.
        CCECCryptorRef pubK = nullptr;
        if (CCECCryptorImportKey(kCCImportKeyBinary, buf.span().data(), pubLen, ccECKeyPublic, &pubK))
            return nullptr;
        return std::make_unique<ECKey109>(pubK, m_curve, false);
    }

    // Export X9.63 uncompressed public point (0x04 || X || Y).
    std::optional<Vector<uint8_t>> exportX963Pub() const
    {
        size_t coordLen = m_curve.coordinateSizeInBytes();
        size_t outLen = 1 + 2 * coordLen;
        Vector<uint8_t> buf(outLen + 8);
        size_t bufLen = buf.size();
        if (CCECCryptorExportKey(kCCImportKeyBinary, buf.mutableSpan().data(), &bufLen, ccECKeyPublic, m_cryptor))
            return std::nullopt;
        buf.shrink(bufLen);
        return buf;
    }

    // Export X9.63 private (0x04 || X || Y || D).
    std::optional<Vector<uint8_t>> exportX963Private() const
    {
        if (!m_isPrivate)
            return std::nullopt;
        size_t coordLen = m_curve.coordinateSizeInBytes();
        size_t outLen = 1 + 3 * coordLen;
        Vector<uint8_t> buf(outLen + 8);
        size_t bufLen = buf.size();
        if (CCECCryptorExportKey(kCCImportKeyBinary, buf.mutableSpan().data(), &bufLen, ccECKeyPrivate, m_cryptor))
            return std::nullopt;
        buf.shrink(bufLen);
        return buf;
    }

    // ECDH shared secret computation: this is private, peer is public.
    std::optional<Vector<uint8_t>> sharedSecret(const ECKey109& peerPublic) const
    {
        if (!m_isPrivate || peerPublic.m_isPrivate)
            return std::nullopt;
        size_t coordLen = m_curve.coordinateSizeInBytes();
        Vector<uint8_t> out(coordLen);
        size_t outLen = out.size();
        if (CCECCryptorComputeSharedSecret(m_cryptor, peerPublic.m_cryptor, out.mutableSpan().data(), &outLen))
            return std::nullopt;
        out.shrink(outLen);
        return out;
    }

private:
    CCECCryptorRef m_cryptor;
    ECCurve m_curve;
    bool m_isPrivate;
};

} // namespace pal

#endif // PLATFORM(MAC)
