// A singular CALayer transform leaves the caller-visible hidden state alone while suppressing the layer's pixels.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static unsigned failures;
#define EXPECT(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); ++failures; } } while (0)

static uint32_t renderPixel(CALayer *root)
{
    uint32_t pixel = 0;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(&pixel, 1, 1, 8, sizeof(pixel), colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    [root renderInContext:context];
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    return pixel;
}

static void callNativeTransform(CALayer *layer, CATransform3D transform)
{
    SEL selector = sel_registerName("setTransform:");
    IMP implementation = class_getMethodImplementation([CALayer class], selector);
    ((void (*)(id, SEL, CATransform3D))implementation)(layer, selector, transform);
}

static void callNativeHidden(CALayer *layer, BOOL hidden)
{
    SEL selector = sel_registerName("setHidden:");
    IMP implementation = class_getMethodImplementation([CALayer class], selector);
    ((void (*)(id, SEL, BOOL))implementation)(layer, selector, hidden);
}

static BOOL nativeHidden(CALayer *layer)
{
    SEL selector = sel_registerName("isHidden");
    IMP implementation = class_getMethodImplementation([CALayer class], selector);
    return ((BOOL (*)(id, SEL))implementation)(layer, selector);
}

int main(void)
{
    @autoreleasepool {
        [CATransaction setDisableActions:YES];
        CALayer *root = [CALayer layer];
        root.bounds = CGRectMake(0, 0, 1, 1);
        CALayer *child = [CALayer layer];
        child.bounds = CGRectMake(0, 0, 1, 1);
        child.anchorPoint = CGPointZero;
        child.position = CGPointZero;
        child.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
        [root addSublayer:child];

        CATransform3D singular = CATransform3DMakeScale(1, 1, 0);
        callNativeTransform(child, singular);
        EXPECT(renderPixel(root));
        EXPECT(!nativeHidden(child));

        callNativeTransform(child, CATransform3DIdentity);
        callNativeHidden(child, YES);
        EXPECT(child.hidden);
        EXPECT(child.isHidden);
        callNativeHidden(child, NO);

        child.transform = CATransform3DMakeTranslation(1, 0, 0);
        EXPECT(!objc_getAssociatedObject(child, sel_registerName("wk_layerCallerHiddenWhileForcingSingularTransform")));
        child.transform = CATransform3DIdentity;

        child.transform = singular;
        EXPECT(!child.hidden);
        EXPECT(nativeHidden(child));
        EXPECT(!renderPixel(root));

        child.hidden = YES;
        child.transform = CATransform3DIdentity;
        EXPECT(child.hidden);
        EXPECT(nativeHidden(child));
        child.hidden = NO;
        EXPECT(!child.hidden);
        EXPECT(!nativeHidden(child));

        callNativeHidden(child, YES);
        child.transform = singular;
        EXPECT(child.hidden);
        EXPECT(nativeHidden(child));
        child.transform = CATransform3DIdentity;
        EXPECT(child.hidden);
        EXPECT(nativeHidden(child));
        callNativeHidden(child, NO);

        child.transform = CATransform3DMakeScale(1, 1, 1e-310);
        EXPECT(!child.hidden);
        EXPECT(!nativeHidden(child));
        EXPECT(renderPixel(root));

        child.affineTransform = CGAffineTransformMakeScale(0, 1);
        EXPECT(!child.hidden);
        EXPECT(nativeHidden(child));
        EXPECT(!renderPixel(root));
        child.transform = CATransform3DIdentity;
        EXPECT(!child.hidden);
        EXPECT(!nativeHidden(child));
        EXPECT(!objc_getAssociatedObject(child, sel_registerName("wk_layerCallerHiddenWhileForcingSingularTransform")));

        callNativeTransform(child, singular);
        callNativeHidden(child, YES);
        child.transform = CATransform3DIdentity;
        EXPECT(child.hidden);
        EXPECT(nativeHidden(child));
        EXPECT(!objc_getAssociatedObject(child, sel_registerName("wk_layerCallerHiddenWhileForcingSingularTransform")));
        callNativeHidden(child, NO);

        [child setValue:[NSValue valueWithCATransform3D:singular] forKey:@"transform"];
        EXPECT(!nativeHidden(child));
        child.transform = singular;
        EXPECT(!child.hidden);
        EXPECT(nativeHidden(child));
        EXPECT(!renderPixel(root));

        callNativeHidden(child, NO);
        EXPECT(!child.hidden);
        child.transform = singular;
        EXPECT(!child.hidden);
        EXPECT(nativeHidden(child));
        child.transform = CATransform3DIdentity;
        EXPECT(!child.hidden);
        EXPECT(!nativeHidden(child));
        EXPECT(renderPixel(root));
    }
    fprintf(stderr, "CALayer singular transform: %u failures\n", failures);
    return failures ? 1 : 0;
}
