// Compare CSS 3D groups to native depth sorting, and exercise the logical CALayer hierarchy.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

@interface CALayer (WKDepthSorting)
@property BOOL usesWebKitBehavior;
@property BOOL sortsSublayers;
@end

static unsigned failures;
#define EXPECT(...) do { if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); ++failures; } } while (0)

static void configure(CALayer *layer)
{
    layer.usesWebKitBehavior = YES;
    layer.sortsSublayers = [layer isKindOfClass:[CATransformLayer class]];
}

static CATransformLayer *scene(void)
{
    CATransformLayer *group = [CATransformLayer layer];
    configure(group);
    group.frame = CGRectMake(0, 0, 200, 240);
    CALayer *front = [CALayer layer];
    configure(front);
    front.frame = CGRectMake(60, 80, 80, 80);
    front.transform = CATransform3DMakeTranslation(0, 0, 40);
    front.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
    CALayer *back = [CALayer layer];
    configure(back);
    back.frame = CGRectMake(30, 50, 140, 140);
    back.transform = CATransform3DMakeTranslation(0, 0, 20);
    back.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    group.sublayers = @[front, back];
    return group;
}

static void compareHalves(NSWindow *window, const char *name)
{
    [CATransaction flush];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
        (CGWindowID)window.windowNumber, kCGWindowImageBoundsIgnoreFraming);
    EXPECT(image);
    if (!image)
        return;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    EXPECT(width == 400 && height == 240);
    uint8_t *pixels = calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    unsigned different = 0, maxDifference = 0;
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width / 2; ++x) {
            unsigned pixelDifference = 0;
            for (unsigned c = 0; c < 4; ++c) {
                unsigned d = abs(pixels[4 * (y * width + x) + c] - pixels[4 * (y * width + x + width / 2) + c]);
                if (d > pixelDifference)
                    pixelDifference = d;
            }
            different += !!pixelDifference;
            if (pixelDifference > maxDifference)
                maxDifference = pixelDifference;
        }
    }
    fprintf(stderr, "%s: %u different pixels, max channel difference %u\n", name, different, maxDifference);
    // Equivalent perspective concatenations can round antialiased edges by one channel level.
    EXPECT(maxDifference <= 1);
    if (maxDifference > 1) {
        NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
        [[bitmap representationUsingType:NSPNGFileType properties:@{}] writeToFile:[NSString stringWithFormat:@"/tmp/wk-depth-%s.png", name] atomically:YES];
    }
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    CGImageRelease(image);
    free(pixels);
    [CATransaction setDisableActions:YES];
}

