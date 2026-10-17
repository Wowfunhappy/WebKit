// 10.9's H.264 decoder refuses a format description whose avcC SPS colour description lies outside
// colour_primaries 0-8, transfer_characteristics 0-12 and matrix_coefficients 0-8: a bare session, reached
// through VideoToolbox's own symbols, answers 10.9's bad-data status for the frame, and accepts every value
// within those ranges. Through the session functions the polyfill layer replaces, the same frame decodes from
// a description made with CMVideoFormatDescriptionCreate over its avcC and from one made with
// CMVideoFormatDescriptionCreateFromH264ParameterSets, the caller's description keeps its own avcC, and the
// session accepts that description. A sample whose data is not ready decodes once its make-data-ready callback
// succeeds, and answers the callback's status when it fails.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../polyfills/c/wk_symbols.h"

// One x264 Constrained Baseline key frame, 320x200, Annex B: AUD, SPS (colour_primaries 1,
// transfer_characteristics 13, matrix_coefficients 6), PPS, SEI, three IDR slices.
static const uint8_t keyFrame[] = {
    0x00, 0x00, 0x00, 0x01, 0x09, 0x10, 0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x14, 0xda, 0x05,
    0x06, 0xfe, 0x5c, 0x05, 0xa8, 0x08, 0x68, 0x35, 0x28, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00,
    0x03, 0x01, 0xe4, 0x78, 0xa1, 0x55, 0x00, 0x00, 0x00, 0x01, 0x68, 0xce, 0x3c, 0x80, 0x00, 0x00,
    0x00, 0x01, 0x06, 0x05, 0xff, 0xff, 0x9f, 0xdc, 0x45, 0xe9, 0xbd, 0xe6, 0xd9, 0x48, 0xb7, 0x96,
    0x2c, 0xd8, 0x20, 0xd9, 0x23, 0xee, 0xef, 0x78, 0x32, 0x36, 0x34, 0x20, 0x2d, 0x20, 0x63, 0x6f,
    0x72, 0x65, 0x20, 0x31, 0x36, 0x35, 0x20, 0x2d, 0x20, 0x48, 0x2e, 0x32, 0x36, 0x34, 0x2f, 0x4d,
    0x50, 0x45, 0x47, 0x2d, 0x34, 0x20, 0x41, 0x56, 0x43, 0x20, 0x63, 0x6f, 0x64, 0x65, 0x63, 0x20,
    0x2d, 0x20, 0x43, 0x6f, 0x70, 0x79, 0x6c, 0x65, 0x66, 0x74, 0x20, 0x32, 0x30, 0x30, 0x33, 0x2d,
    0x32, 0x30, 0x32, 0x35, 0x20, 0x2d, 0x20, 0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f, 0x77, 0x77,
    0x77, 0x2e, 0x76, 0x69, 0x64, 0x65, 0x6f, 0x6c, 0x61, 0x6e, 0x2e, 0x6f, 0x72, 0x67, 0x2f, 0x78,
    0x32, 0x36, 0x34, 0x2e, 0x68, 0x74, 0x6d, 0x6c, 0x20, 0x2d, 0x20, 0x6f, 0x70, 0x74, 0x69, 0x6f,
    0x6e, 0x73, 0x3a, 0x20, 0x63, 0x61, 0x62, 0x61, 0x63, 0x3d, 0x30, 0x20, 0x72, 0x65, 0x66, 0x3d,
    0x31, 0x20, 0x64, 0x65, 0x62, 0x6c, 0x6f, 0x63, 0x6b, 0x3d, 0x30, 0x3a, 0x30, 0x3a, 0x30, 0x20,
    0x61, 0x6e, 0x61, 0x6c, 0x79, 0x73, 0x65, 0x3d, 0x30, 0x3a, 0x30, 0x20, 0x6d, 0x65, 0x3d, 0x64,
    0x69, 0x61, 0x20, 0x73, 0x75, 0x62, 0x6d, 0x65, 0x3d, 0x30, 0x20, 0x70, 0x73, 0x79, 0x3d, 0x31,
    0x20, 0x70, 0x73, 0x79, 0x5f, 0x72, 0x64, 0x3d, 0x31, 0x2e, 0x30, 0x30, 0x3a, 0x30, 0x2e, 0x30,
    0x30, 0x20, 0x6d, 0x69, 0x78, 0x65, 0x64, 0x5f, 0x72, 0x65, 0x66, 0x3d, 0x30, 0x20, 0x6d, 0x65,
    0x5f, 0x72, 0x61, 0x6e, 0x67, 0x65, 0x3d, 0x31, 0x36, 0x20, 0x63, 0x68, 0x72, 0x6f, 0x6d, 0x61,
    0x5f, 0x6d, 0x65, 0x3d, 0x31, 0x20, 0x74, 0x72, 0x65, 0x6c, 0x6c, 0x69, 0x73, 0x3d, 0x30, 0x20,
    0x38, 0x78, 0x38, 0x64, 0x63, 0x74, 0x3d, 0x30, 0x20, 0x63, 0x71, 0x6d, 0x3d, 0x30, 0x20, 0x64,
    0x65, 0x61, 0x64, 0x7a, 0x6f, 0x6e, 0x65, 0x3d, 0x32, 0x31, 0x2c, 0x31, 0x31, 0x20, 0x66, 0x61,
    0x73, 0x74, 0x5f, 0x70, 0x73, 0x6b, 0x69, 0x70, 0x3d, 0x31, 0x20, 0x63, 0x68, 0x72, 0x6f, 0x6d,
    0x61, 0x5f, 0x71, 0x70, 0x5f, 0x6f, 0x66, 0x66, 0x73, 0x65, 0x74, 0x3d, 0x30, 0x20, 0x74, 0x68,
    0x72, 0x65, 0x61, 0x64, 0x73, 0x3d, 0x33, 0x20, 0x6c, 0x6f, 0x6f, 0x6b, 0x61, 0x68, 0x65, 0x61,
    0x64, 0x5f, 0x74, 0x68, 0x72, 0x65, 0x61, 0x64, 0x73, 0x3d, 0x33, 0x20, 0x73, 0x6c, 0x69, 0x63,
    0x65, 0x64, 0x5f, 0x74, 0x68, 0x72, 0x65, 0x61, 0x64, 0x73, 0x3d, 0x31, 0x20, 0x73, 0x6c, 0x69,
    0x63, 0x65, 0x73, 0x3d, 0x33, 0x20, 0x6e, 0x72, 0x3d, 0x30, 0x20, 0x64, 0x65, 0x63, 0x69, 0x6d,
    0x61, 0x74, 0x65, 0x3d, 0x31, 0x20, 0x69, 0x6e, 0x74, 0x65, 0x72, 0x6c, 0x61, 0x63, 0x65, 0x64,
    0x3d, 0x30, 0x20, 0x62, 0x6c, 0x75, 0x72, 0x61, 0x79, 0x5f, 0x63, 0x6f, 0x6d, 0x70, 0x61, 0x74,
    0x3d, 0x30, 0x20, 0x63, 0x6f, 0x6e, 0x73, 0x74, 0x72, 0x61, 0x69, 0x6e, 0x65, 0x64, 0x5f, 0x69,
    0x6e, 0x74, 0x72, 0x61, 0x3d, 0x30, 0x20, 0x62, 0x66, 0x72, 0x61, 0x6d, 0x65, 0x73, 0x3d, 0x30,
    0x20, 0x77, 0x65, 0x69, 0x67, 0x68, 0x74, 0x70, 0x3d, 0x30, 0x20, 0x6b, 0x65, 0x79, 0x69, 0x6e,
    0x74, 0x3d, 0x31, 0x35, 0x20, 0x6b, 0x65, 0x79, 0x69, 0x6e, 0x74, 0x5f, 0x6d, 0x69, 0x6e, 0x3d,
    0x31, 0x20, 0x73, 0x63, 0x65, 0x6e, 0x65, 0x63, 0x75, 0x74, 0x3d, 0x30, 0x20, 0x69, 0x6e, 0x74,
    0x72, 0x61, 0x5f, 0x72, 0x65, 0x66, 0x72, 0x65, 0x73, 0x68, 0x3d, 0x30, 0x20, 0x72, 0x63, 0x5f,
    0x6c, 0x6f, 0x6f, 0x6b, 0x61, 0x68, 0x65, 0x61, 0x64, 0x3d, 0x30, 0x20, 0x72, 0x63, 0x3d, 0x63,
    0x62, 0x72, 0x20, 0x6d, 0x62, 0x74, 0x72, 0x65, 0x65, 0x3d, 0x30, 0x20, 0x62, 0x69, 0x74, 0x72,
    0x61, 0x74, 0x65, 0x3d, 0x31, 0x30, 0x30, 0x30, 0x20, 0x72, 0x61, 0x74, 0x65, 0x74, 0x6f, 0x6c,
    0x3d, 0x31, 0x2e, 0x30, 0x20, 0x71, 0x63, 0x6f, 0x6d, 0x70, 0x3d, 0x30, 0x2e, 0x36, 0x30, 0x20,
    0x71, 0x70, 0x6d, 0x69, 0x6e, 0x3d, 0x30, 0x20, 0x71, 0x70, 0x6d, 0x61, 0x78, 0x3d, 0x36, 0x39,
    0x20, 0x71, 0x70, 0x73, 0x74, 0x65, 0x70, 0x3d, 0x34, 0x20, 0x76, 0x62, 0x76, 0x5f, 0x6d, 0x61,
    0x78, 0x72, 0x61, 0x74, 0x65, 0x3d, 0x31, 0x30, 0x30, 0x30, 0x20, 0x76, 0x62, 0x76, 0x5f, 0x62,
    0x75, 0x66, 0x73, 0x69, 0x7a, 0x65, 0x3d, 0x31, 0x32, 0x30, 0x20, 0x6e, 0x61, 0x6c, 0x5f, 0x68,
    0x72, 0x64, 0x3d, 0x6e, 0x6f, 0x6e, 0x65, 0x20, 0x66, 0x69, 0x6c, 0x6c, 0x65, 0x72, 0x3d, 0x30,
    0x20, 0x69, 0x70, 0x5f, 0x72, 0x61, 0x74, 0x69, 0x6f, 0x3d, 0x31, 0x2e, 0x34, 0x30, 0x20, 0x61,
    0x71, 0x3d, 0x30, 0x00, 0x80, 0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x05, 0xa8, 0x46, 0x28,
    0x00, 0x0a, 0x1f, 0xc7, 0x00, 0x01, 0x1a, 0x68, 0xe0, 0x00, 0x22, 0xf3, 0x27, 0x27, 0x27, 0x27,
    0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x27, 0x5d,
    0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75,
    0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7,
    0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x80, 0x00, 0x00, 0x00,
    0x01, 0x65, 0x02, 0x88, 0x88, 0x40, 0x5a, 0x84, 0x62, 0x80, 0x00, 0xa1, 0xfc, 0x70, 0x00, 0x11,
    0xa6, 0x8e, 0x00, 0x02, 0x2f, 0x32, 0x72, 0x72, 0x72, 0x72, 0x72, 0x72, 0x72, 0x72, 0x72, 0x72,
    0x72, 0x72, 0x72, 0x72, 0x72, 0x72, 0x72, 0x72, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7,
    0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d,
    0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75,
    0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7,
    0x5d, 0x75, 0xd7, 0x5d, 0x78, 0x00, 0x00, 0x00, 0x01, 0x65, 0x01, 0x6a, 0x22, 0x10, 0x16, 0xa1,
    0x18, 0xa0, 0x00, 0x28, 0x7f, 0x1c, 0x00, 0x04, 0x69, 0xa3, 0x80, 0x00, 0x8b, 0xcc, 0x9c, 0x9c,
    0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c, 0x9c,
    0x9d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d,
    0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75,
    0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x5e,
};

