#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

typedef struct OpaqueVTPixelBufferConformer *VTPixelBufferConformerRef;
extern OSStatus VTPixelBufferConformerCopyConformedPixelBuffer(VTPixelBufferConformerRef, CVPixelBufferRef, Boolean, CVPixelBufferRef *);
static OSStatus (*createConformer)(CFAllocatorRef, CFDictionaryRef, VTPixelBufferConformerRef *);

static const unsigned char colors[][3] = {
    { 253, 0, 0 }, { 0, 250, 0 }, { 0, 0, 255 }, { 255, 0, 0 },
    { 0, 255, 255 }, { 255, 255, 0 }, { 0, 0, 0 }, { 255, 255, 255 }, { 128, 128, 128 }
};

static VTPixelBufferConformerRef conformer(OSType format, unsigned width, unsigned height)
{
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef keys[] = { kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferWidthKey, kCVPixelBufferHeightKey };
    unsigned values[] = { format, width, height };
    for (unsigned i = 0; i < 3; ++i) {
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &values[i]);
        CFDictionarySetValue(attributes, keys[i], number);
        CFRelease(number);
    }
    CFDictionaryRef surface = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey, surface);
    CFRelease(surface);
    VTPixelBufferConformerRef result = NULL;
    assert(!createConformer(NULL, attributes, &result));
    CFRelease(attributes);
    return result;
}

static CVPixelBufferRef source(unsigned width, unsigned height, OSType format, CFStringRef matrix, Boolean tagged)
{
    CVPixelBufferRef result = NULL;
    assert(!CVPixelBufferCreate(NULL, width, height, format, NULL, &result));
    assert(!CVPixelBufferLockBaseAddress(result, 0));
    size_t stride = CVPixelBufferGetBytesPerRow(result);
    unsigned char *base = CVPixelBufferGetBaseAddress(result);
    for (unsigned y = 0; y < height; ++y) {
        for (unsigned x = 0; x < width; ++x) {
            const unsigned char *rgb = colors[(x * 9) / width];
            unsigned char *pixel = base + y * stride + x * 4;
            if (format == kCVPixelFormatType_32BGRA) {
                pixel[0] = rgb[2]; pixel[1] = rgb[1]; pixel[2] = rgb[0]; pixel[3] = 255;
            } else {
                pixel[0] = 255; pixel[1] = rgb[0]; pixel[2] = rgb[1]; pixel[3] = rgb[2];
            }
        }
    }
    assert(!CVPixelBufferUnlockBaseAddress(result, 0));
    if (matrix)
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    if (tagged) {
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    }
    return result;
}

static double clamp(double value)
{
    return fmax(0, fmin(255, value));
}

static void checkColors(CVPixelBufferRef output, CFStringRef expectedMatrix)
{
    assert(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    assert(CVPixelBufferGetIOSurface(output));
    CFTypeRef matrix = CVBufferGetAttachment(output, kCVImageBufferYCbCrMatrixKey, NULL);
    assert(matrix && CFEqual(matrix, expectedMatrix));
    double kr, kb;
    if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) { kr = .299; kb = .114; }
    else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) { kr = .2126; kb = .0722; }
    else if (CFEqual(matrix, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) { kr = .212; kb = .087; }
    else { assert(CFEqual(matrix, CFSTR("ITU_R_2020"))); kr = .2627; kb = .0593; }
    assert(!CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly));
    const unsigned char *luma = CVPixelBufferGetBaseAddressOfPlane(output, 0);
    const unsigned char *chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1);
    size_t width = CVPixelBufferGetWidth(output);
    for (size_t row = 0; row < CVPixelBufferGetHeightOfPlane(output, 1); ++row) {
        for (size_t column = 0; column < ((width + 1) / 2) * 2; ++column)
            assert(chroma[row * CVPixelBufferGetBytesPerRowOfPlane(output, 1) + column] >= 1);
    }
    for (unsigned i = 0; i < 9; ++i) {
        size_t x = ((2 * i + 1) * width / 18) & ~(size_t)1;
        double y = luma[x], cb = chroma[x] - 128., cr = chroma[x + 1] - 128.;
        double rgb[] = { y + 2 * (1 - kr) * cr,
            y - 2 * kb * (1 - kb) / (1 - kr - kb) * cb - 2 * kr * (1 - kr) / (1 - kr - kb) * cr,
            y + 2 * (1 - kb) * cb };
        for (unsigned c = 0; c < 3; ++c) {
            if (fabs(clamp(rgb[c]) - colors[i][c]) > 2) {
                fprintf(stderr, "color %u channel %u: %.3f expected %u (YUV %.0f %.0f %.0f)\n", i, c, clamp(rgb[c]), colors[i][c], y, cb + 128, cr + 128);
                assert(0);
            }
        }
        assert(chroma[x] && chroma[x + 1]);
    }
    assert(luma[(7 * width / 9 + width / 18)] == 255);
    assert(luma[(6 * width / 9 + width / 18)] == 0);
    assert(!CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly));
}

