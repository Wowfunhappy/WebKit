#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <assert.h>
#include <math.h>

@interface CABackdropLayer : CALayer
@property(nonatomic) BOOL windowServerAware;
@end
@interface CAFilter : NSObject
+ (id)filterWithType:(NSString *)type;
- (void)setName:(NSString *)name;
@end
typedef struct {
    float m11, m12, m13, m14, m15;
    float m21, m22, m23, m24, m25;
    float m31, m32, m33, m34, m35;
    float m41, m42, m43, m44, m45;
} CAColorMatrix;
@interface NSValue (CADetails)
+ (NSValue *)valueWithCAColorMatrix:(CAColorMatrix)matrix;
@end

static CAFilter *colorMatrixFilter(float scale, float offset, float alpha)
{
    CAColorMatrix matrix = {
        scale, 0, 0, 0, offset,
        0, scale, 0, 0, offset,
        0, 0, scale, 0, offset,
        0, 0, 0, alpha, 0,
    };
    CAFilter *filter = [CAFilter filterWithType:@"colorMatrix"];
    [filter setValue:[NSValue valueWithCAColorMatrix:matrix] forKey:@"inputColorMatrix"];
    return filter;
}

@interface BackdropAnimationDelegate : NSObject {
@public
    unsigned starts;
    unsigned stops;
    NSString *keyPath;
}
@end
@implementation BackdropAnimationDelegate
- (void)animationDidStart:(CAAnimation *)animation
{
    ++starts;
    assert([[(CAPropertyAnimation *)animation keyPath] isEqualToString:keyPath]);
    assert(animation.delegate == self);
}
- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished
{
    assert(finished);
    ++stops;
    assert([[(CAPropertyAnimation *)animation keyPath] isEqualToString:keyPath]);
    assert(animation.delegate == self);
}
@end

static void runFor(NSTimeInterval duration)
{
    [CATransaction flush];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:duration]];
    [CATransaction setDisableActions:YES];
}

static NSBitmapImageRep *capture(NSWindow *window)
{
    CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
        (CGWindowID)window.windowNumber, kCGWindowImageBoundsIgnoreFraming);
    assert(image);
    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
    CGImageRelease(image);
    return bitmap;
}

