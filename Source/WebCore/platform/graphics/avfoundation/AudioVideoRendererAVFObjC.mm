// macOS 10.9 backport: custom AudioVideoRendererAVFObjC (see header).
// Video plays through AVSampleBufferDisplayLayer driven by a manually-managed CMTimebase.
// Audio is not yet wired (stage 1); audio samples are accepted and dropped so the append loop runs.
#include "config.h"
#import "AudioVideoRendererAVFObjC.h"

#if ENABLE(MEDIA_SOURCE)

#import "Logging.h"
#import "MediaSampleAVFObjC.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <asl.h>
#import <pal/avfoundation/MediaTimeAVFoundation.h>
#import <unistd.h>
#import <wtf/BlockPtr.h>
#import <wtf/MainThread.h>
#import <wtf/MonotonicTime.h>

#import <pal/cf/CoreMediaSoftLink.h>
#import <pal/cocoa/AVFoundationSoftLink.h>

#define AVR_BISECT(fmt, ...) asl_log(nullptr, nullptr, ASL_LEVEL_NOTICE, "AVR_BISECT [%d] " fmt, (int)getpid(), ##__VA_ARGS__) // 10.9: re-enabled for MSE bring-up

namespace WebCore {

Ref<AudioVideoRendererAVFObjC> AudioVideoRendererAVFObjC::create(Ref<const Logger>&& logger, uint64_t logIdentifier)
{
    return adoptRef(*new AudioVideoRendererAVFObjC(WTF::move(logger), logIdentifier));
}

AudioVideoRendererAVFObjC::AudioVideoRendererAVFObjC(Ref<const Logger>&& logger, uint64_t logIdentifier)
    : m_logger(WTF::move(logger))
    , m_logIdentifier(logIdentifier)
{
    AVR_BISECT("ctor ENTRY");
    CMTimebaseRef timebase = nullptr;
    AVR_BISECT("ctor: CMClockGetHostTimeClock() about to call");
    CMClockRef hostClock = CMClockGetHostTimeClock();
    AVR_BISECT("ctor: hostClock=%p", hostClock);
    AVR_BISECT("ctor: CMTimebaseCreateWithMasterClock about to call");
    OSStatus tbStatus = CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, hostClock, &timebase);
    AVR_BISECT("ctor: CMTimebaseCreateWithMasterClock status=%d timebase=%p", (int)tbStatus, timebase);
    m_timebase = adoptCF(timebase);
    if (m_timebase) {
        AVR_BISECT("ctor: CMTimebaseSetRate(0)");
        CMTimebaseSetRate(m_timebase.get(), 0);
        AVR_BISECT("ctor: CMTimebaseSetTime(kCMTimeZero)");
        CMTimebaseSetTime(m_timebase.get(), kCMTimeZero);
    }
    AVR_BISECT("ctor: ensureDisplayLayer");
    ensureDisplayLayer();
    AVR_BISECT("ctor EXIT");
}

AudioVideoRendererAVFObjC::~AudioVideoRendererAVFObjC()
{
    if (m_displayTimer)
        dispatch_source_cancel(m_displayTimer.get());
    teardownDecompressionSession();
    teardownAudioQueue();
    // m_videoDataRequest is an AutoRejectProducer: it auto-rejects if still pending at destruction.
}

void AudioVideoRendererAVFObjC::ensureDisplayLayer()
{
    if (m_videoLayer)
        return;
    // 10.9: AVSampleBufferDisplayLayer accepts samples but never decodes/displays here. Use a plain
    // CALayer whose .contents we set to each decoded frame's IOSurface (the proven 10.9 path), and a
    // VideoToolbox VTDecompressionSession created lazily from the first sample's format description.
    AVR_BISECT("ensureDisplayLayer: creating plain CALayer for VT-decoded frames");
    m_videoLayer = adoptNS([[CALayer alloc] init]);
    [m_videoLayer setContentsGravity:kCAGravityResizeAspect];
    [m_videoLayer setName:@"WK 10.9 MSE VT-decoded video frames"];
    CGSize seed = m_presentationSize.isEmpty() ? CGSizeMake(640, 480) : CGSizeMake(m_presentationSize.width(), m_presentationSize.height());
    [m_videoLayer setBounds:CGRectMake(0, 0, seed.width, seed.height)];
    [m_videoLayer setPosition:CGPointMake(seed.width / 2, seed.height / 2)];
    startDisplayTimer();
    AVR_BISECT("ensureDisplayLayer EXIT (videoLayer=%p)", m_videoLayer.get());
}