static void checkAllocation(void)
{
    CVPixelBufferRef input = source(486, 720, kCVPixelFormatType_32BGRA, NULL, false);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int fullRange = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, videoRange = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, alignment = 128;
    CFNumberRef formats[] = { CFNumberCreate(NULL, kCFNumberIntType, &fullRange), CFNumberCreate(NULL, kCFNumberIntType, &videoRange) };
    CFNumberRef align = CFNumberCreate(NULL, kCFNumberIntType, &alignment);
    CFDictionarySetValue(attributes, kCVPixelBufferBytesPerRowAlignmentKey, align);
    CFRelease(align);
    for (unsigned formatCount = 0; formatCount < 3; ++formatCount) {
        CFTypeRef value = formatCount ? (CFTypeRef)CFArrayCreate(NULL, (const void **)formats, formatCount, &kCFTypeArrayCallBacks) : CFRetain(formats[0]);
        CFDictionarySetValue(attributes, kCVPixelBufferPixelFormatTypeKey, value);
        CFRelease(value);
        VTPixelBufferConformerRef converter = NULL;
        assert(!createConformer(NULL, attributes, &converter));
        CVPixelBufferRef output = NULL;
        assert(!VTPixelBufferConformerCopyConformedPixelBuffer(converter, input, true, &output));
        assert(CVPixelBufferGetWidth(output) == 486 && CVPixelBufferGetHeight(output) == 720);
        assert(!(CVPixelBufferGetBytesPerRowOfPlane(output, 0) % alignment));
        assert(!(CVPixelBufferGetBytesPerRowOfPlane(output, 1) % alignment));
        checkColors(output, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
        assert(!CVBufferGetAttachment(input, kCVImageBufferYCbCrMatrixKey, NULL));
        CFRelease(output);
        CFRelease(converter);
    }
    CFRelease(formats[0]); CFRelease(formats[1]); CFRelease(attributes); CFRelease(input);
}

int main(void)
{
    void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW);
    assert(vt);
    createConformer = dlsym(vt, "VTPixelBufferConformerCreateWithAttributes");
    assert(createConformer);
    checkAllocation();
    CFStringRef matrices[] = { NULL, kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995, CFSTR("ITU_R_2020") };
    const unsigned sizes[][3] = { { 486, 272, 1 }, { 486, 720, 1 }, { 486, 272, 2 }, { 485, 273, 1 } };
    unsigned count = 0;
    for (unsigned format = 0; format < 2; ++format) {
        for (unsigned size = 0; size < 4; ++size) {
            unsigned width = sizes[size][0], height = sizes[size][1], scale = sizes[size][2];
            CFStringRef defaultMatrix = height * scale >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4;
            for (unsigned matrix = 0; matrix < 5; ++matrix) {
                for (unsigned tagged = 0; tagged < 2; ++tagged) {
                    CFStringRef expectedMatrix = matrices[matrix] ? matrices[matrix] : defaultMatrix;
                    CVPixelBufferRef input = source(width, height, format ? kCVPixelFormatType_32ARGB : kCVPixelFormatType_32BGRA, matrices[matrix], tagged);
                    VTPixelBufferConformerRef converter = conformer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width * scale, height * scale);
                    CVPixelBufferRef output = NULL;
                    assert(!VTPixelBufferConformerCopyConformedPixelBuffer(converter, input, false, &output));
                    assert(output != input);
                    assert(CVPixelBufferGetWidth(output) == width * scale && CVPixelBufferGetHeight(output) == height * scale);
                    checkColors(output, expectedMatrix);
                    CFStringRef keys[] = { kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey };
                    for (unsigned k = 0; k < 2; ++k) {
                        CFTypeRef expected = CVBufferGetAttachment(input, keys[k], NULL);
                        CFTypeRef actual = CVBufferGetAttachment(output, keys[k], NULL);
                        assert(expected ? actual && CFEqual(expected, actual) : !actual);
                    }
                    if (!tagged) {
                        VTPixelTransferSessionRef session = NULL;
                        assert(!VTPixelTransferSessionCreate(NULL, &session));
                        assert(!VTPixelTransferSessionTransferImage(session, input, output));
                        checkColors(output, defaultMatrix);
                        expectedMatrix = defaultMatrix;
                        VTPixelTransferSessionInvalidate(session);
                        CFRelease(session);
                    }
                    CVPixelBufferRef same = NULL, copy = NULL;
                    assert(!VTPixelBufferConformerCopyConformedPixelBuffer(converter, output, false, &same));
                    assert(same == output);
                    assert(!VTPixelBufferConformerCopyConformedPixelBuffer(converter, output, true, &copy));
                    assert(copy != output);
                    assert(!CVPixelBufferLockBaseAddress(copy, 0));
                    ((unsigned char *)CVPixelBufferGetBaseAddressOfPlane(copy, 0))[0] = 0;
                    assert(!CVPixelBufferUnlockBaseAddress(copy, 0));
                    checkColors(output, expectedMatrix);
                    CFRelease(copy); CFRelease(same); CFRelease(output); CFRelease(converter); CFRelease(input);
                    ++count;
                }
            }
        }
    }
    printf("PASS: %u RGB/metadata conversions with IOSurfaces, scaling, odd dimensions, full range and matching matrices; direct transfers, pass-through and independent copies\n", count);
    return 0;
}
