// kVTEncodeFrameOptionKey_ForceKeyFrame makes a frame a keyframe. On bare sessions, reached through VideoToolbox's own
// symbols, 10.9's H.264 encoder encodes a forced frame that follows a keyframe as a NotSync non-IDR picture. Through
// the session functions the polyfill layer replaces, every forced frame of a run of consecutive forced frames comes out
// a sync IDR, with outputs held or emitted as frames are submitted and with the encoder's own keyframes beside them;
// the caller receives exactly one output per frame it submitted, each with its own refcon and timestamp, and the
// stream decodes to one image per frame. A session with a MaxKeyFrameInterval of 1 encodes every frame as an IDR,
// except under low-latency usage, which ignores the interval (measured). The encoder writes the number of pictures it
// encoded before an IDR, modulo 4, as its idr_pic_id (measured), which counts the frames of the polyfill's own: with
// interval 1 there are none, and under low-latency usage there is one before each forced frame that follows a
// keyframe.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../polyfills/c/wk_symbols.h"

typedef OSStatus (*CreateFunction)(CFAllocatorRef, int32_t, int32_t, CMVideoCodecType, CFDictionaryRef, CFDictionaryRef,
    CFAllocatorRef, VTCompressionOutputCallback, void *, VTCompressionSessionRef *);
typedef OSStatus (*EncodeFunction)(VTCompressionSessionRef, CVImageBufferRef, CMTime, CMTime, CFDictionaryRef, void *, VTEncodeInfoFlags *);

enum { kFrames = 9 };

struct Outputs {
    int count;
    int refcons[kFrames];
    int isSync[kFrames];
    int isIDR[kFrames];
    int idrPicID[kFrames];
    CMTime times[kFrames];
    CMSampleBufferRef samples[kFrames];
    int unknownRefcons;
};

static int sampleIsSync(CMSampleBufferRef sample)
{
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (!attachments || !CFArrayGetCount(attachments))
        return 1;
    return !CFDictionaryContainsKey(CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_NotSync);
}

static unsigned readBits(const uint8_t *bytes, unsigned *bit, unsigned count)
{
    unsigned value = 0;
    for (unsigned i = 0; i < count; ++i, ++*bit)
        value = (value << 1) | ((bytes[*bit / 8] >> (7 - *bit % 8)) & 1);
    return value;
}

static unsigned readUE(const uint8_t *bytes, unsigned *bit)
{
    unsigned zeros = 0;
    while (!readBits(bytes, bit, 1))
        ++zeros;
    return (1u << zeros) - 1 + readBits(bytes, bit, zeros);
}

// The idr_pic_id of a Baseline IDR slice whose NAL unit starts at |slice|, or -1.
static int idrPicID(CMSampleBufferRef sample, const uint8_t *slice)
{
    if ((slice[0] & 0x1f) != 5)
        return -1;
    const uint8_t *sps;
    size_t spsLength;
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(CMSampleBufferGetFormatDescription(sample), 0, &sps, &spsLength, NULL, NULL) || sps[1] != 66)
        return -1;
    unsigned bit = 32; // NAL header, profile_idc, constraint flags, level_idc.
    readUE(sps, &bit); // seq_parameter_set_id
    unsigned frameNumBits = readUE(sps, &bit) + 4;
    bit = 8;
    readUE(slice, &bit); // first_mb_in_slice
    readUE(slice, &bit); // slice_type
    readUE(slice, &bit); // pic_parameter_set_id
    readBits(slice, &bit, frameNumBits);
    return (int)readUE(slice, &bit);
}

// Whether the sample's length-prefixed NAL units include an IDR slice; |*picID| receives its idr_pic_id.
static int sampleHasIDRSlice(CMSampleBufferRef sample, int *picID)
{
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t length = CMBlockBufferGetDataLength(block);
    uint8_t *bytes = malloc(length);
    assert(bytes && !CMBlockBufferCopyDataBytes(block, 0, length, bytes));
    int idr = 0;
    for (size_t position = 0; position + 4 < length;) {
        size_t unit = ((size_t)bytes[position] << 24) | ((size_t)bytes[position + 1] << 16) | ((size_t)bytes[position + 2] << 8) | bytes[position + 3];
        if ((bytes[position + 4] & 0x1f) == 5 && !idr) {
            idr = 1;
            *picID = idrPicID(sample, bytes + position + 4);
        }
        position += 4 + unit;
    }
    free(bytes);
    return idr;
}