void AudioVideoRendererAVFObjC::startDisplayTimer()
{
    if (m_displayTimer)
        return;
    m_displayTimer = adoptOSObject(dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue()));
    dispatch_source_set_timer(m_displayTimer.get(), DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_SEC / 120);
    ThreadSafeWeakPtr weakThis { *this };
    dispatch_source_set_event_handler(m_displayTimer.get(), makeBlockPtr([weakThis] {
        if (RefPtr protectedThis = weakThis.get())
            protectedThis->displayTick();
    }).get());
    dispatch_resume(m_displayTimer.get());
}

// Main thread (display timer). Pick the decoded frame due at currentTime and push its IOSurface
// to the layer's contents. Drops frames already passed; keeps the one currently due.
void AudioVideoRendererAVFObjC::displayTick()
{
    if (!m_videoLayer)
        return;
    MediaTime target = currentTime();
    if (!target.isValid())
        target = MediaTime::zeroTime();

    RetainPtr<CVPixelBufferRef> frameToShow;
    MediaTime frameToShowPTS = MediaTime::invalidTime();
    size_t queueDepth = 0;
    {
        Locker locker { m_frameLock };
        queueDepth = m_decodedFrames.size();
        // Drop frames we've already passed, keeping the one currently due.
        while (m_decodedFrames.size() >= 2 && m_decodedFrames[1].first <= target)
            m_decodedFrames.removeAt(0);
        if (!m_decodedFrames.isEmpty()) {
            bool nothingShownYet = !m_displayedPTS.isValid();
            // Show the frame due at currentTime; OR, before playback has advanced past the first frame
            // (currentTime can sit at 0 while the first sample's PTS is slightly >0), show the earliest
            // decoded frame so the very first picture appears immediately.
            if ((m_decodedFrames[0].first <= target || nothingShownYet) && m_decodedFrames[0].first != m_displayedPTS) {
                frameToShow = m_decodedFrames[0].second;
                frameToShowPTS = m_decodedFrames[0].first;
            }
        }
    }

    if (frameToShow) {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(frameToShow.get());
        AVR_BISECT("displayTick: SHOW pts=%.3f target=%.3f depth=%zu surface=%p", frameToShowPTS.toFloat(), target.toFloat(), queueDepth, surface);
        if (surface) {
            [m_videoLayer setContents:(__bridge id)surface];
            m_displayedPixelBuffer = frameToShow;
            m_displayedPTS = frameToShowPTS;
        }
    }
}

// AudioInterface
void AudioVideoRendererAVFObjC::setVolume(float volume)
{
    m_volume = volume;
    if (m_audioQueue)
        AudioQueueSetParameter(m_audioQueue, kAudioQueueParam_Volume, m_muted ? 0.0f : m_volume);
}
void AudioVideoRendererAVFObjC::setMuted(bool muted)
{
    m_muted = muted;
    if (m_audioQueue)
        AudioQueueSetParameter(m_audioQueue, kAudioQueueParam_Volume, m_muted ? 0.0f : m_volume);
}

// VideoInterface
void AudioVideoRendererAVFObjC::setIsVisible(bool visible) { m_visible = visible; }
void AudioVideoRendererAVFObjC::setPresentationSize(const IntSize& size) { m_presentationSize = size; }
RefPtr<VideoFrame> AudioVideoRendererAVFObjC::currentVideoFrame() const { return nullptr; }
std::optional<VideoPlaybackQualityMetrics> AudioVideoRendererAVFObjC::videoPlaybackQualityMetrics() { return std::nullopt; }
PlatformLayer* AudioVideoRendererAVFObjC::platformVideoLayer() const { return (PlatformLayer*)m_videoLayer.get(); }

void AudioVideoRendererAVFObjC::notifyFirstFrameAvailable(Function<void()>&& callback) { m_firstFrameAvailableCallback = WTF::move(callback); }
void AudioVideoRendererAVFObjC::notifyWhenHasAvailableVideoFrame(Function<void(const MediaTime&, double)>&& callback) { m_hasAvailableVideoFrameCallback = WTF::move(callback); }
void AudioVideoRendererAVFObjC::notifyWhenRequiresFlushToResume(Function<void()>&& callback) { m_requiresFlushToResumeCallback = WTF::move(callback); }
void AudioVideoRendererAVFObjC::notifyRenderingModeChanged(Function<void()>&& callback) { m_renderingModeChangedCallback = WTF::move(callback); }
void AudioVideoRendererAVFObjC::notifySizeChanged(Function<void(const MediaTime&, FloatSize)>&& callback) { m_sizeChangedCallback = WTF::move(callback); }
void AudioVideoRendererAVFObjC::flushAndRemoveImage()
{
    Locker locker { m_frameLock };
    m_decodedFrames.clear();
    m_displayedPTS = MediaTime::invalidTime();
    if (m_videoLayer)
        [m_videoLayer setContents:nil];
}
FloatSize AudioVideoRendererAVFObjC::videoLayerSize() const { return m_videoLayerSize; }
void AudioVideoRendererAVFObjC::setVideoLayerSize(const FloatSize& size) { m_videoLayerSize = size; }
void AudioVideoRendererAVFObjC::notifyVideoLayerSizeChanged(Function<void(const MediaTime&, FloatSize)>&& callback) { m_videoLayerSizeChangedCallback = WTF::move(callback); }

