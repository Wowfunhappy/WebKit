// The timed metadata of an HLS stream played through the legacy playbin: one text track of kind "metadata" whose in-band
// dispatch type is "com.apple.streaming", fed by the ID3 tags of MPEG-TS stream type 0x15 and by the EXT-X-DATERANGE tags
// hlsdemux reports, with the cue values, cue types and cue timing MediaPlayerPrivateAVFoundationObjC gives the same metadata.

#pragma once

#if ENABLE(VIDEO) && USE(GSTREAMER) && ENABLE(DATACUE_VALUE) && PLATFORM(COCOA)

#include "GRefPtrGStreamer.h"
#include <wtf/Forward.h>
#include <wtf/RefPtr.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

namespace WebCore {

class HLSTimedMetadataTrackGStreamer;
class MediaPlayer;
class MediaPlayerPrivateGStreamer;

class HLSTimedMetadataGStreamer {
    WTF_MAKE_TZONE_ALLOCATED(HLSTimedMetadataGStreamer);
public:
    HLSTimedMetadataGStreamer();
    ~HLSTimedMetadataGStreamer();

    // For each pad uridecodebin exposes, on the thread that exposes it: links an ID3 metadata pad, which playbin leaves
    // unlinked, to a sink that hands the player each tag at its presentation time.
    static void linkID3Pad(GstElement* pipeline, GstPad*, ThreadSafeWeakPtr<MediaPlayerPrivateGStreamer>&&);

    // On the main thread, as MediaPlayerPrivateAVFoundationObjC::metadataDidArrive handles a timed metadata group.
    void handleID3Sample(GstSample*, MediaPlayer&, unsigned inbandTextTrackCount, bool isSeeking);
    // On the main thread, as MediaPlayerPrivateAVFoundationObjC::metadataGroupDidArrive handles date range groups.
    void handleDateRanges(const GstStructure*, MediaPlayer&, unsigned inbandTextTrackCount, bool isSeeking);

private:
    HLSTimedMetadataTrackGStreamer& ensureTrack(MediaPlayer&, unsigned inbandTextTrackCount);

    RefPtr<HLSTimedMetadataTrackGStreamer> m_track;
};

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && ENABLE(DATACUE_VALUE) && PLATFORM(COCOA)
