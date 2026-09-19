// Split text uses vertically unbounded clips. Its glyphs must composite once on an IOSurface.
#include <CoreText/CoreText.h>
#include <IOSurface/IOSurface.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);

enum { width = 640, height = 280 };
static unsigned char pixels[2][width * height * 4];

static bool draw(bool split)
{
    int w = width, h = height, pixelBytes = 4;
    CFNumberRef widthNumber = CFNumberCreate(NULL, kCFNumberIntType, &w);
    CFNumberRef heightNumber = CFNumberCreate(NULL, kCFNumberIntType, &h);
    CFNumberRef bytesNumber = CFNumberCreate(NULL, kCFNumberIntType, &pixelBytes);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement };
    const void *values[] = { widthNumber, heightNumber, bytesNumber };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    CFRelease(widthNumber);
    CFRelease(heightNumber);
    CFRelease(bytesNumber);
    if (!surface)
        return false;

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGIOSurfaceContextCreate(surface, width, height, 8, 32, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (!context) {
        CFRelease(surface);
        return false;
    }
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextSetShouldSmoothFonts(context, false);
    CGContextSetShouldSubpixelPositionFonts(context, true);
    CGContextSetShouldSubpixelQuantizeFonts(context, true);

    CTFontRef font = CTFontCreateWithName(CFSTR("Baghdad"), 50, NULL);
    CGGlyph glyphs[] = { 114, 50 };
    CGPoint positions[] = { { 8, 208 }, { 25.3583984375, 208 } };
    if (!split)
        CTFontDrawGlyphs(font, glyphs, positions, 2, context);
    else {
        for (unsigned side = 0; side < 2; ++side) {
            CGContextSaveGState(context);
            CGContextClipToRect(context, CGRectMake(side ? 24 : 8, -FLT_MAX / 2, side ? FLT_MAX : 16, FLT_MAX));
            CTFontDrawGlyphs(font, glyphs, positions, 2, context);
            CGContextRestoreGState(context);
        }
    }

    CGContextFlush(context);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    const unsigned char *base = IOSurfaceGetBaseAddress(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    for (unsigned y = 0; y < height; ++y)
        memcpy(pixels[split] + width * 4 * y, base + stride * y, width * 4);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(font);
    CGContextRelease(context);
    CFRelease(surface);
    return true;
}

int main(void)
{
    if (!draw(false) || !draw(true)) {
        fprintf(stderr, "FAIL creating IOSurface text context\n");
        return 1;
    }
    unsigned changedPixels = 0, maximumDifference = 0, inkPixels = 0;
    for (unsigned i = 0; i < width * height; ++i) {
        bool changed = false;
        inkPixels += pixels[0][4 * i] < 255;
        for (unsigned channel = 0; channel < 3; ++channel) {
            unsigned difference = abs((int)pixels[0][4 * i + channel] - pixels[1][4 * i + channel]);
            changed |= difference != 0;
            if (difference > maximumDifference)
                maximumDifference = difference;
        }
        changedPixels += changed;
    }
    printf("clipped glyphs: ink=%u, differing pixels=%u, maximum difference=%u\n", inkPixels, changedPixels, maximumDifference);
    return !inkPixels || changedPixels;
}
