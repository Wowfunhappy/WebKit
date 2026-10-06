#include "config.h"
#include "ID3v2FrameParser.h"

#include <algorithm>
#include <cstring>

#ifdef ID3V2_FUZZ_GUARDED_COPY
const uint8_t* id3v2FuzzGuardedCopy(const uint8_t*, size_t);
#endif

namespace WebCore {

namespace {

constexpr size_t maximumTagSize = 16 * 1024 * 1024;
constexpr size_t maximumFrameCount = 256;
constexpr size_t headerSize = 10;

struct ByteView {
    const uint8_t* data { nullptr };
    size_t size { 0 };

    ByteView subview(size_t offset) const { return offset <= size ? ByteView { data + offset, size - offset } : ByteView { }; }
    ByteView subview(size_t offset, size_t length) const
    {
        if (offset > size || length > size - offset)
            return { };
        return { data + offset, length };
    }
};

bool readSynchsafe(ByteView view, size_t offset, uint32_t& value)
{
    if (offset > view.size || view.size - offset < 4)
        return false;
    const uint8_t* bytes = view.data + offset;
    if ((bytes[0] | bytes[1] | bytes[2] | bytes[3]) & 0x80)
        return false;
    value = (static_cast<uint32_t>(bytes[0]) << 21) | (static_cast<uint32_t>(bytes[1]) << 14) | (static_cast<uint32_t>(bytes[2]) << 7) | bytes[3];
    return true;
}

bool readBigEndian32(ByteView view, size_t offset, uint32_t& value)
{
    if (offset > view.size || view.size - offset < 4)
        return false;
    const uint8_t* bytes = view.data + offset;
    value = (static_cast<uint32_t>(bytes[0]) << 24) | (static_cast<uint32_t>(bytes[1]) << 16) | (static_cast<uint32_t>(bytes[2]) << 8) | bytes[3];
    return true;
}

// Reverses unsynchronisation: every 0xFF 0x00 pair loses its 0x00.
std::vector<uint8_t> removeUnsynchronisation(ByteView view)
{
    std::vector<uint8_t> result;
    result.reserve(view.size);
    for (size_t i = 0; i < view.size; ++i) {
        result.push_back(view.data[i]);
        if (view.data[i] == 0xFF && i + 1 < view.size && !view.data[i + 1])
            ++i;
    }
    return result;
}

// A bounded view of owned bytes, placed where a fuzzing harness can guard it.
struct OwnedBytes {
    std::vector<uint8_t> storage;
    ByteView view() const
    {
#ifdef ID3V2_FUZZ_GUARDED_COPY
        return { id3v2FuzzGuardedCopy(storage.data(), storage.size()), storage.size() };
#else
        return { storage.data(), storage.size() };
#endif
    }
};

void appendUTF8(std::string& output, uint32_t codePoint)
{
    if (codePoint > 0x10FFFF || (codePoint >= 0xD800 && codePoint <= 0xDFFF))
        codePoint = 0xFFFD;
    if (codePoint < 0x80)
        output.push_back(static_cast<char>(codePoint));
    else if (codePoint < 0x800) {
        output.push_back(static_cast<char>(0xC0 | (codePoint >> 6)));
        output.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else if (codePoint < 0x10000) {
        output.push_back(static_cast<char>(0xE0 | (codePoint >> 12)));
        output.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        output.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else {
        output.push_back(static_cast<char>(0xF0 | (codePoint >> 18)));
        output.push_back(static_cast<char>(0x80 | ((codePoint >> 12) & 0x3F)));
        output.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        output.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    }
}

bool isValidEncoding(uint8_t encoding)
{
    return encoding <= 3;
}

bool isWideEncoding(uint8_t encoding)
{
    return encoding == 1 || encoding == 2;
}

// The string that starts at offset and ends at the terminator of its encoding (one zero byte, or two zero
// bytes on a code unit boundary), or at the end of the view. next is the offset after the terminator.
ByteView terminatedString(ByteView view, size_t offset, uint8_t encoding, size_t& next)
{
    if (offset >= view.size) {
        next = view.size;
        return { };
    }
    if (isWideEncoding(encoding)) {
        size_t i = offset;
        for (; i + 1 < view.size; i += 2) {
            if (!view.data[i] && !view.data[i + 1]) {
                next = i + 2;
                return view.subview(offset, i - offset);
            }
        }
        next = view.size;
        return view.subview(offset, i - offset);
    }
    for (size_t i = offset; i < view.size; ++i) {
        if (!view.data[i]) {
            next = i + 1;
            return view.subview(offset, i - offset);
        }
    }
    next = view.size;
    return view.subview(offset);
}

std::string decodeString(ByteView bytes, uint8_t encoding)
{
    std::string output;
    switch (encoding) {
    case 0:
        for (size_t i = 0; i < bytes.size; ++i)
            appendUTF8(output, bytes.data[i]);
        break;
    case 3:
        output.assign(reinterpret_cast<const char*>(bytes.data), bytes.size);
        break;
    case 1:
    case 2: {
        bool bigEndian = encoding == 2;
        size_t i = 0;
        if (encoding == 1 && bytes.size >= 2) {
            if (bytes.data[0] == 0xFF && bytes.data[1] == 0xFE) {
                bigEndian = false;
                i = 2;
            } else if (bytes.data[0] == 0xFE && bytes.data[1] == 0xFF) {
                bigEndian = true;
                i = 2;
            }
        }
        auto unitAt = [&](size_t index) -> uint16_t {
            return bigEndian ? static_cast<uint16_t>((bytes.data[index] << 8) | bytes.data[index + 1]) : static_cast<uint16_t>((bytes.data[index + 1] << 8) | bytes.data[index]);
        };
        while (i + 1 < bytes.size) {
            uint16_t unit = unitAt(i);
            i += 2;
            if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < bytes.size) {
                uint16_t low = unitAt(i);
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    i += 2;
                    appendUTF8(output, 0x10000 + ((static_cast<uint32_t>(unit) - 0xD800) << 10) + (low - 0xDC00));
                    continue;
                }
            }
            appendUTF8(output, unit);
        }
        break;
    }
    default:
        break;
    }
    return output;
}

void addAttribute(ID3v2Frame& frame, const char* name, std::string&& value)
{
    if (!value.empty())
        frame.otherAttributes.emplace_back(name, std::move(value));
}

bool parseFrame(ID3v2Frame& frame, ByteView payload)
{
    const std::string& key = frame.key;
    if (key[0] == 'T' && key != "TXXX") {
        if (!payload.size || !isValidEncoding(payload.data[0]))
            return false;
        uint8_t encoding = payload.data[0];
        size_t next;
        frame.valueKind = ID3v2Frame::ValueKind::Text;
        frame.text = decodeString(terminatedString(payload, 1, encoding, next), encoding);
        return true;
    }
    if (key == "TXXX" || key == "WXXX") {
        if (!payload.size || !isValidEncoding(payload.data[0]))
            return false;
        uint8_t encoding = payload.data[0];
        size_t next;
        auto description = decodeString(terminatedString(payload, 1, encoding, next), encoding);
        size_t end;
        frame.valueKind = ID3v2Frame::ValueKind::Text;
        if (key == "TXXX")
            frame.text = decodeString(terminatedString(payload, next, encoding, end), encoding);
        else
            frame.text = decodeString(terminatedString(payload, next, 0, end), 0);
        addAttribute(frame, "info", std::move(description));
        return true;
    }
    if (key[0] == 'W') {
        size_t next;
        frame.valueKind = ID3v2Frame::ValueKind::Text;
        frame.text = decodeString(terminatedString(payload, 0, 0, next), 0);
        return true;
    }
    if (key == "COMM" || key == "USLT") {
        if (payload.size < 4 || !isValidEncoding(payload.data[0]))
            return false;
        uint8_t encoding = payload.data[0];
        size_t next;
        auto description = decodeString(terminatedString(payload, 4, encoding, next), encoding);
        size_t end;
        frame.valueKind = ID3v2Frame::ValueKind::Text;
        frame.text = decodeString(terminatedString(payload, next, encoding, end), encoding);
        addAttribute(frame, "info", std::move(description));
        return true;
    }
    if (key == "GEOB") {
        if (!payload.size || !isValidEncoding(payload.data[0]))
            return false;
        uint8_t encoding = payload.data[0];
        size_t afterType;
        size_t afterName;
        size_t afterDescription;
        auto type = terminatedString(payload, 1, 0, afterType);
        auto name = terminatedString(payload, afterType, encoding, afterName);
        auto description = terminatedString(payload, afterName, encoding, afterDescription);
        auto object = payload.subview(afterDescription);
        frame.type = decodeString(type, 0);
        addAttribute(frame, "info", decodeString(description, encoding));
        addAttribute(frame, "name", decodeString(name, encoding));
        frame.valueKind = ID3v2Frame::ValueKind::Bytes;
        frame.bytes.assign(object.data, object.data + object.size);
        return true;
    }
    if (key == "APIC") {
        if (!payload.size || !isValidEncoding(payload.data[0]))
            return false;
        uint8_t encoding = payload.data[0];
        size_t afterType;
        auto type = terminatedString(payload, 1, 0, afterType);
        if (afterType >= payload.size)
            return false;
        size_t afterDescription;
        auto description = terminatedString(payload, afterType + 1, encoding, afterDescription);
        auto picture = payload.subview(afterDescription);
        frame.type = decodeString(type, 0);
        addAttribute(frame, "info", decodeString(description, encoding));
        frame.valueKind = ID3v2Frame::ValueKind::Bytes;
        frame.bytes.assign(picture.data, picture.data + picture.size);
        return true;
    }
    if (key == "PRIV") {
        size_t next;
        auto owner = terminatedString(payload, 0, 0, next);
        auto data = payload.subview(next);
        addAttribute(frame, "info", decodeString(owner, 0));
        frame.valueKind = ID3v2Frame::ValueKind::Bytes;
        frame.bytes.assign(data.data, data.data + data.size);
        return true;
    }
    frame.valueKind = ID3v2Frame::ValueKind::Bytes;
    frame.bytes.assign(payload.data, payload.data + payload.size);
    return true;
}

} // namespace

std::vector<ID3v2Frame> parseID3v2Frames(const uint8_t* data, size_t size)
{
    std::vector<ID3v2Frame> frames;
    ByteView input { data, size };
    if (!data || size < headerSize || std::memcmp(data, "ID3", 3))
        return frames;

    uint8_t majorVersion = data[3];
    if ((majorVersion != 3 && majorVersion != 4) || data[4] == 0xFF)
        return frames;
    uint8_t flags = data[5];
    uint32_t declaredSize;
    if (!readSynchsafe(input, 6, declaredSize))
        return frames;

    size_t tagSize = std::min<size_t>({ declaredSize, size - headerSize, maximumTagSize });
    ByteView tag = input.subview(headerSize, tagSize);

    OwnedBytes unsynchronisedTag;
    if (majorVersion == 3 && (flags & 0x80)) {
        unsynchronisedTag.storage = removeUnsynchronisation(tag);
        tag = unsynchronisedTag.view();
    }

    size_t offset = 0;
    if (flags & 0x40) {
        uint32_t extendedSize;
        if (majorVersion == 3) {
            if (!readBigEndian32(tag, 0, extendedSize) || extendedSize > tag.size - 4)
                return frames;
            offset = 4 + static_cast<size_t>(extendedSize);
        } else {
            if (!readSynchsafe(tag, 0, extendedSize) || extendedSize < 6 || extendedSize > tag.size)
                return frames;
            offset = extendedSize;
        }
    }

    while (frames.size() < maximumFrameCount && offset <= tag.size && tag.size - offset >= headerSize) {
        ByteView header = tag.subview(offset, headerSize);
        if (!header.data[0])
            break;
        bool validIdentifier = true;
        for (size_t i = 0; i < 4; ++i) {
            uint8_t character = header.data[i];
            if (!((character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9')))
                validIdentifier = false;
        }
        if (!validIdentifier)
            break;

        uint32_t frameSize;
        if (!(majorVersion == 4 ? readSynchsafe(header, 4, frameSize) : readBigEndian32(header, 4, frameSize)))
            break;
        uint16_t frameFlags = static_cast<uint16_t>((header.data[8] << 8) | header.data[9]);
        offset += headerSize;
        if (frameSize > tag.size - offset)
            break;
        ByteView payload = tag.subview(offset, frameSize);
        offset += frameSize;

        bool compressed = majorVersion == 4 ? (frameFlags & 0x0008) : (frameFlags & 0x0080);
        bool encrypted = majorVersion == 4 ? (frameFlags & 0x0004) : (frameFlags & 0x0040);
        bool grouped = majorVersion == 4 ? (frameFlags & 0x0040) : (frameFlags & 0x0020);
        if (compressed || encrypted)
            continue;
        if (grouped) {
            if (!payload.size)
                continue;
            payload = payload.subview(1);
        }

        OwnedBytes unsynchronisedFrame;
        if (majorVersion == 4) {
            if (frameFlags & 0x0001) {
                if (payload.size < 4)
                    continue;
                payload = payload.subview(4);
            }
            if ((flags & 0x80) || (frameFlags & 0x0002)) {
                unsynchronisedFrame.storage = removeUnsynchronisation(payload);
                payload = unsynchronisedFrame.view();
            }
        }

        ID3v2Frame frame;
        frame.key.assign(reinterpret_cast<const char*>(header.data), 4);
        if (parseFrame(frame, payload))
            frames.push_back(std::move(frame));
    }
    return frames;
}

} // namespace WebCore
