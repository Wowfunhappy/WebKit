// An H.264 session whose encoder specification requires RequiredLowLatency, as libwebrtc's RTCVideoEncoderH264
// creates it, emits each frame before the next is submitted. Asked for a Baseline profile it hands back a stream
// labelled Constrained Baseline that VideoToolbox decodes, with a forced key frame as its only other sync sample.
// Asked for High it keeps the encoder's own label. A session below 192x108, whose specification names usage 1
// itself as libwebrtc's does at those sizes, is labelled Constrained Baseline the same way. Fed frames without durations on a clock that started long
// before it, as libwebrtc feeds them, it holds its average bit rate. A session that does not require low latency
// is left at the default usage.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/time.h>

enum { frameCount = 30, forcedKeyFrame = 15, width = 640, height = 480 };

struct Encoded {
    pthread_mutex_t lock;
    pthread_cond_t delivered;
    unsigned outputs;
    unsigned dropped;
    CMSampleBufferRef samples[frameCount];
};

static void encoded(void *context, void *frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    struct Encoded *encoded = context;
    unsigned index = (unsigned)(uintptr_t)frame;
    assert(!status && index < frameCount);
    pthread_mutex_lock(&encoded->lock);
    if (sample)
        encoded->samples[index] = (CMSampleBufferRef)CFRetain(sample);
    else
        ++encoded->dropped;
    ++encoded->outputs;
    pthread_cond_broadcast(&encoded->delivered);
    pthread_mutex_unlock(&encoded->lock);
}

static CVPixelBufferRef sizedPicture(unsigned frame, size_t width, size_t height)
{
    CVPixelBufferRef image = NULL;
    assert(!CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &image));
    assert(!CVPixelBufferLockBaseAddress(image, 0));
    for (size_t plane = 0; plane < 2; ++plane) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(image, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane);
        size_t rows = plane ? height / 2 : height;
        for (size_t y = 0; y < rows; ++y) {
            for (size_t x = 0; x < width; ++x)
                base[y * stride + x] = plane ? 128 : (uint8_t)(128 + 60 * sin((x + frame * 4) / 40.0) * cos((y + frame * 2) / 30.0));
        }
    }
    assert(!CVPixelBufferUnlockBaseAddress(image, 0));
    return image;
}

static CVPixelBufferRef picture(unsigned frame)
{
    return sizedPicture(frame, width, height);
}

static CVPixelBufferRef noisyPicture(unsigned frame)
{
    static uint32_t noise = 1;
    CVPixelBufferRef image = NULL;
    assert(!CVPixelBufferCreate(NULL, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &image));
    assert(!CVPixelBufferLockBaseAddress(image, 0));
    for (size_t plane = 0; plane < 2; ++plane) {
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(image, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane);
        for (size_t y = 0; y < (plane ? 120 : 240); ++y) {
            for (size_t x = 0; x < 320; ++x) {
                noise = noise * 1103515245 + 12345;
                base[y * stride + x] = plane ? (uint8_t)(128 + ((x + frame * 3) & 31)) : (uint8_t)(((x + y + frame * 4) & 255) / 2 + ((noise >> 16) & 63));
            }
        }
    }
    assert(!CVPixelBufferUnlockBaseAddress(image, 0));
    return image;
}

struct Rate {
    size_t bytes;
};

static void measured(void *context, void *frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    struct Rate *rate = context;
    assert(!status);
    if (sample && (uintptr_t)frame >= 90)
        __atomic_add_fetch(&rate->bytes, CMSampleBufferGetTotalSampleSize(sample), __ATOMIC_RELAXED);
}

static VTCompressionSessionRef createSession(struct Encoded *result, int lowLatency, CFStringRef profileLevel)
{
    CFMutableDictionaryRef specification = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(specification, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanTrue);
    CFDictionarySetValue(specification, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    if (lowLatency)
        CFDictionarySetValue(specification, CFSTR("RequiredLowLatency"), kCFBooleanTrue);
    VTCompressionSessionRef session = NULL;
    assert(!VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264, specification, NULL, NULL, encoded, result, &session));
    CFRelease(specification);
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, profileLevel));
    int32_t bitRate = 500000, frameRate = 30;
    CFNumberRef bitRateNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &bitRate);
    CFNumberRef frameRateNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &frameRate);
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitRateNumber));
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, frameRateNumber));
    CFRelease(bitRateNumber);
    CFRelease(frameRateNumber);
    return session;
}

static int32_t usageOf(VTCompressionSessionRef session)
{
    CFNumberRef usage = NULL;
    int32_t value = -1;
    assert(!VTSessionCopyProperty(session, CFSTR("EncoderUsage"), NULL, &usage) && usage);
    CFNumberGetValue(usage, kCFNumberSInt32Type, &value);
    CFRelease(usage);
    return value;
}

