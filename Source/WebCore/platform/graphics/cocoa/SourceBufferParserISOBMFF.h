/*
 * 10.9 backport: software ISO BMFF (fragmented-MP4) Media Source parser.
 *
 * AVStreamDataParser does not exist on macOS 10.9 and libwebm is not built,
 * so MSE demuxing is done in software here: the MSE byte stream (ftyp/moov
 * init segments, then [styp] moof+mdat media segments) is parsed by hand,
 * H.264 ('avc1'/'avc3') and AAC ('mp4a') tracks are exposed through the
 * generic SourceBufferParser callbacks, and samples are delivered as
 * MediaSampleAVFObjC objects (one multi-sample CMSampleBuffer per track run,
 * built by toCMSampleBuffer(); AudioVideoRendererAVFObjC splits and decodes
 * them with VideoToolbox / AudioQueue).
 */

#pragma once

#if ENABLE(MEDIA_SOURCE)

#include "FourCC.h"
#include "SourceBufferParser.h"
#include "TrackInfo.h"
#include <wtf/HashMap.h>
#include <wtf/Vector.h>

namespace WebCore {

class ContentType;

class SourceBufferParserISOBMFF final : public SourceBufferParser {
public:
    static MediaPlayerEnums::SupportsType isContentTypeSupported(const ContentType&);
    static RefPtr<SourceBufferParser> create();

    SourceBufferParserISOBMFF();

    Type type() const final { return Type::ISOBMFF; }
    Expected<void, PlatformMediaError> appendData(Ref<const SharedBuffer>&&, AppendFlags = AppendFlags::None) final;
    void flushPendingMediaData() final;
    void resetParserState() final;
    void invalidate() final;
#if !RELEASE_LOG_DISABLED
    void setLogger(const Logger&, uint64_t logIdentifier) final;
#endif

private:
    // Per-track defaults from the moov's mvex/trex box.
    struct TrackExtendsDefaults {
        uint32_t defaultSampleDescriptionIndex { 1 };
        uint32_t defaultSampleDuration { 0 };
        uint32_t defaultSampleSize { 0 };
        uint32_t defaultSampleFlags { 0 };
    };

    struct TrackState {
        RefPtr<TrackInfo> info; // VideoInfo or AudioInfo
        uint32_t timescale { 1 };
        TrackExtendsDefaults trexDefaults;
        // Decode time of the next sample if no tfdt is present.
        uint64_t nextDecodeTime { 0 };
    };

    bool parseTopLevelBoxes();
    bool parseMoov(std::span<const uint8_t> moovPayload);
    void parseTrak(std::span<const uint8_t> trakPayload, MediaTime movieDuration, InitializationSegment&);
    bool parseMoofAndEmitSamples(std::span<const uint8_t> moofPayload, uint64_t moofStreamOffset);

    TrackState* trackState(uint64_t trackID);

    // Bytes appended but not yet consumed; m_pendingStreamOffset is the
    // absolute MSE byte-stream offset of m_pending[0] (trun/tfhd data offsets
    // are absolute within the byte stream).
    Vector<uint8_t> m_pending;
    uint64_t m_pendingStreamOffset { 0 };

    Vector<std::pair<uint64_t, TrackState>> m_tracks;
    bool m_invalidated { false };
    bool m_didSeeInitializationSegment { false };

#if !RELEASE_LOG_DISABLED
    RefPtr<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
#endif
};

} // namespace WebCore

#endif // ENABLE(MEDIA_SOURCE)
