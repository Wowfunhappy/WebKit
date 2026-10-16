// The Core Image polyfills (polyfills/methods/CoreImage.m), each against what the API it supplies does:
// the CIFilterBuiltins accessors answer the named filters with their inputs set; CIColor's clear colour
// and colour-space colour; CIImage's unpremultiplied image; CIKernel's extent-and-callback application
// of a kernel-language kernel and the Metal compiler's refusal; each CIBlendKernel operator on two
// premultiplied colours; a render task's placement of `fromRect` at `atPoint` of an IOSurface; and the
// filters 10.9 does not register: rectangle morphology and the per-axis Gaussian blur.
#import <CoreImage/CoreImage.h>
#import <CoreImage/CIFilterBuiltins.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

// A context without colour management, so components read back as they were computed.
static CIContext *context(void)
{
    return [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null], kCIContextWorkingFormat: @(kCIFormatRGBAf),
        kCIContextUseSoftwareRenderer: @YES }];
}

// The premultiplied RGBA of `image` at (x, y) of its extent, as floats.
static void readPixel(CIImage *image, CGFloat x, CGFloat y, float out[4])
{
    float pixel[4] = { -1, -1, -1, -1 };
    [context() render:image toBitmap:pixel rowBytes:16 bounds:CGRectMake(x, y, 1, 1) format:kCIFormatRGBAf colorSpace:NULL];
    for (int i = 0; i < 4; i++)
        out[i] = pixel[i];
}

// A context working in sRGB, as WebCore's filter contexts work in a colour space, for the filters below.
static CIContext *managedContext(void)
{
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIContext *result = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: (id)sRGB, kCIContextWorkingFormat: @(kCIFormatRGBAf),
        kCIContextUseSoftwareRenderer: @YES }];
    CGColorSpaceRelease(sRGB);
    return result;
}

static float alphaAt(CIImage *image, CGFloat x, CGFloat y)
{
    float pixel[4] = { -1, -1, -1, -1 };
    [managedContext() render:image toBitmap:pixel rowBytes:16 bounds:CGRectMake(x, y, 1, 1) format:kCIFormatRGBAf colorSpace:NULL];
    return pixel[3];
}

// The same, colour-managed into extended sRGB.
static void readPixelInSRGB(CIImage *image, CGFloat x, CGFloat y, float out[4])
{
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIContext *managed = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: (id)sRGB, kCIContextUseSoftwareRenderer: @YES }];
    [managed render:image toBitmap:out rowBytes:16 bounds:CGRectMake(x, y, 1, 1) format:kCIFormatRGBAf colorSpace:sRGB];
    CGColorSpaceRelease(sRGB);
}

static bool near(const float a[4], float r, float g, float b, float alpha)
{
    return fabsf(a[0] - r) < 0.01f && fabsf(a[1] - g) < 0.01f && fabsf(a[2] - b) < 0.01f && fabsf(a[3] - alpha) < 0.01f;
}

static CIImage *solid(CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
    return [[CIImage imageWithColor:[CIColor colorWithRed:r green:g blue:b alpha:a]] imageByCroppingToRect:CGRectMake(0, 0, 4, 4)];
}

