#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
extern bool CGColorSpaceUsesITUR_2100TF(CGColorSpaceRef);

static void convert(CGColorSpaceRef source, CGColorSpaceRef destination, const float input[4], float output[4])
{
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, input, 4 * sizeof(float), NULL);
    CGBitmapInfo format = kCGBitmapFloatComponents | kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedLast;
    CGImageRef image = CGImageCreate(1, 1, 32, 128, 4 * sizeof(float), source, format, provider, NULL, false, kCGRenderingIntentRelativeColorimetric);
    CGContextRef context = CGBitmapContextCreate(output, 1, 1, 32, 4 * sizeof(float), destination, format);
    assert(image && context);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image);
    CGContextRelease(context);
    CGImageRelease(image);
    CGDataProviderRelease(provider);
}

static unsigned read32(const unsigned char *bytes)
{
    return ((unsigned)bytes[0] << 24) | ((unsigned)bytes[1] << 16) | ((unsigned)bytes[2] << 8) | bytes[3];
}

static void write32(unsigned char *bytes, unsigned value)
{
    bytes[0] = value >> 24; bytes[1] = value >> 16; bytes[2] = value >> 8; bytes[3] = value;
}

static void write16(unsigned char *bytes, unsigned value)
{
    bytes[0] = value >> 8; bytes[1] = value;
}

static void writeFixed(unsigned char *bytes, double value)
{
    write32(bytes, (unsigned)(int)lround(value * 65536));
}

// An lutAToB or lutBToA of the full shape -- identity A and B curves, an identity 2x2x2 CLUT, the sRGB
// matrix in the lut's PCSXYZ encoding (1.0 encodes 65535/32768) and M curves of the given parametric type,
// each the identity. Returns its size.
static unsigned writeLut(unsigned char *tag, bool reverse, unsigned type)
{
    static const double toXYZ[9] = { .4360747, .3850649, .1430804, .2225045, .7168786, .0606169, .0139322, .0971045, .7141733 };
    static const unsigned parameterCounts[] = { 1, 3, 4, 5, 7 };
    unsigned paraSize = 12 + 4 * parameterCounts[type];
    unsigned offsets[5] = { 32, 32 + 36, 32 + 36 + 48, 0, 0 };
    offsets[3] = offsets[2] + 3 * paraSize;
    offsets[4] = offsets[3] + 20 + 8 * 3 * 2;
    memcpy(tag, reverse ? "mBA " : "mAB ", 4);
    tag[8] = tag[9] = 3;
    for (unsigned i = 0; i < 5; ++i)
        write32(tag + 12 + 4 * i, offsets[i]);
    for (unsigned channel = 0; channel < 3; ++channel) {
        memcpy(tag + offsets[0] + 12 * channel, "curv", 4);
        memcpy(tag + offsets[4] + 12 * channel, "curv", 4);
    }
    double matrix[9];
    double determinant = toXYZ[0] * (toXYZ[4] * toXYZ[8] - toXYZ[5] * toXYZ[7]) - toXYZ[1] * (toXYZ[3] * toXYZ[8] - toXYZ[5] * toXYZ[6])
        + toXYZ[2] * (toXYZ[3] * toXYZ[7] - toXYZ[4] * toXYZ[6]);
    for (unsigned row = 0; row < 3; ++row) {
        for (unsigned column = 0; column < 3; ++column) {
            if (!reverse) {
                matrix[3 * row + column] = toXYZ[3 * row + column] * 32768 / 65535;
                continue;
            }
            unsigned r0 = (column + 1) % 3, r1 = (column + 2) % 3, c0 = (row + 1) % 3, c1 = (row + 2) % 3;
            double cofactor = toXYZ[3 * r0 + c0] * toXYZ[3 * r1 + c1] - toXYZ[3 * r0 + c1] * toXYZ[3 * r1 + c0];
            matrix[3 * row + column] = cofactor / determinant * 65535 / 32768;
        }
    }
    for (unsigned i = 0; i < 9; ++i)
        writeFixed(tag + offsets[1] + 4 * i, matrix[i]);
    for (unsigned channel = 0; channel < 3; ++channel) {
        unsigned char *curve = tag + offsets[2] + paraSize * channel;
        memcpy(curve, "para", 4);
        write16(curve + 8, type);
        writeFixed(curve + 12, 1);
        if (type)
            writeFixed(curve + 16, 1);
    }
    unsigned char *clut = tag + offsets[3];
    clut[0] = clut[1] = clut[2] = 2;
    clut[16] = 2;
    for (unsigned vertex = 0; vertex < 8; ++vertex) {
        for (unsigned channel = 0; channel < 3; ++channel)
            write16(clut + 20 + 6 * vertex + 2 * channel, vertex & (4 >> channel) ? 65535 : 0);
    }
    return offsets[4] + 36;
}

