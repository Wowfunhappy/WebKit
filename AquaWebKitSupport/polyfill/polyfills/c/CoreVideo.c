// CoreVideo: entry points modern WebKit calls that 10.9's CoreVideo does not export. The colour-space
// constants live in polyfills/shared/cv_colorimetry.c, which the deps builds compile too.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdbool.h>
#include <string.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>

// CVBufferCopyAttachments (macOS 12) is CVBufferGetAttachments with +1 ownership.
WK_SYSTEM_FN("CoreVideo", CFDictionaryRef, CVBufferGetAttachments, (CVBufferRef, CVAttachmentMode));
WK_POLYFILL_ABSENT("CoreVideo", CFDictionaryRef, CVBufferCopyAttachments, (CVBufferRef buffer, CVAttachmentMode mode))
{
    if (!WK_SYSTEM(CVBufferGetAttachments))
        return NULL;
    // A COPY, not a retain: 10.9's CVBufferGetAttachments hands back the buffer's live mutable
    // dictionary (measured — the same pointer mutates under a later CVBufferSetAttachment), and the
    // contract promises a snapshot the caller owns. An absent-or-empty set is the documented NULL.
    CFDictionaryRef attachments = WK_SYSTEM(CVBufferGetAttachments)(buffer, mode);
    if (!attachments || !CFDictionaryGetCount(attachments))
        return NULL;
    return CFDictionaryCreateCopy(kCFAllocatorDefault, attachments);
}