// SynchronizerInterface
void AudioVideoRendererAVFObjC::updateTimebaseRate()
{
    double effective = m_paused ? 0 : m_rate;
    AVR_BISECT("updateTimebaseRate: paused=%d rate=%g -> effective=%g hasTimebase=%d", m_paused, m_rate, effective, !!m_timebase);
    if (m_timebase)
        CMTimebaseSetRate(m_timebase.get(), effective);
    // Drive the AudioQueue alongside the video timebase.
    if (m_audioQueue) {
        if (m_paused || !m_rate) {
            AudioQueuePause(m_audioQueue);
            m_audioQueueStarted = false;
        } else {
            OSStatus ss = AudioQueueStart(m_audioQueue, nullptr);
            m_audioQueueStarted = (ss == noErr);
        }
    }
    if (m_effectiveRateChangedCallback)
        m_effectiveRateChangedCallback(effective);
}

void AudioVideoRendererAVFObjC::play(std::optional<MonotonicTime>) { AVR_BISECT("play() rate=%g", m_rate); m_paused = false; updateTimebaseRate(); }
void AudioVideoRendererAVFObjC::pause(std::optional<MonotonicTime>) { m_paused = true; updateTimebaseRate(); }
bool AudioVideoRendererAVFObjC::paused() const { return m_paused; }
void AudioVideoRendererAVFObjC::setRate(double rate) { m_rate = rate; if (!m_paused) updateTimebaseRate(); }
double AudioVideoRendererAVFObjC::effectiveRate() const { return m_paused ? 0 : m_rate; }
void AudioVideoRendererAVFObjC::notifyEffectiveRateChanged(Function<void(double)>&& callback) { m_effectiveRateChangedCallback = WTF::move(callback); }

Ref<MediaTimePromise> AudioVideoRendererAVFObjC::seekTo(const MediaTime& time)
{
    bool needFlush = !m_seekFlushedFor || *m_seekFlushedFor != time;
    AVR_BISECT("seekTo: %.3f needFlush=%d", time.toDouble(), needFlush);
    if (m_timebase)
        CMTimebaseSetTime(m_timebase.get(), PAL::toCMTime(time));
    if (needFlush) {
        // First seekTo for this target: drop stale decoded video + queued audio, then ask the player to
        // re-enqueue samples from the seek keyframe. Rejecting with RequiresFlushToResume is what drives
        // MediaPlayerPrivateMediaSourceAVFObjC::reenqueueMediaForTime — WITHOUT it the decoded queue is
        // never refilled after a seek (no post-seek enqueueSample/decode) and the video freezes on the
        // last pre-seek frame. m_displayedPTS is reset by flush() so displayTick paints the first new
        // frame immediately (nothing-shown-yet path). The player then retries seekTo (below).
        m_seekFlushedFor = time;
        flush();
        flushAudio();
        if (m_displayLayer)
            [m_displayLayer flush];
        return MediaTimePromise::createAndReject(PlatformMediaError::RequiresFlushToResume);
    }
    // Retry after the player re-enqueued from the keyframe: complete the seek.
    m_seekFlushedFor = std::nullopt;
    return MediaTimePromise::createAndResolve(time);
}

bool AudioVideoRendererAVFObjC::seeking() const { return false; }

// TracksRendererManager
auto AudioVideoRendererAVFObjC::addTrack(TrackType type) -> std::optional<TrackIdentifier>
{
    auto id = TrackIdentifier::generate();
    m_tracks.add(id, TrackState { type });
    AVR_BISECT("addTrack: type=%d (Video=%d) -> id=%llu", (int)type, (int)TrackType::Video, (unsigned long long)id.toUInt64());
    if (type == TrackType::Video) {
        m_videoTrack = id;
        ensureDisplayLayer();
    } else if (type == TrackType::Audio)
        m_audioTrack = id;
    return id;
}

void AudioVideoRendererAVFObjC::removeTrack(TrackIdentifier id)
{
    m_tracks.remove(id);
    m_reenqueueCallbacks.remove(id);
    if (m_videoTrack == id)
        m_videoTrack = std::nullopt;
    if (m_audioTrack == id)
        m_audioTrack = std::nullopt;
}

