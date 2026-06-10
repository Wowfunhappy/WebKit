/*
 * 10.9 backport: software ISO BMFF (fragmented-MP4) Media Source parser.
 * See SourceBufferParserISOBMFF.h for the architecture overview.
 */

#include "config.h"
#include "SourceBufferParserISOBMFF.h"

#if ENABLE(MEDIA_SOURCE)

#include "AudioTrackPrivate.h"
#include "CMUtilities.h"
#include "ContentType.h"
#include "Logging.h"
#include "MediaDescription.h"
#include "MediaSampleAVFObjC.h"
#include "MediaSamplesBlock.h"
#include "SharedBuffer.h"
#include "VideoTrackPrivate.h"
#include <wtf/HexNumber.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

// ---- Big-endian box reader ----------------------------------------------------------------------

namespace {

class BoxReader {
public:
    explicit BoxReader(std::span<const uint8_t> data)
        : m_data(data)
    {
    }

    size_t position() const { return m_position; }
    size_t remaining() const { return m_data.size() - m_position; }
    bool atEnd() const { return m_position >= m_data.size(); }

    bool skip(size_t count)
    {
        if (remaining() < count)
            return false;
        m_position += count;
        return true;
    }

    bool readU8(uint8_t& value)
    {
        if (remaining() < 1)
            return false;
        value = m_data[m_position++];
        return true;
    }

    bool readU16(uint16_t& value)
    {
        if (remaining() < 2)
            return false;
        value = static_cast<uint16_t>(m_data[m_position]) << 8 | m_data[m_position + 1];
        m_position += 2;
        return true;
    }

    bool readU32(uint32_t& value)
    {
        if (remaining() < 4)
            return false;
        value = static_cast<uint32_t>(m_data[m_position]) << 24 | static_cast<uint32_t>(m_data[m_position + 1]) << 16 | static_cast<uint32_t>(m_data[m_position + 2]) << 8 | m_data[m_position + 3];
        m_position += 4;
        return true;
    }

    bool readU64(uint64_t& value)
    {
        uint32_t high, low;
        if (!readU32(high) || !readU32(low))
            return false;
        value = static_cast<uint64_t>(high) << 32 | low;
        return true;
    }

    bool readS32(int32_t& value)
    {
        uint32_t unsignedValue;
        if (!readU32(unsignedValue))
            return false;
        value = static_cast<int32_t>(unsignedValue);
        return true;
    }

    // Reads version + flags of a "full box".
    bool readFullBoxHeader(uint8_t& version, uint32_t& flags)
    {
        uint32_t versionAndFlags;
        if (!readU32(versionAndFlags))
            return false;
        version = versionAndFlags >> 24;
        flags = versionAndFlags & 0xffffff;
        return true;
    }

    std::span<const uint8_t> readSpan(size_t count)
    {
        if (remaining() < count)
            return { };
        auto span = m_data.subspan(m_position, count);
        m_position += count;
        return span;
    }

private:
    std::span<const uint8_t> m_data;
    size_t m_position { 0 };
};

// Iterates the child boxes of a container payload. Yields (type, payload) pairs.
class BoxIterator {
public:
    explicit BoxIterator(std::span<const uint8_t> container)
        : m_container(container)
    {
    }

    bool next(uint32_t& type, std::span<const uint8_t>& payload)
    {
        while (m_offset + 8 <= m_container.size()) {
            uint32_t size = static_cast<uint32_t>(m_container[m_offset]) << 24 | static_cast<uint32_t>(m_container[m_offset + 1]) << 16 | static_cast<uint32_t>(m_container[m_offset + 2]) << 8 | m_container[m_offset + 3];
            type = static_cast<uint32_t>(m_container[m_offset + 4]) << 24 | static_cast<uint32_t>(m_container[m_offset + 5]) << 16 | static_cast<uint32_t>(m_container[m_offset + 6]) << 8 | m_container[m_offset + 7];

            uint64_t boxSize = size;
            size_t headerSize = 8;
            if (size == 1) {
                if (m_offset + 16 > m_container.size())
                    return false;
                boxSize = 0;
                for (int i = 0; i < 8; ++i)
                    boxSize = boxSize << 8 | m_container[m_offset + 8 + i];
                headerSize = 16;
            } else if (!size)
                boxSize = m_container.size() - m_offset; // box extends to end of container

            if (boxSize < headerSize || m_offset + boxSize > m_container.size())
                return false; // malformed or truncated; stop iterating

            payload = m_container.subspan(m_offset + headerSize, static_cast<size_t>(boxSize) - headerSize);
            m_offset += static_cast<size_t>(boxSize);
            return true;
        }
        return false;
    }

private:
    std::span<const uint8_t> m_container;
    size_t m_offset { 0 };
};

constexpr uint32_t fourCC(char a, char b, char c, char d)
{
    return static_cast<uint32_t>(a) << 24 | static_cast<uint32_t>(b) << 16 | static_cast<uint32_t>(c) << 8 | static_cast<uint32_t>(d);
}

// ---- Track-private / MediaDescription implementations -------------------------------------------

class MediaDescriptionISOBMFF final : public MediaDescription {
public:
    static Ref<MediaDescriptionISOBMFF> create(String&& codec, TrackInfo::TrackType type)
    {
        return adoptRef(*new MediaDescriptionISOBMFF(WTF::move(codec), type));
    }

