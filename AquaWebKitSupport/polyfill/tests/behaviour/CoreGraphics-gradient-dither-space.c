// The CGContextDrawLinearGradient and CGContextDrawRadialGradient replacements (polyfills/c/CoreGraphics.c)
// in an 8-bit bitmap whose colour space is not the gradient's. A stretch between two equal sRGB stops
// drawn into a linear-sRGB bitmap must hold the single colour CoreGraphics matches that stop to, as a
// flat fill of it does; 10.9's own definition dithers it, which is the premise. A ramp drawn the same way
// stays dithered, a gamma-1 ramp drawn into sRGB deviates from its exact encoding no more than 10.9's
// draw does, a gamma-1 conic gradient into sRGB keeps every level, and a gradient drawn into its own colour
// space is untouched. A conic gradient of Adobe RGB green drawn into an Adobe RGB
// bitmap keeps that green, which a DeviceRGB ramp clips.
#include <CoreGraphics/CoreGraphics.h>
#include <mach-o/dyld.h>
#include <stdbool.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

typedef void (*DrawLinearFn)(CGContextRef, CGGradientRef, CGPoint, CGPoint, CGGradientDrawingOptions);
typedef void (*DrawRadialFn)(CGContextRef, CGGradientRef, CGPoint, CGFloat, CGPoint, CGFloat, CGGradientDrawingOptions);

enum { kWidth = 100, kHeight = 100 };
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
static const CGGradientDrawingOptions kExtend = kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation;

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static void *systemSymbol(const char *name)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, name, NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? NSAddressOfSymbol(found) : 0;
}

static CGColorSpaceRef createLinearSRGB(void)
{
    const CGFloat white[3] = { 0.9505, 1.0, 1.0890 }, black[3] = { 0, 0, 0 }, gamma[3] = { 1, 1, 1 };
    const CGFloat primaries[9] = { 0.4124564, 0.2126729, 0.0193339, 0.3575761, 0.7151522, 0.1191920, 0.1804375, 0.0721750, 0.9503041 };
    return CGColorSpaceCreateCalibratedRGB(white, black, gamma, primaries);
}

static CGContextRef createBitmap(CGColorSpaceRef space)
{
    CGContextRef context = CGBitmapContextCreate(NULL, kWidth, kHeight, 8, kWidth * 4, space, kBGRA);
    CGContextClearRect(context, CGRectMake(0, 0, kWidth, kHeight));
    return context;
}

// Pixels of columns [first, last) that differ from `pixel`.
static int countOther(CGContextRef context, size_t first, size_t last, const unsigned char pixel[4])
{
    const unsigned char *base = CGBitmapContextGetData(context);
    int count = 0;
    for (size_t y = 0; y < kHeight; y++) {
        for (size_t x = first; x < last; x++)
            count += memcmp(base + y * kWidth * 4 + x * 4, pixel, 4) != 0;
    }
    return count;
}

// Columns of [first, last) whose rows are not all alike.
static int ditheredColumns(CGContextRef context, size_t first, size_t last)
{
    const unsigned char *base = CGBitmapContextGetData(context);
    int count = 0;
    for (size_t x = first; x < last; x++) {
        for (size_t y = 1; y < kHeight; y++) {
            if (memcmp(base + y * kWidth * 4 + x * 4, base + x * 4, 4)) {
                count++;
                break;
            }
        }
    }
    return count;
}

static double sRGBEncoding(double linearValue)
{
    return linearValue <= 0.0031308 ? linearValue * 12.92 : 1.055 * pow(linearValue, 1 / 2.4) - 0.055;
}