void AudioVideoRendererAVFObjC::maybeReportSizeAndFirstFrame(CMSampleBufferRef sampleBuffer)
{
    if (CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer)) {
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(description);
        FloatSize size(dimensions.width, dimensions.height);
        AVR_BISECT("maybeReportSizeAndFirstFrame: dims=%dx%d cur=%gx%g hasCb=%d", dimensions.width, dimensions.height, m_naturalSize.width(), m_naturalSize.height(), !!m_sizeChangedCallback);
        if (!size.isEmpty() && size != m_naturalSize) {
            m_naturalSize = size;
            if (m_sizeChangedCallback)
                m_sizeChangedCallback(currentTime(), size);
        }
    } else
        AVR_BISECT("maybeReportSizeAndFirstFrame: NO format description on sample");
    if (!m_hasReportedFirstFrame) {
        m_hasReportedFirstFrame = true;
        if (m_firstFrameAvailableCallback)
            m_firstFrameAvailableCallback();
        if (m_hasAvailableVideoFrameCallback)
            m_hasAvailableVideoFrameCallback(currentTime(), MonotonicTime::now().secondsSinceEpoch().seconds());
    }
}

void AudioVideoRendererAVFObjC::enqueueSample(TrackIdentifier id, Ref<MediaSample>&& sample, std::optional<MediaTime>)
{
    auto it = m_tracks.find(id);
    if (it == m_tracks.end()) {
        AVR_BISECT("enqueueSample: unknown track id=%llu, dropping", (unsigned long long)id.toUInt64());
        return;
    }
    AVR_BISECT("enqueueSample: id=%llu resolvedType=%d (Video=%d audioTrack=%llu)", (unsigned long long)id.toUInt64(), (int)it->value.type, (int)TrackType::Video, (unsigned long long)(m_audioTrack ? m_audioTrack->toUInt64() : 0));
    if (it->value.type != TrackType::Video) {
        // 10.9: play AAC via AudioQueue (no AVSampleBufferAudioRenderer on this OS).
        CMSampleBufferRef audioSampleBuffer = downcast<MediaSampleAVFObjC>(sample.get()).sampleBuffer();
        AVR_BISECT("enqueueSample: AUDIO branch sb=%p", audioSampleBuffer);
        if (audioSampleBuffer)
            enqueueAudioSample(audioSampleBuffer);
        return;
    }

    CMSampleBufferRef cmSampleBuffer = downcast<MediaSampleAVFObjC>(sample.get()).sampleBuffer();
    if (!cmSampleBuffer) {
        AVR_BISECT("enqueueSample: null cmSampleBuffer!");
        return;
    }
    // 10.9: decode with VideoToolbox and queue the resulting frame for the display timer to show.
    maybeReportSizeAndFirstFrame(cmSampleBuffer);
    decodeAndQueue(cmSampleBuffer);
}

// VTDecompressionSession output callback: runs on a VT-internal queue. Hand the decoded frame back.
static void avrDecompressionOutputCallback(void* decompressionOutputRefCon, void* sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime)
{
    auto* weakPtr = static_cast<ThreadSafeWeakPtr<AudioVideoRendererAVFObjC>*>(decompressionOutputRefCon);
    RefPtr<AudioVideoRendererAVFObjC> renderer = weakPtr ? weakPtr->get() : nullptr;
    if (!renderer || status != noErr || !imageBuffer || CFGetTypeID(imageBuffer) != CVPixelBufferGetTypeID())
        return;
    MediaTime pts = PAL::toMediaTime(presentationTimeStamp);
    renderer->onDecodedFrame((CVPixelBufferRef)imageBuffer, pts);
}

void AudioVideoRendererAVFObjC::onDecodedFrame(CVPixelBufferRef pixelBuffer, const MediaTime& pts)
{
    size_t depth;
    {
        Locker locker { m_frameLock };
        // Insert keeping PTS order (decode order may differ from presentation order due to B-frames).
        size_t pos = 0;
        while (pos < m_decodedFrames.size() && m_decodedFrames[pos].first <= pts)
            ++pos;
        m_decodedFrames.insert(pos, std::pair<MediaTime, RetainPtr<CVPixelBufferRef>> { pts, RetainPtr<CVPixelBufferRef> { pixelBuffer } });
        // Cap memory: keep at most ~32 decoded frames.
        while (m_decodedFrames.size() > 32)
            m_decodedFrames.removeAt(0);
        depth = m_decodedFrames.size();
    }
    AVR_BISECT("onDecodedFrame: pts=%.3f depth=%zu", pts.toFloat(), depth);
}

void AudioVideoRendererAVFObjC::ensureDecompressionSession(CMSampleBufferRef sampleBuffer)
{
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!format)
        return;
    if (m_decompressionSession && m_decompressionFormat && CMFormatDescriptionEqual(m_decompressionFormat.get(), format))
        return;
    teardownDecompressionSession();

    // Output 32BGRA IOSurface-backed pixel buffers (what CALayer.contents composites on 10.9).
    NSDictionary *pixelBufferAttributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{ }
    };
    m_decompressionRefcon = ThreadSafeWeakPtr { *this };
    VTDecompressionOutputCallbackRecord callback { avrDecompressionOutputCallback, &m_decompressionRefcon };
    VTDecompressionSessionRef session = nullptr;
    OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, format, nullptr, (__bridge CFDictionaryRef)pixelBufferAttributes, &callback, &session);
    AVR_BISECT("ensureDecompressionSession: VTDecompressionSessionCreate status=%d session=%p", (int)st, session);
    if (st != noErr || !session) {
        if (session)
            CFRelease(session);
        return;
    }
    m_decompressionSession = adoptCF(session);
    m_decompressionFormat = format;
}

