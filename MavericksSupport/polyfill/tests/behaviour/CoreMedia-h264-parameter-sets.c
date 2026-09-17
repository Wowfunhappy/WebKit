#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef OSStatus (*GetParameterSet)(CMFormatDescriptionRef, size_t, const uint8_t**, size_t*, size_t*, int*);

struct Test {
    GetParameterSet nativeGet;
    VTDecompressionSessionRef decoder;
    unsigned encoded;
    unsigned decoded;
};

static void decoded(void* context, void* frame, OSStatus status, VTDecodeInfoFlags flags,
    CVImageBufferRef image, CMTime presentation, CMTime duration)
{
    (void)frame;
    (void)flags;
    (void)presentation;
    (void)duration;
    struct Test* test = context;
    assert(status == noErr && image);
    assert(CVPixelBufferGetWidth(image) == 320 && CVPixelBufferGetHeight(image) == 240);
    ++test->decoded;
}

static void encoded(void* context, void* frame, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    (void)frame;
    (void)flags;
    struct Test* test = context;
    assert(status == noErr && sample && CMSampleBufferGetTotalSampleSize(sample));
    CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sample);
    size_t count = 0;
    int headerLength = 0;
    assert(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, 999, NULL, NULL, &count, &headerLength) == noErr);
    assert(count == 2 && headerLength == 4);
    for (unsigned outputs = 1; outputs < 4; ++outputs) {
        const uint8_t* expected = (const uint8_t*)1;
        const uint8_t* actual = (const uint8_t*)1;
        size_t expectedSize = 123, actualSize = 123;
        size_t expectedCount = 0, actualCount = 0;
        int expectedHeader = 0, actualHeader = 0;
        OSStatus expectedStatus = test->nativeGet(description, 999,
            outputs & 1 ? &expected : NULL, outputs & 2 ? &expectedSize : NULL,
            &expectedCount, &expectedHeader);
        OSStatus actualStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, 999,
            outputs & 1 ? &actual : NULL, outputs & 2 ? &actualSize : NULL,
            &actualCount, &actualHeader);
        assert(actualStatus == noErr);
        assert(actualCount == count && actualHeader == headerLength);
        // Native High-profile atom parsing can fail even for a count query.
        if (expectedStatus == noErr) {
            assert(actualCount == expectedCount && actualHeader == expectedHeader);
            if (outputs & 1)
                assert(actual == expected);
            if (outputs & 2)
                assert(actualSize == expectedSize);
        }
        if (outputs & 1)
            assert(actual == (const uint8_t*)1);
        if (outputs & 2)
            assert(actualSize == 123);
    }
    const uint8_t* missing = NULL;
    size_t missingSize = 0;
    assert(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, count, &missing, &missingSize, NULL, NULL) == noErr);
    assert(!missing && !missingSize);
    for (size_t i = 0; i < count; ++i) {
        const uint8_t* expected = NULL;
        const uint8_t* actual = NULL;
        size_t expectedSize = 0, actualSize = 0, actualCount = 0;
        assert(test->nativeGet(description, i, &expected, &expectedSize, NULL, NULL) == noErr);
        assert(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, i, &actual, &actualSize, &actualCount, NULL) == noErr);
        assert(actualCount == count && actualSize == expectedSize && !memcmp(actual, expected, actualSize));
    }
    if (!test->decoder) {
        VTDecompressionOutputCallbackRecord callback = { decoded, test };
        assert(VTDecompressionSessionCreate(NULL, description, NULL, NULL, &callback, &test->decoder) == noErr);
    }
    assert(VTDecompressionSessionDecodeFrame(test->decoder, sample, 0, NULL, NULL) == noErr);
    ++test->encoded;
}

int main(void)
{
    void* library = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_LAZY | RTLD_FIRST);
    assert(library);
    GetParameterSet nativeGet = (GetParameterSet)dlsym(library, "CMVideoFormatDescriptionGetH264ParameterSetAtIndex");
    assert(nativeGet);
    CFStringRef profiles[] = { kVTProfileLevel_H264_Baseline_3_1, kVTProfileLevel_H264_High_3_1, kVTProfileLevel_H264_High_AutoLevel };
    for (unsigned profile = 0; profile < 3; ++profile) {
        struct Test test = { nativeGet, NULL, 0, 0 };
        VTCompressionSessionRef encoder = NULL;
        assert(VTCompressionSessionCreate(NULL, 320, 240, kCMVideoCodecType_H264, NULL, NULL, NULL, encoded, &test, &encoder) == noErr);
        assert(VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ProfileLevel, profiles[profile]) == noErr);
        assert(VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) == noErr);
        int fps = 30, bitrate = 300000;
        CFNumberRef rate = CFNumberCreate(NULL, kCFNumberIntType, &fps);
        CFNumberRef bits = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
        assert(VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, rate) == noErr);
        assert(VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AverageBitRate, bits) == noErr);
        CFRelease(rate);
        CFRelease(bits);
        CVPixelBufferRef pixel = NULL;
        assert(CVPixelBufferCreate(NULL, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pixel) == kCVReturnSuccess);
        CVPixelBufferLockBaseAddress(pixel, 0);
        for (size_t plane = 0; plane < CVPixelBufferGetPlaneCount(pixel); ++plane)
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), plane ? 128 : 80,
                CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane));
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        for (unsigned i = 0; i < 4; ++i)
            assert(VTCompressionSessionEncodeFrame(encoder, pixel, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL) == noErr);
        assert(VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid) == noErr);
        assert(test.decoder);
        assert(VTDecompressionSessionWaitForAsynchronousFrames(test.decoder) == noErr);
        assert(test.encoded == 4 && test.decoded == 4);
        VTDecompressionSessionInvalidate(test.decoder);
        CFRelease(test.decoder);
        VTCompressionSessionInvalidate(encoder);
        CFRelease(encoder);
        CVPixelBufferRelease(pixel);
        printf("PASS H264 profile %u: parameter sets and four-frame decode round trip\n", profile);
    }
    dlclose(library);
}
