// The destinations the CGContextDrawImage replacement (polyfills/c/CoreGraphics.c) records for a marked image
// are IOSurface contexts only.
//
// Gate J: an asynchronously drawing Core Animation layer's drawing context, which is built on QuartzCore's
// renderer delegate as an IOSurface context's is, keeps its own delegate callbacks after a marked image is
// drawn into it, while an IOSurface context given the same image is recorded and has its delegate wrapped,
// and the context whose image was made is watched.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include <IOSurface/IOSurface.h>
#include <stdio.h>

extern CGColorSpaceRef CGContextGetColorSpace(CGContextRef);
extern CGContextRef CGIOSurfaceContextCreate(IOSurfaceRef, size_t, size_t, size_t, size_t, CGColorSpaceRef, CGBitmapInfo);
extern CGImageRef CGIOSurfaceContextCreateImage(CGContextRef);
extern void *CGContextGetDelegate(CGContextRef);
extern void *CGContextDelegateGetCallback(void *delegate, int name);
extern bool wk_drawsThroughCoreAnimationIOSurface(CGContextRef);

enum { kSide = 64, kDrawImageCallback = 7 };
static const CGBitmapInfo kBGRA = (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static CGContextRef createSurfaceContext(CGColorSpaceRef space)
{
    int side = kSide, bytesPerElement = 4, bytesPerRow = kSide * 4;
    unsigned format = 'BGRA';
    NSDictionary *properties = @{ (id)kIOSurfaceWidth: @(side), (id)kIOSurfaceHeight: @(side), (id)kIOSurfaceBytesPerElement: @(bytesPerElement),
        (id)kIOSurfaceBytesPerRow: @(bytesPerRow), (id)kIOSurfacePixelFormat: @(format) };
    IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
    CGContextRef context = surface ? CGIOSurfaceContextCreate(surface, kSide, kSide, 8, 32, space, kBGRA) : NULL;
    if (surface)
        CFRelease(surface);
    if (context) {
        CGContextClearRect(context, CGRectMake(0, 0, kSide, kSide));
        CGContextFlush(context);
    }
    return context;
}

static bool gDrawn, gLayerThroughCoreAnimation, gLayerKept, gSurfaceWrapped, gSourceWatched;

@interface ProbeDelegate : NSObject <CALayerDelegate>
@end

@implementation ProbeDelegate
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context
{
    CGColorSpaceRef space = CGContextGetColorSpace(context);
    CGContextRef source = createSurfaceContext(space);
    CGContextRef surfaceDestination = createSurfaceContext(space);
    if (!source || !surfaceDestination)
        return;
    void *sourceCallback = CGContextDelegateGetCallback(CGContextGetDelegate(source), kDrawImageCallback);
    void *layerCallback = CGContextDelegateGetCallback(CGContextGetDelegate(context), kDrawImageCallback);
    void *surfaceCallback = CGContextDelegateGetCallback(CGContextGetDelegate(surfaceDestination), kDrawImageCallback);
    CGContextSetRGBFillColor(source, 0, 1, 0, 1);
    CGContextFillRect(source, CGRectMake(0, 0, kSide, kSide));
    CGImageRef image = CGIOSurfaceContextCreateImage(source);

    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image);
    CGContextDrawImage(surfaceDestination, CGRectMake(0, 0, kSide, kSide), image);

    gLayerThroughCoreAnimation = wk_drawsThroughCoreAnimationIOSurface(context);
    gLayerKept = CGContextDelegateGetCallback(CGContextGetDelegate(context), kDrawImageCallback) == layerCallback;
    gSurfaceWrapped = CGContextDelegateGetCallback(CGContextGetDelegate(surfaceDestination), kDrawImageCallback) != surfaceCallback;
    gSourceWatched = CGContextDelegateGetCallback(CGContextGetDelegate(source), kDrawImageCallback) != sourceCallback;
    gDrawn = true;

    CGImageRelease(image);
    CGContextRelease(surfaceDestination);
    CGContextRelease(source);
}
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, kSide, kSide)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        NSView *view = [window contentView];
        [view setWantsLayer:YES];
        ProbeDelegate *delegate = [[ProbeDelegate alloc] init];
        CALayer *layer = [CALayer layer];
        layer.drawsAsynchronously = YES;
        layer.frame = CGRectMake(0, 0, kSide, kSide);
        layer.delegate = delegate;
        [view.layer addSublayer:layer];
        [layer setNeedsDisplay];
        [window orderFront:nil];
        [CATransaction flush];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];

        printf("A marked image drawn into an asynchronous layer's context and into an IOSurface context:\n");
        check(gDrawn && gLayerThroughCoreAnimation, "J: the layer's context draws through QuartzCore's renderer delegate");
        check(gDrawn && gLayerKept, "J: the layer's context keeps its own delegate callbacks");
        check(gDrawn && gSurfaceWrapped, "J: the IOSurface context's delegate is wrapped");
        check(gDrawn && gSourceWatched, "J: the context the image was made from is watched");
        [window orderOut:nil];
    }
    printf("%s\n", failures ? "FAIL" : "PASS");
    return failures ? 1 : 0;
}