    bool isVideo() const final { return m_type == TrackInfo::TrackType::Video; }
    bool isAudio() const final { return m_type == TrackInfo::TrackType::Audio; }
    bool isText() const final { return m_type == TrackInfo::TrackType::Text; }

private:
    MediaDescriptionISOBMFF(String&& codec, TrackInfo::TrackType type)
        : MediaDescription(WTF::move(codec))
        , m_type(type)
    {
    }

    const TrackInfo::TrackType m_type;
};

class VideoTrackPrivateISOBMFF final : public VideoTrackPrivate {
public:
    static Ref<VideoTrackPrivateISOBMFF> create(TrackID trackID, int trackIndex)
    {
        return adoptRef(*new VideoTrackPrivateISOBMFF(trackID, trackIndex));
    }

    TrackID id() const final { return m_trackID; }
    int trackIndex() const final { return m_trackIndex; }
    Kind kind() const final { return Kind::Main; }

private:
    VideoTrackPrivateISOBMFF(TrackID trackID, int trackIndex)
        : m_trackID(trackID)
        , m_trackIndex(trackIndex)
    {
    }

    TrackID m_trackID;
    int m_trackIndex;
};

class AudioTrackPrivateISOBMFF final : public AudioTrackPrivate {
public:
    static Ref<AudioTrackPrivateISOBMFF> create(TrackID trackID, int trackIndex)
    {
        return adoptRef(*new AudioTrackPrivateISOBMFF(trackID, trackIndex));
    }

    TrackID id() const final { return m_trackID; }
    int trackIndex() const final { return m_trackIndex; }
    Kind kind() const final { return Kind::Main; }

private:
    AudioTrackPrivateISOBMFF(TrackID trackID, int trackIndex)
        : m_trackID(trackID)
        , m_trackIndex(trackIndex)
    {
    }

    TrackID m_trackID;
    int m_trackIndex;
};

// ---- MPEG-4 esds (ES_Descriptor) parsing ---------------------------------------------------------

// Reads an MPEG-4 descriptor "size of instance" (up to 4 bytes, 7 bits each).
static size_t readDescriptorLength(BoxReader& reader)
{
    size_t length = 0;
    for (int i = 0; i < 4; ++i) {
        uint8_t byte;
        if (!reader.readU8(byte))
            return 0;
        length = length << 7 | (byte & 0x7f);
        if (!(byte & 0x80))
            break;
    }
    return length;
}

struct ParsedAudioSpecificConfig {
    uint32_t sampleRate { 0 };
    uint32_t channels { 0 };
    uint32_t framesPerPacket { 1024 };
};

// Parses the AudioSpecificConfig found in the esds DecoderSpecificInfo.
static std::optional<ParsedAudioSpecificConfig> parseAudioSpecificConfig(std::span<const uint8_t> ascData)
{
    if (ascData.size() < 2)
        return std::nullopt;

    static constexpr uint32_t frequencyTable[] = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

    uint32_t bits = static_cast<uint32_t>(ascData[0]) << 8 | ascData[1];
    uint8_t audioObjectType = bits >> 11;
    uint8_t frequencyIndex = (bits >> 7) & 0xf;
    uint8_t channelConfiguration;
    uint32_t sampleRate = 0;
    if (frequencyIndex == 15) {
        // 24-bit explicit frequency follows; channelConfiguration after that.
        if (ascData.size() < 5)
            return std::nullopt;
        sampleRate = (static_cast<uint32_t>(ascData[0] & 0x7f) << 17)
            | (static_cast<uint32_t>(ascData[1]) << 9)
            | (static_cast<uint32_t>(ascData[2]) << 1)
            | (ascData[3] >> 7);
        channelConfiguration = (ascData[3] >> 3) & 0xf;
    } else {
        if (frequencyIndex >= std::size(frequencyTable))
            return std::nullopt;
        sampleRate = frequencyTable[frequencyIndex];
        channelConfiguration = (bits >> 3) & 0xf;
    }

    ParsedAudioSpecificConfig config;
    config.sampleRate = sampleRate;
    config.channels = channelConfiguration ? channelConfiguration : 2;
    // AAC-LC uses 1024 samples per frame (960 is allowed by the frameLengthFlag
    // but unused in practice; HE-AAC's SBR doubling is handled by the decoder).
    config.framesPerPacket = 1024;
    UNUSED_PARAM(audioObjectType);
    return config;
}

// Extracts the DecoderSpecificInfo (AudioSpecificConfig) from an esds payload
// (starting at the FullBox version/flags).
static std::span<const uint8_t> extractAudioSpecificConfigFromESDS(std::span<const uint8_t> esdsPayload)
{
    BoxReader reader(esdsPayload);
    uint8_t version;
    uint32_t flags;
    if (!reader.readFullBoxHeader(version, flags))
        return { };

    uint8_t tag;
    if (!reader.readU8(tag) || tag != 0x03) // ES_Descriptor
        return { };
    readDescriptorLength(reader);

    uint16_t esID;
    uint8_t esFlags;
    if (!reader.readU16(esID) || !reader.readU8(esFlags))
        return { };
    if (esFlags & 0x80) { // streamDependenceFlag
        if (!reader.skip(2))
            return { };
    }
    if (esFlags & 0x40) { // URL_Flag
        uint8_t urlLength;
        if (!reader.readU8(urlLength) || !reader.skip(urlLength))
            return { };
    }
    if (esFlags & 0x20) { // OCRstreamFlag
        if (!reader.skip(2))
            return { };
    }

    if (!reader.readU8(tag) || tag != 0x04) // DecoderConfigDescriptor
        return { };
    readDescriptorLength(reader);
    if (!reader.skip(13)) // objectTypeIndication(1) + streamType(1) + bufferSizeDB(3) + maxBitrate(4) + avgBitrate(4)
        return { };

    if (!reader.readU8(tag) || tag != 0x05) // DecoderSpecificInfo
        return { };
    size_t ascLength = readDescriptorLength(reader);
    if (!ascLength || reader.remaining() < ascLength)
        return { };
    return reader.readSpan(ascLength);
}

} // anonymous namespace

