// ICC profiles handed to ColorSync. 10.9's CMMLutTag::InitializeCurveTable reads a parametric ('para')
// curve of an lutAToB ('mAB ') or lutBToA ('mBA ') tag with its function type at byte 2 instead of byte 8,
// so it rejects every such curve. An RGB profile whose lut tags are all one matrix/TRC transform is given
// to ColorSync as that matrix/TRC profile, its parametric curves intact. Any other is given with each of those
// curves sampled as a 'curv' of WK_ICC_CURVE_SAMPLES points; in a lut tag 10.9 evaluates no curve below
// x/16. Every other byte of every tag is the profile's own. The profile ID, a digest of the original
// bytes, is zeroed, which ICC defines as "not calculated". A space made from such a profile answers for
// its profile, and its property list, with the bytes the caller supplied.
#include "wk_polyfill.h"
#include "wk_icc.h"

#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

enum { WK_ICC_CURVE_SAMPLES = 16384 };

static uint32_t wk_iccRead32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t wk_iccRead16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static void wk_iccWrite32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void wk_iccWrite16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static size_t wk_iccRound4(size_t n) { return (n + 3) & ~(size_t)3; }

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
} WKICCBuffer;

static bool wk_iccReserve(WKICCBuffer *buffer, size_t extra)
{
    if (extra > SIZE_MAX - buffer->length)
        return false;
    size_t needed = buffer->length + extra;
    if (needed <= buffer->capacity)
        return true;
    size_t capacity = buffer->capacity ? buffer->capacity : 4096;
    while (capacity < needed)
        capacity *= 2;
    uint8_t *bytes = realloc(buffer->bytes, capacity);
    if (!bytes)
        return false;
    buffer->bytes = bytes;
    buffer->capacity = capacity;
    return true;
}

static bool wk_iccAppend(WKICCBuffer *buffer, const void *bytes, size_t length)
{
    if (!wk_iccReserve(buffer, length))
        return false;
    memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length;
    return true;
}

static bool wk_iccPad(WKICCBuffer *buffer)
{
    size_t padding = wk_iccRound4(buffer->length) - buffer->length;
    if (!wk_iccReserve(buffer, padding))
        return false;
    memset(buffer->bytes + buffer->length, 0, padding);
    buffer->length += padding;
    return true;
}

// ICC.1:2010 10.18, parametricCurveType: g, a, b, c, d, e, f by function type.
static const unsigned wk_iccParameterCounts[] = { 1, 3, 4, 5, 7 };

static double wk_iccParametricValue(uint16_t type, const double *p, double x)
{
    double g = p[0], y;
    switch (type) {
    case 0:
        y = pow(x, g);
        break;
    case 1:
        y = p[1] * x + p[2] >= 0 && x >= -p[2] / p[1] ? pow(p[1] * x + p[2], g) : 0;
        break;
    case 2:
        y = p[1] * x + p[2] >= 0 && x >= -p[2] / p[1] ? pow(p[1] * x + p[2], g) + p[3] : p[3];
        break;
    case 3:
        y = x >= p[4] ? pow(fmax(p[1] * x + p[2], 0), g) : p[3] * x;
        break;
    default:
        y = x >= p[4] ? pow(fmax(p[1] * x + p[2], 0), g) + p[5] : p[3] * x + p[6];
        break;
    }
    return isnan(y) ? 0 : fmin(fmax(y, 0), 1);
}

