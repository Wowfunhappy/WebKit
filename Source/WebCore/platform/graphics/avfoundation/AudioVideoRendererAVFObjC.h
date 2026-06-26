// MAVERICKS_BACKPORT: custom AudioVideoRendererAVFObjC.
//
// The upstream renderer is built on AVSampleBufferRenderSynchronizer + AVSampleBufferAudioRenderer
// (both 10.10+, ABSENT on 10.9). This reimplementation drives video through a VideoToolbox
// VTDecompressionSession (AVSampleBufferDisplayLayer accepts samples but never decodes/displays on
// 10.9) and pushes each decoded frame's IOSurface to a plain CALayer's contents, with a
// manually-managed CMTimebase for play/pause/rate/currentTime. Audio is not yet wired (stage 1 is
// video-only); audio samples are accepted and dropped so the MediaSource append loop keeps
// progressing. It implements the WebCore::AudioVideoRenderer interface so
// MediaPlayerPrivateMediaSourceAVFObjC works unchanged.
#pragma once

#if ENABLE(MEDIA_SOURCE)

#include "AudioVideoRenderer.h"
#include "FloatSize.h"
#include "IntSize.h"
#include <dispatch/dispatch.h>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/MediaTime.h>
#include <wtf/OSObjectPtr.h>
#include <wtf/RetainPtr.h>
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/Vector.h>

OBJC_CLASS AVSampleBufferDisplayLayer;
OBJC_CLASS CALayer;
typedef struct OpaqueCMTimebase* CMTimebaseRef;
typedef struct opaqueCMSampleBuffer* CMSampleBufferRef;
typedef const struct opaqueCMFormatDescription* CMFormatDescriptionRef;
typedef struct __CVBuffer* CVPixelBufferRef;
typedef struct OpaqueVTDecompressionSession* VTDecompressionSessionRef;
typedef struct OpaqueAudioQueue* AudioQueueRef;
typedef struct AudioQueueBuffer* AudioQueueBufferRef;

namespace WebCore {

class AudioVideoRendererAVFObjC final
    : public AudioVideoRenderer
    , public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<AudioVideoRendererAVFObjC> {
public:
    WTF_ABSTRACT_THREAD_SAFE_REF_COUNTED_AND_CAN_MAKE_WEAK_PTR_IMPL;

    static Ref<AudioVideoRendererAVFObjC> create(Ref<const Logger>&&, uint64_t logIdentifier);
    virtual ~AudioVideoRendererAVFObjC();

    // AudioInterface
    void setVolume(float) final;
    void setMuted(bool) final;

    // VideoInterface
    void setIsVisible(bool) final;
    void setPresentationSize(const IntSize&) final;
    RefPtr<VideoFrame> currentVideoFrame() const final;
    std::optional<VideoPlaybackQualityMetrics> videoPlaybackQualityMetrics() final;
    PlatformLayer* platformVideoLayer() const final;
    void notifyFirstFrameAvailable(Function<void()>&&) final;
    void notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&&) final;
    void notifyWhenRequiresFlushToResume(Function<void()>&&) final;
    void notifyRenderingModeChanged(Function<void()>&&) final;
    void notifySizeChanged(Function<void(const MediaTime&, FloatSize)>&&) final;
    void flushAndRemoveImage() final;
    FloatSize videoLayerSize() const final;
    void setVideoLayerSize(const FloatSize&) final;
    void notifyVideoLayerSizeChanged(Function<void(const MediaTime&, FloatSize)>&&) final;

    // SynchronizerInterface
    void play(std::optional<MonotonicTime>) final;
    void pause(std::optional<MonotonicTime>) final;
    bool paused() const final;
    void setRate(double) final;
    double effectiveRate() const final;
    void notifyEffectiveRateChanged(Function<void(double)>&&) final;
    Ref<MediaTimePromise> seekTo(const MediaTime&) final;
    bool seeking() const final;

    // TracksRendererManager
    std::optional<TrackIdentifier> addTrack(TrackType) final;
    void removeTrack(TrackIdentifier) final;
    void enqueueSample(TrackIdentifier, Ref<MediaSample>&&, std::optional<MediaTime>) final;
    bool isReadyForMoreSamples(TrackIdentifier) final;
    Ref<RequestPromise> requestMediaDataWhenReady(TrackIdentifier) final;
    void notifyTrackNeedsReenqueuing(TrackIdentifier, Function<void(TrackIdentifier, const MediaTime&)>&&) final;
    bool timeIsProgressing() const final;
    MediaTime currentTime() const final;
    void flush() final;
    void flushTrack(TrackIdentifier) final;
    void notifyWhenErrorOccurs(Function<void(PlatformMediaError)>&&) final;

