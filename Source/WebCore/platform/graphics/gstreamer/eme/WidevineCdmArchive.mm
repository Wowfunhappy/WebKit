// MAVERICKS_BACKPORT: see WidevineCdmArchive.h.

#import "config.h"
#import "WidevineCdmArchive.h"

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <wtf/Scope.h>
#import <wtf/cocoa/SpanCocoa.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/text/MakeString.h>
#import <zlib.h>

namespace WebCore {

// The one member of the archive that matters, and the largest one this will unpack.
static constexpr auto moduleArchivePath = "_platform_specific/mac_x64/libwidevinecdm.dylib"_s;
static constexpr size_t maximumModuleSize = 128 * MB;

// ------------------------------------------------------------------------------------------
// The signature. A CRX3 is a protobuf header in front of an ordinary zip, and the header carries
// signatures over that zip. Google publishes the Widevine module under the extension id below,
// which IS the first half of the SHA-256 of the key it signs with -- so a proof by the key that
// opens this id, over these bytes, is the module being what it is published as.

static constexpr std::array<uint8_t, 16> widevineExtensionID { 0xe8, 0xce, 0xcf, 0x42, 0x06, 0xd0, 0x93, 0x49, 0x6d, 0xd9, 0x89, 0xe1, 0x41, 0x04, 0x86, 0x4a };

// The declaration OS X's own SDK keeps to itself; 10.9's Security.framework exports it.
extern "C" OSStatus SecKeyRawVerify(SecKeyRef, SecPadding, const uint8_t*, size_t, const uint8_t*, size_t);

// Protobuf, limited to the two wire types a CRX3 header uses: |handler| sees each
// length-delimited field, and varints are stepped over.
template<typename Handler> static bool forEachProtobufField(std::span<const uint8_t> message, Handler&& handler)
{
    size_t position = 0;
    auto varint = [&](uint64_t& value) {
        value = 0;
        unsigned shift = 0;
        while (position < message.size()) {
            uint8_t byte = message[position++];
            value |= static_cast<uint64_t>(byte & 0x7f) << shift;
            shift += 7;
            if (!(byte & 0x80))
                return shift <= 70;
        }
        return false;
    };

    while (position < message.size()) {
        uint64_t key = 0;
        if (!varint(key))
            return false;
        uint64_t field = key >> 3;
        switch (key & 0x7) {
        case 0: {
            uint64_t ignored = 0;
            if (!varint(ignored))
                return false;
            break;
        }
        case 2: {
            uint64_t length = 0;
            if (!varint(length) || length > message.size() - position)
                return false;
            handler(field, message.subspan(position, length));
            position += length;
            break;
        }
        default:
            return false;
        }
    }
    return true;
}

static bool verifiesWith(std::span<const uint8_t> publicKey, std::span<const uint8_t> signature, std::span<const uint8_t> payload)
{
    RetainPtr keyData = toNSData(publicKey);
    SecExternalFormat format = kSecFormatOpenSSL;
    SecExternalItemType type = kSecItemTypePublicKey;
    SecItemImportExportKeyParameters parameters { };
    parameters.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
    CFArrayRef importedItems = nullptr;
    // A null keychain imports the key without putting it anywhere.
    if (SecItemImport(bridge_cast(keyData.get()), nullptr, &format, &type, 0, &parameters, nullptr, &importedItems) || !importedItems)
        return false;
    RetainPtr items = adoptCF(importedItems);
    if (!CFArrayGetCount(items.get()))
        return false;
    auto* item = CFArrayGetValueAtIndex(items.get(), 0);
    if (CFGetTypeID(item) != SecKeyGetTypeID())
        return false;
    auto key = static_cast<SecKeyRef>(const_cast<void*>(item));

    // OS X's SecKeyRawVerify predates the digest-specific paddings, so what is signed is spelled
    // out here -- the DigestInfo a PKCS#1 v1.5 signature covers -- and kSecPaddingPKCS1 adds only
    // the padding around it.
    static constexpr std::array<uint8_t, 19> sha256DigestInfo { 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
    std::array<uint8_t, sha256DigestInfo.size() + CC_SHA256_DIGEST_LENGTH> signedData { };
    memcpySpan(std::span { signedData }, std::span { sha256DigestInfo });
    CC_SHA256(payload.data(), payload.size(), signedData.data() + sha256DigestInfo.size());
    return !SecKeyRawVerify(key, kSecPaddingPKCS1, signedData.data(), signedData.size(), signature.data(), signature.size());
}

// Whether the archive carries a proof, by the key the extension id names, over the zip behind it.
static bool isSignedByWidevine(std::span<const uint8_t> header, std::span<const uint8_t> zip)
{
    Vector<std::pair<std::span<const uint8_t>, std::span<const uint8_t>>> rsaProofs;
    std::span<const uint8_t> signedHeaderData;
    bool headerIsSound = forEachProtobufField(header, [&](uint64_t field, std::span<const uint8_t> value) {
        if (field == 2) {
            std::span<const uint8_t> publicKey;
            std::span<const uint8_t> signature;
            forEachProtobufField(value, [&](uint64_t proofField, std::span<const uint8_t> proofValue) {
                if (proofField == 1)
                    publicKey = proofValue;
                else if (proofField == 2)
                    signature = proofValue;
            });
            if (!publicKey.empty() && !signature.empty())
                rsaProofs.append({ publicKey, signature });
        } else if (field == 10000)
            signedHeaderData = value;
    });
    if (!headerIsSound || signedHeaderData.empty())
        return false;

    std::span<const uint8_t> extensionID;
    forEachProtobufField(signedHeaderData, [&](uint64_t field, std::span<const uint8_t> value) {
        if (field == 1)
            extensionID = value;
    });
    if (extensionID.size() != widevineExtensionID.size() || memcmp(extensionID.data(), widevineExtensionID.data(), extensionID.size()))
        return false;

    // What the signature covers, as the format defines it: the context string INCLUDING its
    // terminator, then the length of the signed header data, then that data and the archive.
    Vector<uint8_t> payload;
    payload.append(byteCast<uint8_t>(unsafeSpanIncludingNullTerminator("CRX3 SignedData")));
    for (unsigned i = 0; i < 4; ++i)
        payload.append(static_cast<uint8_t>(signedHeaderData.size() >> (8 * i)));
    payload.append(signedHeaderData);
    payload.append(zip);

    for (auto& [publicKey, signature] : rsaProofs) {
        std::array<uint8_t, CC_SHA256_DIGEST_LENGTH> keyDigest { };
        CC_SHA256(publicKey.data(), publicKey.size(), keyDigest.data());
        if (memcmp(keyDigest.data(), widevineExtensionID.data(), widevineExtensionID.size()))
            continue;
        return verifiesWith(publicKey, signature, payload.span());
    }
    return false;
}

// ------------------------------------------------------------------------------------------
// Unpacking. The module arrives as a CRX3: a signed header in front of an ordinary zip.

template<typename T> static std::optional<T> littleEndianAt(std::span<const uint8_t> bytes, size_t offset)
{
    if (offset > bytes.size() || bytes.size() - offset < sizeof(T))
        return std::nullopt;
    T value = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        value |= static_cast<T>(bytes[offset + i]) << (8 * i);
    return value;
}

static std::optional<Vector<uint8_t>> inflate(std::span<const uint8_t> compressed, size_t expandedSize)
{
    Vector<uint8_t> expanded(expandedSize);
    z_stream stream { };
    // A zip member holds a raw deflate stream, without the zlib wrapper inflateInit expects.
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK)
        return std::nullopt;
    auto endStream = makeScopeExit([&] { inflateEnd(&stream); });

    stream.next_in = const_cast<Bytef*>(compressed.data());
    stream.avail_in = compressed.size();
    stream.next_out = expanded.mutableSpan().data();
    stream.avail_out = expanded.size();
    if (::inflate(&stream, Z_FINISH) != Z_STREAM_END || stream.avail_out)
        return std::nullopt;
    return expanded;
}

// The member's bytes, found through the zip's central directory.
static std::optional<Vector<uint8_t>> unpack(std::span<const uint8_t> archive, ASCIILiteral member)
{
    static constexpr uint32_t endOfCentralDirectorySignature = 0x06054b50;
    static constexpr uint32_t centralFileHeaderSignature = 0x02014b50;
    static constexpr uint32_t localFileHeaderSignature = 0x04034b50;

    // The end-of-central-directory record sits at the end of the file, behind a comment of up to
    // 64K, and is the only fixed point a zip has.
    std::optional<size_t> endRecord;
    size_t searchLimit = std::min<size_t>(archive.size(), 64 * KB + 22);
    for (size_t distance = 22; distance <= searchLimit; ++distance) {
        size_t offset = archive.size() - distance;
        if (littleEndianAt<uint32_t>(archive, offset) == endOfCentralDirectorySignature) {
            endRecord = offset;
            break;
        }
    }
    if (!endRecord)
        return std::nullopt;

    auto entryCount = littleEndianAt<uint16_t>(archive, *endRecord + 10);
    auto directoryOffset = littleEndianAt<uint32_t>(archive, *endRecord + 16);
    if (!entryCount || !directoryOffset)
        return std::nullopt;

    size_t offset = *directoryOffset;
    for (uint16_t i = 0; i < *entryCount; ++i) {
        if (littleEndianAt<uint32_t>(archive, offset) != centralFileHeaderSignature)
            return std::nullopt;
        auto compressionMethod = littleEndianAt<uint16_t>(archive, offset + 10);
        auto checksum = littleEndianAt<uint32_t>(archive, offset + 16);
        auto compressedSize = littleEndianAt<uint32_t>(archive, offset + 20);
        auto expandedSize = littleEndianAt<uint32_t>(archive, offset + 24);
        auto nameLength = littleEndianAt<uint16_t>(archive, offset + 28);
        auto extraLength = littleEndianAt<uint16_t>(archive, offset + 30);
        auto commentLength = littleEndianAt<uint16_t>(archive, offset + 32);
        auto localHeaderOffset = littleEndianAt<uint32_t>(archive, offset + 42);
        if (!compressionMethod || !checksum || !compressedSize || !expandedSize || !nameLength || !extraLength || !commentLength || !localHeaderOffset)
            return std::nullopt;
        if (offset + 46 > archive.size() || archive.size() - offset - 46 < *nameLength)
            return std::nullopt;

        auto name = archive.subspan(offset + 46, *nameLength);
        offset += 46 + *nameLength + *extraLength + *commentLength;
        if (name.size() != member.length() || memcmp(name.data(), member.characters(), name.size()))
            continue;

        if (*expandedSize > maximumModuleSize)
            return std::nullopt;
        // The local header repeats the name and carries an extra field of its own, so where the
        // member's bytes start is something only it can say.
        if (littleEndianAt<uint32_t>(archive, *localHeaderOffset) != localFileHeaderSignature)
            return std::nullopt;
        auto localNameLength = littleEndianAt<uint16_t>(archive, *localHeaderOffset + 26);
        auto localExtraLength = littleEndianAt<uint16_t>(archive, *localHeaderOffset + 28);
        if (!localNameLength || !localExtraLength)
            return std::nullopt;
        size_t contentsOffset = *localHeaderOffset + 30 + *localNameLength + *localExtraLength;
        if (contentsOffset > archive.size() || archive.size() - contentsOffset < *compressedSize)
            return std::nullopt;
        auto contents = archive.subspan(contentsOffset, *compressedSize);

        std::optional<Vector<uint8_t>> bytes;
        if (!*compressionMethod && *compressedSize == *expandedSize)
            bytes = Vector<uint8_t> { contents };
        else if (*compressionMethod == Z_DEFLATED)
            bytes = inflate(contents, *expandedSize);
        if (!bytes || crc32(crc32(0, nullptr, 0), bytes->span().data(), bytes->size()) != *checksum)
            return std::nullopt;
        return bytes;
    }
    return std::nullopt;
}

Expected<Vector<uint8_t>, String> extractWidevineCdmModule(std::span<const uint8_t> archive)
{
    // CRX3: "Cr24", a format version, then the length of a signed header the zip follows.
    auto headerSize = littleEndianAt<uint32_t>(archive, 8);
    if (archive.size() < 12 || memcmp(archive.data(), "Cr24", 4) || littleEndianAt<uint32_t>(archive, 4) != 3
        || !headerSize || archive.size() - 12 <= *headerSize)
        return makeUnexpected("the module did not arrive as a CRX3 archive"_s);

    auto header = archive.subspan(12, *headerSize);
    auto zip = archive.subspan(12 + *headerSize);
    if (!isSignedByWidevine(header, zip))
        return makeUnexpected("the archive is not signed by the key its extension id names"_s);

    auto module = unpack(zip, moduleArchivePath);
    if (!module)
        return makeUnexpected(makeString("the archive holds no "_s, moduleArchivePath));
    return WTF::move(*module);
}

} // namespace WebCore

#endif // PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