// Appends the count curves that start at offset in the element, sampling each parametric one.
static bool wk_iccCopyCurves(const uint8_t *element, size_t size, size_t offset, unsigned count, WKICCBuffer *out, bool *rewritten)
{
    for (unsigned i = 0; i < count; ++i) {
        if (offset > size || size - offset < 12)
            return false;
        const uint8_t *curve = element + offset;
        uint32_t signature = wk_iccRead32(curve);
        size_t length;
        if (signature == 'curv') {
            uint32_t entries = wk_iccRead32(curve + 8);
            if (entries > (size - offset - 12) / 2)
                return false;
            length = 12 + 2 * (size_t)entries;
            if (!wk_iccAppend(out, curve, length))
                return false;
        } else if (signature == 'para') {
            uint16_t type = wk_iccRead16(curve + 8);
            if (type > 4)
                return false;
            unsigned parameterCount = wk_iccParameterCounts[type];
            length = 12 + 4 * (size_t)parameterCount;
            if (length > size - offset)
                return false;
            double parameters[7];
            for (unsigned p = 0; p < parameterCount; ++p)
                parameters[p] = (int32_t)wk_iccRead32(curve + 12 + 4 * p) / 65536.0;
            uint8_t header[12] = { 'c', 'u', 'r', 'v' };
            wk_iccWrite32(header + 8, WK_ICC_CURVE_SAMPLES);
            if (!wk_iccAppend(out, header, sizeof(header)) || !wk_iccReserve(out, 2 * WK_ICC_CURVE_SAMPLES))
                return false;
            for (unsigned s = 0; s < WK_ICC_CURVE_SAMPLES; ++s) {
                double y = wk_iccParametricValue(type, parameters, (double)s / (WK_ICC_CURVE_SAMPLES - 1));
                wk_iccWrite16(out->bytes + out->length, (uint16_t)lround(y * 65535));
                out->length += 2;
            }
            *rewritten = true;
        } else
            return false;
        if (!wk_iccPad(out))
            return false;
        offset += wk_iccRound4(length);
    }
    return true;
}

// ICC.1:2010 10.12 and 10.13: a 32-byte header whose offsets name the B curves, matrix, M curves, CLUT
// and A curves. The element is rebuilt in that order with its offsets rewritten.
static bool wk_iccCopyLut(const uint8_t *element, size_t size, WKICCBuffer *out, bool *rewritten)
{
    if (size < 32)
        return false;
    bool toPCS = wk_iccRead32(element) == 'mAB ';
    unsigned inputs = element[8], outputs = element[9];
    unsigned curveCounts[] = { toPCS ? outputs : inputs, 0, toPCS ? outputs : inputs, 0, toPCS ? inputs : outputs };
    size_t start = out->length;
    if (!wk_iccAppend(out, element, 32))
        return false;
    for (unsigned field = 0; field < 5; ++field) {
        size_t offset = wk_iccRead32(element + 12 + 4 * field);
        uint32_t written = 0;
        if (offset) {
            if (offset >= size)
                return false;
            written = (uint32_t)(out->length - start);
            if (field == 1) {
                if (size - offset < 48 || !wk_iccAppend(out, element + offset, 48))
                    return false;
            } else if (field == 3) {
                if (size - offset < 20)
                    return false;
                const uint8_t *clut = element + offset;
                size_t entries = clut[16];
                for (unsigned i = 0; i < inputs && i < 16; ++i) {
                    if (clut[i] && entries > SIZE_MAX / clut[i])
                        return false;
                    entries *= clut[i];
                }
                if (outputs && entries > SIZE_MAX / outputs)
                    return false;
                entries *= outputs;
                if (entries > size - offset - 20 || !wk_iccAppend(out, clut, 20 + entries))
                    return false;
            } else if (!wk_iccCopyCurves(element, size, offset, curveCounts[field], out, rewritten))
                return false;
            if (!wk_iccPad(out))
                return false;
        }
        wk_iccWrite32(out->bytes + start + 12 + 4 * field, written);
    }
    return true;
}

// The curve at offset in the element, and its length; NULL when it is not a well-formed curv or para.
static const uint8_t *wk_iccCurve(const uint8_t *element, size_t size, size_t offset, size_t *length)
{
    if (offset > size || size - offset < 12)
        return NULL;
    const uint8_t *curve = element + offset;
    uint32_t signature = wk_iccRead32(curve);
    if (signature == 'curv') {
        uint32_t entries = wk_iccRead32(curve + 8);
        if (entries > (size - offset - 12) / 2)
            return NULL;
        *length = 12 + 2 * (size_t)entries;
    } else if (signature == 'para') {
        uint16_t type = wk_iccRead16(curve + 8);
        if (type > 4)
            return NULL;
        *length = 12 + 4 * (size_t)wk_iccParameterCounts[type];
        if (*length > size - offset)
            return NULL;
    } else
        return NULL;
    return curve;
}

