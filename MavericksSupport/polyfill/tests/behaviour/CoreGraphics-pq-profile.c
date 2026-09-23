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

static CGColorSpaceRef parserFixture(CGColorSpaceRef pq, unsigned type, unsigned malformed)
{
    CFDataRef original = CGColorSpaceCopyICCProfile(pq);
    CFMutableDataRef data = CFDataCreateMutableCopy(NULL, 0, original);
    CFRelease(original);
    unsigned char *bytes = CFDataGetMutableBytePtr(data);
    memset(bytes + 84, 0, 16);
    for (unsigned i = 0; i < read32(bytes + 128); ++i) {
        unsigned char *entry = bytes + 132 + 12 * i;
        bool forward = !memcmp(entry, "A2B0", 4), reverse = !memcmp(entry, "B2A0", 4);
        if (!forward && !reverse)
            continue;
        unsigned char *tag = bytes + read32(entry + 4);
        unsigned offset = read32(tag + 20);
        static const unsigned parameterCounts[] = { 1, 3, 4, 5, 7 };
        unsigned size = 12 + 4 * parameterCounts[type];
        for (unsigned channel = 0; channel < 3; ++channel) {
            unsigned char *curve = tag + offset + size * channel;
            memset(curve, 0, size);
            memcpy(curve, "para", 4);
            curve[9] = type;
            write32(curve + 12, 65536);
            if (type)
                write32(curve + 16, 65536);
            if (type >= 3)
                write32(curve + 24, 65536);
        }
        if (malformed && ((malformed <= 2 && forward) || (malformed > 2 && reverse))) {
            if (malformed == 1 || malformed == 3)
                tag[offset + 9] = 5;
            else {
                unsigned truncatedOffset = read32(entry + 8) - 12;
                write32(tag + 20, truncatedOffset);
                memset(tag + truncatedOffset, 0, 12);
                memcpy(tag + truncatedOffset, "para", 4);
                tag[truncatedOffset + 9] = 4;
            }
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithICCProfile(data);
    CFRelease(data);
    return space;
}

static void checkParser(CGColorSpaceRef pq, CGColorSpaceRef linear)
{
    CGColorSpaceRef reference = parserFixture(pq, 0, 0);
    assert(reference);
    for (unsigned type = 0; type <= 4; ++type) {
        CGColorSpaceRef test = parserFixture(pq, type, 0);
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
        assert(!parserFixture(pq, 4, malformed));
    puts("PASS embedded ICC para types 0-4; malformed types and truncation rejected in both directions");
}

static double encode(double nits)
{
    double p = pow(nits / 10000, 2610.0 / 16384);
    return pow((3424.0 / 4096 + (2413.0 / 128) * p) / (1 + (2392.0 / 128) * p), 2523.0 / 32);
}

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
            assert(fabs(output[c] - expected) < expected * .004 + 2e-7);
        }
        convert(linear, pq, output, roundtrip);
        for (unsigned c = 0; c < 3; ++c)
            assert(fabs(roundtrip[c] - encoded) < .001);
    }
    float saturated[][4] = { {1,0,0,1}, {0,1,0,1}, {0,0,1,1}, {1,1,0,1}, {.58,.3,.02,1} };
    for (unsigned i = 0; i < sizeof(saturated) / sizeof(saturated[0]); ++i) {
        float output[4] = { 0 }, roundtrip[4] = { 0 };
        convert(pq, linear, saturated[i], output);
        convert(linear, pq, output, roundtrip);
        for (unsigned c = 0; c < 3; ++c) {
            printf("color%u channel%u: %.9g expected %.9g\n", i, c, roundtrip[c], saturated[i][c]);
            assert(fabs(roundtrip[c] - saturated[i][c]) < .006);
        }
    }
    checkParser(pq, linear);
    CGColorSpaceRelease(linear);
    CGColorSpaceRelease(pq);
    puts("PASS PQ luminance, shadow precision, inverse transfer, saturated P3 colors");
}
