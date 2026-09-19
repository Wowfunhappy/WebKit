#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <stdio.h>
#include <string.h>

extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
extern CGImageRef CGIOSurfaceContextCreateImageReference(CGContextRef);

int main(void)
{
    int side = 4, bytesPerElement = 4;
    CFNumberRef size = CFNumberCreate(NULL, kCFNumberIntType, &side);
    CFNumberRef element = CFNumberCreate(NULL, kCFNumberIntType, &bytesPerElement);
    const void *keys[] = { kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerElement };
    const void *values[] = { size, size, element };
    CFDictionaryRef properties = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGIOSurfaceContextCreate(surface, side, side, 8, 32, space,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!surface || !context)
        return 1;
    CGContextClearRect(context, CGRectMake(0, 0, side, side));
    CGContextFlush(context);

    const unsigned char colors[][4] = { { 0, 0, 0, 0 }, { 255, 0, 0, 255 }, { 0, 0, 255, 255 } };
    int failures = 0;
    for (unsigned step = 0; step < sizeof(colors) / sizeof(colors[0]); ++step) {
        if (step) {
            IOSurfaceLock(surface, 0, NULL);
            for (int y = 0; y < side; ++y) {
                unsigned char *row = (unsigned char *)IOSurfaceGetBaseAddress(surface) + y * IOSurfaceGetBytesPerRow(surface);
                for (int x = 0; x < side; ++x) {
                    row[4 * x] = colors[step][2];
                    row[4 * x + 1] = colors[step][1];
                    row[4 * x + 2] = colors[step][0];
                    row[4 * x + 3] = colors[step][3];
                }
            }
            IOSurfaceUnlock(surface, 0, NULL);
        }
        CGImageRef image = CGIOSurfaceContextCreateImageReference(context);
        unsigned char pixel[4] = { 0 };
        CGContextRef destination = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, kCGImageAlphaPremultipliedLast);
        if (!image || !destination)
            return 1;
        CGContextDrawImage(destination, CGRectMake(0, 0, 1, 1), image);
        int passed = !memcmp(pixel, colors[step], sizeof(pixel));
        printf("reference after external write %u: %u,%u,%u,%u %s\n", step,
            pixel[0], pixel[1], pixel[2], pixel[3], passed ? "PASS" : "FAIL");
        failures += !passed;
        CGContextRelease(destination);
        CGImageRelease(image);
    }
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    CFRelease(surface);
    CFRelease(properties);
    CFRelease(size);
    CFRelease(element);
    return failures != 0;
}