// ---- Content-type support ------------------------------------------------------------------------

MediaPlayerEnums::SupportsType SourceBufferParserISOBMFF::isContentTypeSupported(const ContentType& contentType)
{
    auto containerType = contentType.containerType();
    if (!equalLettersIgnoringASCIICase(containerType, "video/mp4"_s)
        && !equalLettersIgnoringASCIICase(containerType, "audio/mp4"_s)
        && !equalLettersIgnoringASCIICase(containerType, "application/mp4"_s))
        return MediaPlayerEnums::SupportsType::IsNotSupported;

    auto codecs = contentType.codecs();
    if (codecs.isEmpty())
        return MediaPlayerEnums::SupportsType::MayBeSupported;

    for (auto& codec : codecs) {
        // H.264: avc1.* / avc3.* — decoded with VideoToolbox (present on 10.9).
        if (codec.startsWith("avc1"_s) || codec.startsWith("avc3"_s))
            continue;
        // AAC: mp4a.40.x (and bare mp4a). HE-AAC profiles decode via the
        // system AAC decoder. Reject non-AAC mp4a object types (e.g. mp3).
        if (codec.startsWith("mp4a.40"_s) || equalLettersIgnoringASCIICase(codec, "mp4a"_s))
            continue;
        // FLAC/Opus/VP9/AV1/HEVC are not decodable on 10.9.
        return MediaPlayerEnums::SupportsType::IsNotSupported;
    }
    return MediaPlayerEnums::SupportsType::IsSupported;
}

RefPtr<SourceBufferParser> SourceBufferParserISOBMFF::create()
{
    return adoptRef(new SourceBufferParserISOBMFF());
}

SourceBufferParserISOBMFF::SourceBufferParserISOBMFF() = default;

// ---- Append / top-level box loop -----------------------------------------------------------------

Expected<void, PlatformMediaError> SourceBufferParserISOBMFF::appendData(Ref<const SharedBuffer>&& buffer, AppendFlags)
{
    if (m_invalidated)
        return { };

    m_pending.append(buffer->span());

    if (!parseTopLevelBoxes())
        return makeUnexpected(PlatformMediaError::ParsingError);
    return { };
}

