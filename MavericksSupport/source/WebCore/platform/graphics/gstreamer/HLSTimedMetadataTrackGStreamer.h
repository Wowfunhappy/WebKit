#pragma once

#include "InbandTextTrackPrivate.h"
#include "SerializedPlatformDataCue.h"
#include <limits>

namespace WebCore {

// In-band HLS metadata has AVFoundation's dispatch type and open-ended cue updates.
class HLSTimedMetadataTrackGStreamer final : public InbandTextTrackPrivate {
public:
    static Ref<HLSTimedMetadataTrackGStreamer> create(unsigned index)
    {
        return adoptRef(*new HLSTimedMetadataTrackGStreamer(index));
    }

    Kind kind() const final { return Kind::Metadata; }
    int trackIndex() const final { return m_index; }
    TrackID id() const final { return std::numeric_limits<TrackID>::max(); }
    String inBandMetadataTrackDispatchType() const final { return "com.apple.streaming"_s; }

    void addDataCue(const MediaTime& start, const MediaTime& end, Ref<SerializedPlatformDataCue>&& cueData, const String& type)
    {
        ASSERT(isMainThread());
        if (!hasClients())
            return;
        m_currentCueStartTime = start;
        if (end.isPositiveInfinite())
            m_incompleteCues.append({ cueData.copyRef(), start });
        notifyMainThreadClient([&](auto& client) {
            downcast<InbandTextTrackPrivateClient>(client).addDataCue(start, end, WTF::move(cueData), type);
        });
    }

    void updatePendingCueEndTimes(const MediaTime& time)
    {
        ASSERT(isMainThread());
        if (time >= m_currentCueStartTime && hasClients()) {
            for (auto& cue : m_incompleteCues) {
                notifyMainThreadClient([&](auto& client) {
                    downcast<InbandTextTrackPrivateClient>(client).updateDataCue(cue.second, time, cue.first.get());
                });
            }
        }
        m_incompleteCues.clear();
        m_currentCueStartTime = MediaTime::zeroTime();
    }

private:
    explicit HLSTimedMetadataTrackGStreamer(unsigned index)
        : InbandTextTrackPrivate(CueFormat::Data)
        , m_index(index)
    {
    }

    int m_index;
    MediaTime m_currentCueStartTime;
    Vector<std::pair<Ref<SerializedPlatformDataCue>, MediaTime>> m_incompleteCues;
};

} // namespace WebCore
