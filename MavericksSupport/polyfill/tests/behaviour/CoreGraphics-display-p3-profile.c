#include <CoreGraphics/CoreGraphics.h>
#include <png.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char** argv)
{
    assert(argc == 2);
    FILE* input = fopen(argv[1], "rb");
    assert(input);
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    png_infop info = png_create_info_struct(png);
    assert(png && info);
    assert(!setjmp(png_jmpbuf(png)));
    png_init_io(png, input);
    png_read_info(png, info);
    char* name;
    unsigned char* bytes;
    png_uint_32 length;
    int compression;
    assert(png_get_iCCP(png, info, &name, &compression, &bytes, &length));
    CFDataRef data = CFDataCreate(NULL, bytes, length);
    CGColorSpaceRef sourceSpace = CGColorSpaceCreateWithICCProfile(data);
    CGColorSpaceRef destination = CGColorSpaceCreateWithName(CFSTR("kCGColorSpaceDisplayP3"));
    assert(sourceSpace && destination);
    const unsigned char samples[][4] = {
        { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 },
        { 255, 0, 0, 204 }, { 187, 0, 0, 255 }
    };
    for (unsigned i = 0; i < sizeof(samples) / sizeof(samples[0]); ++i) {
        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, samples[i], 4, NULL);
        CGImageRef image = CGImageCreate(1, 1, 8, 32, 4, sourceSpace, kCGImageAlphaLast, provider, NULL, false, kCGRenderingIntentDefault);
        unsigned char pixel[4] = { 0 };
        CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, destination, kCGImageAlphaPremultipliedLast);
        assert(image && context);
        CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image);
        for (unsigned channel = 0; channel < 4; ++channel) {
            int expected = channel == 3 ? samples[i][3] : samples[i][channel] * samples[i][3] / 255;
            assert(abs(pixel[channel] - expected) <= 1);
        }
        CGContextRelease(context);
        CGImageRelease(image);
        CGDataProviderRelease(provider);
    }
    assert(CGColorSpaceIsWideGamutRGB(destination));
    const CGFloat white[] = { .95047, 1, 1.08883 };
    const CGFloat gamma[] = { 1.7, 1.7, 1.7 };
    const CGFloat matrix[] = {
        .4865709486, .2289745641, 0,
        .2656676932, .6917385218, .0451133819,
        .1982172852, .0792869141, 1.0439443689
    };
    CGColorSpaceRef custom = CGColorSpaceCreateCalibratedRGB(white, NULL, gamma, matrix);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    assert(custom && srgb && gray);
    assert(CGColorSpaceIsWideGamutRGB(custom));
    assert(!CGColorSpaceIsWideGamutRGB(srgb));
    assert(!CGColorSpaceIsWideGamutRGB(gray));
    CGColorSpaceRelease(gray);
    CGColorSpaceRelease(srgb);
    CGColorSpaceRelease(custom);
    CGColorSpaceRelease(destination);
    CGColorSpaceRelease(sourceSpace);
    CFRelease(data);
    png_destroy_read_struct(&png, &info, NULL);
    fclose(input);
    puts("PASS Display P3 ICC primary and translucent pixel preservation");
}
