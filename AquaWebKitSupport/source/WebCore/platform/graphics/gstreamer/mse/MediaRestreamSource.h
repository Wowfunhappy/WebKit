#pragma once

#include "MediaRestreamSegmenter.h"
#include "MediaRestreamFrameQueue.h"
#include <WebCore/IntSize.h>
#include <WebCore/HTMLMediaElement.h>
#include <WebCore/Document.h>
#include <wtf/Expected.h>
#include <wtf/FileSystem.h>
#include <wtf/FileHandle.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/WorkQueue.h>
#include <wtf/HashSet.h>
#include <atomic>
#include <deque>
#include <WebCore/MediaPromiseTypes.h>
#include <WebCore/PlatformTimeRanges.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NativePromise.h>
#include <wtf/RunLoop.h>

namespace WebCore {
class AudioSourceProviderGStreamer;
class EventListener;
class MediaRestreamCapture;
class MediaRestreamSubtitles;
class TextTrack;

class WEBCORE_EXPORT MediaRestreamSource final : public RefCountedAndCanMakeWeakPtr<MediaRestreamSource> {
public:
    static void audioRoutingChanged(AudioSourceProviderGStreamer&);
    static bool externalPlaybackTarget(const HTMLMediaElement&);
    static bool preparingExternalPlayback(const HTMLMediaElement&);
    static void setExternalPlaybackTarget(HTMLMediaElement&, uint64_t owner, bool);
    static void setPreparingExternalPlayback(HTMLMediaElement&, uint64_t owner, bool preparing);
    static MediaRestreamSource* remoteSourceForPlayer(const MediaPlayer&);
    void setRemoteControl(Function<void(const String&, double, CompletionHandler<void(bool)>&&)>&& control) { m_remoteControl = WTF::move(control); }
    void remoteStateChanged(double position, double duration, double rate);
    void remoteCommand(const String&, double = 0);
    Ref<MediaTimePromise> remoteSeek(const MediaTime&);
    MediaTime remoteTime() const;
    MediaTime remoteDuration() const { return MediaTime::createWithDouble(m_remoteDuration); }
    bool remoteReady() const { return m_accepted; }
    bool remotePaused() const { return m_remotePaused; }
    double remoteRate() const { return m_remotePreferredRate; }
    const PlatformTimeRanges& remoteSeekable() const { return m_remoteSeekable; }
    static bool requiresCapture(HTMLMediaElement&);
    static bool canNegotiateRemotePlayback(HTMLMediaElement&);
    static bool handoffPaused(HTMLMediaElement&);
    static unsigned textTrackCount(HTMLMediaElement&);
    static Vector<Ref<TextTrack>> selectedTextTracks(HTMLMediaElement&, const std::optional<Vector<Ref<TextTrack>>>&);
    static bool validateTextTracks(HTMLMediaElement&, const Vector<Ref<TextTrack>>&);
    static bool isPlayingExternally(const HTMLMediaElement&);
    static void elementDestroyed(HTMLMediaElement&);
    static void elementWillLoad(HTMLMediaElement&);
    static void create(HTMLMediaElement&, const std::optional<Vector<Ref<TextTrack>>>&, const IntSize&, const String& videoCodec, std::optional<double> maxHistoryDuration, std::optional<uint64_t> minimumFreeStorage, CompletionHandler<void(Expected<Ref<MediaRestreamSource>, String>&&)>&&);
    static Ref<MediaRestreamSource> createDirect(HTMLMediaElement&, bool matchingTimeline, bool remote = false);
    ~MediaRestreamSource();
    String streamDescription() { return m_frames ? m_frames->description() : String { }; }
    void nextFrame(bool video, MediaRestreamFrameQueue::Reader&& reader) { if (m_frames) m_frames->next(video, WTF::move(reader)); else reader({ }); }
    void textResource(const String&, CompletionHandler<void(String&&)>&&);
    void segment(uint64_t request, uint64_t index, CompletionHandler<void(RefPtr<SharedBuffer>&&)>&&);
    void cancel(uint64_t request);
    void stop(bool returnToInline = false, std::optional<double> position = std::nullopt);
    void accept(const URL&);
    void setDidStop(Function<void()>&& callback) { m_didStop = WTF::move(callback); }

private:
    static constexpr unsigned hlsTargetDuration = 3;
    static constexpr unsigned hlsMinimumDuration = 3 * hlsTargetDuration;
    friend class RestreamLifetimeListener;
    explicit MediaRestreamSource(HTMLMediaElement&, GstElement*);
    bool valid() const;
    bool sameSource() const;
    void startCapture();
    void sendRemoteSeek();
    void detachReceiver();
    void beginSourceChange();
    void resumeAfterSourceChange();
    void detachElement();
    void interruptCapture();
    void finishCapture();
    void append(double, double, double, double, Ref<SharedBuffer>&&, CompletionHandler<void()>&&);
    void initialized(Expected<Ref<MediaRestreamSource>, String>&&);
    String playlist(std::optional<uint64_t> subtitle = std::nullopt) const;
    String masterPlaylist() const;
    struct FileRange { std::shared_ptr<FileSystem::FileHandle> file; uint64_t offset; uint64_t size; };
    void read(FileRange, CompletionHandler<void(RefPtr<SharedBuffer>&&)>&&);
    struct Segment {
        double duration;
        FileRange media;
        bool discontinuity;
        Vector<FileRange> subtitles;
    };
    const Segment* segmentForSequence(uint64_t) const;
    void trimHistory();
    bool updateStoragePressure();
    struct RetiredSegment {
        uint64_t sequence;
        Segment segment;
        MonotonicTime expires;
    };
    struct Storage {
        std::shared_ptr<FileSystem::FileHandle> file;
        uint64_t writtenBytes { 0 };
        double writtenDuration { 0 };
        Ref<WorkQueue> queue { WorkQueue::create("Media restream storage"_s) };
        std::atomic<bool> stopped { false };
    };
    std::shared_ptr<Storage> m_storage;
    RefPtr<EventListener> m_listener;
    RefPtr<MediaRestreamSubtitles> m_subtitles;
    WeakPtr<HTMLMediaElement> m_element;
    WeakPtr<Document, WeakPtrImplWithEventTargetData> m_document;
    RefPtr<MediaPlayer> m_player;
    const MediaPlayerPrivateInterface* m_backend;
    GRefPtr<GstElement> m_pipeline;
    std::shared_ptr<MediaRestreamCapture> m_capture;
    IntSize m_captureSize;
    String m_videoCodec;
    std::shared_ptr<MediaRestreamFrameQueue> m_frames;
    RefPtr<MediaRestreamSource> m_initializing;
    std::optional<CompletionHandler<void(Expected<Ref<MediaRestreamSource>, String>&&)>> m_ready;
    Function<void()> m_didStop;
    std::deque<Segment> m_segments;
    std::deque<RetiredSegment> m_retiredSegments;
    uint64_t m_firstSequence { 0 };
    uint64_t m_discontinuitySequence { 0 };
    double m_playlistDuration { 0 };
    std::optional<double> m_maxHistoryDuration;
    std::optional<uint64_t> m_minimumFreeStorage;
    HashSet<uint64_t> m_cancelledRequests;
    HashSet<uint64_t> m_requests;
    uint64_t m_pendingWrites { 0 };
    uint64_t m_pendingReads { 0 };
    RestreamCounters m_nextCounters;
    double m_peakBandwidth { 0 };
    double m_peakSubtitleBandwidth { 0 };
    double m_totalDuration { 0 };
    uint64_t m_generation { 0 };
    bool m_direct { false };
    bool m_matchingTimeline { false };
    bool m_wasPlaying { false };
    bool m_stopped { false };
    bool m_accepted { false };
    bool m_discontinuity { false };
    bool m_ended { false };
    bool m_restartingLoop { false };
    bool m_rebinding { false };
    bool m_loopSeeked { false };
    bool m_captureDrained { false };
    bool m_storagePressure { false };
    URL m_initialURL;
    uint64_t m_presentationOwner;
    bool m_remote { false };
    bool m_receiverDetached { false };
    bool m_returning { false };
    bool m_applyingRemoteState { false };
    unsigned m_remoteCommandsPending { 0 };
    bool m_remotePaused { true };
    double m_remotePosition { 0 };
    double m_remoteDuration { 0 };
    double m_remoteRate { 0 };
    double m_remotePreferredRate { 1 };
    MonotonicTime m_remoteUpdated;
    PlatformTimeRanges m_remoteSeekable;
    Function<void(const String&, double, CompletionHandler<void(bool)>&&)> m_remoteControl;
    std::optional<MediaTimePromise::Producer> m_remoteSeek;
    RunLoop::Timer m_startupTimer;
};
}