static bool wk_iccIsIdentity(const uint8_t *curve)
{
    if (wk_iccRead32(curve) == 'curv')
        return !wk_iccRead32(curve + 8) || (wk_iccRead32(curve + 8) == 1 && wk_iccRead16(curve + 12) == 0x0100);
    return !wk_iccRead16(curve + 8) && wk_iccRead32(curve + 12) == 0x10000;
}

typedef struct {
    const uint8_t *curves[3];
    size_t lengths[3];
    const uint8_t *matrix;
    bool parametric;
} WKICCShaper;

// An lutAToB or lutBToA that is a matrix/TRC transform: three channels, identity A and B curves, no CLUT,
// and a matrix without offsets. The M curves are the transfer functions.
static bool wk_iccMatrixShaper(const uint8_t *element, size_t size, WKICCShaper *shaper)
{
    if (size < 32 || element[8] != 3 || element[9] != 3)
        return false;
    size_t curveSets[] = { wk_iccRead32(element + 12), wk_iccRead32(element + 28) };
    size_t matrix = wk_iccRead32(element + 16), curves = wk_iccRead32(element + 20);
    if (!curveSets[0] || !matrix || !curves || wk_iccRead32(element + 24) || matrix > size || size - matrix < 48)
        return false;
    for (unsigned i = 36; i < 48; ++i) {
        if (element[matrix + i])
            return false;
    }
    for (unsigned set = 0; set < 2; ++set) {
        size_t offset = curveSets[set], length;
        for (unsigned i = 0; offset && i < 3; ++i) {
            const uint8_t *curve = wk_iccCurve(element, size, offset, &length);
            if (!curve || !wk_iccIsIdentity(curve))
                return false;
            offset += wk_iccRound4(length);
        }
    }
    shaper->matrix = element + matrix;
    shaper->parametric = false;
    for (unsigned i = 0; i < 3; ++i) {
        shaper->curves[i] = wk_iccCurve(element, size, curves, &shaper->lengths[i]);
        if (!shaper->curves[i])
            return false;
        shaper->parametric |= wk_iccRead32(shaper->curves[i]) == 'para';
        curves += wk_iccRound4(shaper->lengths[i]);
    }
    return true;
}

static double wk_iccCurveValue(const uint8_t *curve, double x)
{
    if (wk_iccRead32(curve) == 'para') {
        uint16_t type = wk_iccRead16(curve + 8);
        double parameters[7];
        for (unsigned p = 0; p < wk_iccParameterCounts[type]; ++p)
            parameters[p] = (int32_t)wk_iccRead32(curve + 12 + 4 * p) / 65536.0;
        return wk_iccParametricValue(type, parameters, x);
    }
    uint32_t entries = wk_iccRead32(curve + 8);
    if (!entries)
        return x;
    if (entries == 1)
        return pow(x, wk_iccRead16(curve + 12) / 256.0);
    double position = fmin(fmax(x, 0), 1) * (entries - 1);
    uint32_t index = (uint32_t)position;
    if (index >= entries - 1)
        return wk_iccRead16(curve + 12 + 2 * (entries - 1)) / 65535.0;
    double low = wk_iccRead16(curve + 12 + 2 * index) / 65535.0, high = wk_iccRead16(curve + 14 + 2 * index) / 65535.0;
    return low + (high - low) * (position - index);
}

static double wk_iccMatrixEntry(const WKICCShaper *shaper, unsigned row, unsigned column)
{
    return (int32_t)wk_iccRead32(shaper->matrix + 4 * (3 * row + column)) / 65536.0;
}

// The same transform as the forward one: identical matrix and M curves.
static bool wk_iccSameShaper(const WKICCShaper *forward, const WKICCShaper *other)
{
    if (memcmp(forward->matrix, other->matrix, 48))
        return false;
    for (unsigned i = 0; i < 3; ++i) {
        if (forward->lengths[i] != other->lengths[i] || memcmp(forward->curves[i], other->curves[i], forward->lengths[i]))
            return false;
    }
    return true;
}