static void checkHierarchy(void)
{
    CALayer *parent = [CALayer layer];
    configure(parent);
    CATransformLayer *a = scene(), *b = scene(), *c = scene();
    CALayer *plain = [CALayer layer];
    [parent addSublayer:a];
    EXPECT(a.superlayer == parent);
    EXPECT([parent.sublayers isEqualToArray:@[a]]);
    [parent insertSublayer:b below:a];
    [parent insertSublayer:c above:a];
    EXPECT([parent.sublayers isEqualToArray:@[b, a, c]]);
    [parent insertSublayer:plain atIndex:1];
    EXPECT([parent.sublayers isEqualToArray:@[b, plain, a, c]]);
    [parent replaceSublayer:a with:b];
    EXPECT([parent.sublayers isEqualToArray:@[plain, b, c]]);
    EXPECT(!a.superlayer);
    parent.sublayers = @[c, b, plain];
    EXPECT([parent.sublayers isEqualToArray:@[c, b, plain]]);
    [c addSublayer:b];
    EXPECT(b.superlayer == c);
    EXPECT([parent.sublayers isEqualToArray:@[c, plain]]);
    [parent addSublayer:b];
    EXPECT(b.superlayer == parent);
    [b removeFromSuperlayer];
    EXPECT(!b.superlayer);
    parent.sortsSublayers = YES;
    EXPECT(c.superlayer == parent);
    parent.sortsSublayers = NO;
    EXPECT(c.superlayer == parent);
    parent.usesWebKitBehavior = NO;
    EXPECT(c.superlayer == parent);
    parent.usesWebKitBehavior = YES;
    parent.sublayers = nil;
    EXPECT(!c.superlayer);
    EXPECT(!parent.sublayers.count);
    @autoreleasepool {
        CATransformLayer *onlyOwnedByParent = [[CATransformLayer alloc] init];
        configure(onlyOwnedByParent);
        [parent addSublayer:onlyOwnedByParent];
        [onlyOwnedByParent release];
        [onlyOwnedByParent removeFromSuperlayer];
        EXPECT(!parent.sublayers.count);
    }
    EXPECT(![CALayer instancesRespondToSelector:NSSelectorFromString(@"usesWebKitBehavior")]);
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [CATransaction setDisableActions:YES];
        checkHierarchy();
        NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 240)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
        window.contentView.wantsLayer = YES;
        CALayer *root = window.contentView.layer;
        root.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
        CALayer *reference = [CALayer layer], *actual = [CALayer layer];
        configure(actual);
        reference.frame = CGRectMake(0, 0, 200, 240);
        actual.frame = CGRectMake(200, 0, 200, 240);
        CATransformLayer *referenceScene = scene(), *actualScene = scene();
        [reference addSublayer:referenceScene];
        [actual addSublayer:actualScene];
        root.sublayers = @[reference, actual];
        [window orderFrontRegardless];
        compareHalves(window, "depth order");
        referenceScene.transform = actualScene.transform = CATransform3DMakeRotation(0.7, 0, 1, 0);
        CATransform3D perspective = CATransform3DIdentity;
        perspective.m34 = -1.0 / 500;
        reference.sublayerTransform = actual.sublayerTransform = perspective;
        compareHalves(window, "perspective and rotation");
        reference.anchorPoint = actual.anchorPoint = CGPointMake(0.2, 0.3);
        reference.position = CGPointMake(40, 72);
        actual.position = CGPointMake(240, 72);
        compareHalves(window, "perspective origin");
        reference.bounds = actual.bounds = CGRectMake(15, 20, 200, 240);
        compareHalves(window, "bounds origin");
        reference.anchorPointZ = actual.anchorPointZ = 10;
        compareHalves(window, "anchor depth");
        reference.geometryFlipped = actual.geometryFlipped = YES;
        compareHalves(window, "flipped geometry");
        referenceScene.transform = actualScene.transform = CATransform3DMakeRotation(2.4, 0, 1, 0);
        compareHalves(window, "reversed depth");
        reference.sublayerTransform = actual.sublayerTransform = CATransform3DIdentity;
        referenceScene.transform = actualScene.transform = CATransform3DMakeTranslation(0, 0, -50);
        compareHalves(window, "negative depth");
        CATransformLayer *nestedReference = scene(), *nestedActual = scene();
        nestedReference.transform = nestedActual.transform = CATransform3DMakeTranslation(20, 10, 30);
        [referenceScene addSublayer:nestedReference];
        [actualScene addSublayer:nestedActual];
        compareHalves(window, "nested 3D contexts");
        [reference addSublayer:nestedReference];
        [actual addSublayer:nestedActual];
        compareHalves(window, "reparented 3D contexts");
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform"];
        animation.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
        animation.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeRotation(1.5, 0, 1, 0)];
        animation.duration = 1;
        animation.speed = 0;
        animation.timeOffset = 0.5;
        [nestedReference addAnimation:animation forKey:@"rotation"];
        [nestedActual addAnimation:animation forKey:@"rotation"];
        compareHalves(window, "animated transform");
        [window orderOut:nil];
    }
    fprintf(stderr, "depth sorting: %u failures\n", failures);
    return failures ? 1 : 0;
}