// Returns false on unrecoverable parse error; true otherwise (including "need more data").
bool SourceBufferParserISOBMFF::parseTopLevelBoxes()
{
    while (true) {
        if (m_pending.size() < 8)
            return true;

        auto pending = m_pending.span();
        uint32_t size32 = static_cast<uint32_t>(pending[0]) << 24 | static_cast<uint32_t>(pending[1]) << 16 | static_cast<uint32_t>(pending[2]) << 8 | pending[3];
        uint32_t type = static_cast<uint32_t>(pending[4]) << 24 | static_cast<uint32_t>(pending[5]) << 16 | static_cast<uint32_t>(pending[6]) << 8 | pending[7];

        uint64_t boxSize = size32;
        size_t headerSize = 8;
        if (size32 == 1) {
            if (m_pending.size() < 16)
                return true;
            boxSize = 0;
            for (int i = 0; i < 8; ++i)
                boxSize = boxSize << 8 | pending[8 + i];
            headerSize = 16;
        } else if (!size32) {
            // "Extends to end of file" is not usable in an unbounded MSE stream.
            RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: top-level box with size 0");
            return false;
        }
        if (boxSize < headerSize) {
            RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: malformed box size %llu", static_cast<unsigned long long>(boxSize));
            return false;
        }

        if (m_pending.size() < boxSize)
            return true; // wait for more data

        auto payload = pending.subspan(headerSize, static_cast<size_t>(boxSize) - headerSize);

        bool consumedBeyondThisBox = false;
        switch (type) {
        case fourCC('m', 'o', 'o', 'v'):
            if (!parseMoov(payload))
                return false;
            break;
        case fourCC('m', 'o', 'o', 'f'): {
            // A moof's trun data offsets generally point into the following
            // mdat. Wait until the next mdat box is complete, then process the
            // fragment and consume through the end of that mdat.
            size_t scanOffset = static_cast<size_t>(boxSize);
            uint64_t mdatEnd = 0;
            bool foundCompleteMdat = false;
            while (scanOffset + 8 <= m_pending.size()) {
                uint32_t scanSize = static_cast<uint32_t>(pending[scanOffset]) << 24 | static_cast<uint32_t>(pending[scanOffset + 1]) << 16 | static_cast<uint32_t>(pending[scanOffset + 2]) << 8 | pending[scanOffset + 3];
                uint32_t scanType = static_cast<uint32_t>(pending[scanOffset + 4]) << 24 | static_cast<uint32_t>(pending[scanOffset + 5]) << 16 | static_cast<uint32_t>(pending[scanOffset + 6]) << 8 | pending[scanOffset + 7];
                uint64_t scanBoxSize = scanSize;
                size_t scanHeader = 8;
                if (scanSize == 1) {
                    if (scanOffset + 16 > m_pending.size())
                        break;
                    scanBoxSize = 0;
                    for (int i = 0; i < 8; ++i)
                        scanBoxSize = scanBoxSize << 8 | pending[scanOffset + 8 + i];
                    scanHeader = 16;
                } else if (!scanSize)
                    break;
                if (scanBoxSize < scanHeader)
                    return false;
                if (scanOffset + scanBoxSize > m_pending.size())
                    break; // mdat (or intervening box) incomplete
                if (scanType == fourCC('m', 'd', 'a', 't')) {
                    mdatEnd = scanOffset + scanBoxSize;
                    foundCompleteMdat = true;
                    break;
                }
                scanOffset += static_cast<size_t>(scanBoxSize);
            }
            if (!foundCompleteMdat)
                return true; // wait for the fragment's data

            if (!parseMoofAndEmitSamples(payload, m_pendingStreamOffset))
                return false;

            m_pendingStreamOffset += mdatEnd;
            m_pending.removeAt(0, static_cast<size_t>(mdatEnd));
            consumedBeyondThisBox = true;
            break;
        }
        case fourCC('f', 't', 'y', 'p'):
        case fourCC('s', 't', 'y', 'p'):
        case fourCC('s', 'i', 'd', 'x'):
        case fourCC('f', 'r', 'e', 'e'):
        case fourCC('s', 'k', 'i', 'p'):
        case fourCC('e', 'm', 's', 'g'):
        case fourCC('p', 'r', 'f', 't'):
        case fourCC('m', 'd', 'a', 't'): // stray mdat with no pending moof
        case fourCC('u', 'u', 'i', 'd'):
        default:
            break;
        }

        if (!consumedBeyondThisBox) {
            m_pendingStreamOffset += boxSize;
            m_pending.removeAt(0, static_cast<size_t>(boxSize));
        }
    }
}

// ---- moov (initialization segment) ---------------------------------------------------------------

bool SourceBufferParserISOBMFF::parseMoov(std::span<const uint8_t> moovPayload)
{
    uint32_t movieTimescale = 1;
    uint64_t movieDurationValue = 0;

    // First pass: mvhd for the movie timescale/duration.
    {
        BoxIterator iterator(moovPayload);
        uint32_t type;
        std::span<const uint8_t> payload;
        while (iterator.next(type, payload)) {
            if (type != fourCC('m', 'v', 'h', 'd'))
                continue;
            BoxReader reader(payload);
            uint8_t version;
            uint32_t flags;
            if (!reader.readFullBoxHeader(version, flags))
                return false;
            if (version == 1) {
                if (!reader.skip(16) || !reader.readU32(movieTimescale) || !reader.readU64(movieDurationValue))
                    return false;
            } else {
                uint32_t duration32 = 0;
                if (!reader.skip(8) || !reader.readU32(movieTimescale) || !reader.readU32(duration32))
                    return false;
                movieDurationValue = duration32 == 0xffffffff ? std::numeric_limits<uint64_t>::max() : duration32;
            }
            break;
        }
    }
    if (!movieTimescale)
        movieTimescale = 1;

    MediaTime movieDuration = (!movieDurationValue || movieDurationValue == std::numeric_limits<uint64_t>::max() || movieDurationValue == 0xffffffff)
        ? MediaTime::indefiniteTime()
        : MediaTime(static_cast<int64_t>(movieDurationValue), movieTimescale);

    m_tracks.clear();

    InitializationSegment segment;
    segment.duration = movieDuration;

    // Second pass: tracks and fragment defaults.
    BoxIterator iterator(moovPayload);
    uint32_t type;
    std::span<const uint8_t> payload;
    while (iterator.next(type, payload)) {
        switch (type) {
        case fourCC('t', 'r', 'a', 'k'):
            parseTrak(payload, movieDuration, segment);
            break;
        case fourCC('m', 'v', 'e', 'x'): {
            BoxIterator mvexIterator(payload);
            uint32_t mvexChildType;
            std::span<const uint8_t> mvexChildPayload;
            while (mvexIterator.next(mvexChildType, mvexChildPayload)) {
                if (mvexChildType != fourCC('t', 'r', 'e', 'x'))
                    continue;
                BoxReader reader(mvexChildPayload);
                uint8_t version;
                uint32_t flags;
                uint32_t trackID;
                TrackExtendsDefaults defaults;
                if (!reader.readFullBoxHeader(version, flags) || !reader.readU32(trackID)
                    || !reader.readU32(defaults.defaultSampleDescriptionIndex)
                    || !reader.readU32(defaults.defaultSampleDuration)
                    || !reader.readU32(defaults.defaultSampleSize)
                    || !reader.readU32(defaults.defaultSampleFlags))
                    continue;
                if (auto* state = trackState(trackID))
                    state->trexDefaults = defaults;
            }
            break;
        }
        default:
            break;
        }
    }

    if (segment.videoTracks.isEmpty() && segment.audioTracks.isEmpty()) {
        RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: moov contained no supported tracks");
        return false;
    }

    m_didSeeInitializationSegment = true;

    // Deliver the initialization segment first (it registers the tracks),
    // then per-track format descriptions (matched against those tracks).
    // Ordering is preserved by the serial client-thread dispatcher.
    m_callOnClientThreadCallback([protectedThis = Ref { *this }, segment = WTF::move(segment)]() mutable {
        if (protectedThis->m_didParseInitializationDataCallback)
            protectedThis->m_didParseInitializationDataCallback(WTF::move(segment));
    });

    for (auto& pair : m_tracks) {
        if (!pair.second.info)
            continue;
        m_callOnClientThreadCallback([protectedThis = Ref { *this }, info = Ref { *pair.second.info }, trackID = pair.first]() mutable {
            if (protectedThis->m_didUpdateFormatDescriptionForTrackIDCallback)
                protectedThis->m_didUpdateFormatDescriptionForTrackIDCallback(WTF::move(info), trackID);
        });
    }

    return true;
}