// CVImageBufferCreateColorSpaceFromAttachments reads the dictionary without checking it: 10.9 passes it
// straight to CFDictionaryGetValue, so a NULL attachment set faults there. Callers treat a NULL return as
// "no colour space in the attachments" and pick a fallback -- WebCore's createCGColorSpaceForCVPixelBuffer
// falls back to sRGB -- and reach this with NULL whenever the buffer carries no attachments, which is
// what CVBufferCopyAttachments above answers for an absent-or-empty set.
//
// 10.9 synthesizes a space only from all three of primaries, transfer function and matrix, and writes every
// value later than itself as QuickTime 'nclc' code 2, "unspecified": that transfer function draws with a
// 1.8 gamma and those primaries with BT.709's colorants (measured: the sRGB transfer function maps grey 100
// to 119, and P3 or BT.2020 primaries paint red as BT.709 ones do). The later values resolve as follows:
// - ITU_R_2020 is the BT.709 transfer function (CVImageBuffer.h: "kCVImageBufferTransferFunction_ITU_R_709_2
//   is equivalent, and preferred"), and a matrix has no part in the colour space.
// - The sRGB transfer function is this CoreGraphics' sRGB profile; the linear one is a 1.0 exponent.
// - P3 and BT.2020 primaries replace the colorants of the profile for the same transfer function on BT.709
//   primaries, Bradford-adapted to the D50 white of the profile connection space.
// - PQ, HLG and SMPTE ST 428-1 signals have no 10.9 colour space, so they synthesize none.
WK_SYSTEM_FN("CoreVideo", CGColorSpaceRef, CVImageBufferCreateColorSpaceFromAttachments, (CFDictionaryRef));
WK_SYSTEM_FN("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithName, (CFStringRef));

// CIE 1931 xy chromaticities of the red, green and blue primaries and of the white point.
typedef struct {
    CFStringRef name;
    bool isLaterThan10_9;
    double red[2], green[2], blue[2], white[2];
} wk_cv_primaries;

static bool wk_cv_isString(CFTypeRef value, CFStringRef string)
{
    return value && CFGetTypeID(value) == CFStringGetTypeID() && CFEqual(value, string);
}

static const wk_cv_primaries *wk_cv_lookupPrimaries(CFTypeRef value)
{
    static const wk_cv_primaries table[] = {
        { CFSTR("ITU_R_709_2"), false, { 0.64, 0.33 }, { 0.30, 0.60 }, { 0.15, 0.06 }, { 0.3127, 0.3290 } },
        { CFSTR("EBU_3213"), false, { 0.64, 0.33 }, { 0.29, 0.60 }, { 0.15, 0.06 }, { 0.3127, 0.3290 } },
        { CFSTR("SMPTE_C"), false, { 0.630, 0.340 }, { 0.310, 0.595 }, { 0.155, 0.070 }, { 0.3127, 0.3290 } },
        { CFSTR("P22"), false, { 0.625, 0.340 }, { 0.280, 0.595 }, { 0.155, 0.070 }, { 0.3127, 0.3290 } },
        { CFSTR("DCI_P3"), true, { 0.680, 0.320 }, { 0.265, 0.690 }, { 0.150, 0.060 }, { 0.314, 0.351 } },
        { CFSTR("P3_D65"), true, { 0.680, 0.320 }, { 0.265, 0.690 }, { 0.150, 0.060 }, { 0.3127, 0.3290 } },
        { CFSTR("ITU_R_2020"), true, { 0.708, 0.292 }, { 0.170, 0.797 }, { 0.131, 0.046 }, { 0.3127, 0.3290 } },
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        if (wk_cv_isString(value, table[i].name))
            return &table[i];
    }
    return NULL;
}

static bool wk_cv_invert(const double m[9], double out[9])
{
    double determinant = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (fabs(determinant) < 1e-12)
        return false;
    out[0] = (m[4] * m[8] - m[5] * m[7]) / determinant;
    out[1] = (m[2] * m[7] - m[1] * m[8]) / determinant;
    out[2] = (m[1] * m[5] - m[2] * m[4]) / determinant;
    out[3] = (m[5] * m[6] - m[3] * m[8]) / determinant;
    out[4] = (m[0] * m[8] - m[2] * m[6]) / determinant;
    out[5] = (m[2] * m[3] - m[0] * m[5]) / determinant;
    out[6] = (m[3] * m[7] - m[4] * m[6]) / determinant;
    out[7] = (m[1] * m[6] - m[0] * m[7]) / determinant;
    out[8] = (m[0] * m[4] - m[1] * m[3]) / determinant;
    return true;
}

static void wk_cv_multiply(const double a[9], const double b[9], double out[9])
{
    for (unsigned row = 0; row < 3; row++) {
        for (unsigned column = 0; column < 3; column++)
            out[3 * row + column] = a[3 * row] * b[column] + a[3 * row + 1] * b[3 + column] + a[3 * row + 2] * b[6 + column];
    }
}

static void wk_cv_whiteXYZ(const double white[2], double xyz[3])
{
    xyz[0] = white[0] / white[1];
    xyz[1] = 1;
    xyz[2] = (1 - white[0] - white[1]) / white[1];
}

// The RGB-to-XYZ matrix of `primaries`, row-major, one column per primary, scaled so RGB white is the
// white point at Y = 1.
static bool wk_cv_rgbToXYZ(const wk_cv_primaries *primaries, double matrix[9])
{
    const double *chromaticities[3] = { primaries->red, primaries->green, primaries->blue };
    double unscaled[9];
    for (unsigned column = 0; column < 3; column++) {
        double x = chromaticities[column][0], y = chromaticities[column][1];
        unscaled[column] = x / y;
        unscaled[3 + column] = 1;
        unscaled[6 + column] = (1 - x - y) / y;
    }
    double inverse[9], white[3], scale[3];
    if (!wk_cv_invert(unscaled, inverse))
        return false;
    wk_cv_whiteXYZ(primaries->white, white);
    for (unsigned row = 0; row < 3; row++)
        scale[row] = inverse[3 * row] * white[0] + inverse[3 * row + 1] * white[1] + inverse[3 * row + 2] * white[2];
    for (unsigned row = 0; row < 3; row++) {
        for (unsigned column = 0; column < 3; column++)
            matrix[3 * row + column] = unscaled[3 * row + column] * scale[column];
    }
    return true;
}

// The colorants of `primaries` as ICC XYZType values: Bradford-adapted to D50, one row per primary, in
// s15Fixed16.
static bool wk_cv_colorantsD50(const wk_cv_primaries *primaries, uint32_t colorants[3][3])
{
    static const double bradford[9] = { 0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296 };
    static const double d50[3] = { 0.9642, 1.0, 0.8249 };
    double rgbToXYZ[9], bradfordInverse[9], white[3], coneSource[3], coneTarget[3];
    if (!wk_cv_rgbToXYZ(primaries, rgbToXYZ) || !wk_cv_invert(bradford, bradfordInverse))
        return false;
    wk_cv_whiteXYZ(primaries->white, white);
    for (unsigned row = 0; row < 3; row++) {
        coneSource[row] = bradford[3 * row] * white[0] + bradford[3 * row + 1] * white[1] + bradford[3 * row + 2] * white[2];
        coneTarget[row] = bradford[3 * row] * d50[0] + bradford[3 * row + 1] * d50[1] + bradford[3 * row + 2] * d50[2];
    }
    double scaled[9], adaptation[9], adapted[9];
    for (unsigned row = 0; row < 3; row++) {
        for (unsigned column = 0; column < 3; column++)
            scaled[3 * row + column] = bradford[3 * row + column] * coneTarget[row] / coneSource[row];
    }
    wk_cv_multiply(bradfordInverse, scaled, adaptation);
    wk_cv_multiply(adaptation, rgbToXYZ, adapted);
    for (unsigned primary = 0; primary < 3; primary++) {
        for (unsigned component = 0; component < 3; component++)
            colorants[primary][component] = (uint32_t)(int32_t)lround(adapted[3 * component + primary] * 65536.0);
    }
    return true;
}

static uint32_t wk_cv_readUInt32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void wk_cv_writeUInt32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)(value >> 24);
    p[1] = (uint8_t)(value >> 16);
    p[2] = (uint8_t)(value >> 8);
    p[3] = (uint8_t)value;
}