// The bit position of colour_primaries in the fixture's SPS RBSP, NAL header included.
enum { colourPrimariesPosition = 85 };

// 10.9 reports a bad-data decode as -8969, where the modern SDK's kVTVideoDecoderBadDataErr is -12909.
enum { badData = -8969 };

typedef struct {
    const uint8_t *data;
    size_t size;
} Unit;

static size_t units(Unit *out, size_t capacity)
{
    size_t count = 0, start = 0;
    int open = 0;
    for (size_t i = 0; i + 4 <= sizeof(keyFrame); ++i) {
        if (keyFrame[i] || keyFrame[i + 1] || keyFrame[i + 2] || keyFrame[i + 3] != 1)
            continue;
        if (open && count < capacity)
            out[count++] = (Unit) { keyFrame + start, i - start };
        start = i + 4;
        open = 1;
        i += 3;
    }
    if (open && count < capacity)
        out[count++] = (Unit) { keyFrame + start, sizeof(keyFrame) - start };
    return count;
}

// The SPS with its three colour fields replaced, escaped again, in |sps| (capacity 64); its length.
static size_t spsWithColour(const Unit *original, unsigned primaries, unsigned transfer, unsigned matrix, uint8_t *sps)
{
    uint8_t rbsp[64];
    size_t rbspSize = 0;
    unsigned zeros = 0;
    for (size_t i = 0; i < original->size; ++i) {
        if (zeros >= 2 && original->data[i] == 3) {
            zeros = 0;
            continue;
        }
        rbsp[rbspSize++] = original->data[i];
        zeros = original->data[i] ? 0 : zeros + 1;
    }
    unsigned values[3] = { primaries, transfer, matrix };
    for (unsigned field = 0; field < 3; ++field) {
        for (unsigned bit = 0; bit < 8; ++bit) {
            size_t position = colourPrimariesPosition + field * 8 + bit;
            uint8_t mask = (uint8_t)(1 << (7 - position % 8));
            if ((values[field] >> (7 - bit)) & 1)
                rbsp[position / 8] |= mask;
            else
                rbsp[position / 8] &= (uint8_t)~mask;
        }
    }
    size_t size = 0;
    zeros = 0;
    for (size_t i = 0; i < rbspSize; ++i) {
        if (zeros >= 2 && rbsp[i] <= 3) {
            sps[size++] = 3;
            zeros = 0;
        }
        sps[size++] = rbsp[i];
        zeros = rbsp[i] ? 0 : zeros + 1;
    }
    return size;
}