static void encoded(void *context, void *frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    (void)flags;
    struct Outputs *outputs = context;
    intptr_t index = (intptr_t)frame - 1;
    if (index < 0 || index >= kFrames) {
        ++outputs->unknownRefcons;
        return;
    }
    if (status || !sample || outputs->count >= kFrames)
        return;
    outputs->refcons[outputs->count] = (int)index;
    outputs->isSync[outputs->count] = sampleIsSync(sample);
    outputs->idrPicID[outputs->count] = -1;
    outputs->isIDR[outputs->count] = sampleHasIDRSlice(sample, &outputs->idrPicID[outputs->count]);
    outputs->times[outputs->count] = CMSampleBufferGetPresentationTimeStamp(sample);
    outputs->samples[outputs->count] = (CMSampleBufferRef)CFRetain(sample);
    ++outputs->count;
}

static void encode(CreateFunction create, EncodeFunction encodeFrame, const int *forced, int maxKeyFrameInterval, int lowLatency,
    struct Outputs *outputs)
{
    const void *keys[] = { CFSTR("RequiredLowLatency") };
    const void *values[] = { kCFBooleanTrue };
    CFDictionaryRef specification = lowLatency
        ? CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
    VTCompressionSessionRef session = NULL;
    assert(!create(NULL, 320, 240, kCMVideoCodecType_H264, specification, NULL, NULL, encoded, outputs, &session));
    if (specification)
        CFRelease(specification);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    if (maxKeyFrameInterval) {
        CFNumberRef interval = CFNumberCreate(NULL, kCFNumberIntType, &maxKeyFrameInterval);
        VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, interval);
        CFRelease(interval);
    }
    for (int i = 0; i < kFrames; ++i) {
        CVPixelBufferRef image = NULL;
        assert(!CVPixelBufferCreate(NULL, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &image));
        CVPixelBufferLockBaseAddress(image, 0);
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 0), 16 + i * 20, CVPixelBufferGetBytesPerRowOfPlane(image, 0) * 240);
        memset(CVPixelBufferGetBaseAddressOfPlane(image, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * 120);
        CVPixelBufferUnlockBaseAddress(image, 0);
        CFDictionaryRef properties = NULL;
        if (forced[i]) {
            const void *keys[] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
            const void *values[] = { kCFBooleanTrue };
            properties = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        }
        assert(!encodeFrame(session, image, CMTimeMake(i, 30), kCMTimeInvalid, properties, (void *)(intptr_t)(i + 1), NULL));
        if (properties)
            CFRelease(properties);
        CVPixelBufferRelease(image);
    }
    VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
}

static int decodedImages;
static void decoded(void *context, void *frame, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration)
{
    (void)context;
    (void)frame;
    (void)flags;
    (void)pts;
    (void)duration;
    decodedImages += !status && image;
}