static void assertSamePixel(NSWindow *window)
{
    NSBitmapImageRep *bitmap = capture(window);
    for (NSInteger x = 25; x <= 175; x += 75) {
        NSColor *actual = [[bitmap colorAtX:x y:100] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        NSColor *expected = [[bitmap colorAtX:x + 200 y:100] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        assert(fabs(actual.redComponent - expected.redComponent) < .015);
        assert(fabs(actual.greenComponent - expected.greenComponent) < .015);
        assert(fabs(actual.blueComponent - expected.blueComponent) < .015);
    }
}

static CGColorRef color(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat components[] = { red, green, blue, alpha };
    CGColorRef result = CGColorCreate(space, components);
    CGColorSpaceRelease(space);
    return result;
}

static void assertSameColor(CGColorRef a, CGColorRef b)
{
    assert(a && b);
    NSColor *first = [[NSColor colorWithCGColor:a] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    NSColor *second = [[NSColor colorWithCGColor:b] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    assert(fabs(first.redComponent - second.redComponent) < .002);
    assert(fabs(first.greenComponent - second.greenComponent) < .002);
    assert(fabs(first.blueComponent - second.blueComponent) < .002);
    assert(fabs(first.alphaComponent - second.alphaComponent) < .002);
}

int main(void)
{
    setbuf(stdout, NULL);
    @autoreleasepool {
        assert(!NSClassFromString(@"CABackdropLayer"));
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 400, 200)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        window.level = NSStatusWindowLevel;
        NSView *view = window.contentView;
        view.wantsLayer = YES;
        view.layer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
        [CATransaction setDisableActions:YES];
        CABackdropLayer *layer = [CABackdropLayer layer];
        layer.frame = CGRectMake(20, 20, 160, 160);
        CALayer *reference = [CALayer layer];
        reference.frame = CGRectMake(220, 20, 160, 160);
        CALayer *fill = [CALayer layer];
        fill.frame = reference.bounds;
        CGColorRef black = color(0, 0, 0, .25 * 144 / 145);
        fill.backgroundColor = black;
        CGColorRelease(black);
        [reference addSublayer:fill];
        [view.layer addSublayer:layer];
        [view.layer addSublayer:reference];
        [window orderFront:nil];
        assert(!layer.windowServerAware);
        assert(!layer.filters && !layer.backgroundColor);
        layer.windowServerAware = YES;
        CAFilter *filter = [CAFilter filterWithType:@"gaussianBlur"];
        [filter setName:@"filter_0"];
        [filter setValue:@12 forKey:@"inputRadius"];
        NSMutableArray *filters = [NSMutableArray arrayWithObject:filter];
        layer.filters = filters;
        [filters removeAllObjects];
        assert(layer.filters.count == 1 && !layer.backgroundColor);
        assert(![layer valueForKey:@"backgroundColor"]);
        NSArray *(*nativeFilters)(id, SEL) = (void *)class_getMethodImplementation([CALayer class], @selector(filters));
        assert(!nativeFilters(layer, @selector(filters)).count && !layer.backgroundFilters.count);
        layer.opacity = reference.opacity = .5;
        layer.cornerRadius = reference.cornerRadius = 24;
        layer.masksToBounds = reference.masksToBounds = YES;
        runFor(.1);
        assertSamePixel(window);
        assert([[capture(window) colorAtX:20 y:20] colorUsingColorSpaceName:NSCalibratedRGBColorSpace].redComponent > .99);
        layer.opacity = reference.opacity = 1;
        CGColorRef red = color(1, 0, 0, .2);
        CGColorRef blue = color(0, 0, 1, .8);
        layer.backgroundColor = reference.backgroundColor = red;
        assert(CGColorEqualToColor(layer.backgroundColor, red));
        assert(CGColorEqualToColor((CGColorRef)[layer valueForKey:@"backgroundColor"], red));
        runFor(.1);
        assertSamePixel(window);
        assertSameColor(((CABackdropLayer *)layer.presentationLayer).backgroundColor, red);
        assert(((CABackdropLayer *)layer.presentationLayer).windowServerAware);
        layer.filters = nil;
        fill.hidden = YES;
        assert(CGColorEqualToColor(layer.backgroundColor, red));
        runFor(.1);
        assertSamePixel(window);
        layer.filters = @[filter];
        fill.hidden = NO;
        CABackdropLayer *decoded = [NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:layer]];
        assert(decoded.windowServerAware && decoded.filters.count == 1);
        assert([[decoded valueForKeyPath:@"filters.filter_0.inputRadius"] doubleValue] == 12);
        assertSameColor(decoded.backgroundColor, red);
        decoded.windowServerAware = NO;
        decoded = [NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:decoded]];
        assert(!decoded.windowServerAware);
        [view.layer replaceSublayer:layer with:decoded];
        runFor(.1);
        assertSamePixel(window);
        [view.layer replaceSublayer:decoded with:layer];
        puts("PASS caller color, KVC, presentation copy, coding and verified default");

        CGColorSpaceRef imageSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL, 160, 160, 8, 0, imageSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextSetRGBFillColor(context, 1, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(40, 40, 80, 80));
        CGImageRef image = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        CGColorSpaceRelease(imageSpace);
        CALayer *foreground = [CALayer layer];
        foreground.frame = reference.bounds;
        foreground.contents = (id)image;
        [reference addSublayer:foreground];
        layer.contents = (id)image;
        runFor(.1);
        assertSamePixel(window);
        assert(!layer.sublayers.count);
        layer.contents = nil;
        CALayer *child = [CALayer layer];
        child.frame = layer.bounds;
        child.contents = (id)image;
        [layer addSublayer:child];
        runFor(.1);
        assertSamePixel(window);
        assert(child.superlayer == layer && layer.sublayers.count == 1);
        [child removeFromSuperlayer];
        [foreground removeFromSuperlayer];
        CGImageRelease(image);

        [CATransaction begin];
        [CATransaction setDisableActions:NO];
        [CATransaction setAnimationDuration:1];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear]];
        layer.backgroundColor = reference.backgroundColor = blue;
        [CATransaction commit];
        CABasicAnimation *implicit = (id)[layer animationForKey:@"backgroundColor"];
        assert([implicit isKindOfClass:[CABasicAnimation class]]);
        assert([implicit.keyPath isEqualToString:@"backgroundColor"]);
        assertSameColor((CGColorRef)implicit.fromValue, red);
        CABasicAnimation *paused = [[implicit copy] autorelease];
        paused.speed = 0;
        paused.timeOffset = .5;
        paused.toValue = (id)blue;
        [layer addAnimation:paused forKey:@"backgroundColor"];
        [reference addAnimation:paused forKey:@"backgroundColor"];
        runFor(.1);
        assertSameColor(((CABackdropLayer *)layer.presentationLayer).backgroundColor, ((CALayer *)reference.presentationLayer).backgroundColor);
        assertSamePixel(window);
        layer.filters = nil;
        fill.hidden = YES;
        runFor(.1);
        assertSamePixel(window);
        layer.filters = @[filter];
        fill.hidden = NO;
        runFor(.1);
        assertSamePixel(window);
        [layer removeAllAnimations];
        [reference removeAllAnimations];
        assert(!layer.animationKeys.count);
        puts("PASS implicit color animation, presentation values and filter changes during animation");

        CABasicAnimation *frozenFilter = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputRadius"];
        frozenFilter.fromValue = @0;
        frozenFilter.toValue = @40;
        frozenFilter.duration = 1;
        frozenFilter.speed = 0;
        frozenFilter.timeOffset = .5;
        [layer addAnimation:frozenFilter forKey:@"frozenFilter"];
        runFor(.1);
        assertSamePixel(window);
        assert([[layer valueForKeyPath:@"filters.filter_0.inputRadius"] doubleValue] == 12);
        [layer removeAnimationForKey:@"frozenFilter"];

        BackdropAnimationDelegate *delegate = [[[BackdropAnimationDelegate alloc] init] autorelease];
        delegate->keyPath = @"backgroundColor";
        CABasicAnimation *callback = [[paused copy] autorelease];
        callback.speed = 1;
        callback.timeOffset = 0;
        callback.beginTime = 0;
        callback.duration = .2;
        callback.delegate = delegate;
        [layer addAnimation:callback forKey:@"callback"];
        runFor(.05);
        layer.filters = nil;
        layer.filters = @[filter];
        runFor(.3);
        assert(delegate->starts == 1 && delegate->stops == 1);
        delegate->starts = delegate->stops = 0;
        delegate->keyPath = @"filters.filter_0.inputRadius";
        CABasicAnimation *blur = [CABasicAnimation animationWithKeyPath:delegate->keyPath];
        blur.fromValue = @0;
        blur.toValue = @20;
        blur.duration = .03;
        blur.delegate = delegate;
        [layer addAnimation:blur forKey:@"blur"];
        runFor(.1);
        assert(delegate->starts == 1 && delegate->stops == 1);
        assert([[layer valueForKeyPath:@"filters.filter_0.inputRadius"] doubleValue] == 12);
        layer.filters = @[];
        assert(CGColorEqualToColor(layer.backgroundColor, blue));
        layer.backgroundColor = nil;
        assert(!layer.backgroundColor);
        CGColorRelease(red);
        CGColorRelease(blue);
        puts("PASS callback identity, clearing and native opacity/clipping");

        [window orderOut:nil];
        [window release];

        // Left: the polyfill over black, grey and white bands. Right: the same bands under a native layer that
        // renders them through the same filters, which is what a backdrop with that chain shows.
        NSWindow *bands = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 300, 60)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        bands.level = NSStatusWindowLevel;
        NSView *bandsView = bands.contentView;
        bandsView.wantsLayer = YES;
        CALayer *root = bandsView.layer;
        CALayer *(^bandsLayer)(CGFloat) = ^(CGFloat x) {
            CALayer *container = [CALayer layer];
            container.frame = CGRectMake(x, 0, 150, 60);
            for (int i = 0; i < 3; ++i) {
                CALayer *band = [CALayer layer];
                band.frame = CGRectMake(i * 50, 0, 50, 60);
                CGColorRef gray = color(i * .5, i * .5, i * .5, 1);
                band.backgroundColor = gray;
                CGColorRelease(gray);
                [container addSublayer:band];
            }
            return container;
        };
        [root addSublayer:bandsLayer(0)];
        [root addSublayer:bandsLayer(150)];
        CALayer *native = bandsLayer(150);
        [root addSublayer:native];
        CABackdropLayer *backdrop = [CABackdropLayer layer];
        backdrop.frame = CGRectMake(0, 0, 150, 60);
        [root addSublayer:backdrop];
        CALayer *expectedFill = [CALayer layer];
        expectedFill.frame = CGRectMake(150, 0, 150, 60);
        [root addSublayer:expectedFill];
        [bands orderFront:nil];
        [CATransaction setDisableActions:YES];

        void (^compareBands)(const char *, BOOL) = ^(const char *name, BOOL everyBand) {
            runFor(.1);
            NSBitmapImageRep *bitmap = capture(bands);
            BOOL failed = NO;
            for (int i = everyBand ? 0 : 1; i < (everyBand ? 3 : 2); ++i) {
                NSUInteger polyfill[4], reference[4];
                [bitmap getPixel:polyfill atX:25 + i * 50 y:30];
                [bitmap getPixel:reference atX:175 + i * 50 y:30];
                for (int c = 1; c < 4; ++c)
                    failed = failed || labs((long)polyfill[c] - (long)reference[c]) > 3;
                printf("  %s band %d: polyfill %lu,%lu,%lu native %lu,%lu,%lu\n", name, i,
                    polyfill[1], polyfill[2], polyfill[3], reference[1], reference[2], reference[3]);
            }
            assert(!failed);
        };
        CAFilter *(^named)(CAFilter *) = ^(CAFilter *f) { [f setName:@"filter_0"]; return f; };
        CAFilter *(^typed)(NSString *, NSString *, id) = ^(NSString *type, NSString *key, id value) {
            CAFilter *f = [CAFilter filterWithType:type];
            if (key)
                [f setValue:value forKey:key];
            return f;
        };
        CGColorRef halfGray = color(.5, .5, .5, 1);
        CGColorRef fifthGray = color(.2, .2, .2, 1);
        CGColorRef fortyGray = color(.4, .4, .4, 1);
        CAColorMatrix sepiaMatrix = {
            .393, .769, .189, 0, 0,
            .349, .686, .168, 0, 0,
            .272, .534, .131, 0, 0,
            0, 0, 0, 1, 0,
        };
        CAFilter *sepia = [CAFilter filterWithType:@"colorMatrix"];
        [sepia setValue:[NSValue valueWithCAColorMatrix:sepiaMatrix] forKey:@"inputColorMatrix"];
        CAFilter *gradient = [CAFilter filterWithType:@"multiplyGradient"];
        [gradient setValue:(id)fortyGray forKey:@"inputColor0"];
        [gradient setValue:(id)fortyGray forKey:@"inputColor1"];
        CAFilter *disabled = colorMatrixFilter(0, 0, 1);
        [disabled setValue:@NO forKey:@"enabled"];
        struct { const char *name; NSArray *filters; BOOL everyBand; } chains[] = {
            { "matrix .5x+.25", @[colorMatrixFilter(.5, .25, 1)], YES },
            { "matrix .7x", @[colorMatrixFilter(.7, 0, 1)], YES },
            { "matrix black at alpha .5", @[colorMatrixFilter(0, 0, .5)], YES },
            { "colorContrast .5", @[typed(@"colorContrast", @"inputAmount", @.5)], YES },
            { "multiplyColor .5", @[typed(@"multiplyColor", @"inputColor", (id)halfGray)], YES },
            { "colorMonochrome 1", @[typed(@"colorMonochrome", @"inputAmount", @1)], YES },
            { "colorSaturate 2", @[typed(@"colorSaturate", @"inputAmount", @2)], YES },
            { "colorHueRotate 1", @[typed(@"colorHueRotate", @"inputAngle", @1)], YES },
            { "disabled matrix", @[disabled], YES },
            { "colorBrightness unset", @[typed(@"colorBrightness", nil, nil)], YES },
            { "multiplyGradient uniform .4", @[gradient], YES },
            { "bias unset", @[typed(@"bias", nil, nil)], NO },
            { "sepia matrix", @[sepia], NO },
            { "matrix 1.6x", @[colorMatrixFilter(1.6, 0, 1)], NO },
            { "matrix .9x+.3", @[colorMatrixFilter(.9, .3, 1)], NO },
            { "colorBrightness .2", @[typed(@"colorBrightness", @"inputAmount", @.2)], NO },
            { "colorBrightness -.2", @[typed(@"colorBrightness", @"inputAmount", @-.2)], NO },
            { "colorContrast 2", @[typed(@"colorContrast", @"inputAmount", @2)], NO },
            { "colorInvert", @[typed(@"colorInvert", nil, nil)], NO },
            { "colorAdd .2", @[typed(@"colorAdd", @"inputColor", (id)fifthGray)], NO },
            { "colorSubtract .2", @[typed(@"colorSubtract", @"inputColor", (id)fifthGray)], NO },
            { "bias .2", @[typed(@"bias", @"inputAmount", @.2)], NO },
            { "luminanceToAlpha", @[typed(@"luminanceToAlpha", nil, nil)], NO },
        };
        for (size_t i = 0; i < sizeof(chains) / sizeof(chains[0]); ++i) {
            backdrop.filters = chains[i].filters;
            native.filters = chains[i].filters;
            compareBands(chains[i].name, chains[i].everyBand);
        }
        native.filters = nil;
        backdrop.filters = @[colorMatrixFilter(1.6, 0, 1)];
        runFor(.1);
        NSUInteger lighter[4];
        [capture(bands) getPixel:lighter atX:75 y:30];
        assert(lighter[1] > 191);
        puts("PASS fill matches 10.9's colour filters on black, grey and white");

        // A blur has no native backdrop rendering; it darkens by 25% scaled by r^2 / (r^2 + 1).
        double (^blurAlpha)(double) = ^(double radius) { return .25 * radius * radius / (radius * radius + 1); };
        void (^expectBlack)(double) = ^(double alpha) {
            CGColorRef black = color(0, 0, 0, alpha);
            expectedFill.backgroundColor = black;
            CGColorRelease(black);
        };
        CAFilter *blur12 = named([CAFilter filterWithType:@"gaussianBlur"]);
        [blur12 setValue:@12 forKey:@"inputRadius"];
        backdrop.filters = @[blur12];
        expectBlack(blurAlpha(12));
        compareBands("blur 12", YES);
        backdrop.filters = @[blur12, colorMatrixFilter(1, 0, .5)];
        expectBlack(blurAlpha(12) / 2);
        compareBands("blur 12 at alpha .5", YES);
        puts("PASS blur darkening");

        // WebKit's image of the content beneath shows through the filter chain, rasterized, and fades in over
        // the image before it.
        CGImageRef (^sampleImage)(size_t, size_t, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) =
            ^(size_t width, size_t height, CGFloat r0, CGFloat g0, CGFloat b0, CGFloat r1, CGFloat g1, CGFloat b1) {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
            CGContextSetRGBFillColor(context, r0, g0, b0, 1);
            CGContextFillRect(context, CGRectMake(0, 0, width / 2., height));
            CGContextSetRGBFillColor(context, r1, g1, b1, 1);
            CGContextFillRect(context, CGRectMake(width / 2., 0, width / 2., height));
            CGImageRef result = CGBitmapContextCreateImage(context);
            CGContextRelease(context);
            CGColorSpaceRelease(space);
            return result;
        };
        void (^setImage)(CABackdropLayer *, CGImageRef, CGRect) = ^(CABackdropLayer *target, CGImageRef image, CGRect rect) {
            [target setValue:image ? @{ @"image": (id)image, @"rect": [NSValue valueWithBytes:&rect objCType:@encode(CGRect)] } : nil forKey:@"aquaWebKitBackdropImage"];
            CGImageRelease(image);
        };
        CALayer *(^imagesOf)(CABackdropLayer *) = ^(CABackdropLayer *target) {
            return (CALayer *)object_getIvar(target, class_getInstanceVariable([CABackdropLayer class], "_images"));
        };
        void (^expectPixel)(const char *, int, int, int, int, int) = ^(const char *name, int x, int red, int green, int blue, int tolerance) {
            NSUInteger pixel[4];
            [capture(bands) getPixel:pixel atX:x y:30];
            printf("  %s at %d: %lu,%lu,%lu expected %d,%d,%d\n", name, x, pixel[1], pixel[2], pixel[3], red, green, blue);
            assert(labs((long)pixel[1] - red) <= tolerance && labs((long)pixel[2] - green) <= tolerance && labs((long)pixel[3] - blue) <= tolerance);
        };
        CGRect whole = CGRectMake(0, 0, 150, 60);
        backdrop.filters = @[blur12];
        setImage(backdrop, sampleImage(30, 12, 1, 0, 0, 1, 0, 0), whole);
        // The caller's edge flags reach the images, with 10.9's inputHardEdges for inputNormalizeEdges.
        assert(![[imagesOf(backdrop).filters[0] valueForKey:@"inputHardEdges"] boolValue]);
        CAFilter *normalized = [[blur12 copy] autorelease];
        [normalized setValue:@YES forKey:@"inputNormalizeEdges"];
        CAFilter *hard = [[blur12 copy] autorelease];
        [hard setValue:@YES forKey:@"inputHardEdges"];
        backdrop.filters = @[hard];
        assert([[imagesOf(backdrop).filters[0] valueForKey:@"inputHardEdges"] boolValue]);
        backdrop.filters = @[normalized];
        assert([[imagesOf(backdrop).filters[0] valueForKey:@"inputHardEdges"] boolValue]);
        assert(!backdrop.sublayers.count && imagesOf(backdrop).sublayers.count == 1);
        assert(fabs(imagesOf(backdrop).rasterizationScale - .4) < 1e-6 && imagesOf(backdrop).shouldRasterize);
        runFor(.1);
        for (int x = 2; x < 150; x += 73)
            expectPixel("first image, at once, edges clamped", x, 255, 0, 0, 3);
        backdrop.filters = @[normalized, colorMatrixFilter(.5, 0, 1)];
        runFor(.1);
        expectPixel("then a dimming matrix", 75, 128, 0, 0, 3);
        backdrop.filters = @[normalized];
        setImage(backdrop, sampleImage(30, 12, 1, 1, 1, 0, 0, 0), whole);
        runFor(.3);
        assert(imagesOf(backdrop).sublayers.count == 1);
        expectPixel("left of a white-black edge", 10, 255, 255, 255, 3);
        expectPixel("at the blurred edge", 75, 128, 128, 128, 12);
        expectPixel("right of the edge", 140, 0, 0, 0, 3);
        NSUInteger nearEdge[4], farEdge[4];
        [capture(bands) getPixel:nearEdge atX:65 y:30];
        [capture(bands) getPixel:farEdge atX:85 y:30];
        assert(nearEdge[1] < 230 && farEdge[1] > 25);

        // At a tenth of the speed the fade takes a second; an image arriving mid-fade starts from what shows.
        setImage(backdrop, sampleImage(30, 12, 1, 0, 0, 1, 0, 0), whole);
        runFor(.3);
        backdrop.speed = .1;
        setImage(backdrop, sampleImage(30, 12, 0, 0, 1, 0, 0, 1), whole);
        runFor(.4);
        NSUInteger middle[4];
        [capture(bands) getPixel:middle atX:75 y:30];
        printf("  mid-fade: %lu,%lu,%lu\n", middle[1], middle[2], middle[3]);
        assert(middle[1] > 40 && middle[3] > 40 && imagesOf(backdrop).sublayers.count == 2);
        setImage(backdrop, sampleImage(30, 12, 0, 1, 0, 0, 1, 0), whole);
        runFor(.02);
        NSUInteger restarted[4];
        [capture(bands) getPixel:restarted atX:75 y:30];
        printf("  just after a second image: %lu,%lu,%lu\n", restarted[1], restarted[2], restarted[3]);
        assert(restarted[1] > 25 && labs((long)restarted[1] - (long)middle[1]) < 60 && labs((long)restarted[3] - (long)middle[3]) < 60);
        assert(imagesOf(backdrop).sublayers.count == 3);
        runFor(1.6);
        backdrop.speed = 1;
        expectPixel("faded in", 75, 0, 255, 0, 3);
        assert(imagesOf(backdrop).sublayers.count == 1);

        // The images keep to this layer's coordinates when its bounds origin moves.
        backdrop.bounds = CGRectMake(50, 0, 150, 60);
        setImage(backdrop, sampleImage(30, 12, 0, 0, 1, 0, 0, 1), CGRectMake(50, 0, 150, 60));
        runFor(.3);
        expectPixel("image at a moved bounds origin", 2, 0, 0, 255, 3);
        expectPixel("image at a moved bounds origin", 148, 0, 0, 255, 3);
        backdrop.bounds = whole;
        setImage(backdrop, sampleImage(30, 12, 0, 1, 0, 0, 1, 0), whole);
        runFor(.3);

        // A sublayer of the caller's draws over the images, which `sublayers` does not list, on this layer or its
        // presentation copy.
        CALayer *callerSublayer = [CALayer layer];
        callerSublayer.frame = CGRectMake(100, 0, 50, 60);
        callerSublayer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
        [backdrop addSublayer:callerSublayer];
        assert(backdrop.sublayers.count == 1 && backdrop.sublayers[0] == callerSublayer);
        [backdrop insertSublayer:[CALayer layer] atIndex:0];
        assert(backdrop.sublayers.count == 2 && backdrop.sublayers[1] == callerSublayer);
        backdrop.sublayers = @[callerSublayer];
        runFor(.1);
        expectPixel("image under the caller's sublayer", 25, 0, 255, 0, 3);
        expectPixel("caller's sublayer", 125, 255, 255, 255, 3);
        CALayer *bottom = [CALayer layer];
        [backdrop insertSublayer:bottom below:nil];
        assert(backdrop.sublayers.count == 2 && backdrop.sublayers[0] == bottom);
        runFor(.1);
        assert([backdrop.presentationLayer sublayers].count == 2);
        for (CALayer *presented in [backdrop.presentationLayer sublayers])
            assert(![presented isKindOfClass:[imagesOf(backdrop) class]]);
        backdrop.sublayers = nil;
        assert(!backdrop.sublayers.count && imagesOf(backdrop).superlayer == backdrop);

        // The images run the filter animations, under the same filter names.
        CAFilter *darkening = colorMatrixFilter(1, 0, 1);
        [darkening setName:@"filter_1"];
        backdrop.filters = @[blur12, darkening];
        CABasicAnimation *dimImages = [CABasicAnimation animationWithKeyPath:@"filters.filter_1.inputColorMatrix"];
        dimImages.fromValue = [colorMatrixFilter(1, 0, 1) valueForKey:@"inputColorMatrix"];
        dimImages.toValue = [colorMatrixFilter(0, 0, 1) valueForKey:@"inputColorMatrix"];
        dimImages.duration = 1;
        dimImages.speed = 0;
        dimImages.timeOffset = .5;
        [backdrop addAnimation:dimImages forKey:@"dimImages"];
        runFor(.1);
        assert(imagesOf(backdrop).animationKeys.count == 1 && !imagesOf(backdrop).shouldRasterize);
        expectPixel("paused animation on the images", 75, 0, 128, 0, 4);
        [backdrop removeAnimationForKey:@"dimImages"];
        runFor(.1);
        assert(!imagesOf(backdrop).animationKeys.count && imagesOf(backdrop).shouldRasterize);
        expectPixel("animation removed", 75, 0, 255, 0, 3);
        backdrop.filters = @[blur12];

        // The images archive with the layer.
        CABackdropLayer *archived = [NSKeyedUnarchiver unarchiveObjectWithData:[NSKeyedArchiver archivedDataWithRootObject:backdrop]];
        assert(imagesOf(archived) && imagesOf(archived).sublayers.count == 1 && !archived.sublayers.count);
        assert(CFGetTypeID((CFTypeRef)[imagesOf(archived).sublayers[0] contents]) == CGImageGetTypeID());
        assert([imagesOf(archived).filters count] == 1);

        // Without an image the images fade out and the fill stands in; a later image fades in over it.
        setImage(backdrop, NULL, CGRectZero);
        assert(imagesOf(backdrop).sublayers.count == 1);
        runFor(.3);
        assert(!imagesOf(backdrop).sublayers.count);
        expectBlack(blurAlpha(12));
        compareBands("no image", YES);
        expectedFill.backgroundColor = nil;
        backdrop.speed = .1;
        setImage(backdrop, sampleImage(30, 12, 1, 0, 0, 1, 0, 0), whole);
        runFor(.5);
        NSUInteger returning[4];
        [capture(bands) getPixel:returning atX:75 y:30];
        printf("  image fading in over the fill: %lu,%lu,%lu\n", returning[1], returning[2], returning[3]);
        assert(returning[1] > 120 && returning[1] < 235 && returning[2] > 20);
        setImage(backdrop, NULL, CGRectZero);
        runFor(.5);
        NSUInteger leaving[4];
        [capture(bands) getPixel:leaving atX:75 y:30];
        printf("  image fading out mid-fade-in: %lu,%lu,%lu\n", leaving[1], leaving[2], leaving[3]);
        assert(leaving[2] > 20 && labs((long)leaving[1] - (long)returning[1]) < 90);
        runFor(1);
        backdrop.speed = 1;
        assert(!imagesOf(backdrop).sublayers.count);
        expectBlack(blurAlpha(12));
        compareBands("faded out", YES);
        expectedFill.backgroundColor = nil;
        puts("PASS blurred images of the backdrop, their fade, sublayers, animations and archiving");

        // Paused filter animations: the native layer runs the same animation on its own filters.
        CAFilter *identity = named(colorMatrixFilter(1, 0, 1));
        CAFilter *dim = named(colorMatrixFilter(.4, 0, 1));
        expectedFill.backgroundColor = nil;
        CABasicAnimation *dimming = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputColorMatrix"];
        dimming.fromValue = [identity valueForKey:@"inputColorMatrix"];
        dimming.toValue = [dim valueForKey:@"inputColorMatrix"];
        dimming.duration = 1;
        dimming.speed = 0;
        dimming.timeOffset = .5;
        CAKeyframeAnimation *dip = [CAKeyframeAnimation animationWithKeyPath:@"filters.filter_0.inputColorMatrix"];
        dip.values = @[dimming.fromValue, dimming.toValue, dimming.fromValue];
        dip.duration = 1;
        dip.speed = 0;
        dip.timeOffset = .25;
        CABasicAnimation *eased = [[dimming copy] autorelease];
        eased.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        NSArray *pausedAnimations = @[dimming, dip, eased];
        const char *pausedNames[] = { "paused basic", "paused keyframe", "paused ease-in" };
        for (NSUInteger i = 0; i < pausedAnimations.count; ++i) {
            backdrop.filters = native.filters = @[identity];
            [backdrop addAnimation:pausedAnimations[i] forKey:@"dim"];
            [native addAnimation:pausedAnimations[i] forKey:@"dim"];
            assert([backdrop.animationKeys isEqualToArray:@[@"dim"]]);
            compareBands(pausedNames[i], YES);
            [backdrop removeAnimationForKey:@"dim"];
            [native removeAnimationForKey:@"dim"];
            assert(!backdrop.animationKeys.count);
            runFor(.1);
            NSUInteger cleared[4];
            [capture(bands) getPixel:cleared atX:75 y:30];
            assert(cleared[1] >= 126 && cleared[1] <= 130);
        }

        // Core Animation's own semantics: to + by, additive, cubic keyframes.
        CAFilter *brightness = named(typed(@"colorBrightness", @"inputAmount", @0));
        CABasicAnimation *toBy = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputAmount"];
        toBy.toValue = @.3;
        toBy.byValue = @.2;
        toBy.duration = 1;
        toBy.speed = 0;
        backdrop.filters = native.filters = @[brightness];
        [backdrop addAnimation:toBy forKey:@"toBy"];
        [native addAnimation:toBy forKey:@"toBy"];
        compareBands("to + by", NO);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];
        CAFilter *contrast = named(typed(@"colorContrast", @"inputAmount", @.5));
        CABasicAnimation *additive = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputAmount"];
        additive.fromValue = @0;
        additive.toValue = @.4;
        additive.additive = YES;
        additive.duration = 1;
        additive.speed = 0;
        additive.timeOffset = .5;
        CAKeyframeAnimation *cubic = [CAKeyframeAnimation animationWithKeyPath:@"filters.filter_0.inputAmount"];
        cubic.values = @[@1, @.2, @1, @.5];
        cubic.calculationMode = kCAAnimationCubic;
        cubic.duration = 1;
        cubic.speed = 0;
        cubic.timeOffset = .2;
        NSArray *semantics = @[additive, cubic];
        const char *semanticsNames[] = { "additive", "cubic keyframes" };
        for (NSUInteger i = 0; i < semantics.count; ++i) {
            backdrop.filters = native.filters = @[contrast];
            [backdrop addAnimation:semantics[i] forKey:@"semantics"];
            [native addAnimation:semantics[i] forKey:@"semantics"];
            compareBands(semanticsNames[i], YES);
            [backdrop removeAllAnimations];
            [native removeAllAnimations];
        }

        // Unkeyed animations are mirrored too, and removeAllAnimations clears them.
        backdrop.filters = native.filters = @[identity];
        [backdrop addAnimation:dimming forKey:nil];
        [native addAnimation:dimming forKey:nil];
        assert(!backdrop.animationKeys.count);
        compareBands("unkeyed", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];
        runFor(.1);
        NSUInteger unkeyedCleared[4];
        [capture(bands) getPixel:unkeyedCleared atX:75 y:30];
        assert(unkeyedCleared[1] >= 126 && unkeyedCleared[1] <= 130);

        // Animations with different durations, sampled after the shorter one has ended.
        CAFilter *first = named(typed(@"colorContrast", @"inputAmount", @1));
        CAFilter *second = typed(@"colorContrast", @"inputAmount", @1);
        [second setName:@"filter_1"];
        backdrop.filters = native.filters = @[first, second];
        double began = [backdrop convertTime:CACurrentMediaTime() fromLayer:nil] - 1.5;
        CABasicAnimation *shorter = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputAmount"];
        shorter.fromValue = @1;
        shorter.toValue = @.5;
        shorter.duration = 1;
        shorter.fillMode = kCAFillModeForwards;
        shorter.removedOnCompletion = NO;
        CABasicAnimation *longer = [CABasicAnimation animationWithKeyPath:@"filters.filter_1.inputAmount"];
        longer.fromValue = @1;
        longer.toValue = @.6;
        longer.duration = 2;
        longer.fillMode = kCAFillModeForwards;
        longer.removedOnCompletion = NO;
        for (CALayer *target in @[backdrop, native]) {
            shorter.beginTime = longer.beginTime = began + [target convertTime:CACurrentMediaTime() fromLayer:nil] - [backdrop convertTime:CACurrentMediaTime() fromLayer:nil];
            [target addAnimation:shorter forKey:@"shorter"];
            [target addAnimation:longer forKey:@"longer"];
        }
        compareBands("different durations", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];

        // Paced matrix keyframes, spaced by the Euclidean distance between values.
        CAColorMatrix channelMatrices[3] = {
            { 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 },
            { .2, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0 },
            { .6, 0, 0, 0, 0, 0, .6, 0, 0, 0, 0, 0, .6, 0, 0, 0, 0, 0, 1, 0 },
        };
        NSArray *channelValues = @[[NSValue valueWithCAColorMatrix:channelMatrices[0]], [NSValue valueWithCAColorMatrix:channelMatrices[1]], [NSValue valueWithCAColorMatrix:channelMatrices[2]]];
        for (NSString *mode in @[kCAAnimationPaced, kCAAnimationCubicPaced]) {
            for (NSNumber *offset in @[@.3, @.6]) {
                CAKeyframeAnimation *paced = [CAKeyframeAnimation animationWithKeyPath:@"filters.filter_0.inputColorMatrix"];
                paced.values = channelValues;
                paced.calculationMode = mode;
                paced.duration = 1;
                paced.speed = 0;
                paced.timeOffset = offset.doubleValue;
                backdrop.filters = native.filters = @[identity];
                [backdrop addAnimation:paced forKey:@"paced"];
                [native addAnimation:paced forKey:@"paced"];
                compareBands([[NSString stringWithFormat:@"%@ at %@", mode, offset] UTF8String], NO);
                [backdrop removeAllAnimations];
                [native removeAllAnimations];
            }
        }

        // Cumulative repeats, finite and endless, at their third iteration.
        CABasicAnimation *accumulating = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputAmount"];
        accumulating.fromValue = @1;
        accumulating.toValue = @.8;
        accumulating.cumulative = YES;
        accumulating.duration = 1;
        accumulating.repeatCount = 3;
        accumulating.speed = 0;
        accumulating.timeOffset = 2.5;
        backdrop.filters = native.filters = @[named(typed(@"colorContrast", @"inputAmount", @1))];
        [backdrop addAnimation:accumulating forKey:@"accumulating"];
        [native addAnimation:accumulating forKey:@"accumulating"];
        compareBands("cumulative, three repeats", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];
        accumulating.repeatCount = HUGE_VALF;
        accumulating.speed = 1;
        accumulating.timeOffset = 0;
        for (CALayer *target in @[backdrop, native]) {
            accumulating.beginTime = [target convertTime:CACurrentMediaTime() fromLayer:nil] - 2.5;
            [target addAnimation:accumulating forKey:@"accumulating"];
        }
        compareBands("cumulative, endless", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];

        // A finite animation beside an endless or a paused one, after the finite one has ended.
        CABasicAnimation *endless = [CABasicAnimation animationWithKeyPath:@"filters.filter_1.inputAmount"];
        endless.fromValue = @1;
        endless.toValue = @.6;
        endless.duration = .7;
        endless.repeatCount = HUGE_VALF;
        CABasicAnimation *frozen = [CABasicAnimation animationWithKeyPath:@"filters.filter_1.inputAmount"];
        frozen.fromValue = @1;
        frozen.toValue = @.6;
        frozen.duration = 1;
        frozen.speed = 0;
        frozen.timeOffset = .5;
        for (CABasicAnimation *other in @[endless, frozen]) {
            backdrop.filters = native.filters = @[first, second];
            for (CALayer *target in @[backdrop, native]) {
                double now = [target convertTime:CACurrentMediaTime() fromLayer:nil];
                shorter.beginTime = now - 1.5;
                other.beginTime = now - 1.5;
                [target addAnimation:shorter forKey:@"shorter"];
                [target addAnimation:other forKey:@"other"];
            }
            compareBands(other == endless ? "finite beside endless" : "finite beside paused", YES);
            [backdrop removeAllAnimations];
            [native removeAllAnimations];
        }

        // An endless animation added now begins at the commit, as its mirror does.
        endless.keyPath = @"filters.filter_0.inputAmount";
        endless.beginTime = 0;
        backdrop.filters = native.filters = @[named(typed(@"colorContrast", @"inputAmount", @1))];
        [backdrop addAnimation:endless forKey:@"endless"];
        [native addAnimation:endless forKey:@"endless"];
        runFor(1.2);
        compareBands("endless from the commit", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];

        // A to-only matrix animation after another on the same key starts from that one's value.
        CABasicAnimation *held = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputColorMatrix"];
        held.fromValue = held.toValue = [colorMatrixFilter(.2, 0, 1) valueForKey:@"inputColorMatrix"];
        held.duration = 1;
        held.speed = 0;
        CABasicAnimation *toward = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputColorMatrix"];
        toward.toValue = [colorMatrixFilter(.6, 0, 1) valueForKey:@"inputColorMatrix"];
        toward.duration = 1;
        toward.speed = 0;
        toward.timeOffset = .5;
        backdrop.filters = native.filters = @[identity];
        for (CALayer *target in @[backdrop, native]) {
            [target addAnimation:held forKey:@"held"];
            [target addAnimation:toward forKey:@"toward"];
        }
        compareBands("stacked to-only matrix", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];

        // A keyframe dip under an animation-wide ease-in, sampled near its middle keyframe.
        CAKeyframeAnimation *easedDip = [[dip copy] autorelease];
        easedDip.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        easedDip.timeOffset = .66;
        backdrop.filters = native.filters = @[identity];
        [backdrop addAnimation:easedDip forKey:@"easedDip"];
        [native addAnimation:easedDip forKey:@"easedDip"];
        compareBands("keyframes under ease-in", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];

        // Reversed playback.
        CAKeyframeAnimation *reversed = [CAKeyframeAnimation animationWithKeyPath:@"filters.filter_0.inputAmount"];
        reversed.values = @[@1, @.4, @1];
        reversed.duration = 1;
        reversed.speed = -1;
        reversed.timeOffset = 1;
        backdrop.filters = native.filters = @[named(typed(@"colorContrast", @"inputAmount", @1))];
        for (CALayer *target in @[backdrop, native]) {
            reversed.beginTime = [target convertTime:CACurrentMediaTime() fromLayer:nil] - .3;
            [target addAnimation:reversed forKey:@"reversed"];
        }
        compareBands("reversed keyframes", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];

        // An endless discrete keyframe animation beside a finite one lasting several of its periods.
        CAKeyframeAnimation *stepping = [CAKeyframeAnimation animationWithKeyPath:@"filters.filter_1.inputAmount"];
        stepping.values = @[@1, @.6, @.8];
        stepping.calculationMode = kCAAnimationDiscrete;
        stepping.duration = .2;
        stepping.repeatCount = HUGE_VALF;
        backdrop.filters = native.filters = @[first, second];
        for (CALayer *target in @[backdrop, native]) {
            double now = [target convertTime:CACurrentMediaTime() fromLayer:nil];
            shorter.beginTime = stepping.beginTime = now - 1.3;
            [target addAnimation:shorter forKey:@"shorter"];
            [target addAnimation:stepping forKey:@"stepping"];
        }
        compareBands("endless discrete beside finite", YES);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];

        // Cumulative quarter turns of hue after sepia recur every four iterations; sampled past the 64th.
        CAFilter *namedSepia = [[sepia copy] autorelease];
        [namedSepia setName:@"filter_0"];
        CAFilter *hue = typed(@"colorHueRotate", @"inputAngle", @0);
        [hue setName:@"filter_1"];
        CABasicAnimation *turning = [CABasicAnimation animationWithKeyPath:@"filters.filter_1.inputAngle"];
        turning.fromValue = @0;
        turning.toValue = @(M_PI / 2);
        turning.cumulative = YES;
        turning.duration = .1;
        turning.repeatCount = HUGE_VALF;
        backdrop.filters = native.filters = @[namedSepia, hue];
        for (CALayer *target in @[backdrop, native]) {
            turning.beginTime = [target convertTime:CACurrentMediaTime() fromLayer:nil] - 7.03;
            [target addAnimation:turning forKey:@"turning"];
        }
        compareBands("cumulative hue past 64 periods", NO);
        [backdrop removeAllAnimations];
        [native removeAllAnimations];
        CGColorRelease(fortyGray);
        native.filters = nil;
        CAFilter *blur0 = named([CAFilter filterWithType:@"gaussianBlur"]);
        [blur0 setValue:@0 forKey:@"inputRadius"];
        backdrop.filters = @[blur0];
        CABasicAnimation *blurIn = [CABasicAnimation animationWithKeyPath:@"filters.filter_0.inputRadius"];
        blurIn.fromValue = @0;
        blurIn.toValue = @20;
        blurIn.duration = 1;
        blurIn.speed = 0;
        blurIn.timeOffset = .5;
        [backdrop addAnimation:blurIn forKey:@"blurIn"];
        expectBlack(blurAlpha(10));
        compareBands("paused blur radius", YES);
        blurIn.timeOffset = .025;
        [backdrop addAnimation:blurIn forKey:@"blurIn"];
        expectBlack(blurAlpha(.5));
        compareBands("blur radius near zero", YES);
        [backdrop removeAllAnimations];
        assert(!backdrop.animationKeys.count);
        CGColorRelease(halfGray);
        CGColorRelease(fifthGray);
        puts("PASS fill follows paused filter animations");
        [bands orderOut:nil];
        [bands release];
    }
    return 0;
}
