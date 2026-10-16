// kCGColorSpaceLinearSRGB and kCGColorSpaceLinearDisplayP3 (polyfills/c/CoreGraphics.c), which 10.9 lacks.
// Every 8-bit sRGB grey level, as a floating-point component, converted by CoreGraphics into a
// floating-point linear-sRGB bitmap lands on its exact linearization, and every linear level back into
// sRGB on its exact encoding: the match between the two spaces is the tone curve alone, with no matrix
// residue to move a channel or tint a grey. Display P3 greys behave the same against linear Display P3. And
// an 8-bit premultiplied grey image drawn into an 8-bit bitmap of the other space lands on that value rounded:
// sRGB 7 is linear 0.54, so 1.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static double linearize(double encoded)
{
    return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4);
}

static double encode(double linear)
{
    return linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055;
}

// Opaque greys at every 8-bit level in `from`, drawn into a floating-point bitmap of `to`: the worst distance,
// in 8-bit levels, of any channel from `exact` of the level.
static double worstConversion(CGColorSpaceRef from, CGColorSpaceRef to, double (*exact)(double))
{
    const CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder32Host;
    float source[256 * 4], converted[256 * 4];
    for (int level = 0; level < 256; level++) {
        source[level * 4] = source[level * 4 + 1] = source[level * 4 + 2] = level / 255.0f;
        source[level * 4 + 3] = 1;
    }
    CGContextRef sourceContext = CGBitmapContextCreate(source, 256, 1, 32, sizeof(source), from, info);
    CGImageRef image = CGBitmapContextCreateImage(sourceContext);
    CGContextRef destination = CGBitmapContextCreate(converted, 256, 1, 32, sizeof(converted), to, info);
    CGContextSetBlendMode(destination, kCGBlendModeCopy);
    CGContextDrawImage(destination, CGRectMake(0, 0, 256, 1), image);
    double worst = 0;
    for (int level = 0; level < 256; level++) {
        for (int channel = 0; channel < 3; channel++)
            worst = fmax(worst, fabs(converted[level * 4 + channel] * 255.0 - exact(level / 255.0) * 255.0));
    }
    CGContextRelease(destination);
    CGImageRelease(image);
    CGContextRelease(sourceContext);
    return worst;
}

// The same greys as an 8-bit premultiplied image drawn into an 8-bit bitmap: the worst distance, in levels, of
// any channel from `exact` of the level rounded.
static int worstEightBitDraw(CGColorSpaceRef from, CGColorSpaceRef to, double (*exact)(double))
{
    const CGBitmapInfo info = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    unsigned char source[256 * 4], converted[256 * 4];
    for (int level = 0; level < 256; level++) {
        source[level * 4] = source[level * 4 + 1] = source[level * 4 + 2] = (unsigned char)level;
        source[level * 4 + 3] = 255;
    }
    CGContextRef sourceContext = CGBitmapContextCreate(source, 256, 1, 8, sizeof(source), from, info);
    CGImageRef image = CGBitmapContextCreateImage(sourceContext);
    CGContextRef destination = CGBitmapContextCreate(converted, 256, 1, 8, sizeof(converted), to, info);
    CGContextSetBlendMode(destination, kCGBlendModeCopy);
    CGContextDrawImage(destination, CGRectMake(0, 0, 256, 1), image);
    int worst = 0;
    for (int level = 0; level < 256; level++) {
        int want = (int)lround(exact(level / 255.0) * 255);
        for (int channel = 0; channel < 3; channel++)
            worst = abs(converted[level * 4 + channel] - want) > worst ? abs(converted[level * 4 + channel] - want) : worst;
    }
    CGContextRelease(destination);
    CGImageRelease(image);
    CGContextRelease(sourceContext);
    return worst;
}

int main(void)
{
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef linearSRGB = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceLinearSRGB"));
    CGColorSpaceRef displayP3 = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceDisplayP3"));
    CGColorSpaceRef linearDisplayP3 = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceLinearDisplayP3"));
    if (!sRGB || !linearSRGB || !displayP3 || !linearDisplayP3) {
        printf("  a colour space could not be created\n");
        return 1;
    }

    double worst = worstConversion(sRGB, linearSRGB, linearize);
    printf("    sRGB -> linear sRGB: worst %.4f levels from exact\n", worst);
    check(worst < 0.005, "every sRGB grey lands on its exact linearization");
    worst = worstConversion(linearSRGB, sRGB, encode);
    printf("    linear sRGB -> sRGB: worst %.4f levels from exact\n", worst);
    check(worst < 0.005, "every linear-sRGB grey lands on its exact sRGB encoding");
    worst = worstConversion(displayP3, linearDisplayP3, linearize);
    printf("    Display P3 -> linear Display P3: worst %.4f levels from exact\n", worst);
    check(worst < 0.005, "every Display P3 grey lands on its exact linearization");

    int levels = worstEightBitDraw(sRGB, linearSRGB, linearize);
    printf("    8-bit sRGB -> 8-bit linear sRGB bitmap: worst %d levels from rounded exact\n", levels);
    check(levels == 0, "an 8-bit sRGB image lands on its rounded linearization in a bitmap");
    levels = worstEightBitDraw(linearSRGB, sRGB, encode);
    printf("    8-bit linear sRGB -> 8-bit sRGB bitmap: worst %d levels from rounded exact\n", levels);
    check(levels == 0, "an 8-bit linear-sRGB image lands on its rounded encoding in a bitmap");

    CGColorSpaceRelease(linearDisplayP3);
    CGColorSpaceRelease(displayP3);
    CGColorSpaceRelease(linearSRGB);
    CGColorSpaceRelease(sRGB);
    return failures ? 1 : 0;
}