void AudioVideoRendererAVFObjC::teardownDecompressionSession()
{
    if (m_decompressionSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(m_decompressionSession.get());
        VTDecompressionSessionInvalidate(m_decompressionSession.get());
        m_decompressionSession = nullptr;
    }
    m_decompressionFormat = nullptr;
}

// ---- Audio (10.9 AudioQueue AAC playback) -------------------------------------------------------

static void avrAudioQueueOutputCallback(void*, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    // Each enqueued sample gets its own buffer; free it once the queue has consumed it. A firing
    // callback means the device actually played that buffer (proxy for "audio is audible").
    // 10.9: disabled leftover MSE debug logging (asl_log in the audio callback).
    AudioQueueFreeBuffer(queue, buffer);
}

// Build a 2-byte MPEG-4 AudioSpecificConfig for AAC-LC from the sample rate and channel count.
// Bit layout: audioObjectType(5) | samplingFrequencyIndex(4) | channelConfiguration(4) | 000(3).
// AAC-LC (AOT=2), e.g. 44100/stereo → 0x12 0x10. This is the magic cookie AudioQueue wants.
static Vector<uint8_t> avrSynthesizeAudioSpecificConfig(double sampleRate, uint32_t channels)
{
    static const int kFreqTable[] = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };
    int rate = static_cast<int>(sampleRate + 0.5);
    int freqIndex = 4; // default 44100
    for (size_t k = 0; k < sizeof(kFreqTable) / sizeof(kFreqTable[0]); ++k) {
        if (kFreqTable[k] == rate) { freqIndex = static_cast<int>(k); break; }
    }
    int chanConfig = (channels >= 1 && channels <= 7) ? static_cast<int>(channels) : 2;
    const int aot = 2; // AAC-LC
    Vector<uint8_t> asc;
    asc.append(static_cast<uint8_t>((aot << 3) | (freqIndex >> 1)));
    asc.append(static_cast<uint8_t>(((freqIndex & 1) << 7) | (chanConfig << 3)));
    return asc;
}

// (Unused fallback) Walk the MPEG-4 esds descriptor tree to extract the DecoderSpecificInfo (tag 0x05).
// Kept for reference; the synthesized ASC above is used instead (esds-walk proved fragile).
[[maybe_unused]] static Vector<uint8_t> avrExtractAudioSpecificConfig(std::span<const uint8_t> esds)
{
    size_t i = 0;
    size_t n = esds.size();
    // The format description cookie is the esds box content, which begins with the FullBox version+flags.
    if (n >= 5 && esds[0] != 0x03 && esds[4] == 0x03)
        i = 4;
    auto readLen = [&](size_t& p) -> size_t {
        size_t len = 0;
        for (int k = 0; k < 4 && p < n; ++k) {
            uint8_t b = esds[p++];
            len = (len << 7) | (b & 0x7f);
            if (!(b & 0x80))
                break;
        }
        return len;
    };
    // ES_Descriptor (0x03)
    if (i >= n || esds[i] != 0x03)
        return { };
    ++i; readLen(i);
    if (i + 3 > n)
        return { };
    uint8_t esFlags = esds[i + 2];
    i += 3;
    if (esFlags & 0x80) i += 2;            // streamDependenceFlag → dependsOn_ES_ID
    if (esFlags & 0x40) { if (i >= n) return { }; i += 1 + esds[i]; } // URL_Flag → length-prefixed URL
    if (esFlags & 0x20) i += 2;            // OCRstreamFlag
    // DecoderConfigDescriptor (0x04)
    if (i >= n || esds[i] != 0x04)
        return { };
    ++i; readLen(i);
    i += 13;                               // objectTypeIndication+streamType+bufferSizeDB(3)+max(4)+avg(4)
    // DecoderSpecificInfo (0x05) = AudioSpecificConfig
    if (i >= n || esds[i] != 0x05)
        return { };
    ++i;
    size_t ascLen = readLen(i);
    if (!ascLen || i + ascLen > n)
        return { };
    Vector<uint8_t> asc;
    asc.append(esds.subspan(i, ascLen));
    return asc;
}