static int checkPolyfilled(const int *forced, int maxKeyFrameInterval, int lowLatency, const char *name)
{
    int failures = 0;
    struct Outputs outputs = { 0 };
    encode(VTCompressionSessionCreate, VTCompressionSessionEncodeFrame, forced, maxKeyFrameInterval, lowLatency, &outputs);
    if (outputs.count != kFrames || outputs.unknownRefcons) {
        printf("FAIL %s: %d output(s) for %d frames, %d with a refcon the caller never passed\n", name, outputs.count, kFrames, outputs.unknownRefcons);
        ++failures;
    }
    int separators = 0;
    for (int i = 0; i < outputs.count; ++i) {
        int frame = outputs.refcons[i];
        if (frame != i) {
            printf("FAIL %s: output %d carries frame %d's refcon\n", name, i, frame);
            ++failures;
        }
        if (CMTimeCompare(outputs.times[i], CMTimeMake(frame, 30))) {
            printf("FAIL %s: frame %d comes out at %lld/%d\n", name, frame, outputs.times[i].value, outputs.times[i].timescale);
            ++failures;
        }
        if (maxKeyFrameInterval == 1 && !lowLatency && outputs.idrPicID[i] < 0) {
            printf("FAIL %s: frame %d is not an IDR\n", name, frame);
            ++failures;
        }
        if (maxKeyFrameInterval == 1 && lowLatency && forced[frame] && i && outputs.isSync[i - 1])
            ++separators;
        if (maxKeyFrameInterval == 1 && outputs.idrPicID[i] >= 0 && outputs.idrPicID[i] != (frame + separators) % 4) {
            printf("FAIL %s: frame %d's idr_pic_id is %d after %d frame(s) of the polyfill's own\n", name, frame,
                outputs.idrPicID[i], separators);
            ++failures;
        }
        if (forced[frame] && (!outputs.isSync[i] || !outputs.isIDR[i])) {
            printf("FAIL %s: forced frame %d: sync %d, IDR slice %d\n", name, frame, outputs.isSync[i], outputs.isIDR[i]);
            ++failures;
        }
    }

    if (outputs.count) {
        decodedImages = 0;
        VTDecompressionOutputCallbackRecord callback = { decoded, NULL };
        VTDecompressionSessionRef decoder = NULL;
        assert(!VTDecompressionSessionCreate(NULL, CMSampleBufferGetFormatDescription(outputs.samples[0]), NULL, NULL, &callback, &decoder));
        for (int i = 0; i < outputs.count; ++i)
            VTDecompressionSessionDecodeFrame(decoder, outputs.samples[i], 0, NULL, NULL);
        VTDecompressionSessionWaitForAsynchronousFrames(decoder);
        VTDecompressionSessionInvalidate(decoder);
        CFRelease(decoder);
        if (decodedImages != outputs.count) {
            printf("FAIL %s: the delivered stream decodes to %d image(s) for %d sample(s)\n", name, decodedImages, outputs.count);
            ++failures;
        }
    }
    for (int i = 0; i < outputs.count; ++i)
        CFRelease(outputs.samples[i]);
    return failures;
}

int main(void)
{
    // dlsym answers a replaced name with the replacement, so the system's entry points come from VideoToolbox's
    // own symbol table.
    wk_image videoToolbox;
    assert(wk_find_image("/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox", &videoToolbox));
    CreateFunction systemCreate = (CreateFunction)wk_symbol_in_image(&videoToolbox, "_VTCompressionSessionCreate");
    EncodeFunction systemEncode = (EncodeFunction)wk_symbol_in_image(&videoToolbox, "_VTCompressionSessionEncodeFrame");
    assert(systemCreate && systemEncode && (void *)systemEncode != (void *)VTCompressionSessionEncodeFrame);

    static const int forced[kFrames] = { 1, 1, 1, 0, 0, 1, 1, 0, 1 };
    int failures = 0;

    struct Outputs bare = { 0 };
    encode(systemCreate, systemEncode, forced, 0, 0, &bare);
    if (bare.count != kFrames || bare.isSync[1]) {
        printf("FAIL bare session: %d output(s); the forced frame after the first keyframe is %s\n", bare.count,
            bare.isSync[1] ? "a keyframe" : "not a keyframe");
        ++failures;
    }

    for (int lowLatency = 0; lowLatency < 2; ++lowLatency) {
        failures += checkPolyfilled(forced, 0, lowLatency, lowLatency ? "low latency" : "default");
        failures += checkPolyfilled(forced, 2, lowLatency, lowLatency ? "low latency, keyframe interval 2" : "keyframe interval 2");
        failures += checkPolyfilled(forced, 1, lowLatency, lowLatency ? "low latency, keyframe interval 1" : "keyframe interval 1");
    }
    for (int i = 0; i < bare.count; ++i)
        CFRelease(bare.samples[i]);

    printf("VideoToolbox force key frame: %d failure(s)\n", failures);
    return !!failures;
}