static void profileOf(CMSampleBufferRef sample, unsigned *recordProfile, unsigned *recordFlags, unsigned *spsProfile, unsigned *spsFlags)
{
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    CFDictionaryRef atoms = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    CFDataRef avcC = atoms ? CFDictionaryGetValue(atoms, CFSTR("avcC")) : NULL;
    assert(avcC && CFDataGetLength(avcC) > 3);
    *recordProfile = CFDataGetBytePtr(avcC)[1];
    *recordFlags = CFDataGetBytePtr(avcC)[2];
    const uint8_t *sps = NULL;
    size_t spsLength = 0;
    assert(!CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &spsLength, NULL, NULL) && spsLength > 3);
    *spsProfile = sps[1];
    *spsFlags = sps[2];
}

static int isSync(CMSampleBufferRef sample)
{
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    CFDictionaryRef first = attachments && CFArrayGetCount(attachments) ? CFArrayGetValueAtIndex(attachments, 0) : NULL;
    CFBooleanRef notSync = first ? CFDictionaryGetValue(first, kCMSampleAttachmentKey_NotSync) : NULL;
    return !notSync || !CFBooleanGetValue(notSync);
}

struct Decoded {
    unsigned frames;
    unsigned failures;
};

static void decoded(void *context, void *frame, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime time, CMTime duration)
{
    struct Decoded *decoded = context;
    if (status || !image)
        ++decoded->failures;
    else
        ++decoded->frames;
}

// How many of |count| samples VideoToolbox decodes from the format description of the first.
static unsigned decodable(CMSampleBufferRef *samples, unsigned count)
{
    struct Decoded result = { 0, 0 };
    VTDecompressionOutputCallbackRecord callback = { decoded, &result };
    VTDecompressionSessionRef decoder = NULL;
    assert(!VTDecompressionSessionCreate(NULL, CMSampleBufferGetFormatDescription(samples[0]), NULL, NULL, &callback, &decoder));
    for (unsigned frame = 0; frame < count; ++frame) {
        if (samples[frame])
            assert(!VTDecompressionSessionDecodeFrame(decoder, samples[frame], 0, NULL, NULL));
    }
    assert(!VTDecompressionSessionWaitForAsynchronousFrames(decoder));
    VTDecompressionSessionInvalidate(decoder);
    CFRelease(decoder);
    return result.failures ? 0 : result.frames;
}