void SourceBufferParserISOBMFF::parseTrak(std::span<const uint8_t> trakPayload, MediaTime, InitializationSegment& segment)
{
    uint32_t trackID = 0;
    uint32_t trackWidth = 0; // 16.16 fixed point
    uint32_t trackHeight = 0;
    uint32_t mediaTimescale = 0;
    uint32_t handlerType = 0;
    std::span<const uint8_t> stsdPayload;

    BoxIterator trakIterator(trakPayload);
    uint32_t type;
    std::span<const uint8_t> payload;
    while (trakIterator.next(type, payload)) {
        if (type == fourCC('t', 'k', 'h', 'd')) {
            BoxReader reader(payload);
            uint8_t version;
            uint32_t flags;
            if (!reader.readFullBoxHeader(version, flags))
                return;
            // v1: creation(8) modification(8) trackID(4); v0: 4+4+4.
            if (!reader.skip(version == 1 ? 16 : 8) || !reader.readU32(trackID))
                return;
            // reserved(4), duration(4 or 8), reserved(8), layer(2),
            // alternate_group(2), volume(2), reserved(2), matrix(36).
            if (!reader.skip(4 + (version == 1 ? 8 : 4) + 8 + 2 + 2 + 2 + 2 + 36))
                continue;
            reader.readU32(trackWidth);
            reader.readU32(trackHeight);
        } else if (type == fourCC('m', 'd', 'i', 'a')) {
            BoxIterator mdiaIterator(payload);
            uint32_t mdiaChildType;
            std::span<const uint8_t> mdiaChildPayload;
            while (mdiaIterator.next(mdiaChildType, mdiaChildPayload)) {
                if (mdiaChildType == fourCC('m', 'd', 'h', 'd')) {
                    BoxReader reader(mdiaChildPayload);
                    uint8_t version;
                    uint32_t flags;
                    if (!reader.readFullBoxHeader(version, flags))
                        continue;
                    if (!reader.skip(version == 1 ? 16 : 8))
                        continue;
                    reader.readU32(mediaTimescale);
                } else if (mdiaChildType == fourCC('h', 'd', 'l', 'r')) {
                    BoxReader reader(mdiaChildPayload);
                    uint8_t version;
                    uint32_t flags;
                    uint32_t predefined;
                    if (!reader.readFullBoxHeader(version, flags) || !reader.readU32(predefined))
                        continue;
                    reader.readU32(handlerType);
                } else if (mdiaChildType == fourCC('m', 'i', 'n', 'f')) {
                    BoxIterator minfIterator(mdiaChildPayload);
                    uint32_t minfChildType;
                    std::span<const uint8_t> minfChildPayload;
                    while (minfIterator.next(minfChildType, minfChildPayload)) {
                        if (minfChildType != fourCC('s', 't', 'b', 'l'))
                            continue;
                        BoxIterator stblIterator(minfChildPayload);
                        uint32_t stblChildType;
                        std::span<const uint8_t> stblChildPayload;
                        while (stblIterator.next(stblChildType, stblChildPayload)) {
                            if (stblChildType == fourCC('s', 't', 's', 'd'))
                                stsdPayload = stblChildPayload;
                        }
                    }
                }
            }
        }
    }

    if (!trackID || stsdPayload.empty())
        return;
    if (!mediaTimescale)
        mediaTimescale = 1;

    // stsd: FullBox header + entry_count, then sample entries (boxes).
    BoxReader stsdReader(stsdPayload);
    uint8_t stsdVersion;
    uint32_t stsdFlags, entryCount;
    if (!stsdReader.readFullBoxHeader(stsdVersion, stsdFlags) || !stsdReader.readU32(entryCount) || !entryCount)
        return;
    auto entriesSpan = stsdPayload.subspan(stsdReader.position());

    BoxIterator entryIterator(entriesSpan);
    uint32_t entryType;
    std::span<const uint8_t> entryPayload;
    if (!entryIterator.next(entryType, entryPayload))
        return;

    TrackState state;
    state.timescale = mediaTimescale;

    int trackIndex = static_cast<int>(segment.videoTracks.size() + segment.audioTracks.size());

    if (entryType == fourCC('a', 'v', 'c', '1') || entryType == fourCC('a', 'v', 'c', '3')) {
        // VisualSampleEntry: reserved(6) + data_reference_index(2) +
        // pre_defined/reserved(2+2+12) + width(2) + height(2) + horiz/vert
        // resolution(8) + reserved(4) + frame_count(2) + compressorname(32) +
        // depth(2) + pre_defined(2), then child boxes (avcC et al.)
        BoxReader entryReader(entryPayload);
        if (!entryReader.skip(6 + 2 + 2 + 2 + 12))
            return;
        uint16_t width = 0, height = 0;
        entryReader.readU16(width);
        entryReader.readU16(height);
        if (!entryReader.skip(4 + 4 + 4 + 2 + 32 + 2 + 2))
            return;

        std::span<const uint8_t> avcC;
        BoxIterator configIterator(entryPayload.subspan(entryReader.position()));
        uint32_t configType;
        std::span<const uint8_t> configPayload;
        while (configIterator.next(configType, configPayload)) {
            if (configType == fourCC('a', 'v', 'c', 'C')) {
                avcC = configPayload;
                break;
            }
        }
        if (avcC.size() < 4) {
            RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: avc1 sample entry without avcC");
            return;
        }

        // RFC 6381 codec string from the avcC profile/compatibility/level bytes.
        auto codecString = makeString("avc1."_s, hex(avcC[1], 2), hex(avcC[2], 2), hex(avcC[3], 2));

        FloatSize naturalSize { static_cast<float>(width), static_cast<float>(height) };
        FloatSize displaySize = naturalSize;
        if (trackWidth && trackHeight)
            displaySize = { static_cast<float>(trackWidth >> 16), static_cast<float>(trackHeight >> 16) };

        Vector<TrackInfo::AtomData> extensionAtoms;
        extensionAtoms.append({ FourCC(fourCC('a', 'v', 'c', 'C')), SharedBuffer::create(avcC) });

        Ref videoInfo = VideoInfo::create({
            TrackInfoData { FourCC(entryType), codecString, trackID },
            VideoSpecificInfoData {
                .size = naturalSize,
                .displaySize = displaySize,
                .bitDepth = 8,
                .colorSpace = { },
                .extensionAtoms = WTF::move(extensionAtoms),
            }
        });
        state.info = videoInfo.ptr();

        InitializationSegment::VideoTrackInformation info;
        info.track = VideoTrackPrivateISOBMFF::create(trackID, trackIndex);
        info.description = MediaDescriptionISOBMFF::create(String(codecString), TrackInfo::TrackType::Video);
        segment.videoTracks.append(WTF::move(info));
    } else if (entryType == fourCC('m', 'p', '4', 'a')) {
        // AudioSampleEntry: reserved(6) + data_reference_index(2) +
        // reserved(8) + channelcount(2) + samplesize(2) + pre_defined(2) +
        // reserved(2) + samplerate(4, 16.16), then child boxes (esds).
        BoxReader entryReader(entryPayload);
        if (!entryReader.skip(6 + 2 + 8))
            return;
        uint16_t channelCount = 0, sampleSize = 0;
        uint32_t sampleRateFixed = 0;
        entryReader.readU16(channelCount);
        entryReader.readU16(sampleSize);
        if (!entryReader.skip(2 + 2))
            return;
        entryReader.readU32(sampleRateFixed);
        uint32_t sampleRate = sampleRateFixed >> 16;

        std::span<const uint8_t> esds;
        BoxIterator configIterator(entryPayload.subspan(entryReader.position()));
        uint32_t configType;
        std::span<const uint8_t> configPayload;
        while (configIterator.next(configType, configPayload)) {
            if (configType == fourCC('e', 's', 'd', 's')) {
                esds = configPayload;
                break;
            }
        }

        uint32_t framesPerPacket = 1024;
        String codecString = "mp4a.40.2"_s;
        if (!esds.empty()) {
            if (auto asc = parseAudioSpecificConfig(extractAudioSpecificConfigFromESDS(esds))) {
                if (asc->sampleRate)
                    sampleRate = asc->sampleRate;
                if (asc->channels)
                    channelCount = asc->channels;
                framesPerPacket = asc->framesPerPacket;
            }
        }
        if (!sampleRate)
            sampleRate = 44100;
        if (!channelCount)
            channelCount = 2;

        // The cookie is the esds box content beginning at the FullBox
        // version/flags; AudioVideoRendererAVFObjC normalizes it for
        // AudioQueue (and synthesizes an AudioSpecificConfig if needed).
        RefPtr<SharedBuffer> cookieData = esds.empty() ? nullptr : RefPtr<SharedBuffer> { SharedBuffer::create(esds) };

        Ref audioInfo = AudioInfo::create({
            TrackInfoData { FourCC(entryType), codecString, trackID },
            AudioSpecificInfoData {
                .rate = sampleRate,
                .channels = channelCount,
                .framesPerPacket = framesPerPacket,
                .bitDepth = sampleSize ? static_cast<uint8_t>(sampleSize) : static_cast<uint8_t>(16),
                .cookieData = WTF::move(cookieData),
            }
        });
        state.info = audioInfo.ptr();

        InitializationSegment::AudioTrackInformation info;
        info.track = AudioTrackPrivateISOBMFF::create(trackID, trackIndex);
        info.description = MediaDescriptionISOBMFF::create(String(codecString), TrackInfo::TrackType::Audio);
        segment.audioTracks.append(WTF::move(info));
    } else {
        RELEASE_LOG(MediaSource, "SourceBufferParserISOBMFF: ignoring unsupported sample entry type %c%c%c%c (handler %c%c%c%c)",
            char(entryType >> 24), char(entryType >> 16), char(entryType >> 8), char(entryType),
            char(handlerType >> 24), char(handlerType >> 16), char(handlerType >> 8), char(handlerType));
        return;
    }

    m_tracks.append({ trackID, WTF::move(state) });
}