// The forward transform's inverse: its matrix times the forward one is the identity to within the
// matrices' s15Fixed16 rounding, and each forward M curve applied to its own M curve returns the input to
// within 1/65535 at 4096 points.
static bool wk_iccInverseShaper(const WKICCShaper *forward, const WKICCShaper *inverse)
{
    for (unsigned row = 0; row < 3; ++row) {
        for (unsigned column = 0; column < 3; ++column) {
            double product = 0, tolerance = 0;
            for (unsigned k = 0; k < 3; ++k) {
                product += wk_iccMatrixEntry(inverse, row, k) * wk_iccMatrixEntry(forward, k, column);
                tolerance += (fabs(wk_iccMatrixEntry(inverse, row, k)) + fabs(wk_iccMatrixEntry(forward, k, column))) / 65536;
            }
            if (fabs(product - (row == column)) > tolerance)
                return false;
        }
    }
    for (unsigned channel = 0; channel < 3; ++channel) {
        for (unsigned sample = 0; sample < 4096; ++sample) {
            double y = sample / 4095.0;
            if (fabs(wk_iccCurveValue(forward->curves[channel], wk_iccCurveValue(inverse->curves[channel], y)) - y) > 1 / 65535.0)
                return false;
        }
    }
    return true;
}

static bool wk_iccIsLutTag(uint32_t signature)
{
    return signature == 'A2B0' || signature == 'A2B1' || signature == 'A2B2'
        || signature == 'B2A0' || signature == 'B2A1' || signature == 'B2A2';
}

static bool wk_iccIsShaperTag(uint32_t signature)
{
    return signature == 'rXYZ' || signature == 'gXYZ' || signature == 'bXYZ'
        || signature == 'rTRC' || signature == 'gTRC' || signature == 'bTRC';
}