    // Called from the VTDecompressionSession output callback (static C function) — must be public.
    void onDecodedFrame(CVPixelBufferRef, const MediaTime& pts);

private:
    AudioVideoRendererAVFObjC(Ref<const Logger>&&, uint64_t);

    void ensureDisplayLayer();
    void maybeReportSizeAndFirstFrame(CMSampleBufferRef);
    void updateTimebaseRate();

    // 10.9: AVSampleBufferDisplayLayer accepts samples but never decodes/displays on this OS. Decode
    // each H.264 sample with VideoToolbox (VTDecompressionSession) and push the resulting frame's
    // IOSurface to a plain CALayer's contents — the proven 10.9 display path (see
    // project_video_decode_works_assetreader_may23 / MediaPlayerPrivateAVFoundationObjC AVAssetReader pump).
    void decodeAndQueue(CMSampleBufferRef);
    void ensureDecompressionSession(CMSampleBufferRef);
    void teardownDecompressionSession();
    void startDisplayTimer();
    void displayTick();

    // 10.9: AVSampleBufferAudioRenderer is absent. Play the demuxed AAC through an AudioQueue
    // (compressed-AAC output queue; ASBD + magic cookie come straight from the sample's
    // CMAudioFormatDescription). Fail-safe: any failure sets m_audioQueueFailed and audio is silently
    // dropped (video keeps working).
    void enqueueAudioSample(CMSampleBufferRef);
    void ensureAudioQueue(CMSampleBufferRef);
    void teardownAudioQueue();
    void flushAudio(); // drop enqueued audio buffers (used on seek/track flush)

    struct TrackState {
        TrackType type;
    };

    RetainPtr<AVSampleBufferDisplayLayer> m_displayLayer;
    RetainPtr<CALayer> m_videoLayer;            // host layer returned as platformVideoLayer()
    RetainPtr<VTDecompressionSessionRef> m_decompressionSession;
    RetainPtr<CMFormatDescriptionRef> m_decompressionFormat;  // format the session was created for
    // Stable refcon for the VT output callback (points back to us); lives as long as this object.
    ThreadSafeWeakPtr<AudioVideoRendererAVFObjC> m_decompressionRefcon;
    RetainPtr<CMTimebaseRef> m_timebase;
    OSObjectPtr<dispatch_source_t> m_displayTimer;
    Lock m_frameLock;
    Vector<std::pair<MediaTime, RetainPtr<CVPixelBufferRef>>> m_decodedFrames; // PTS-ordered, guarded by m_frameLock
    RetainPtr<CVPixelBufferRef> m_displayedPixelBuffer;
    MediaTime m_displayedPTS { MediaTime::invalidTime() };
    AudioQueueRef m_audioQueue { nullptr };
    bool m_audioQueueFailed { false };
    bool m_audioQueueStarted { false };
    std::optional<MediaTime> m_seekFlushedFor; // seek target we've already flushed+requested reenqueue for
    HashMap<TrackIdentifier, TrackState> m_tracks;
    std::optional<TrackIdentifier> m_videoTrack;
    std::optional<TrackIdentifier> m_audioTrack;

    std::optional<RequestPromise::AutoRejectProducer> m_videoDataRequest;

    Function<void()> m_firstFrameAvailableCallback;
    Function<void(const MediaTime&, double)> m_hasAvailableVideoFrameCallback;
    Function<void()> m_requiresFlushToResumeCallback;
    Function<void()> m_renderingModeChangedCallback;
    Function<void(const MediaTime&, FloatSize)> m_sizeChangedCallback;
    Function<void(const MediaTime&, FloatSize)> m_videoLayerSizeChangedCallback;
    Function<void(double)> m_effectiveRateChangedCallback;
    Function<void(PlatformMediaError)> m_errorCallback;
    HashMap<TrackIdentifier, Function<void(TrackIdentifier, const MediaTime&)>> m_reenqueueCallbacks;

    FloatSize m_naturalSize;
    FloatSize m_videoLayerSize;
    IntSize m_presentationSize;
    bool m_hasReportedFirstFrame { false };
    bool m_paused { true };
    bool m_visible { true };
    double m_rate { 1.0 };
    float m_volume { 1.0 };
    bool m_muted { false };

    Ref<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
};

} // namespace WebCore

#endif // ENABLE(MEDIA_SOURCE)