int main(void)
{
    @autoreleasepool {
        struct { SEL selector; NSString *name; } builtins[] = {
            { @selector(sourceOverCompositingFilter), @"CISourceOverCompositing" },
            { @selector(multiplyBlendModeFilter), @"CIMultiplyBlendMode" },
            { @selector(screenBlendModeFilter), @"CIScreenBlendMode" },
            { @selector(darkenBlendModeFilter), @"CIDarkenBlendMode" },
            { @selector(lightenBlendModeFilter), @"CILightenBlendMode" },
            { @selector(overlayBlendModeFilter), @"CIOverlayBlendMode" },
            { @selector(colorDodgeBlendModeFilter), @"CIColorDodgeBlendMode" },
            { @selector(colorBurnBlendModeFilter), @"CIColorBurnBlendMode" },
            { @selector(hardLightBlendModeFilter), @"CIHardLightBlendMode" },
            { @selector(softLightBlendModeFilter), @"CISoftLightBlendMode" },
            { @selector(differenceBlendModeFilter), @"CIDifferenceBlendMode" },
            { @selector(exclusionBlendModeFilter), @"CIExclusionBlendMode" },
            { @selector(hueBlendModeFilter), @"CIHueBlendMode" },
            { @selector(saturationBlendModeFilter), @"CISaturationBlendMode" },
            { @selector(colorBlendModeFilter), @"CIColorBlendMode" },
            { @selector(luminosityBlendModeFilter), @"CILuminosityBlendMode" },
        };
        bool everyBuiltin = true;
        for (size_t i = 0; i < sizeof(builtins) / sizeof(builtins[0]); i++) {
            CIFilter *filter = nil;
            switch (i) {
            case 0: filter = [CIFilter sourceOverCompositingFilter]; break;
            case 1: filter = [CIFilter multiplyBlendModeFilter]; break;
            case 2: filter = [CIFilter screenBlendModeFilter]; break;
            case 3: filter = [CIFilter darkenBlendModeFilter]; break;
            case 4: filter = [CIFilter lightenBlendModeFilter]; break;
            case 5: filter = [CIFilter overlayBlendModeFilter]; break;
            case 6: filter = [CIFilter colorDodgeBlendModeFilter]; break;
            case 7: filter = [CIFilter colorBurnBlendModeFilter]; break;
            case 8: filter = [CIFilter hardLightBlendModeFilter]; break;
            case 9: filter = [CIFilter softLightBlendModeFilter]; break;
            case 10: filter = [CIFilter differenceBlendModeFilter]; break;
            case 11: filter = [CIFilter exclusionBlendModeFilter]; break;
            case 12: filter = [CIFilter hueBlendModeFilter]; break;
            case 13: filter = [CIFilter saturationBlendModeFilter]; break;
            case 14: filter = [CIFilter colorBlendModeFilter]; break;
            case 15: filter = [CIFilter luminosityBlendModeFilter]; break;
            }
            everyBuiltin &= [[filter.attributes objectForKey:kCIAttributeFilterName] isEqualToString:builtins[i].name];
        }
        check(everyBuiltin, "each CIFilterBuiltins blend accessor answers its named filter");

        CIFilter<CIStripesGenerator> *stripes = [CIFilter stripesGeneratorFilter];
        stripes.width = 30;
        stripes.sharpness = 0.9f;
        stripes.color0 = [CIColor clearColor];
        stripes.color1 = [CIColor colorWithRed:1 green:0.95 blue:0 alpha:0.35];
        check([[stripes valueForKey:@"inputWidth"] floatValue] == 30 && fabsf([[stripes valueForKey:@"inputSharpness"] floatValue] - 0.9f) < 1e-6,
            "the stripes generator's width and sharpness set its inputs");
        CIColor *color0 = [stripes valueForKey:@"inputColor0"];
        check(color0.alpha == 0 && color0.red == 0, "its colour0 is the clear colour");
        check([stripes outputImage] != nil, "and it has an output image");

        CGColorSpaceRef adobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
        CIColor *adobeGreen = [CIColor colorWithRed:0 green:1 blue:0 alpha:1 colorSpace:adobe];
        float pixel[4];
        readPixelInSRGB([[CIImage imageWithColor:adobeGreen] imageByCroppingToRect:CGRectMake(0, 0, 1, 1)], 0, 0, pixel);
        check(adobeGreen && pixel[0] < 0 && pixel[1] > 1, "a colour-space colour carries its space (Adobe RGB green is out of sRGB)");
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        check(![CIColor colorWithRed:0 green:1 blue:0 alpha:1 colorSpace:gray], "a colour in a space that is not RGB is nil");
        CGColorSpaceRelease(gray);
        CGColorSpaceRelease(adobe);

        CIImage *unpremultiplied = [solid(0.25, 0.25, 0.25, 0.5) imageByUnpremultiplyingAlpha];
        readPixel(unpremultiplied, 1, 1, pixel);
        // solid() takes unpremultiplied components: 0.25 at alpha 0.5 is stored as 0.125.
        check(near(pixel, 0.25f, 0.25f, 0.25f, 0.5f), "an unpremultiplied image divides colour by alpha");

        NSError *error = nil;
        check(![CIKernel kernelsWithMetalString:@"kernel void k() {}" error:&error] && error, "a Metal kernel is refused with an error");

        CIKernel *invert = [CIKernel kernelsWithString:@"kernel vec4 invert(sampler s) { vec4 p = sample(s, samplerCoord(s)); return vec4(p.a - p.rgb, p.a); }"][0];
        __block int roiCalls = 0;
        CIImage *inverted = [invert applyWithExtent:CGRectMake(0, 0, 4, 4) roiCallback:^CGRect(int __unused index, CGRect destRect) {
            roiCalls++;
            return destRect;
        } arguments:@[ solid(0.2, 0.4, 0.6, 1) ]];
        readPixel(inverted, 1, 1, pixel);
        check(near(pixel, 0.8f, 0.6f, 0.4f, 1) && CGRectEqualToRect(inverted.extent, CGRectMake(0, 0, 4, 4)),
            "an applied kernel draws its result over the given extent");
        // A kernel that reads one pixel to its right: its region of interest is the callback's to say.
        CIKernel *shift = [CIKernel kernelsWithString:@"kernel vec4 shift(sampler s) { return sample(s, samplerTransform(s, destCoord() + vec2(1.0, 0.0))); }"][0];
        __block int shiftCalls = 0;
        CIImage *ramp = [[CIImage imageWithColor:[CIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1]] imageByCroppingToRect:CGRectMake(0, 0, 4, 4)];
        CIImage *shifted = [shift applyWithExtent:CGRectMake(0, 0, 4, 4) roiCallback:^CGRect(int __unused index, CGRect destRect) {
            shiftCalls++;
            return CGRectOffset(destRect, 1, 0);
        } arguments:@[ ramp ]];
        readPixel(shifted, 3, 1, pixel);
        printf("  region-of-interest calls: %d, %d; shifted pixel %f\n", roiCalls, shiftCalls, pixel[0]);
        check(shiftCalls > 0, "and asks the callback for its region of interest");

        // Premultiplied, the foreground is (0.25, 0, 0, 0.5) and the background (0, 0, 0.5625, 0.75).
        CIImage *front = solid(0.5, 0, 0, 0.5), *back = solid(0, 0, 0.75, 0.75);
        struct { CIBlendKernel *kernel; float r, b, a; const char *name; } blends[] = {
            { [CIBlendKernel sourceOver], 0.25f, 0.28125f, 0.875f, "source-over" },
            { [CIBlendKernel sourceIn], 0.1875f, 0, 0.375f, "source-in" },
            { [CIBlendKernel sourceOut], 0.0625f, 0, 0.125f, "source-out" },
            { [CIBlendKernel sourceAtop], 0.1875f, 0.28125f, 0.75f, "source-atop" },
            { [CIBlendKernel exclusiveOr], 0.0625f, 0.28125f, 0.5f, "exclusive-or" },
            { [CIBlendKernel componentAdd], 0.25f, 0.5625f, 1.25f, "component-add" },
        };
        for (size_t i = 0; i < sizeof(blends) / sizeof(blends[0]); i++) {
            readPixel([blends[i].kernel applyWithForeground:front background:back], 1, 1, pixel);
            char what[96];
            snprintf(what, sizeof(what), "CIBlendKernel %s composites premultiplied colours", blends[i].name);
            check(near(pixel, blends[i].r, 0, blends[i].b, blends[i].a), what);
        }

        // Rectangle morphology over a white 4x4 square at (10, 10): a 3x3 minimum keeps its inner 2x2, a 3x3
        // maximum grows it by one, and a 101-wide maximum of one pixel reaches exactly 50 each side.
        CIImage *square = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]] imageByCroppingToRect:CGRectMake(10, 10, 4, 4)];
        CIFilter *erode = [CIFilter filterWithName:@"CIMorphologyRectangleMinimum"];
        [erode setValue:square forKey:kCIInputImageKey];
        [erode setValue:@3 forKey:@"inputWidth"];
        [erode setValue:@3 forKey:@"inputHeight"];
        check(alphaAt(erode.outputImage, 11, 11) > 0.99f && alphaAt(erode.outputImage, 10, 11) < 0.01f, "a 3x3 rectangle minimum erodes a square by one pixel");
        CIFilter *dilate = [CIFilter filterWithName:@"CIMorphologyRectangleMaximum"];
        [dilate setValue:square forKey:kCIInputImageKey];
        [dilate setValue:@3 forKey:@"inputWidth"];
        [dilate setValue:@3 forKey:@"inputHeight"];
        check(alphaAt(dilate.outputImage, 9, 9) > 0.99f && alphaAt(dilate.outputImage, 8, 9) < 0.01f, "a 3x3 rectangle maximum dilates it by one pixel");
        CIImage *dot = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]] imageByCroppingToRect:CGRectMake(100, 100, 1, 1)];
        [dilate setValue:dot forKey:kCIInputImageKey];
        [dilate setValue:@201 forKey:@"inputWidth"];
        [dilate setValue:@3 forKey:@"inputHeight"];
        check(alphaAt(dilate.outputImage, 200, 101) > 0.99f && alphaAt(dilate.outputImage, 201, 101) < 0.01f && alphaAt(dilate.outputImage, 0, 99) > 0.99f,
            "a 201x3 maximum reaches 100 pixels each side, over several passes");

        // CIGaussianBlurXY of one white pixel: the result keeps its energy, and falls off along each axis
        // by that axis's deviation (sigmaX 2, sigmaY 4; and 30, which takes several passes).
        CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlurXY"];
        CGFloat sigmas[2][2] = { { 2, 4 }, { 30, 30 } };
        for (int run = 0; run < 2; run++) {
            [blur setValue:dot forKey:kCIInputImageKey];
            [blur setValue:@(sigmas[run][0]) forKey:@"inputSigmaX"];
            [blur setValue:@(sigmas[run][1]) forKey:@"inputSigmaY"];
            CGRect area = CGRectMake(100 - 90, 100 - 90, 181, 181);
            float *pixels = calloc(181 * 181, 16);
            [managedContext() render:blur.outputImage toBitmap:pixels rowBytes:181 * 16 bounds:area format:kCIFormatRGBAf colorSpace:NULL];
            double energy = 0;
            for (int i = 0; i < 181 * 181; i++)
                energy += pixels[i * 4 + 3];
            // The bitmap's first row is the area's top; the dot is at its centre, (90, 90).
            double centre = pixels[(90 * 181 + 90) * 4 + 3];
            double alongX = pixels[(90 * 181 + 90 + (int)sigmas[run][0]) * 4 + 3] / centre;
            double alongY = pixels[((90 - (int)sigmas[run][1]) * 181 + 90) * 4 + 3] / centre;
            printf("  blur sigma %.0f,%.0f: energy %.4f, one deviation along x %.3f, along y %.3f (exp(-1/2) = 0.607)\n",
                sigmas[run][0], sigmas[run][1], energy, alongX, alongY);
            char what[96];
            snprintf(what, sizeof(what), "CIGaussianBlurXY with deviations %.0f and %.0f", sigmas[run][0], sigmas[run][1]);
            check(fabs(energy - 1) < 0.02 && fabs(alongX - 0.6065) < 0.03 && fabs(alongY - 0.6065) < 0.03, what);
            free(pixels);
        }

        // A red 2x2 square at (1, 1) of a 4x4 image, rendered from (1, 1, 2, 2) to (5, 3) of an 8x8 surface.
        int side = 8, bytesPerElement = 4;
        unsigned format = 'BGRA';
        NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(side), (id)kIOSurfaceHeight: @(side), (id)kIOSurfaceBytesPerElement: @(bytesPerElement),
            (id)kIOSurfacePixelFormat: @(format) };
        IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
        IOSurfaceLock(surface, 0, NULL);
        memset(IOSurfaceGetBaseAddress(surface), 0x40, IOSurfaceGetAllocSize(surface));
        IOSurfaceUnlock(surface, 0, NULL);
        CIImage *red = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0 alpha:1]] imageByCroppingToRect:CGRectMake(1, 1, 2, 2)];
        CIRenderDestination *destination = [[CIRenderDestination alloc] initWithIOSurface:(id)surface];
        CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        destination.colorSpace = sRGB;
        CIRenderTask *task = [context() startTaskToRender:red fromRect:CGRectMake(1, 1, 2, 2) toDestination:destination atPoint:CGPointMake(5, 3) error:nil];
        CIRenderInfo *info = [task waitUntilCompletedAndReturnError:nil];
        check(task && info, "a render task completes");
        check(info.pixelsProcessed == 4 && info.kernelExecutionTime >= 0 && info.kernelExecutionTime < 10,
            "its info reports the 2x2 area drawn and the render's time");
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        const unsigned char *base = IOSurfaceGetBaseAddress(surface);
        size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
        int painted = 0, misplaced = 0;
        for (int y = 0; y < side; y++) {
            for (int x = 0; x < side; x++) {
                const unsigned char *p = base + y * rowBytes + x * 4;
                bool isRed = p[2] > 200 && p[0] < 16 && p[1] < 16;
                bool untouched = p[0] == 0x40 && p[1] == 0x40 && p[2] == 0x40 && p[3] == 0x40;
                // Destination coordinates run up from the bottom row; the surface's first row is the top.
                int destinationY = side - 1 - y;
                bool inside = x >= 5 && x < 7 && destinationY >= 3 && destinationY < 5;
                painted += isRed && inside;
                misplaced += inside ? !isRed : !untouched;
            }
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        printf("  render task: %d of 4 pixels painted, %d misplaced\n", painted, misplaced);

        check(painted == 4 && !misplaced, "it places fromRect at atPoint and leaves the rest of the destination");
        [destination release];
        CGColorSpaceRelease(sRGB);
        CFRelease(surface);
    }
    return failures ? 1 : 0;
}