// An RGB profile whose lut tags are all one matrix/TRC transform -- A2B0, any other A2B tag identical to it
// and any B2A tag its inverse -- written as the matrix/TRC profile it is:
// colorants from A2B0's matrix, scaled out of the lut's PCSXYZ encoding (1.0 encodes 65535/32768), and
// A2B0's M curves as the TRCs, byte for byte. 10.9 evaluates parametric TRCs exactly. NULL for any other
// profile, or one whose curves are all sampled already.
static CFDataRef wk_iccMatrixShaperProfile(const uint8_t *bytes, size_t length, uint32_t tagCount)
{
    if (wk_iccRead32(bytes + 16) != 'RGB ' || wk_iccRead32(bytes + 20) != 'XYZ ')
        return NULL;
    WKICCShaper forward = { { NULL }, { 0 }, NULL, false }, others[6];
    uint32_t otherSignatures[6];
    unsigned otherCount = 0;
    for (uint32_t i = 0; i < tagCount; ++i) {
        const uint8_t *entry = bytes + 132 + 12 * i;
        uint32_t signature = wk_iccRead32(entry), offset = wk_iccRead32(entry + 4), size = wk_iccRead32(entry + 8);
        if (!wk_iccIsLutTag(signature))
            continue;
        if (offset > length || size > length - offset || size < 4)
            return NULL;
        uint32_t type = wk_iccRead32(bytes + offset);
        WKICCShaper shaper;
        if ((type != 'mAB ' && type != 'mBA ') || !wk_iccMatrixShaper(bytes + offset, size, &shaper))
            return NULL;
        if (signature == 'A2B0')
            forward = shaper;
        else if (otherCount < 6) {
            others[otherCount] = shaper;
            otherSignatures[otherCount++] = signature;
        } else
            return NULL;
    }
    if (!forward.matrix || !forward.parametric)
        return NULL;
    // A matrix/TRC profile has one transform for every rendering intent, inverted for output: every other
    // lut tag must already say exactly that.
    for (unsigned i = 0; i < otherCount; ++i) {
        bool toPCS = otherSignatures[i] == 'A2B1' || otherSignatures[i] == 'A2B2';
        if (toPCS ? !wk_iccSameShaper(&forward, &others[i]) : !wk_iccInverseShaper(&forward, &others[i]))
            return NULL;
    }

    WKICCBuffer out = { NULL, 0, 0 };
    uint32_t kept = 0;
    for (uint32_t i = 0; i < tagCount; ++i) {
        uint32_t signature = wk_iccRead32(bytes + 132 + 12 * i);
        kept += !wk_iccIsLutTag(signature) && !wk_iccIsShaperTag(signature);
    }
    uint32_t count = kept + 6;
    bool valid = wk_iccAppend(&out, bytes, 128) && wk_iccReserve(&out, 4 + 12 * (size_t)count);
    if (valid) {
        wk_iccWrite32(out.bytes + 128, count);
        memset(out.bytes + 132, 0, 12 * (size_t)count);
        out.length = 132 + 12 * (size_t)count;
    }
    uint32_t written = 0;
    for (uint32_t i = 0; valid && i < tagCount; ++i) {
        const uint8_t *entry = bytes + 132 + 12 * i;
        uint32_t signature = wk_iccRead32(entry), offset = wk_iccRead32(entry + 4), size = wk_iccRead32(entry + 8);
        if (wk_iccIsLutTag(signature) || wk_iccIsShaperTag(signature))
            continue;
        if (offset > length || size > length - offset) {
            valid = false;
            break;
        }
        uint8_t *slot = out.bytes + 132 + 12 * written++;
        wk_iccWrite32(slot, signature);
        wk_iccWrite32(slot + 4, (uint32_t)out.length);
        wk_iccWrite32(slot + 8, size);
        valid = wk_iccAppend(&out, bytes + offset, size) && wk_iccPad(&out);
    }
    static const uint32_t colorants[] = { 'rXYZ', 'gXYZ', 'bXYZ' }, curves[] = { 'rTRC', 'gTRC', 'bTRC' };
    for (unsigned channel = 0; valid && channel < 3; ++channel) {
        uint8_t colorant[20] = { 'X', 'Y', 'Z', ' ' };
        for (unsigned row = 0; row < 3; ++row) {
            double value = (int32_t)wk_iccRead32(forward.matrix + 4 * (3 * row + channel)) / 65536.0 * 65535 / 32768;
            wk_iccWrite32(colorant + 8 + 4 * row, (uint32_t)(int32_t)lround(value * 65536));
        }
        uint8_t *slot = out.bytes + 132 + 12 * written++;
        wk_iccWrite32(slot, colorants[channel]);
        wk_iccWrite32(slot + 4, (uint32_t)out.length);
        wk_iccWrite32(slot + 8, sizeof(colorant));
        valid = wk_iccAppend(&out, colorant, sizeof(colorant)) && wk_iccPad(&out);
        if (!valid)
            break;
        slot = out.bytes + 132 + 12 * written++;
        wk_iccWrite32(slot, curves[channel]);
        wk_iccWrite32(slot + 4, (uint32_t)out.length);
        wk_iccWrite32(slot + 8, (uint32_t)forward.lengths[channel]);
        valid = wk_iccAppend(&out, forward.curves[channel], forward.lengths[channel]) && wk_iccPad(&out);
    }
    if (!valid || out.length > UINT32_MAX) {
        free(out.bytes);
        return NULL;
    }
    wk_iccWrite32(out.bytes, (uint32_t)out.length);
    memset(out.bytes + 84, 0, 16);
    CFDataRef result = CFDataCreate(kCFAllocatorDefault, out.bytes, (CFIndex)out.length);
    free(out.bytes);
    return result;
}