static CFDataRef avcC(const uint8_t *sps, size_t spsSize, const Unit *pps)
{
    uint8_t record[160];
    size_t size = 0;
    record[size++] = 1;
    record[size++] = sps[1];
    record[size++] = sps[2];
    record[size++] = sps[3];
    record[size++] = 0xff;
    record[size++] = 0xe1;
    record[size++] = (uint8_t)(spsSize >> 8);
    record[size++] = (uint8_t)spsSize;
    memcpy(record + size, sps, spsSize);
    size += spsSize;
    record[size++] = 1;
    record[size++] = (uint8_t)(pps->size >> 8);
    record[size++] = (uint8_t)pps->size;
    memcpy(record + size, pps->data, pps->size);
    size += pps->size;
    return CFDataCreate(NULL, record, (CFIndex)size);
}

static CMFormatDescriptionRef formatWithAvcC(CFDataRef record)
{
    const void *atomKeys[] = { CFSTR("avcC") };
    const void *atomValues[] = { record };
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, atomKeys, atomValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms };
    const void *values[] = { atoms };
    CFDictionaryRef extensions = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CMFormatDescriptionRef format = NULL;
    assert(!CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_H264, 320, 200, extensions, &format));
    CFRelease(extensions);
    CFRelease(atoms);
    return format;
}