// Encodes frameCount frames, waiting after each for its output. Returns the number that were not out within a second.
static unsigned encode(VTCompressionSessionRef session, struct Encoded *result)
{
    CFDictionaryRef forceKeyFrame = CFDictionaryCreate(NULL, (const void **)&kVTEncodeFrameOptionKey_ForceKeyFrame, (const void **)&kCFBooleanTrue, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    unsigned late = 0;
    for (unsigned frame = 0; frame < frameCount; ++frame) {
        CVPixelBufferRef image = picture(frame);
        assert(!VTCompressionSessionEncodeFrame(session, image, CMTimeMake(frame, 30), CMTimeMake(1, 30), frame == forcedKeyFrame ? forceKeyFrame : NULL,
            (void *)(uintptr_t)frame, NULL));
        CVPixelBufferRelease(image);
        struct timeval now;
        gettimeofday(&now, NULL);
        struct timespec deadline = { now.tv_sec + 1, now.tv_usec * 1000 };
        pthread_mutex_lock(&result->lock);
        while (result->outputs <= frame) {
            if (pthread_cond_timedwait(&result->delivered, &result->lock, &deadline))
                break;
        }
        if (result->outputs <= frame)
            ++late;
        pthread_mutex_unlock(&result->lock);
    }
    assert(!VTCompressionSessionCompleteFrames(session, kCMTimeInvalid));
    CFRelease(forceKeyFrame);
    return late;
}

int main(void)
{
    int failures = 0;

    static struct Encoded baseline = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
    VTCompressionSessionRef session = createSession(&baseline, 1, CFSTR("H264_Baseline_AutoLevel"));
    if (usageOf(session) != 1) {
        printf("FAIL a session requiring low latency runs at usage %d\n", usageOf(session));
        ++failures;
    }
    unsigned baselineLate = encode(session, &baseline);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    if (baselineLate) {
        printf("FAIL %u of %u frames were not out before the next was submitted\n", baselineLate, frameCount);
        ++failures;
    }
    if (baseline.dropped || !baseline.samples[0]) {
        printf("FAIL %u of %u frames dropped\n", baseline.dropped, frameCount);
        ++failures;
    }
    for (unsigned frame = 0; frame < frameCount && baseline.samples[frame]; ++frame) {
        unsigned recordProfile, recordFlags, spsProfile, spsFlags;
        profileOf(baseline.samples[frame], &recordProfile, &recordFlags, &spsProfile, &spsFlags);
        if (recordProfile != 66 || !(recordFlags & 0x80) || spsProfile != 66 || !(spsFlags & 0x80)) {
            printf("FAIL frame %u is labelled avcC %u/%02x, SPS %u/%02x rather than Constrained Baseline\n", frame, recordProfile, recordFlags, spsProfile, spsFlags);
            ++failures;
            break;
        }
        int shouldSync = !frame || frame == forcedKeyFrame;
        if (isSync(baseline.samples[frame]) != shouldSync) {
            printf("FAIL frame %u is %sa sync sample\n", frame, shouldSync ? "not " : "");
            ++failures;
        }
    }

    unsigned decodedFrames = baseline.samples[0] ? decodable(baseline.samples, frameCount) : 0;
    if (decodedFrames != frameCount) {
        printf("FAIL %u of %u frames decode\n", decodedFrames, frameCount);
        ++failures;
    }

    static struct Encoded small = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
    CFMutableDictionaryRef smallSpecification = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int32_t usage = 1;
    CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &usage);
    CFDictionarySetValue(smallSpecification, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    CFDictionarySetValue(smallSpecification, CFSTR("EncoderUsage"), usageNumber);
    CFRelease(usageNumber);
    assert(!VTCompressionSessionCreate(NULL, 160, 96, kCMVideoCodecType_H264, smallSpecification, NULL, NULL, encoded, &small, &session));
    CFRelease(smallSpecification);
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, CFSTR("H264_Baseline_AutoLevel")));
    for (unsigned frame = 0; frame < 10; ++frame) {
        CVPixelBufferRef image = sizedPicture(frame, 160, 96);
        assert(!VTCompressionSessionEncodeFrame(session, image, CMTimeMake(frame, 30), kCMTimeInvalid, NULL, (void *)(uintptr_t)frame, NULL));
        CVPixelBufferRelease(image);
    }
    assert(!VTCompressionSessionCompleteFrames(session, kCMTimeInvalid));
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    if (!small.samples[0]) {
        printf("FAIL a 160x96 session encoded nothing\n");
        ++failures;
    } else {
        unsigned recordProfile, recordFlags, spsProfile, spsFlags;
        profileOf(small.samples[0], &recordProfile, &recordFlags, &spsProfile, &spsFlags);
        if (recordProfile != 66 || !(recordFlags & 0x80) || spsProfile != 66 || !(spsFlags & 0x80)) {
            printf("FAIL a 160x96 usage-1 session is labelled avcC %u/%02x, SPS %u/%02x rather than Constrained Baseline\n", recordProfile, recordFlags, spsProfile, spsFlags);
            ++failures;
        }
        unsigned smallDecoded = decodable(small.samples, 10);
        if (smallDecoded != 10 - small.dropped) {
            printf("FAIL %u of %u 160x96 frames decode\n", smallDecoded, 10 - small.dropped);
            ++failures;
        }
    }

    static struct Encoded high = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
    session = createSession(&high, 1, kVTProfileLevel_H264_High_AutoLevel);
    unsigned late = encode(session, &high);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    if (late || !high.samples[0]) {
        printf("FAIL %u of %u High-profile frames were late\n", late, frameCount);
        ++failures;
    } else {
        unsigned recordProfile, recordFlags, spsProfile, spsFlags;
        profileOf(high.samples[0], &recordProfile, &recordFlags, &spsProfile, &spsFlags);
        if (recordProfile == 66 || spsProfile == 66) {
            printf("FAIL a High-profile session is labelled Baseline\n");
            ++failures;
        }
    }

    // libwebrtc's ExpectedFrameRate and AverageBitRate, and its capture clock origin.
    static struct Rate rate;
    CFMutableDictionaryRef specification = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(specification, CFSTR("RequiredLowLatency"), kCFBooleanTrue);
    assert(!VTCompressionSessionCreate(NULL, 320, 240, kCMVideoCodecType_H264, specification, NULL, NULL, measured, &rate, &session));
    CFRelease(specification);
    int32_t bitRate = 600000, frameRate = 30;
    CFNumberRef bitRateNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &bitRate);
    CFNumberRef frameRateNumber = CFNumberCreate(NULL, kCFNumberSInt32Type, &frameRate);
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel));
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitRateNumber));
    assert(!VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, frameRateNumber));
    CFRelease(bitRateNumber);
    CFRelease(frameRateNumber);
    const int64_t origin = 75510506;
    for (unsigned frame = 0; frame < 150; ++frame) {
        CVPixelBufferRef image = noisyPicture(frame);
        assert(!VTCompressionSessionEncodeFrame(session, image, CMTimeMake(origin + frame * 1000 / 30, 1000), kCMTimeInvalid, NULL, (void *)(uintptr_t)frame, NULL));
        CVPixelBufferRelease(image);
    }
    assert(!VTCompressionSessionCompleteFrames(session, kCMTimeInvalid));
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    double kilobitsPerSecond = rate.bytes * 8 / 2.0 / 1000;
    if (kilobitsPerSecond > 900) {
        printf("FAIL frames 90-149 without durations run at %.0f kbps for a 600 kbps target\n", kilobitsPerSecond);
        ++failures;
    }

    static struct Encoded plain = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
    session = createSession(&plain, 0, CFSTR("H264_Baseline_AutoLevel"));
    if (usageOf(session) != 0) {
        printf("FAIL a session that does not require low latency runs at usage %d\n", usageOf(session));
        ++failures;
    }
    VTCompressionSessionInvalidate(session);
    CFRelease(session);

    printf("VideoToolbox low latency: %u frames each out before the next, %d failure(s)\n", frameCount - baselineLate, failures);
    return !!failures;
}