CFDataRef wk_iccProfileForColorSync(CFDataRef profile)
{
    if (!profile)
        return NULL;
    const uint8_t *bytes = CFDataGetBytePtr(profile);
    size_t length = (size_t)CFDataGetLength(profile);
    if (length < 132)
        return CFRetain(profile);
    uint32_t tagCount = wk_iccRead32(bytes + 128);
    if (tagCount > (length - 132) / 12)
        return CFRetain(profile);
    CFDataRef shaper = wk_iccMatrixShaperProfile(bytes, length, tagCount);
    if (shaper)
        return shaper;

    WKICCBuffer out = { NULL, 0, 0 };
    bool rewritten = false, valid = wk_iccAppend(&out, bytes, 132 + 12 * (size_t)tagCount) && wk_iccPad(&out);
    for (uint32_t i = 0; valid && i < tagCount; ++i) {
        const uint8_t *entry = bytes + 132 + 12 * i;
        uint32_t offset = wk_iccRead32(entry + 4), size = wk_iccRead32(entry + 8);
        if (offset > length || size > length - offset) {
            valid = false;
            break;
        }
        // Tags that share data keep sharing it.
        uint32_t written = 0, writtenSize = 0;
        for (uint32_t j = 0; j < i; ++j) {
            const uint8_t *earlier = bytes + 132 + 12 * j;
            if (wk_iccRead32(earlier + 4) == offset && wk_iccRead32(earlier + 8) == size) {
                written = wk_iccRead32(out.bytes + 132 + 12 * j + 4);
                writtenSize = wk_iccRead32(out.bytes + 132 + 12 * j + 8);
                break;
            }
        }
        if (!written) {
            written = (uint32_t)out.length;
            uint32_t type = size >= 4 ? wk_iccRead32(bytes + offset) : 0;
            if (type == 'mAB ' || type == 'mBA ')
                valid = wk_iccCopyLut(bytes + offset, size, &out, &rewritten);
            else
                valid = wk_iccAppend(&out, bytes + offset, size);
            writtenSize = (uint32_t)(out.length - written);
            valid = valid && wk_iccPad(&out) && out.length <= UINT32_MAX;
        }
        if (valid) {
            wk_iccWrite32(out.bytes + 132 + 12 * i + 4, written);
            wk_iccWrite32(out.bytes + 132 + 12 * i + 8, writtenSize);
        }
    }
    if (!valid || !rewritten) {
        free(out.bytes);
        return CFRetain(profile);
    }
    wk_iccWrite32(out.bytes, (uint32_t)out.length);
    memset(out.bytes + 84, 0, 16);
    CFDataRef result = CFDataCreate(kCFAllocatorDefault, out.bytes, (CFIndex)out.length);
    free(out.bytes);
    return result ? result : CFRetain(profile);
}

static const char wk_iccOriginalProfileKey;

CFDataRef wk_iccOriginalProfile(CGColorSpaceRef space)
{
    return space ? (CFDataRef)objc_getAssociatedObject((id)space, &wk_iccOriginalProfileKey) : NULL;
}

static CGColorSpaceRef wk_iccKeepOriginal(CGColorSpaceRef space, CFDataRef original, CFDataRef profile)
{
    if (space && profile != original) {
        CFDataRef copy = CFDataCreateCopy(kCFAllocatorDefault, original);
        objc_setAssociatedObject((id)space, &wk_iccOriginalProfileKey, (id)copy, OBJC_ASSOCIATION_RETAIN);
        if (copy)
            CFRelease(copy);
    }
    return space;
}

WK_POLYFILL_REPLACES("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithICCProfile, (CFDataRef data))
{
    CFDataRef profile = wk_iccProfileForColorSync(data);
    CGColorSpaceRef space = wk_iccKeepOriginal(WK_ORIGINAL(CGColorSpaceCreateWithICCProfile)(profile), data, profile);
    if (profile)
        CFRelease(profile);
    return space;
}

WK_POLYFILL_REPLACES("CoreGraphics", CFDataRef, CGColorSpaceCopyICCProfile, (CGColorSpaceRef space))
{
    CFDataRef original = wk_iccOriginalProfile(space);
    return original ? CFRetain(original) : WK_ORIGINAL(CGColorSpaceCopyICCProfile)(space);
}

// The data is a CFData or a CGDataProvider.
WK_POLYFILL_REPLACES("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithICCData, (CFTypeRef data))
{
    CFDataRef bytes = NULL;
    if (data && CFGetTypeID(data) == CFDataGetTypeID())
        bytes = CFRetain(data);
    else if (data && CFGetTypeID(data) == CGDataProviderGetTypeID())
        bytes = CGDataProviderCopyData((CGDataProviderRef)data);
    if (!bytes)
        return WK_ORIGINAL(CGColorSpaceCreateWithICCData)(data);
    CFDataRef profile = wk_iccProfileForColorSync(bytes);
    CGColorSpaceRef space = wk_iccKeepOriginal(WK_ORIGINAL(CGColorSpaceCreateWithICCData)(profile), bytes, profile);
    CFRelease(profile);
    CFRelease(bytes);
    return space;
}