// ---- moof (media segments) -----------------------------------------------------------------------

SourceBufferParserISOBMFF::TrackState* SourceBufferParserISOBMFF::trackState(uint64_t trackID)
{
    for (auto& pair : m_tracks) {
        if (pair.first == trackID)
            return &pair.second;
    }
    return nullptr;
}

bool SourceBufferParserISOBMFF::parseMoofAndEmitSamples(std::span<const uint8_t> moofPayload, uint64_t moofStreamOffset)
{
    if (!m_didSeeInitializationSegment) {
        RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: moof before moov");
        return false;
    }

    BoxIterator moofIterator(moofPayload);
    uint32_t type;
    std::span<const uint8_t> payload;
    while (moofIterator.next(type, payload)) {
        if (type != fourCC('t', 'r', 'a', 'f'))
            continue;

        // --- tfhd / tfdt ---
        uint32_t trackID = 0;
        uint32_t tfhdFlags = 0;
        uint64_t baseDataOffset = moofStreamOffset; // default-base-is-moof and spec default for the first traf
        uint32_t sampleDescriptionIndex = 0;
        uint32_t defaultSampleDuration = 0;
        uint32_t defaultSampleSize = 0;
        uint32_t defaultSampleFlags = 0;
        std::optional<uint64_t> baseMediaDecodeTime;

        // First pass over the traf: tfhd + tfdt (they precede the truns in
        // practice, but don't rely on ordering).
        BoxIterator trafIterator(payload);
        uint32_t trafChildType;
        std::span<const uint8_t> trafChildPayload;
        while (trafIterator.next(trafChildType, trafChildPayload)) {
            if (trafChildType == fourCC('t', 'f', 'h', 'd')) {
                BoxReader reader(trafChildPayload);
                uint8_t version;
                if (!reader.readFullBoxHeader(version, tfhdFlags) || !reader.readU32(trackID))
                    return false;
                if (tfhdFlags & 0x000001) { // base-data-offset-present
                    if (!reader.readU64(baseDataOffset))
                        return false;
                }
                if (tfhdFlags & 0x000002) { // sample-description-index-present
                    if (!reader.readU32(sampleDescriptionIndex))
                        return false;
                }
                if (tfhdFlags & 0x000008) {
                    if (!reader.readU32(defaultSampleDuration))
                        return false;
                }
                if (tfhdFlags & 0x000010) {
                    if (!reader.readU32(defaultSampleSize))
                        return false;
                }
                if (tfhdFlags & 0x000020) {
                    if (!reader.readU32(defaultSampleFlags))
                        return false;
                }
            } else if (trafChildType == fourCC('t', 'f', 'd', 't')) {
                BoxReader reader(trafChildPayload);
                uint8_t version;
                uint32_t flags;
                if (!reader.readFullBoxHeader(version, flags))
                    return false;
                uint64_t decodeTime = 0;
                if (version == 1) {
                    if (!reader.readU64(decodeTime))
                        return false;
                } else {
                    uint32_t decodeTime32;
                    if (!reader.readU32(decodeTime32))
                        return false;
                    decodeTime = decodeTime32;
                }
                baseMediaDecodeTime = decodeTime;
            }
        }

        if (!trackID)
            continue;

        auto* state = trackState(trackID);
        if (!state || !state->info)
            continue; // unsupported/ignored track (e.g. text)

        if (!(tfhdFlags & 0x000008))
            defaultSampleDuration = state->trexDefaults.defaultSampleDuration;
        if (!(tfhdFlags & 0x000010))
            defaultSampleSize = state->trexDefaults.defaultSampleSize;
        if (!(tfhdFlags & 0x000020))
            defaultSampleFlags = state->trexDefaults.defaultSampleFlags;

        uint64_t decodeTime = baseMediaDecodeTime.value_or(state->nextDecodeTime);
        uint32_t timescale = state->timescale;

        // --- second pass: truns, in box order ---
        MediaSamplesBlock::SamplesVector items;
        uint64_t runningDataOffset = baseDataOffset;
        bool firstTrunInTraf = true;

        BoxIterator trunIterator(payload);
        std::span<const uint8_t> trunPayload;
        while (trunIterator.next(trafChildType, trunPayload)) {
            if (trafChildType != fourCC('t', 'r', 'u', 'n'))
                continue;
            BoxReader reader(trunPayload);
            uint8_t version;
            uint32_t trunFlags;
            uint32_t sampleCount;
            if (!reader.readFullBoxHeader(version, trunFlags) || !reader.readU32(sampleCount))
                return false;

            uint64_t runDataOffset = runningDataOffset;
            if (trunFlags & 0x000001) { // data-offset-present
                int32_t dataOffset;
                if (!reader.readS32(dataOffset))
                    return false;
                runDataOffset = baseDataOffset + dataOffset;
            } else if (firstTrunInTraf)
                runDataOffset = baseDataOffset;
            firstTrunInTraf = false;

            uint32_t firstSampleFlags = defaultSampleFlags;
            if (trunFlags & 0x000004) {
                if (!reader.readU32(firstSampleFlags))
                    return false;
            }

            items.reserveCapacity(items.size() + sampleCount);
            uint64_t sampleOffset = runDataOffset;
            for (uint32_t i = 0; i < sampleCount; ++i) {
                uint32_t sampleDuration = defaultSampleDuration;
                uint32_t sampleSize = defaultSampleSize;
                uint32_t sampleFlags = (i == 0 && (trunFlags & 0x000004)) ? firstSampleFlags : defaultSampleFlags;
                int64_t compositionOffset = 0;

                if (trunFlags & 0x000100) {
                    if (!reader.readU32(sampleDuration))
                        return false;
                }
                if (trunFlags & 0x000200) {
                    if (!reader.readU32(sampleSize))
                        return false;
                }
                if (trunFlags & 0x000400) {
                    uint32_t perSampleFlags;
                    if (!reader.readU32(perSampleFlags))
                        return false;
                    if (i || !(trunFlags & 0x000004))
                        sampleFlags = perSampleFlags;
                }
                if (trunFlags & 0x000800) {
                    if (version == 0) {
                        uint32_t unsignedOffset;
                        if (!reader.readU32(unsignedOffset))
                            return false;
                        compositionOffset = unsignedOffset;
                    } else {
                        int32_t signedOffset;
                        if (!reader.readS32(signedOffset))
                            return false;
                        compositionOffset = signedOffset;
                    }
                }

                if (!sampleSize) {
                    RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: sample with no size (no default)");
                    return false;
                }

                // Locate the sample bytes in the pending buffer.
                if (sampleOffset < m_pendingStreamOffset) {
                    RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: sample data offset before current fragment");
                    return false;
                }
                uint64_t relativeOffset = sampleOffset - m_pendingStreamOffset;
                if (relativeOffset + sampleSize > m_pending.size()) {
                    RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: sample data extends past available data");
                    return false;
                }

                MediaSamplesBlock::MediaSampleItem item;
                item.presentationTime = MediaTime(static_cast<int64_t>(decodeTime) + compositionOffset, timescale);
                item.decodeTime = MediaTime(static_cast<int64_t>(decodeTime), timescale);
                item.duration = MediaTime(sampleDuration, timescale);
                item.data = SharedBuffer::create(m_pending.span().subspan(static_cast<size_t>(relativeOffset), sampleSize));
                // ISO/IEC 14496-12 sample flags bit 16: sample_is_non_sync_sample.
                bool isSync = !(sampleFlags & 0x10000);
                item.flags = isSync ? MediaSample::IsSync : MediaSample::None;
                items.append(WTF::move(item));

                decodeTime += sampleDuration;
                sampleOffset += sampleSize;
            }
            runningDataOffset = sampleOffset;
        }

        state->nextDecodeTime = decodeTime;

        if (items.isEmpty())
            continue;

        MediaSamplesBlock block(state->info.get(), WTF::move(items));
        auto expectedBuffer = toCMSampleBuffer(block, nullptr);
        if (!expectedBuffer) {
            RELEASE_LOG_ERROR(MediaSource, "SourceBufferParserISOBMFF: toCMSampleBuffer failed: %s", expectedBuffer.error().data());
            return false;
        }

        m_callOnClientThreadCallback([protectedThis = Ref { *this }, trackID, sampleBuffer = WTF::move(expectedBuffer.value())]() mutable {
            if (!protectedThis->m_didProvideMediaDataCallback)
                return;
            auto mediaSample = MediaSampleAVFObjC::create(sampleBuffer.get(), trackID);
            protectedThis->m_didProvideMediaDataCallback(WTF::move(mediaSample), trackID, emptyString());
        });
    }

    return true;
}

// ---- Misc ----------------------------------------------------------------------------------------

void SourceBufferParserISOBMFF::flushPendingMediaData()
{
}

void SourceBufferParserISOBMFF::resetParserState()
{
    m_pending.clear();
    m_pendingStreamOffset = 0;
}

void SourceBufferParserISOBMFF::invalidate()
{
    m_didParseInitializationDataCallback = nullptr;
    m_didProvideMediaDataCallback = nullptr;
    m_willProvideContentKeyRequestInitializationDataForTrackIDCallback = nullptr;
    m_didProvideContentKeyRequestInitializationDataForTrackIDCallback = nullptr;
    m_didUpdateFormatDescriptionForTrackIDCallback = nullptr;
    m_invalidated = true;
    m_pending.clear();
}

#if !RELEASE_LOG_DISABLED
void SourceBufferParserISOBMFF::setLogger(const Logger& logger, uint64_t logIdentifier)
{
    m_logger = &logger;
    m_logIdentifier = logIdentifier;
}
#endif

} // namespace WebCore

#endif // ENABLE(MEDIA_SOURCE)