struct Readiness {
    OSStatus status;
    int calls;
};

static OSStatus makeReady(CMSampleBufferRef sample, void *context)
{
    (void)sample;
    struct Readiness *readiness = context;
    ++readiness->calls;
    return readiness->status;
}

// A sample whose data is ready, or, given |readiness|, one made ready by its callback.
static CMSampleBufferRef sampleWithFormat(CMFormatDescriptionRef format, const Unit *slices, size_t sliceCount, struct Readiness *readiness)
{
    size_t length = 0;
    for (size_t i = 0; i < sliceCount; ++i)
        length += 4 + slices[i].size;
    uint8_t *bytes = malloc(length);
    size_t offset = 0;
    for (size_t i = 0; i < sliceCount; ++i) {
        uint32_t size = (uint32_t)slices[i].size;
        bytes[offset++] = (uint8_t)(size >> 24);
        bytes[offset++] = (uint8_t)(size >> 16);
        bytes[offset++] = (uint8_t)(size >> 8);
        bytes[offset++] = (uint8_t)size;
        memcpy(bytes + offset, slices[i].data, slices[i].size);
        offset += slices[i].size;
    }
    CMBlockBufferRef block = NULL;
    assert(!CMBlockBufferCreateWithMemoryBlock(NULL, bytes, length, kCFAllocatorMalloc, NULL, 0, length, 0, &block));
    CMSampleBufferRef sample = NULL;
    assert(!CMSampleBufferCreate(NULL, block, !readiness, readiness ? makeReady : NULL, readiness, format, 1, 0, NULL, 1, &length, &sample));
    CFRelease(block);
    return sample;
}

