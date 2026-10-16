#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef CFTypeRef (*CreateWithScale)(CFAllocatorRef, CGRect *, CFIndex, CGRect, unsigned long, Boolean, long, Boolean, Boolean, CGFloat);
typedef CFTypeRef (*Create)(CFAllocatorRef, CGRect *, CFIndex, CGRect, unsigned long, Boolean, long, Boolean, Boolean);

extern CFTypeRef DDHighlightCreateWithRectsInVisibleRectWithStyleScaleAndDirection(CFAllocatorRef, CGRect *, CFIndex, CGRect, unsigned long, Boolean, long, Boolean, Boolean, CGFloat);

static int failures;

static void check(int condition, const char *name)
{
    printf("  %s: %s\n", name, condition ? "ok" : "FAIL");
    failures += !condition;
}

int main(void)
{
    void *framework = dlopen("/System/Library/PrivateFrameworks/DataDetectors.framework/DataDetectors", RTLD_LAZY);
    if (!framework)
        return 1;

    CreateWithScale createWithScale = (CreateWithScale)dlsym(framework, "DDHighlightCreateWithRectsInVisibleRectWithStyleScaleAndDirection");
    Create create = (Create)dlsym(framework, "DDHighlightCreateWithRectsInVisibleRectWithStyleAndDirection");
    CGRect (*boundingRect)(CFTypeRef) = (CGRect (*)(CFTypeRef))dlsym(framework, "DDHighlightGetBoundingRect");
    Boolean (*pointIsOn)(CFTypeRef, CGPoint, Boolean *) = (Boolean (*)(CFTypeRef, CGPoint, Boolean *))dlsym(framework, "DDHighlightPointIsOnHighlight");
    CGLayerRef (*layerWithContext)(CFTypeRef, CGContextRef) = (CGLayerRef (*)(CFTypeRef, CGContextRef))dlsym(framework, "DDHighlightGetLayerWithContext");
    check(createWithScale == DDHighlightCreateWithRectsInVisibleRectWithStyleScaleAndDirection, "soft-linked scale constructor");
    if (!createWithScale || !create || !boundingRect || !pointIsOn || !layerWithContext)
        return 1;

    // ServicesOverlayController's selection highlight: bubble + arrow icon, button, flipped.
    unsigned long style = 1 | (1 << 16);
    CGRect visible = CGRectMake(0, 0, 800, 600);
    CGRect rects[] = { CGRectMake(40.25, 40.5, 300.5, 20.25), CGRectMake(40.25, 61, 180, 20) };

    CFTypeRef reference = create(NULL, rects, 2, visible, style, true, 0, false, true);
    CFTypeRef atZero = createWithScale(NULL, rects, 2, visible, style, true, 0, false, true, 0);
    CFTypeRef atTwo = createWithScale(NULL, rects, 2, visible, style, true, 0, false, true, 2);
    check(reference && atZero && atTwo, "highlights created");
    if (!reference || !atZero || !atTwo)
        return 1;

    CGRect referenceBounds = boundingRect(reference);
    check(CGRectEqualToRect(boundingRect(atZero), referenceBounds), "scale 0 is the direction constructor");
    check(CGRectEqualToRect(boundingRect(atTwo), referenceBounds), "scale 2 builds the same point-aligned shapes");
    check(CGRectContainsRect(referenceBounds, rects[0]) && CGRectContainsRect(referenceBounds, rects[1]), "bounds cover the rects");

    Boolean onButton = false;
    check(pointIsOn(atZero, CGPointMake(100, 50), &onButton), "point inside the rects is on the highlight");
    check(!pointIsOn(atZero, CGPointMake(600, 400), &onButton), "point outside is not");

    size_t width = (size_t)CGRectGetWidth(referenceBounds) * 2, height = (size_t)CGRectGetHeight(referenceBounds) * 2;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(context, 2, 2);
    CGLayerRef layer = layerWithContext(atZero, context);
    check(layer != NULL, "layer for a 2x context");
    if (layer)
        CGContextDrawLayerInRect(context, CGRectMake(0, 0, CGRectGetWidth(referenceBounds), CGRectGetHeight(referenceBounds)), layer);
    const unsigned char *pixels = CGBitmapContextGetData(context);
    size_t painted = 0;
    for (size_t i = 0; i < width * height; ++i)
        painted += pixels[i * 4 + 3] != 0;
    check(painted > width * height / 20, "layer paints the highlight");
    CGContextRelease(context);

    CFRelease(reference);
    CFRelease(atZero);
    CFRelease(atTwo);
    return failures ? 1 : 0;
}