void AudioVideoRendererAVFObjC::ensureAudioQueue(CMSampleBufferRef sampleBuffer)
{
    if (m_audioQueue || m_audioQueueFailed) {
        AVR_BISECT("ensureAudioQueue: early-out queue=%p failed=%d", m_audioQueue, m_audioQueueFailed);
        return;
    }
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!fmt) { AVR_BISECT("ensureAudioQueue: NO format description on audio sample"); m_audioQueueFailed = true; return; }
    CMMediaType mt = CMFormatDescriptionGetMediaType(fmt);
    const AudioStreamBasicDescription* srcAsbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
    AVR_BISECT("ensureAudioQueue: fmt mediaType=%c%c%c%c asbd=%p", (char)(mt>>24),(char)(mt>>16),(char)(mt>>8),(char)mt, srcAsbd);
    if (!srcAsbd) { AVR_BISECT("ensureAudioQueue: NO asbd (not an audio format description?)"); m_audioQueueFailed = true; return; }

    // The demuxer's format description carries mFormatID='mp4a' (the ISO-BMFF box type) — CoreMedia
    // tolerates it, but AudioQueue rejects it with 'fmt?' (kAudioFormatUnsupportedDataFormatError).
    // Normalize to the real CoreAudio AAC id here, and ensure AAC's 1024 frames/packet.
    AudioStreamBasicDescription asbdStorage = *srcAsbd;
    if (asbdStorage.mFormatID != kAudioFormatMPEG4AAC) {
        asbdStorage.mFormatID = kAudioFormatMPEG4AAC;
        asbdStorage.mFormatFlags = kMPEG4Object_AAC_LC;
        if (!asbdStorage.mFramesPerPacket)
            asbdStorage.mFramesPerPacket = 1024;
        asbdStorage.mBytesPerPacket = 0;
        asbdStorage.mBytesPerFrame = 0;
        asbdStorage.mBitsPerChannel = 0;
    }
    const AudioStreamBasicDescription* asbd = &asbdStorage;

    AudioQueueRef queue = nullptr;
    OSStatus st = AudioQueueNewOutput(asbd, avrAudioQueueOutputCallback, this, nullptr, nullptr, 0, &queue);
    AVR_BISECT("ensureAudioQueue: AudioQueueNewOutput status=%d fmtID=%c%c%c%c rate=%g ch=%u fpp=%u", (int)st,
        (char)(asbd->mFormatID >> 24), (char)(asbd->mFormatID >> 16), (char)(asbd->mFormatID >> 8), (char)asbd->mFormatID,
        asbd->mSampleRate, (unsigned)asbd->mChannelsPerFrame, (unsigned)asbd->mFramesPerPacket);
    if (st != noErr || !queue) { m_audioQueueFailed = true; return; }

    // AudioQueue's MagicCookie for AAC is the AudioSpecificConfig — 2 bytes for AAC-LC, NOT the whole
    // esds box (passing the box fails with '!dat'). Synthesize the ASC from the ASBD's rate/channels;
    // this is deterministic and correct for the AAC-LC that web/YouTube uses (esds parsing was fragile).
    auto asc = avrSynthesizeAudioSpecificConfig(asbd->mSampleRate, asbd->mChannelsPerFrame);
    if (!asc.isEmpty()) {
        OSStatus cs = AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie, asc.span().data(), static_cast<UInt32>(asc.size()));
        AVR_BISECT("ensureAudioQueue: set magic cookie (synth ASC %zuB = 0x%02x%02x) status=%d", asc.size(), asc.size() > 0 ? asc[0] : 0, asc.size() > 1 ? asc[1] : 0, (int)cs);
    }
    AudioQueueSetParameter(queue, kAudioQueueParam_Volume, m_muted ? 0.0f : m_volume);

    m_audioQueue = queue;
    if (!m_paused) {
        OSStatus ss = AudioQueueStart(m_audioQueue, nullptr);
        m_audioQueueStarted = (ss == noErr);
        AVR_BISECT("ensureAudioQueue: AudioQueueStart status=%d", (int)ss);
    }
}

