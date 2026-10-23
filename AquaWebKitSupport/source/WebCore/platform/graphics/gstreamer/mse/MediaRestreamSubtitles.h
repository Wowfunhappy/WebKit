#pragma once
#include <WebCore/TextTrackClient.h>
#include <WebCore/TextTrack.h>
#include <WebCore/TextTrackCue.h>
#include <wtf/RefCounted.h>
#include <wtf/Function.h>
#include <wtf/Vector.h>

namespace WebCore {
class HTMLMediaElement;
class EventListener;
class VTTRegion;
class HTMLTrackElement;
class MediaRestreamSubtitles final : public RefCounted<MediaRestreamSubtitles>, public TextTrackClient {
public:
    static Ref<MediaRestreamSubtitles> create(HTMLMediaElement&, const std::optional<Vector<Ref<TextTrack>>>&, bool includeClosedCaptions, uint64_t budget, Function<void()>&&);
    ~MediaRestreamSubtitles();
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    bool ready() const;
    bool valid() const { return !m_failed; }
    bool setBudget(uint64_t budget) { m_budget = budget; return bytes() <= budget; }
    bool empty() const;
    size_t size() const { return m_tracks.size(); }
    void freeze();
    void refresh();
    void reset();
    void rebind(HTMLMediaElement&);
    void prune(double);
    uint64_t bytes() const;
    String renditions() const;
    String segment(size_t, double start, double end, double rate, double offset) const;
    void loaded();
private:
    explicit MediaRestreamSubtitles(Function<void()>&&);
    void detach();
    void textTrackAddCue(TextTrack&, TextTrackCue&) final;
    void textTrackAddCues(TextTrack&, const TextTrackCueList&) final;
    void textTrackRemoveCue(TextTrack&, TextTrackCue&) final;
    void textTrackRemoveCues(TextTrack&, const TextTrackCueList&) final;
    struct Cue {
        WeakPtr<TextTrackCue, WeakPtrImplWithEventTargetData> original;
        double start;
        double end;
        String settings;
        String content;
        String region;
        RefPtr<VTTRegion> originalRegion;
        String regionName;
        String regionStyleID;
        String cueName;
        String cueStyleID;
        String key;
        bool archived { false };
    };
    struct Track { Ref<TextTrack> source; Vector<Cue> cues; Vector<String> styles; String label; String language; bool showing; bool forced; RefPtr<HTMLTrackElement> element; bool available { true }; };
    Vector<Track> m_tracks;
    Function<void()> m_changed;
    RefPtr<EventListener> m_listener;
    bool m_frozen { false };
    bool m_refreshing { false };
    uint64_t m_nextRegion { 0 };
    uint64_t m_nextCue { 0 };
    bool m_failed { false };
    uint64_t m_budget { UINT64_MAX };
};
}
