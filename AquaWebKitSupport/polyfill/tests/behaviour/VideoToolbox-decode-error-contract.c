// VTDecompressionSessionDecodeFrame's contract: an error return means the output callback is not called for that
// frame. On bare sessions, reached through VideoToolbox's own symbols, 10.9 breaks it for a frame its decoder rejects:
// one callback carrying the error, and the same error returned. Through the session functions the polyfill layer
// replaces, a rejected frame answers its error with no callback, and a frame that decodes answers noErr with one
// callback carrying its image.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../polyfills/c/wk_symbols.h"

typedef OSStatus (*CreateFunction)(CFAllocatorRef, CMVideoFormatDescriptionRef, CFDictionaryRef, CFDictionaryRef,
    const VTDecompressionOutputCallbackRecord *, VTDecompressionSessionRef *);
typedef OSStatus (*DecodeFunction)(VTDecompressionSessionRef, CMSampleBufferRef, VTDecodeFrameFlags, void *, VTDecodeInfoFlags *);

static CMSampleBufferRef encodedFrame;

static void encoded(void *context, void *frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    (void)context;
    (void)frame;
    (void)flags;
    if (!status && sample && !encodedFrame)
        encodedFrame = (CMSampleBufferRef)CFRetain(sample);
}

struct Output {
    int callbacks;
    int images;
    OSStatus status;
};

static void decoded(void *context, void *frame, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration)
{
    (void)frame;
    (void)flags;
    (void)pts;
    (void)duration;
    struct Output *output = context;
    ++output->callbacks;
    output->images += image != NULL;
    output->status = status;
}

// |encodedFrame|'s data, zeroed after its first length prefix when |corrupt|, as a sample of |format|.
static CMSampleBufferRef sampleFromEncodedFrame(CMFormatDescriptionRef format, int corrupt)
{
    CMBlockBufferRef source = CMSampleBufferGetDataBuffer(encodedFrame);
    size_t length = CMBlockBufferGetDataLength(source);
    char *bytes = malloc(length);
    assert(bytes && !CMBlockBufferCopyDataBytes(source, 0, length, bytes));
    if (corrupt)
        memset(bytes + 4, 0, length - 4);
    CMBlockBufferRef block = NULL;
    assert(!CMBlockBufferCreateWithMemoryBlock(NULL, bytes, length, kCFAllocatorMalloc, NULL, 0, length, 0, &block));
    CMSampleBufferRef sample = NULL;
    assert(!CMSampleBufferCreate(NULL, block, true, NULL, NULL, format, 1, 0, NULL, 1, &length, &sample));
    CFRelease(block);
    return sample;
}

static OSStatus decode(CreateFunction create, DecodeFunction decodeFrame, CMFormatDescriptionRef format, CMSampleBufferRef sample, struct Output *output)
{
    VTDecompressionOutputCallbackRecord callback = { decoded, output };
    VTDecompressionSessionRef session = NULL;
    assert(!create(NULL, format, NULL, NULL, &callback, &session));
    OSStatus status = decodeFrame(session, sample, kVTDecodeFrame_EnableAsynchronousDecompression, NULL, NULL);
    VTDecompressionSessionWaitForAsynchronousFrames(session);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    return status;
}

int main(void)
{
    VTCompressionSessionRef encoder = NULL;
    assert(!VTCompressionSessionCreate(NULL, 320, 240, kCMVideoCodecType_H264, NULL, NULL, NULL, encoded, NULL, &encoder));
    CVPixelBufferRef image = NULL;
    assert(!CVPixelBufferCreate(NULL, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &image));
    assert(!VTCompressionSessionEncodeFrame(encoder, image, CMTimeMake(0, 30), kCMTimeInvalid, NULL, NULL, NULL));
    VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid);
    VTCompressionSessionInvalidate(encoder);
    CFRelease(encoder);
    CVPixelBufferRelease(image);
    assert(encodedFrame);
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(encodedFrame);

    // dlsym answers a replaced name with the replacement, so the system's entry points come from VideoToolbox's
    // own symbol table.
    wk_image videoToolbox;
    assert(wk_find_image("/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox", &videoToolbox));
    CreateFunction systemCreate = (CreateFunction)wk_symbol_in_image(&videoToolbox, "_VTDecompressionSessionCreate");
    DecodeFunction systemDecode = (DecodeFunction)wk_symbol_in_image(&videoToolbox, "_VTDecompressionSessionDecodeFrame");
    assert(systemCreate && systemDecode && (void *)systemDecode != (void *)VTDecompressionSessionDecodeFrame);

    int failures = 0;
    CMSampleBufferRef rejected = sampleFromEncodedFrame(format, 1);
    struct Output bare = { 0, 0, 0 };
    OSStatus status = decode(systemCreate, systemDecode, format, rejected, &bare);
    if (!status || bare.callbacks != 1 || bare.status != status) {
        printf("FAIL bare session, rejected frame: returned %d, %d callback(s) with %d\n", (int)status, bare.callbacks, (int)bare.status);
        ++failures;
    }

    struct Output output = { 0, 0, 0 };
    status = decode(VTDecompressionSessionCreate, VTDecompressionSessionDecodeFrame, format, rejected, &output);
    if (!status || output.callbacks) {
        printf("FAIL rejected frame: returned %d with %d callback(s)\n", (int)status, output.callbacks);
        ++failures;
    }
    CFRelease(rejected);

    CMSampleBufferRef decodable = sampleFromEncodedFrame(format, 0);
    output = (struct Output) { 0, 0, 0 };
    status = decode(VTDecompressionSessionCreate, VTDecompressionSessionDecodeFrame, format, decodable, &output);
    if (status || output.callbacks != 1 || output.images != 1 || output.status) {
        printf("FAIL decodable frame: returned %d, %d callback(s), %d image(s), callback status %d\n", (int)status,
            output.callbacks, output.images, (int)output.status);
        ++failures;
    }
    CFRelease(decodable);
    CFRelease(encodedFrame);

    printf("VideoToolbox decode error contract: %d failure(s)\n", failures);
    return !!failures;
}