static CGColorSpaceRef parserFixture(unsigned type, unsigned malformed)
{
    unsigned char bytes[2048] = { 0 };
    memcpy(bytes + 4, "appl", 4);
    write32(bytes + 8, 0x04300000);
    memcpy(bytes + 12, "mntrRGB XYZ ", 12);
    memcpy(bytes + 36, "acsp", 4);
    writeFixed(bytes + 68, .9642);
    writeFixed(bytes + 72, 1);
    writeFixed(bytes + 76, .8249);
    write32(bytes + 128, 3);
    unsigned cursor = 132 + 3 * 12;
    static const char *signatures[] = { "wtpt", "A2B0", "B2A0" };
    for (unsigned i = 0; i < 3; ++i) {
        unsigned char *tag = bytes + cursor;
        unsigned size;
        if (!i) {
            memcpy(tag, "XYZ ", 4);
            writeFixed(tag + 8, .9642);
            writeFixed(tag + 12, 1);
            writeFixed(tag + 16, .8249);
            size = 20;
        } else
            size = writeLut(tag, i == 2, type);
        bool damaged = malformed && ((malformed <= 2 && i == 1) || (malformed > 2 && i == 2));
        if (damaged && (malformed == 1 || malformed == 3))
            tag[read32(tag + 20) + 9] = 5;
        else if (damaged) {
            // The M curves start 12 bytes before the end: a type 4 header with no room for its parameters.
            write32(tag + 20, size);
            memcpy(tag + size, "para", 4);
            memset(tag + size + 4, 0, 8);
            tag[size + 9] = 4;
            size += 12;
        }
        memcpy(bytes + 132 + 12 * i, signatures[i], 4);
        write32(bytes + 132 + 12 * i + 4, cursor);
        write32(bytes + 132 + 12 * i + 8, size);
        cursor += (size + 3) & ~3u;
    }
    write32(bytes, cursor);
    CFDataRef data = CFDataCreate(NULL, bytes, cursor);
    CGColorSpaceRef space = CGColorSpaceCreateWithICCProfile(data);
    if (space) {
        // The space answers with the caller's bytes, and its property list round-trips.
        CFDataRef profile = CGColorSpaceCopyICCProfile(space);
        CFPropertyListRef list = CGColorSpaceCopyPropertyList(space);
        assert(profile && CFEqual(profile, data) && list && CFEqual(list, data));
        CGColorSpaceRef again = CGColorSpaceCreateWithPropertyList(list);
        assert(again && CGColorSpaceGetNumberOfComponents(again) == CGColorSpaceGetNumberOfComponents(space));
        CGColorSpaceRelease(again);
        CFRelease(list);
        CFRelease(profile);
    }
    CFRelease(data);
    return space;
}