typedef OSStatus (*CreateFunction)(CFAllocatorRef, CMVideoFormatDescriptionRef, CFDictionaryRef, CFDictionaryRef,
    const VTDecompressionOutputCallbackRecord *, VTDecompressionSessionRef *);
typedef OSStatus (*DecodeFunction)(VTDecompressionSessionRef, CMSampleBufferRef, VTDecodeFrameFlags, void *, VTDecodeInfoFlags *);
typedef Boolean (*CanAcceptFunction)(VTDecompressionSessionRef, CMFormatDescriptionRef);

struct Output {
    OSStatus status;
    int images;
};

static void decoded(void *context, void *frame, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef image, CMTime pts, CMTime duration)
{
    (void)frame;
    (void)flags;
    (void)pts;
    (void)duration;
    struct Output *output = context;
    output->status = status;
    output->images += image != NULL;
}

// The status a session made by |create| from |format| answers |sample| with, from the call or its output.
static OSStatus decode(CreateFunction create, DecodeFunction decodeFrame, CMFormatDescriptionRef format, CMSampleBufferRef sample, int *images)
{
    struct Output output = { 0, 0 };
    VTDecompressionOutputCallbackRecord callback = { decoded, &output };
    VTDecompressionSessionRef session = NULL;
    OSStatus status = create(NULL, format, NULL, NULL, &callback, &session);
    if (status)
        return status;
    status = decodeFrame(session, sample, 0, NULL, NULL);
    VTDecompressionSessionWaitForAsynchronousFrames(session);
    VTDecompressionSessionInvalidate(session);
    CFRelease(session);
    if (images)
        *images = output.images;
    return status ? status : output.status;
}