int main(void)
{
    DrawLinearFn systemLinear = (DrawLinearFn)systemSymbol("_CGContextDrawLinearGradient");
    DrawRadialFn systemRadial = (DrawRadialFn)systemSymbol("_CGContextDrawRadialGradient");
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef linear = createLinearSRGB();
    if (!systemLinear || !systemRadial || !sRGB || !linear)
        return 1;

    // Red up to the middle, then sRGB 0,128,0: the right half is a stretch between two equal stops.
    const CGFloat hardComponents[] = { 1, 0, 0, 1, 1, 0, 0, 1, 0, 128 / 255.0, 0, 1, 0, 128 / 255.0, 0, 1 };
    const CGFloat hardLocations[] = { 0, 0.5, 0.5, 1 };
    CGGradientRef hard = CGGradientCreateWithColorComponents(sRGB, hardComponents, hardLocations, 4);
    const CGFloat rampComponents[] = { 1, 1, 1, 1, 0, 0, 1, 1 };
    CGGradientRef ramp = CGGradientCreateWithColorComponents(sRGB, rampComponents, NULL, 2);

    // The flat fill of the stop colour gives the single colour the stretch must hold.
    CGContextRef flat = createBitmap(linear);
    const CGFloat green[] = { 0, 128 / 255.0, 0, 1 };
    CGContextSetFillColorSpace(flat, sRGB);
    CGContextSetFillColor(flat, green);
    CGContextFillRect(flat, CGRectMake(0, 0, kWidth, kHeight));
    unsigned char matched[4];
    memcpy(matched, CGBitmapContextGetData(flat), 4);
    CGContextRelease(flat);
    printf("  sRGB 0,128,0 in linear sRGB: BGRA %u,%u,%u,%u\n", matched[0], matched[1], matched[2], matched[3]);

    CGContextRef stock = createBitmap(linear);
    systemLinear(stock, hard, CGPointMake(0, 0), CGPointMake(kWidth, 0), kExtend);
    check(countOther(stock, 51, kWidth, matched) > 0, "10.9's linear gradient dithers the stretch between equal stops");
    CGContextRelease(stock);

    CGContextRef archive = createBitmap(linear);
    CGContextDrawLinearGradient(archive, hard, CGPointMake(0, 0), CGPointMake(kWidth, 0), kExtend);
    check(!countOther(archive, 51, kWidth, matched), "linear gradient: the stretch holds the matched stop colour");
    CGContextRelease(archive);

    // A radial gradient centred left of the bitmap: every column right of x = 60 is beyond its middle stop.
    stock = createBitmap(linear);
    systemRadial(stock, hard, CGPointMake(0, kHeight / 2), 0, CGPointMake(0, kHeight / 2), 100, kExtend);
    check(countOther(stock, 75, kWidth, matched) > 0, "10.9's radial gradient dithers the stretch between equal stops");
    CGContextRelease(stock);

    archive = createBitmap(linear);
    CGContextDrawRadialGradient(archive, hard, CGPointMake(0, kHeight / 2), 0, CGPointMake(0, kHeight / 2), 100, kExtend);
    check(!countOther(archive, 75, kWidth, matched), "radial gradient: the stretch holds the matched stop colour");
    CGContextRelease(archive);

    // Under a scaled, flipped and offset CTM, and clipped to a band, the gradient lands where 10.9 puts it.
    CGContextRef archiveBand = createBitmap(linear), reference = createBitmap(linear);
    for (int pass = 0; pass < 2; pass++) {
        CGContextRef context = pass ? reference : archiveBand;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 10, kHeight);
        CGContextScaleCTM(context, 0.8, -1);
        CGContextClipToRect(context, CGRectMake(0, 20, 100, 30));
        if (pass)
            systemLinear(context, hard, CGPointMake(0, 0), CGPointMake(kWidth, 0), kExtend);
        else
            CGContextDrawLinearGradient(context, hard, CGPointMake(0, 0), CGPointMake(kWidth, 0), kExtend);
        CGContextRestoreGState(context);
    }
    const unsigned char *a = CGBitmapContextGetData(archiveBand), *r = CGBitmapContextGetData(reference);
    bool sameCoverage = true;
    for (size_t i = 0; i < kWidth * kHeight; i++)
        sameCoverage &= (a[i * 4 + 3] == 0) == (r[i * 4 + 3] == 0);
    check(sameCoverage, "a transformed, clipped draw covers the pixels 10.9's covers");
    CGContextRelease(archiveBand);
    CGContextRelease(reference);

    archive = createBitmap(linear);
    CGContextDrawLinearGradient(archive, ramp, CGPointMake(0, 0), CGPointMake(kWidth, 0), kExtend);
    check(ditheredColumns(archive, 0, kWidth) > kWidth / 2, "a ramp into linear sRGB stays dithered");
    CGContextRelease(archive);

    // A gamma-1 ramp from black to 0.02 drawn into sRGB covers sRGB levels 0 to 39: every pixel's deviation
    // from the exact sRGB encoding of its gamma-1 value, worst and mean, must be no larger than 10.9's own
    // draw shows.
    {
        enum { kRampWidth = 512, kRampHeight = 16 };
        const CGFloat darkComponents[] = { 0, 0, 0, 1, 0.02, 0.02, 0.02, 1 };
        CGGradientRef dark = CGGradientCreateWithColorComponents(linear, darkComponents, NULL, 2);
        double worst[2] = { 0, 0 }, mean[2] = { 0, 0 };
        for (int pass = 0; pass < 2; pass++) {
            CGContextRef context = CGBitmapContextCreate(NULL, kRampWidth, kRampHeight, 8, kRampWidth * 4, sRGB, kBGRA);
            if (pass)
                systemLinear(context, dark, CGPointMake(0, 0), CGPointMake(kRampWidth, 0), kExtend);
            else
                CGContextDrawLinearGradient(context, dark, CGPointMake(0, 0), CGPointMake(kRampWidth, 0), kExtend);
            const unsigned char *pixels = CGBitmapContextGetData(context);
            for (size_t y = 0; y < kRampHeight; y++) {
                for (size_t x = 0; x < kRampWidth; x++) {
                    double deviation = fabs(pixels[(y * kRampWidth + x) * 4 + 1] - sRGBEncoding(0.02 * (x + 0.5) / kRampWidth) * 255);
                    worst[pass] = fmax(worst[pass], deviation);
                    mean[pass] += deviation / (kRampWidth * kRampHeight);
                }
            }
            CGContextRelease(context);
        }
        printf("  gamma-1 ramp into sRGB, deviation from exact: archive worst %.2f mean %.3f, 10.9 worst %.2f mean %.3f\n",
            worst[0], mean[0], worst[1], mean[1]);
        check(worst[0] <= worst[1] && mean[0] <= mean[1], "a gamma-1 ramp into sRGB is no noisier than 10.9's draw");

        // The same ramp as a conic gradient, whose ramp is sampled in its own colour space: every level the
        // exact encoding of the ramp rounds to, each pixel within a level of exact.
        CGContextRef conic = CGBitmapContextCreate(NULL, 256, 256, 8, 256 * 4, sRGB, kBGRA);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        CGContextDrawConicGradient(conic, dark, CGPointMake(128, 128), 0);
#pragma clang diagnostic pop
        bool conicLevels[256] = { false }, exactLevels[256] = { false };
        const unsigned char *conicPixels = CGBitmapContextGetData(conic);
        double conicWorst = 0;
        for (size_t y = 0; y < 256; y++) {
            for (size_t x = 0; x < 256; x++) {
                unsigned char level = conicPixels[(y * 256 + x) * 4 + 1];
                conicLevels[level] = true;
                double dx = x + 0.5 - 128, dy = 128 - (y + 0.5);
                double turn = atan2(dy, dx);
                if (turn < 0)
                    turn += 2 * M_PI;
                if (hypot(dx, dy) > 4)
                    conicWorst = fmax(conicWorst, fabs(level - sRGBEncoding(0.02 * turn / (2 * M_PI)) * 255));
            }
        }
        int missing = 0;
        for (size_t x = 0; x < kRampWidth; x++)
            exactLevels[(int)lround(sRGBEncoding(0.02 * (x + 0.5) / kRampWidth) * 255)] = true;
        for (int level = 0; level < 256; level++)
            if (exactLevels[level] && !conicLevels[level]) {
                printf("    level %d missing\n", level);
                missing++;
            }
        printf("  gamma-1 conic into sRGB: %d of the exact levels missing, worst deviation from exact %.2f\n", missing, conicWorst);
        check(!missing && conicWorst <= 1.5, "a gamma-1 conic gradient into sRGB keeps every level, within a level of exact");
        CGContextRelease(conic);
        CGGradientRelease(dark);
    }

    // Under the copy blend mode the bitmap's transparent surroundings would clear the destination, so the
    // draw is 10.9's own: a gradient without extension over an opaque fill.
    CGContextRef copied = createBitmap(linear), copiedStock = createBitmap(linear);
    for (int pass = 0; pass < 2; pass++) {
        CGContextRef context = pass ? copiedStock : copied;
        CGContextSetFillColorSpace(context, sRGB);
        CGContextSetFillColor(context, green);
        CGContextFillRect(context, CGRectMake(0, 0, kWidth, kHeight));
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        if (pass)
            systemLinear(context, ramp, CGPointMake(20, 0), CGPointMake(60, 0), 0);
        else
            CGContextDrawLinearGradient(context, ramp, CGPointMake(20, 0), CGPointMake(60, 0), 0);
    }
    check(!memcmp(CGBitmapContextGetData(copied), CGBitmapContextGetData(copiedStock), kWidth * kHeight * 4),
        "under the copy blend mode the draw is 10.9's own");
    CGContextRelease(copied);
    CGContextRelease(copiedStock);

    CGContextRef own = createBitmap(sRGB), ownStock = createBitmap(sRGB);
    CGContextDrawLinearGradient(own, ramp, CGPointMake(0, 0), CGPointMake(kWidth, 0), kExtend);
    systemLinear(ownStock, ramp, CGPointMake(0, 0), CGPointMake(kWidth, 0), kExtend);
    check(!memcmp(CGBitmapContextGetData(own), CGBitmapContextGetData(ownStock), kWidth * kHeight * 4),
        "a gradient in the bitmap's own colour space is 10.9's own drawing");
    CGContextRelease(own);
    CGContextRelease(ownStock);

    {
        CGColorSpaceRef adobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
        const CGFloat greenComponents[] = { 0, 1, 0, 1, 0, 1, 0, 1 };
        CGGradientRef green = CGGradientCreateWithColorComponents(adobe, greenComponents, NULL, 2);
        CGContextRef conic = createBitmap(adobe);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        CGContextDrawConicGradient(conic, green, CGPointMake(kWidth / 2, kHeight / 2), 0);
#pragma clang diagnostic pop
        const unsigned char *pixel = (const unsigned char *)CGBitmapContextGetData(conic) + (10 * kWidth + 10) * 4;
        printf("  conic Adobe RGB green into Adobe RGB: BGRA %u,%u,%u,%u\n", pixel[0], pixel[1], pixel[2], pixel[3]);
        check(pixel[0] <= 1 && pixel[1] >= 254 && pixel[2] <= 1 && pixel[3] == 255, "a conic gradient keeps a wide-gamut colour");
        CGContextRelease(conic);
        CGGradientRelease(green);
        CGColorSpaceRelease(adobe);
    }

    CGGradientRelease(hard);
    CGGradientRelease(ramp);
    CGColorSpaceRelease(linear);
    CGColorSpaceRelease(sRGB);
    return failures ? 1 : 0;
}