// `base`'s ICC profile with its rXYZ, gXYZ and bXYZ colorant tags replaced by those of `primaries`.
static CGColorSpaceRef wk_cv_createWithPrimaries(CGColorSpaceRef base, const wk_cv_primaries *primaries)
{
    uint32_t colorants[3][3];
    if (!base || !wk_cv_colorantsD50(primaries, colorants))
        return NULL;
    CFDataRef baseProfile = CGColorSpaceCopyICCProfile(base);
    if (!baseProfile)
        return NULL;
    CFMutableDataRef profile = CFDataCreateMutableCopy(NULL, 0, baseProfile);
    CFRelease(baseProfile);
    if (!profile)
        return NULL;

    // The tag table follows the 128-byte header: a count, then one 12-byte entry per tag carrying its
    // signature, its offset from the start of the profile and its size. An XYZType tag is its signature,
    // 4 reserved bytes and three s15Fixed16 numbers.
    static const char *const colorantTags[3] = { "rXYZ", "gXYZ", "bXYZ" };
    uint8_t *bytes = CFDataGetMutableBytePtr(profile);
    size_t length = (size_t)CFDataGetLength(profile);
    unsigned colorantsWritten = 0;
    uint32_t tagCount = length >= 132 ? wk_cv_readUInt32(bytes + 128) : 0;
    for (uint32_t i = 0; i < tagCount && 132 + 12 * (size_t)(i + 1) <= length; i++) {
        const uint8_t *entry = bytes + 132 + 12 * (size_t)i;
        uint32_t offset = wk_cv_readUInt32(entry + 4);
        uint32_t size = wk_cv_readUInt32(entry + 8);
        if (offset > length || size > length - offset || size < 20 || memcmp(bytes + offset, "XYZ ", 4))
            continue;
        for (unsigned c = 0; c < 3; c++) {
            if (memcmp(entry, colorantTags[c], 4))
                continue;
            for (unsigned component = 0; component < 3; component++)
                wk_cv_writeUInt32(bytes + offset + 8 + 4 * component, colorants[c][component]);
            colorantsWritten++;
        }
    }

    CGColorSpaceRef space = colorantsWritten == 3 ? CGColorSpaceCreateWithICCProfile(profile) : NULL;
    CFRelease(profile);
    return space;
}

static CGColorSpaceRef wk_cv_createLinear(const wk_cv_primaries *primaries)
{
    double rgbToXYZ[9];
    if (!wk_cv_rgbToXYZ(primaries, rgbToXYZ))
        return NULL;
    CGFloat whitePoint[3], matrix[9];
    double white[3];
    wk_cv_whiteXYZ(primaries->white, white);
    for (unsigned component = 0; component < 3; component++)
        whitePoint[component] = (CGFloat)white[component];
    for (unsigned primary = 0; primary < 3; primary++) {
        for (unsigned component = 0; component < 3; component++)
            matrix[3 * primary + component] = (CGFloat)rgbToXYZ[3 * component + primary];
    }
    const CGFloat blackPoint[3] = { 0, 0, 0 };
    const CGFloat gamma[3] = { 1, 1, 1 };
    return CGColorSpaceCreateCalibratedRGB(whitePoint, blackPoint, gamma, matrix);
}