int main(void)
{
    Unit found[16];
    size_t count = units(found, 16);
    const Unit *sps = NULL, *pps = NULL;
    Unit slices[8];
    size_t sliceCount = 0;
    for (size_t i = 0; i < count; ++i) {
        unsigned type = found[i].data[0] & 0x1f;
        if (type == 7)
            sps = &found[i];
        else if (type == 8)
            pps = &found[i];
        else if (type == 5 && sliceCount < 8)
            slices[sliceCount++] = found[i];
    }
    assert(sps && pps && sliceCount);

    // dlsym answers a replaced name with the replacement, so the system's entry points come from VideoToolbox's
    // own symbol table.
    wk_image videoToolbox;
    assert(wk_find_image("/System/Library/Frameworks/VideoToolbox.framework/Versions/A/VideoToolbox", &videoToolbox));
    CreateFunction systemCreate = (CreateFunction)wk_symbol_in_image(&videoToolbox, "_VTDecompressionSessionCreate");
    DecodeFunction systemDecode = (DecodeFunction)wk_symbol_in_image(&videoToolbox, "_VTDecompressionSessionDecodeFrame");
    assert(systemCreate && systemDecode && (void *)systemCreate != (void *)VTDecompressionSessionCreate);

    int failures = 0;
    // The premise, on bare sessions: each field swept over 0-255 with the other two at the fixture's in-range
    // BT.709/BT.709/BT.601 values.
    static const unsigned limits[3] = { 8, 12, 8 };
    static const char *names[3] = { "colour_primaries", "transfer_characteristics", "matrix_coefficients" };
    for (unsigned field = 0; field < 3; ++field) {
        for (unsigned value = 0; value < 256; ++value) {
            unsigned colour[3] = { 1, 1, 6 };
            colour[field] = value;
            uint8_t edited[64];
            size_t size = spsWithColour(sps, colour[0], colour[1], colour[2], edited);
            CFDataRef record = avcC(edited, size, pps);
            CMFormatDescriptionRef format = formatWithAvcC(record);
            CMSampleBufferRef sample = sampleWithFormat(format, slices, sliceCount, NULL);
            OSStatus status = decode(systemCreate, systemDecode, format, sample, NULL);
            OSStatus expected = value <= limits[field] ? noErr : badData;
            if (status != expected) {
                printf("FAIL bare session, %s %u: %d, expected %d\n", names[field], value, (int)status, (int)expected);
                ++failures;
            }
            CFRelease(sample);
            CFRelease(format);
            CFRelease(record);
        }
    }

    // The fixture itself, transfer_characteristics 13.
    CFDataRef record = avcC(sps->data, sps->size, pps);
    CMFormatDescriptionRef format = formatWithAvcC(record);
    const uint8_t *parameterSets[2] = { sps->data, pps->data };
    size_t parameterSetSizes[2] = { sps->size, pps->size };
    CMFormatDescriptionRef parameterSetFormat = NULL;
    assert(!CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, parameterSets, parameterSetSizes, 4, &parameterSetFormat));
    CMFormatDescriptionRef formats[2] = { format, parameterSetFormat };
    static const char *paths[2] = { "CMVideoFormatDescriptionCreate", "CMVideoFormatDescriptionCreateFromH264ParameterSets" };
    for (unsigned path = 0; path < 2; ++path) {
        CMSampleBufferRef sample = sampleWithFormat(formats[path], slices, sliceCount, NULL);
        OSStatus bare = decode(systemCreate, systemDecode, formats[path], sample, NULL);
        if (bare != badData) {
            printf("FAIL bare session, %s: %d, expected %d\n", paths[path], (int)bare, (int)badData);
            ++failures;
        }
        int images = 0;
        OSStatus status = decode(VTDecompressionSessionCreate, VTDecompressionSessionDecodeFrame, formats[path], sample, &images);
        if (status || images != 1) {
            printf("FAIL %s: %d with %d image(s)\n", paths[path], (int)status, images);
            ++failures;
        }

        VTDecompressionOutputCallbackRecord callback = { decoded, &(struct Output) { 0, 0 } };
        VTDecompressionSessionRef session = NULL;
        assert(!VTDecompressionSessionCreate(NULL, formats[path], NULL, NULL, &callback, &session));
        if (!VTDecompressionSessionCanAcceptFormatDescription(session, formats[path])) {
            printf("FAIL %s: the session does not accept the description it was made from\n", paths[path]);
            ++failures;
        }
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
        CFRelease(sample);

        // A sample whose data its callback makes ready decodes; one whose callback fails answers that failure.
        static const OSStatus readyStatuses[2] = { noErr, -12345 };
        for (unsigned ready = 0; ready < 2; ++ready) {
            struct Readiness readiness = { readyStatuses[ready], 0 };
            CMSampleBufferRef pending = sampleWithFormat(formats[path], slices, sliceCount, &readiness);
            images = 0;
            status = decode(VTDecompressionSessionCreate, VTDecompressionSessionDecodeFrame, formats[path], pending, &images);
            int expectedImages = readiness.status ? 0 : 1;
            if (status != readiness.status || images != expectedImages || readiness.calls != 1
                || CMSampleBufferDataIsReady(pending) != !readiness.status) {
                printf("FAIL %s, data made ready with %d: %d with %d image(s), %d callback(s), ready %d\n", paths[path],
                    (int)readiness.status, (int)status, images, readiness.calls, (int)CMSampleBufferDataIsReady(pending));
                ++failures;
            }
            CFRelease(pending);
        }
    }
    CFDictionaryRef atoms = CMFormatDescriptionGetExtension(format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!CFEqual(CFDictionaryGetValue(atoms, CFSTR("avcC")), record)) {
        printf("FAIL the caller's description lost its own avcC\n");
        ++failures;
    }
    CFRelease(parameterSetFormat);
    CFRelease(format);
    CFRelease(record);

    printf("VideoToolbox decode colour description: %d failure(s)\n", failures);
    return !!failures;
}