static void checkParser(CGColorSpaceRef linear)
{
    CGColorSpaceRef reference = parserFixture(0, 0);
    assert(reference);
    for (unsigned type = 0; type <= 4; ++type) {
        CGColorSpaceRef test = parserFixture(type, 0);
        assert(test);
        const float samples[][4] = { {.01,.01,.01,1}, {.5,.5,.5,1}, {1,1,1,1}, {.7,.2,.05,1} };
        for (unsigned i = 0; i < sizeof(samples) / sizeof(samples[0]); ++i) {
            for (unsigned reverse = 0; reverse < 2; ++reverse) {
                float expected[4] = { 0 }, actual[4] = { 0 };
                convert(reverse ? linear : reference, reverse ? reference : linear, samples[i], expected);
                convert(reverse ? linear : test, reverse ? test : linear, samples[i], actual);
                for (unsigned channel = 0; channel < 4; ++channel)
                    assert(fabs(actual[channel] - expected[channel]) < 1e-5);
            }
        }
        CGColorSpaceRelease(test);
    }
    CGColorSpaceRelease(reference);
    for (unsigned malformed = 1; malformed <= 4; ++malformed)
        assert(!parserFixture(4, malformed));
    puts("PASS embedded ICC para types 0-4; malformed types and truncation rejected in both directions; caller bytes read back");
}

static double encode(double nits)
{
    double p = pow(nits / 10000, 2610.0 / 16384);
    return pow((3424.0 / 4096 + (2413.0 / 128) * p) / (1 + (2392.0 / 128) * p), 2523.0 / 32);
}

static double decode(double encoded)
{
    double p = pow(fmax(encoded, 0), 32.0 / 2523);
    return pow(fmax(p - 3424.0 / 4096, 0) / (2413.0 / 128 - (2392.0 / 128) * p), 16384.0 / 2610) * 125;
}

// CoreGraphics converts through 10.9's ColorSync, which evaluates the space's transfer function as its
// 16-bit TRC: within one step of the 10000 cd/m^2 curve, in the linear space's 80 cd/m^2 units.
static const double curveStep = 125.0 / 65535;

int main(void)
{
    CGColorSpaceRef pq = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceDisplayP3_PQ"));
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceExtendedLinearDisplayP3"));
    assert(pq && linear && CGColorSpaceUsesITUR_2100TF(pq));
    assert(!CGColorSpaceUsesITUR_2100TF(linear));
    double nits[] = { .0001, .001, .01, .05, .1, 80, 203, 1000, 10000 };
    for (unsigned i = 0; i < sizeof(nits) / sizeof(nits[0]); ++i) {
        float encoded = encode(nits[i]);
        float input[] = { encoded, encoded, encoded, 1 }, output[4] = { 0 }, roundtrip[4] = { 0 };
        convert(pq, linear, input, output);
        double expected = nits[i] / 80;
        for (unsigned c = 0; c < 3; ++c) {
            printf("%g nits channel%u: %.9g expected %.9g\n", nits[i], c, output[c], expected);
            assert(fabs(output[c] - expected) < expected * .004 + curveStep);
        }
        convert(linear, pq, output, roundtrip);
        for (unsigned c = 0; c < 3; ++c)
            assert(fabs(decode(roundtrip[c]) - expected) < expected * .004 + curveStep);
    }
    float saturated[][4] = { {1,0,0,1}, {0,1,0,1}, {0,0,1,1}, {1,1,0,1}, {.58,.3,.02,1} };
    for (unsigned i = 0; i < sizeof(saturated) / sizeof(saturated[0]); ++i) {
        float output[4] = { 0 }, roundtrip[4] = { 0 };
        convert(pq, linear, saturated[i], output);
        convert(linear, pq, output, roundtrip);
        for (unsigned c = 0; c < 3; ++c) {
            printf("color%u channel%u: %.9g expected %.9g\n", i, c, roundtrip[c], saturated[i][c]);
            double light = decode(saturated[i][c]);
            assert(fabs(decode(roundtrip[c]) - light) < light * .006 + curveStep);
        }
    }
    checkParser(linear);
    CGColorSpaceRelease(linear);
    CGColorSpaceRelease(pq);
    puts("PASS PQ luminance, inverse transfer and saturated P3 colors within the 10.9 TRC bound");
}