void AudioVideoRendererAVFObjC::enqueueAudioSample(CMSampleBufferRef sampleBuffer)
{
    AVR_BISECT("enqueueAudioSample: ENTER sb=%p", sampleBuffer);
    ensureAudioQueue(sampleBuffer);
    if (!m_audioQueue) {
        AVR_BISECT("enqueueAudioSample: no audio queue after ensure (failed=%d)", m_audioQueueFailed);
        return;
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!bb)
        return;
    size_t totalLen = CMBlockBufferGetDataLength(bb);
    if (!totalLen)
        return;
    CMItemCount numPackets = CMSampleBufferGetNumSamples(sampleBuffer);
    if (numPackets < 1)
        numPackets = 1;

    AudioQueueBufferRef aqBuf = nullptr;
    OSStatus st = AudioQueueAllocateBufferWithPacketDescriptions(m_audioQueue, static_cast<UInt32>(totalLen), static_cast<UInt32>(numPackets), &aqBuf);
    if (st != noErr || !aqBuf)
        return;
    if (CMBlockBufferCopyDataBytes(bb, 0, totalLen, aqBuf->mAudioData) != kCMBlockBufferNoErr) {
        AudioQueueFreeBuffer(m_audioQueue, aqBuf);
        return;
    }
    aqBuf->mAudioDataByteSize = static_cast<UInt32>(totalLen);

    // Per-packet (AAC frame) byte sizes → AudioStreamPacketDescription array.
    Vector<size_t> sizes(static_cast<size_t>(numPackets), 0);
    CMItemCount sizeArrayEntries = 0;
    if (CMSampleBufferGetSampleSizeArray(sampleBuffer, numPackets, sizes.mutableSpan().data(), &sizeArrayEntries) != noErr)
        sizeArrayEntries = 0;
    size_t offset = 0;
    UInt32 descCount = 0;
    for (CMItemCount i = 0; i < numPackets; ++i) {
        // GetSampleSizeArray returns 1 entry when all samples share a size; else one per packet.
        size_t pktSize = sizeArrayEntries == 1 ? sizes[0] : (i < sizeArrayEntries ? sizes[static_cast<size_t>(i)] : 0);
        if (!pktSize)
            pktSize = static_cast<size_t>(totalLen) / static_cast<size_t>(numPackets);
        if (offset + pktSize > totalLen)
            pktSize = totalLen - offset;
        if (!pktSize)
            break;
        aqBuf->mPacketDescriptions[descCount].mStartOffset = static_cast<SInt64>(offset);
        aqBuf->mPacketDescriptions[descCount].mVariableFramesInPacket = 0;
        aqBuf->mPacketDescriptions[descCount].mDataByteSize = static_cast<UInt32>(pktSize);
        offset += pktSize;
        ++descCount;
    }
    aqBuf->mPacketDescriptionCount = descCount;

    OSStatus es = AudioQueueEnqueueBuffer(m_audioQueue, aqBuf, 0, nullptr);
    if (es != noErr) {
        AVR_BISECT("enqueueAudioSample: EnqueueBuffer status=%d", (int)es);
        AudioQueueFreeBuffer(m_audioQueue, aqBuf);
        return;
    }
    // Start once we actually have data, if playing.
    if (!m_audioQueueStarted && !m_paused) {
        OSStatus ss = AudioQueueStart(m_audioQueue, nullptr);
        m_audioQueueStarted = (ss == noErr);
        AVR_BISECT("enqueueAudioSample: deferred AudioQueueStart status=%d", (int)ss);
    }
}

void AudioVideoRendererAVFObjC::teardownAudioQueue()
{
    if (m_audioQueue) {
        AudioQueueStop(m_audioQueue, true);
        AudioQueueDispose(m_audioQueue, true);
        m_audioQueue = nullptr;
    }
    m_audioQueueStarted = false;
}

