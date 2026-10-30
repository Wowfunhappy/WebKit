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
        CGColorRef black = CGColorCreateGenericGray(0, .15);
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
        [window orderOut:nil];
        [window release];
        puts("PASS callback identity, clearing and native opacity/clipping");
    }
    return 0;
}
