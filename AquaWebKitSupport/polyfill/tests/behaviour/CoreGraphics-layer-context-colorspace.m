// CGContextGetColorSpace (polyfills/c/CoreGraphics.c) for the context a Core Animation layer that draws
// asynchronously hands its delegate. That context is built on QuartzCore's renderer delegate and has
// no colour space 10.9's CoreGraphics can report; the answer must be the space QuartzCore renders the
// drawing into, which is the space a synchronously drawn sibling layer's bitmap context carries. The
// archive's CGContextDrawImage then hands QuartzCore a large linear-sRGB image already matched to that
// space, which the window shows at the level CoreGraphics' bitmap route gives; 10.9's own definition,
// drawn into a second asynchronous layer, shows QuartzCore's colour cube instead, which is the premise.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <mach-o/dyld.h>
#include <stdio.h>

extern CGColorSpaceRef CGContextGetColorSpace(CGContextRef);
extern bool wk_drawsThroughCoreAnimationIOSurface(CGContextRef);
extern bool CGColorSpaceEqualToColorSpace(CGColorSpaceRef, CGColorSpaceRef);

enum { kWidth = 256, kHeight = 64 };

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

typedef void (*DrawImageFn)(CGContextRef, CGRect, CGImageRef);

static DrawImageFn systemDrawImage(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CGContextDrawImage", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawImageFn)NSAddressOfSymbol(found) : 0;
}

static CGColorSpaceRef gAsyncSpace, gSyncSpace;
static DrawImageFn gSystemDraw;
static bool gAsyncThroughCoreAnimation, gAsyncDrawn;
static CGImageRef gLevels;

@interface ProbeDelegate : NSObject <CALayerDelegate>
@end

@implementation ProbeDelegate
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    CGColorSpaceRef space = CGContextGetColorSpace(context);
    if ([layer.name isEqualToString:@"stock"])
        gSystemDraw(context, CGRectMake(0, 0, kWidth, kHeight), gLevels);
    else if (layer.drawsAsynchronously) {
        gAsyncSpace = space ? CGColorSpaceRetain(space) : NULL;
        gAsyncThroughCoreAnimation = wk_drawsThroughCoreAnimationIOSurface(context);
        CGContextDrawImage(context, CGRectMake(0, 0, kWidth, kHeight), gLevels);
        gAsyncDrawn = true;
    } else
        gSyncSpace = space ? CGColorSpaceRetain(space) : NULL;
}
@end

static CGColorSpaceRef createLinearSRGB(void)
{
    const CGFloat white[3] = { 0.9505, 1.0, 1.0890 }, black[3] = { 0, 0, 0 }, gamma[3] = { 1, 1, 1 };
    const CGFloat primaries[9] = { 0.4124564, 0.2126729, 0.0193339, 0.3575761, 0.7151522, 0.1191920, 0.1804375, 0.0721750, 0.9503041 };
    return CGColorSpaceCreateCalibratedRGB(white, black, gamma, primaries);
}

// Level x in every colour component of column x.
static CGImageRef createLevels(CGColorSpaceRef space)
{
    CGContextRef bitmap = CGBitmapContextCreate(NULL, kWidth, kHeight, 8, kWidth * 4, space,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    unsigned char *pixels = CGBitmapContextGetData(bitmap);
    for (size_t y = 0; y < kHeight; y++) {
        for (size_t x = 0; x < kWidth; x++) {
            unsigned char *p = pixels + y * kWidth * 4 + x * 4;
            p[0] = p[1] = p[2] = (unsigned char)x;
            p[3] = 0xff;
        }
    }
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    return image;
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        CGColorSpaceRef linear = createLinearSRGB();
        gLevels = createLevels(linear);
        gSystemDraw = systemDrawImage();

        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, kWidth, 3 * kHeight)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        NSView *view = [window contentView];
        [view setWantsLayer:YES];
        ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
        for (int index = 0; index < 3; index++) {
            CALayer *layer = [CALayer layer];
            layer.drawsAsynchronously = index > 0;
            layer.name = index == 2 ? @"stock" : @"archive";
            layer.frame = CGRectMake(0, index * kHeight, kWidth, kHeight);
            layer.delegate = delegate;
            [view.layer addSublayer:layer];
            [layer setNeedsDisplay];
        }
        [window orderFront:nil];
        [CATransaction flush];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];

        check(gAsyncDrawn && gAsyncThroughCoreAnimation, "the asynchronous layer draws through QuartzCore's renderer delegate");
        check(gAsyncSpace && gSyncSpace && CGColorSpaceEqualToColorSpace(gAsyncSpace, gSyncSpace),
            "its context reports the space a synchronous layer's bitmap carries");

        // What CoreGraphics' bitmap route makes of each level, matched into the reported space.
        unsigned char expected[kWidth] = { 0 };
        if (gAsyncSpace) {
            CGContextRef bitmap = CGBitmapContextCreate(NULL, kWidth, 1, 8, kWidth * 4, gAsyncSpace,
                (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGContextDrawImage(bitmap, CGRectMake(0, 0, kWidth, 1), gLevels);
            const unsigned char *pixels = CGBitmapContextGetData(bitmap);
            for (size_t x = 0; x < kWidth; x++)
                expected[x] = pixels[x * 4 + 1];
            CGContextRelease(bitmap);
        }

        // The window's pixels, read back in the same space. The bitmap's first row is the window's top:
        // the stock layer's rows, then the archive's.
        CGImageRef shot = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)[window windowNumber],
            kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
        bool matches = false, stockDiffers = false;
        if (shot && gAsyncSpace && CGImageGetWidth(shot) == kWidth) {
            CGContextRef bitmap = CGBitmapContextCreate(NULL, kWidth, 3 * kHeight, 8, kWidth * 4, gAsyncSpace,
                (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGContextDrawImage(bitmap, CGRectMake(0, 0, kWidth, 3 * kHeight), shot);
            const unsigned char *pixels = CGBitmapContextGetData(bitmap);
            const unsigned char *stock = pixels + (kHeight / 2) * kWidth * 4;
            const unsigned char *archive = pixels + (kHeight + kHeight / 2) * kWidth * 4;
            matches = true;
            for (size_t x = 0; x < kWidth; x++) {
                matches &= abs((int)archive[x * 4 + 1] - (int)expected[x]) <= 1;
                stockDiffers |= abs((int)stock[x * 4 + 1] - (int)expected[x]) > 1;
            }
            printf("    level 1: archive %u, 10.9 %u, bitmap route %u\n", archive[4 + 1], stock[4 + 1], expected[1]);
            CGContextRelease(bitmap);
        }
        if (shot)
            CGImageRelease(shot);
        check(stockDiffers, "10.9's own definition shows QuartzCore's colour cube");
        check(matches, "a large linear-sRGB image drawn into it shows the bitmap route's levels");

        [window orderOut:nil];
        CGImageRelease(gLevels);
        CGColorSpaceRelease(linear);
    }
    return failures ? 1 : 0;
}