void AudioVideoRendererAVFObjC::decodeAndQueue(CMSampleBufferRef sampleBuffer)
{
    AVR_BISECT("decodeAndQueue: ENTRY, ensuring session");
    ensureDecompressionSession(sampleBuffer);
    if (!m_decompressionSession) {
        AVR_BISECT("decodeAndQueue: no session, bailing");
        return;
    }
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    CMItemCount nSamples = CMSampleBufferGetNumSamples(sampleBuffer);
    if (!fmt || !bb || nSamples < 1) {
        AVR_BISECT("decodeAndQueue: missing fmt/bb/samples (n=%ld)", (long)nSamples);
        return;
    }

    // VTDecompressionSessionDecodeFrame decodes ONE frame per call. Our demuxer packs a whole
    // MediaSamplesBlock (e.g. 24 frames) into a single multi-sample CMSampleBuffer; passing that
    // directly returns kVTVideoDecoderBadDataErr (-8969). Split into per-sample CMSampleBuffers
    // (sub-referencing the shared block buffer) and decode each. CMSampleBufferCopySampleBufferForRange
    // is 10.10+, so build the single-sample buffers by hand (all the needed CM APIs exist on 10.9).
    size_t offset = 0;
    for (CMItemCount i = 0; i < nSamples; ++i) {
        size_t sampleSize = CMSampleBufferGetSampleSize(sampleBuffer, i);
        if (!sampleSize) {
            AVR_BISECT("decodeAndQueue: sample %ld has zero size, stopping", (long)i);
            break;
        }
        CMSampleTimingInfo timing;
        if (CMSampleBufferGetSampleTimingInfo(sampleBuffer, i, &timing) != noErr)
            timing = kCMTimingInfoInvalid;

        CMBlockBufferRef sub = nullptr;
        OSStatus bbStatus = CMBlockBufferCreateWithBufferReference(kCFAllocatorDefault, bb, offset, sampleSize, 0, &sub);
        offset += sampleSize;
        if (bbStatus != noErr || !sub) {
            AVR_BISECT("decodeAndQueue: sub block-buffer create failed st=%d", (int)bbStatus);
            continue;
        }
        if (i == 0) {
            uint8_t head[8] = { 0 };
            CMBlockBufferCopyDataBytes(sub, 0, 8, head);
            AVR_BISECT("decodeAndQueue: sample0 size=%zu head=%02x%02x%02x%02x %02x%02x%02x%02x", sampleSize, head[0],head[1],head[2],head[3],head[4],head[5],head[6],head[7]);
        }
        CMSampleBufferRef one = nullptr;
        size_t oneSize = sampleSize;
        OSStatus sbStatus = CMSampleBufferCreate(kCFAllocatorDefault, sub, true, nullptr, nullptr, fmt, 1, 1, &timing, 1, &oneSize, &one);
        CFRelease(sub);
        if (sbStatus != noErr || !one) {
            AVR_BISECT("decodeAndQueue: single-sample CMSampleBufferCreate failed st=%d", (int)sbStatus);
            continue;
        }
        if (i == 0) {
            uint8_t head[8] = { 0 };
            CMBlockBufferCopyDataBytes(sub ? sub : bb, 0, 8, head);
            AVR_BISECT("decodeAndQueue: sample0 size=%zu head=%02x%02x%02x%02x %02x%02x%02x%02x", sampleSize, head[0],head[1],head[2],head[3],head[4],head[5],head[6],head[7]);
        }
        VTDecodeInfoFlags infoFlags = 0;
        OSStatus st = VTDecompressionSessionDecodeFrame(m_decompressionSession.get(), one,
            kVTDecodeFrame_EnableAsynchronousDecompression, nullptr, &infoFlags);
        if (i == 0)
            AVR_BISECT("decodeAndQueue: DecodeFrame[0] status=%d", (int)st);
        CFRelease(one);
    }
    AVR_BISECT("decodeAndQueue: dispatched %ld samples to decoder", (long)nSamples);
}

bool AudioVideoRendererAVFObjC::isReadyForMoreSamples(TrackIdentifier id)
{
    auto it = m_tracks.find(id);
    if (it == m_tracks.end())
        return false;
    // VT decode path: accept samples as long as we're not sitting on a huge backlog of decoded frames.
    if (it->value.type == TrackType::Video) {
        Locker locker { m_frameLock };
        return m_decodedFrames.size() < 24;
    }
    return true;
}

Ref<AudioVideoRendererAVFObjC::RequestPromise> AudioVideoRendererAVFObjC::requestMediaDataWhenReady(TrackIdentifier id)
{
    // VT decode path is asynchronous and self-paced; always signal ready so the SourceBuffer keeps
    // feeding samples (isReadyForMoreSamples applies backpressure when the decoded queue is full).
    return RequestPromise::createAndResolve(id);
}

void AudioVideoRendererAVFObjC::notifyTrackNeedsReenqueuing(TrackIdentifier id, Function<void(TrackIdentifier, const MediaTime&)>&& callback)
{
    m_reenqueueCallbacks.set(id, WTF::move(callback));
}

bool AudioVideoRendererAVFObjC::timeIsProgressing() const { return !m_paused && m_rate > 0; }

MediaTime AudioVideoRendererAVFObjC::currentTime() const
{
    if (!m_timebase)
        return MediaTime::zeroTime();
    return PAL::toMediaTime(CMTimebaseGetTime(m_timebase.get()));
}

void AudioVideoRendererAVFObjC::flush()
{
    // Drop all queued decoded frames (VT path; no AVSampleBufferDisplayLayer on 10.9).
    Locker locker { m_frameLock };
    m_decodedFrames.clear();
    m_displayedPTS = MediaTime::invalidTime();
}

void AudioVideoRendererAVFObjC::flushAudio()
{
    if (m_audioQueue) {
        // AudioQueueReset drops all enqueued buffers (invoking the output callback to free each) and
        // clears decoder state, while leaving the queue running so post-seek samples play immediately.
        OSStatus st = AudioQueueReset(m_audioQueue);
        AVR_BISECT("flushAudio: AudioQueueReset status=%d", (int)st);
    }
}

void AudioVideoRendererAVFObjC::flushTrack(TrackIdentifier id)
{
    auto it = m_tracks.find(id);
    if (it == m_tracks.end())
        return;
    if (it->value.type == TrackType::Video)
        flush();
    else
        flushAudio();
}

void AudioVideoRendererAVFObjC::notifyWhenErrorOccurs(Function<void(PlatformMediaError)>&& callback) { m_errorCallback = WTF::move(callback); }

} // namespace WebCore

#endif // ENABLE(MEDIA_SOURCE)
