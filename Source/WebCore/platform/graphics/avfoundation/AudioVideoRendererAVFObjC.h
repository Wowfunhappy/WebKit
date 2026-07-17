// MAVERICKS_BACKPORT: custom AudioVideoRendererAVFObjC.
//
// The upstream renderer is built on AVSampleBufferRenderSynchronizer + AVSampleBufferAudioRenderer
// (both 10.10+, ABSENT on 10.9). This reimplementation drives video through a VideoToolbox
// VTDecompressionSession (AVSampleBufferDisplayLayer accepts samples but never decodes/displays on
// 10.9) and pushes each decoded frame's IOSurface to a plain CALayer's contents, with a
// manually-managed CMTimebase for play/pause/rate/currentTime. Audio plays through an
// AudioToolbox AudioQueue fed from the appended audio samples. It implements the
// WebCore::AudioVideoRenderer interface so MediaPlayerPrivateMediaSourceAVFObjC works unchanged.
// MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
#pragma once

#if ENABLE(MEDIA_SOURCE)

#include "AudioVideoRenderer.h"
#include "FloatSize.h"
#include "IntSize.h"
#include <dispatch/dispatch.h>
#include <wtf/HashMap.h>
// MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
#include <wtf/Lock.h>
#include <wtf/MediaTime.h>
#include <wtf/OSObjectPtr.h>
#include <wtf/RetainPtr.h>
#include <wtf/ThreadSafeWeakPtr.h>
// MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
#include <wtf/Vector.h>

// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// OBJC_CLASS AVSampleBufferAudioRenderer;
// (end MAVERICKS_BACKPORT restored block)
OBJC_CLASS AVSampleBufferDisplayLayer;
// MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
OBJC_CLASS CALayer;
typedef struct OpaqueCMTimebase* CMTimebaseRef;
typedef struct opaqueCMSampleBuffer* CMSampleBufferRef;
typedef const struct opaqueCMFormatDescription* CMFormatDescriptionRef;
typedef struct __CVBuffer* CVPixelBufferRef;
typedef struct OpaqueVTDecompressionSession* VTDecompressionSessionRef;
typedef struct OpaqueAudioQueue* AudioQueueRef;
typedef struct AudioQueueBuffer* AudioQueueBufferRef;

namespace WebCore {

// MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
class AudioVideoRendererAVFObjC final
    : public AudioVideoRenderer
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    , public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<AudioVideoRendererAVFObjC> {
public:
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     static Ref<AudioVideoRendererAVFObjC> create(const Logger& logger, uint64_t logIdentifier) { return adoptRef(*new AudioVideoRendererAVFObjC(logger, logIdentifier)); }
//
//     ~AudioVideoRendererAVFObjC();
// (end MAVERICKS_BACKPORT restored block)
    WTF_ABSTRACT_THREAD_SAFE_REF_COUNTED_AND_CAN_MAKE_WEAK_PTR_IMPL;

    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    static Ref<AudioVideoRendererAVFObjC> create(Ref<const Logger>&&, uint64_t logIdentifier);
    virtual ~AudioVideoRendererAVFObjC();

    // AudioInterface
    void setVolume(float) final;
    void setMuted(bool) final;
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    void setPreservesPitchAndCorrectionAlgorithm(bool, std::optional<PitchCorrectionAlgorithm>) final;
    void setAudioTimePitchAlgorithm(AVSampleBufferAudioRenderer *, NSString *) const;
#if HAVE(AUDIO_OUTPUT_DEVICE_UNIQUE_ID)
    void setOutputDeviceId(const String&) final;
    void setOutputDeviceIdOnRenderer(AVSampleBufferAudioRenderer *);
#endif
MAVERICKS_BACKPORT */

    // VideoInterface
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    void setIsVisible(bool) final;
    void setPresentationSize(const IntSize&) final;
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    RefPtr<VideoFrame> currentVideoFrame() const final;
    std::optional<VideoPlaybackQualityMetrics> videoPlaybackQualityMetrics() final;
    PlatformLayer* platformVideoLayer() const final;
    void notifyFirstFrameAvailable(Function<void()>&&) final;
    void notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&&) final;
    void notifyWhenRequiresFlushToResume(Function<void()>&&) final;
    void notifyRenderingModeChanged(Function<void()>&&) final;
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     void expectMinimumUpcomingPresentationTime(const MediaTime&) final;
// (end MAVERICKS_BACKPORT restored block)
    void notifySizeChanged(Function<void(const MediaTime&, FloatSize)>&&) final;
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    void flushAndRemoveImage() final;
    FloatSize videoLayerSize() const final;
    void setVideoLayerSize(const FloatSize&) final;
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    void notifyVideoLayerSizeChanged(Function<void(const MediaTime&, FloatSize)>&&) final;

    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    // SynchronizerInterface
    void play(std::optional<MonotonicTime>) final;
    void pause(std::optional<MonotonicTime>) final;
    bool paused() const final;
    void setRate(double) final;
    double effectiveRate() const final;
    void notifyEffectiveRateChanged(Function<void(double)>&&) final;
    Ref<MediaTimePromise> seekTo(const MediaTime&) final;
    bool seeking() const final;

    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
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

    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    // Called from the VTDecompressionSession output callback (static C function) — must be public.
    void onDecodedFrame(CVPixelBufferRef, const MediaTime& pts);

// MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
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
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
//     AudioTrackProperties& NODELETE audioTrackPropertiesFor(TrackIdentifier);
// (end MAVERICKS_BACKPORT restored block)

    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
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

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
    const Ref<const Logger> m_logger;
    const uint64_t m_logIdentifier;
    const UniqueRef<VideoLayerManagerObjC> m_videoLayerManager;
    const RetainPtr<AVSampleBufferRenderSynchronizer> m_synchronizer;
    const Ref<WebAVSampleBufferListener> m_listener;

    Function<void(PlatformMediaError)> m_errorCallback;
MAVERICKS_BACKPORT */
    Function<void()> m_firstFrameAvailableCallback;
    Function<void(const MediaTime&, double)> m_hasAvailableVideoFrameCallback;
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    Function<void()> m_requiresFlushToResumeCallback;
    Function<void()> m_renderingModeChangedCallback;
    Function<void(const MediaTime&, FloatSize)> m_sizeChangedCallback;
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    Function<void(const MediaTime&, FloatSize)> m_videoLayerSizeChangedCallback;
    Function<void(double)> m_effectiveRateChangedCallback;
    Function<void(PlatformMediaError)> m_errorCallback;
    HashMap<TrackIdentifier, Function<void(TrackIdentifier, const MediaTime&)>> m_reenqueueCallbacks;

    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    FloatSize m_naturalSize;
    FloatSize m_videoLayerSize;
    IntSize m_presentationSize;
    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    bool m_hasReportedFirstFrame { false };
    bool m_paused { true };
    bool m_visible { true };
    double m_rate { 1.0 };
    float m_volume { 1.0 };
    bool m_muted { false };

    // MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).
    Ref<const Logger> m_logger;
    uint64_t m_logIdentifier { 0 };
};

} // namespace WebCore
// MAVERICKS_BACKPORT: custom 10.9 AudioVideoRenderer (upstream AVSampleBufferRenderSynchronizer/AudioRenderer are 10.10+).

#endif // ENABLE(MEDIA_SOURCE)