WK_POLYFILL_REPLACES("CoreVideo", CGColorSpaceRef, CVImageBufferCreateColorSpaceFromAttachments,
    (CFDictionaryRef attachments))
{
    if (!attachments || !WK_SYSTEM(CVImageBufferCreateColorSpaceFromAttachments))
        return NULL;

    CFTypeRef primariesValue = CFDictionaryGetValue(attachments, kCVImageBufferColorPrimariesKey);
    CFTypeRef transfer = CFDictionaryGetValue(attachments, kCVImageBufferTransferFunctionKey);
    CFTypeRef matrix = CFDictionaryGetValue(attachments, kCVImageBufferYCbCrMatrixKey);
    if (CFDictionaryContainsKey(attachments, kCVImageBufferICCProfileKey) || !primariesValue || !transfer)
        return WK_SYSTEM(CVImageBufferCreateColorSpaceFromAttachments)(attachments);

    // RGB buffers carry primaries and transfer without a YCbCr matrix. 10.9 requires the
    // matrix key to synthesize an ICC profile, whose colorants and curves are independent of it.
    if (!matrix) {
        CFMutableDictionaryRef rgbAttachments = CFDictionaryCreateMutableCopy(NULL, 0, attachments);
        if (!rgbAttachments)
            return NULL;
        CFDictionarySetValue(rgbAttachments, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
        CGColorSpaceRef space = CVImageBufferCreateColorSpaceFromAttachments(rgbAttachments);
        CFRelease(rgbAttachments);
        return space;
    }

    if (wk_cv_isString(transfer, CFSTR("SMPTE_ST_2084_PQ")) || wk_cv_isString(transfer, CFSTR("ITU_R_2100_HLG")) || wk_cv_isString(transfer, CFSTR("SMPTE_ST_428_1")))
        return NULL;

    const wk_cv_primaries *primaries = wk_cv_lookupPrimaries(primariesValue);
    bool primariesAreLater = primaries && primaries->isLaterThan10_9;
    bool sRGBTransfer = wk_cv_isString(transfer, CFSTR("IEC_sRGB"));
    bool linearTransfer = wk_cv_isString(transfer, CFSTR("Linear"));
    bool bt2020Transfer = wk_cv_isString(transfer, CFSTR("ITU_R_2020"));
    bool bt2020Matrix = wk_cv_isString(matrix, CFSTR("ITU_R_2020"));
    if (!primaries || (!primariesAreLater && !sRGBTransfer && !linearTransfer && !bt2020Transfer && !bt2020Matrix))
        return WK_SYSTEM(CVImageBufferCreateColorSpaceFromAttachments)(attachments);

    if (linearTransfer)
        return wk_cv_createLinear(primaries);

    if (sRGBTransfer) {
        if (!WK_SYSTEM(CGColorSpaceCreateWithName))
            return NULL;
        CGColorSpaceRef sRGB = WK_SYSTEM(CGColorSpaceCreateWithName)(kCGColorSpaceSRGB);
        if (wk_cv_isString(primariesValue, kCVImageBufferColorPrimaries_ITU_R_709_2) || !sRGB)
            return sRGB;
        CGColorSpaceRef space = wk_cv_createWithPrimaries(sRGB, primaries);
        CGColorSpaceRelease(sRGB);
        return space;
    }

    // A transfer function 10.9 knows: 10.9 builds the profile on primaries it knows, and later primaries
    // take that profile's curves.
    CFMutableDictionaryRef resolved = CFDictionaryCreateMutableCopy(NULL, 0, attachments);
    if (!resolved)
        return NULL;
    if (bt2020Transfer)
        CFDictionarySetValue(resolved, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2);
    if (bt2020Matrix)
        CFDictionarySetValue(resolved, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    if (primariesAreLater)
        CFDictionarySetValue(resolved, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2);
    CGColorSpaceRef base = WK_SYSTEM(CVImageBufferCreateColorSpaceFromAttachments)(resolved);
    CFRelease(resolved);
    if (!primariesAreLater || !base)
        return base;
    CGColorSpaceRef space = wk_cv_createWithPrimaries(base, primaries);
    CGColorSpaceRelease(base);
    return space;
}
