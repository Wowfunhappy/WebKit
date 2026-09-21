#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

@interface CABackdropLayer : CALayer @end
@interface CAFilter : NSObject
+ (id)filterWithType:(NSString *)type;
@property(copy) NSString *name;
@end

static unsigned failures;
#define EXPECT(condition) do { if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); ++failures; } } while (0)

@interface BackdropAnimationDelegate : NSObject {
@public
    unsigned starts;
    unsigned stops;
}
@end
@implementation BackdropAnimationDelegate
- (void)animationDidStart:(CAAnimation *)animation
{
    ++starts;
    EXPECT([[(CAPropertyAnimation *)animation keyPath] isEqualToString:@"filters.blur.inputRadius"]);
    EXPECT(animation.delegate == self);
}
- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished
{
    ++stops;
    EXPECT([[(CAPropertyAnimation *)animation keyPath] isEqualToString:@"filters.blur.inputRadius"]);
    EXPECT(animation.delegate == self);
}
@end

static NSBitmapImageRep *capture(NSWindow *window)
{
    [CATransaction flush];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    CGImageRef image = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
        (CGWindowID)window.windowNumber, kCGWindowImageBoundsIgnoreFraming);
    EXPECT(image);
    NSBitmapImageRep *bitmap = image ? [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease] : nil;
    if (image)
        CGImageRelease(image);
    [CATransaction setDisableActions:YES];
    return bitmap;
}

static CGFloat whiteAt(NSBitmapImageRep *bitmap, NSInteger x, NSInteger y)
{
    NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    return color.redComponent;
}

static void compareHalves(NSBitmapImageRep *bitmap)
{
    EXPECT(bitmap.pixelsWide == 400 && bitmap.pixelsHigh == 160);
    unsigned differences = 0;
    for (NSInteger y = 0; y < 160; ++y) {
        for (NSInteger x = 0; x < 200; ++x) {
            NSUInteger actual[4] = { 0 }, expected[4] = { 0 };
            [bitmap getPixel:actual atX:x y:y];
            [bitmap getPixel:expected atX:x + 200 y:y];
            for (unsigned c = 0; c < 4; ++c)
                differences += labs((long)actual[c] - (long)expected[c]) > 1;
        }
    }
    EXPECT(!differences);
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [CATransaction setDisableActions:YES];
        NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 160)
            styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
        NSView *view = window.contentView;
        view.wantsLayer = YES;
        CALayer *backdrops[2];
        for (unsigned i = 0; i < 2; ++i) {
            CALayer *scene = [CALayer layer];
            scene.frame = CGRectMake(i * 200, 0, 200, 160);
            scene.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
            [view.layer addSublayer:scene];
            CALayer *black = [CALayer layer];
            black.frame = CGRectMake(100, 0, 100, 160);
            black.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
            [scene addSublayer:black];
            CATransformLayer *host = [CATransformLayer layer];
            host.frame = scene.bounds;
            [scene addSublayer:host];
            CALayer *backdrop = i ? [CALayer layer] : [CABackdropLayer layer];
            backdrop.frame = CGRectMake(30, 30, 140, 100);
            backdrop.masksToBounds = YES;
            backdrop.cornerRadius = 15;
            [host addSublayer:backdrop];
            backdrops[i] = backdrop;
            CALayer *foreground = [CALayer layer];
            foreground.frame = CGRectMake(85, 45, 30, 20);
            foreground.backgroundColor = CGColorGetConstantColor(kCGColorWhite);
            [host addSublayer:foreground];
        }
        [window orderFrontRegardless];

        CAFilter *invert = [CAFilter filterWithType:@"colorInvert"];
        backdrops[0].filters = @[invert];
        backdrops[1].backgroundFilters = @[invert];
        NSBitmapImageRep *bitmap = capture(window);
        if (!bitmap)
            return 1;
        compareHalves(bitmap);
        EXPECT(whiteAt(bitmap, 60, 80) < 0.05);
        EXPECT(whiteAt(bitmap, 140, 80) > 0.95);
        EXPECT(whiteAt(bitmap, 20, 80) > 0.95);
        EXPECT(whiteAt(bitmap, 31, 31) > 0.95);
        EXPECT([backdrops[0].filters isEqual:backdrops[0].backgroundFilters]);

        CAFilter *blur = [CAFilter filterWithType:@"gaussianBlur"];
        blur.name = @"blur";
        [blur setValue:@6 forKey:@"inputRadius"];
        backdrops[0].filters = @[blur];
        backdrops[1].backgroundFilters = @[blur];
        bitmap = capture(window);
        compareHalves(bitmap);
        CGFloat blurred = whiteAt(bitmap, 99, 80);
        EXPECT(blurred > 0.1 && blurred < 0.9);

        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"filters.blur.inputRadius"];
        animation.fromValue = @2;
        animation.toValue = @12;
        animation.duration = 10;
        animation.speed = 0;
        animation.timeOffset = 5;
        [backdrops[0] addAnimation:animation forKey:@"blur"];
        EXPECT([[(CAPropertyAnimation *)[backdrops[0] animationForKey:@"blur"] keyPath] isEqualToString:animation.keyPath]);
        EXPECT([animation.keyPath isEqualToString:@"filters.blur.inputRadius"]);
        CABasicAnimation *nativeAnimation = [[animation copy] autorelease];
        nativeAnimation.keyPath = @"backgroundFilters.blur.inputRadius";
        [backdrops[1] addAnimation:nativeAnimation forKey:@"blur"];
        compareHalves(capture(window));
        CAAnimation *retrieved = [[[backdrops[0] animationForKey:@"blur"] copy] autorelease];
        [backdrops[0] removeAnimationForKey:@"blur"];
        [backdrops[0] addAnimation:retrieved forKey:@"blur"];
        compareHalves(capture(window));
        CAAnimationGroup *group = [CAAnimationGroup animation];
        CAAnimationGroup *nested = [CAAnimationGroup animation];
        nested.animations = @[animation, nativeAnimation];
        nested.duration = 10;
        group.animations = @[nested];
        group.duration = 10;
        [backdrops[0] addAnimation:group forKey:@"group"];
        CAAnimationGroup *mapped = (CAAnimationGroup *)[backdrops[0] animationForKey:@"group"];
        CAAnimationGroup *mappedNested = (CAAnimationGroup *)mapped.animations[0];
        EXPECT([[(CAPropertyAnimation *)mappedNested.animations[0] keyPath] isEqualToString:animation.keyPath]);
        EXPECT([[(CAPropertyAnimation *)mappedNested.animations[1] keyPath] isEqualToString:nativeAnimation.keyPath]);
        EXPECT([[(CAPropertyAnimation *)nested.animations[0] keyPath] isEqualToString:animation.keyPath]);
        EXPECT([[(CAPropertyAnimation *)nested.animations[1] keyPath] isEqualToString:nativeAnimation.keyPath]);
        CABasicAnimation *filterList = [CABasicAnimation animationWithKeyPath:@"filters"];
        filterList.fromValue = @[blur];
        filterList.toValue = @[blur];
        filterList.duration = 10;
        [backdrops[0] addAnimation:filterList forKey:@"filterList"];
        EXPECT([[(CAPropertyAnimation *)[backdrops[0] animationForKey:@"filterList"] keyPath] isEqualToString:@"filters"]);
        [backdrops[0] removeAllAnimations];
        [backdrops[1] removeAllAnimations];

        BackdropAnimationDelegate *delegate = [[[BackdropAnimationDelegate alloc] init] autorelease];
        CABasicAnimation *callbackAnimation = [[animation copy] autorelease];
        callbackAnimation.speed = 1;
        callbackAnimation.timeOffset = 0;
        callbackAnimation.duration = .01;
        callbackAnimation.delegate = delegate;
        [backdrops[0] addAnimation:callbackAnimation forKey:@"callbacks"];
        EXPECT(callbackAnimation.delegate == delegate);
        EXPECT([backdrops[0] animationForKey:@"callbacks"].delegate == delegate);
        capture(window);
        EXPECT(delegate->starts == 1);
        EXPECT(delegate->stops == 1);

        backdrops[0].filters = nil;
        backdrops[1].backgroundFilters = nil;
        bitmap = capture(window);
        compareHalves(bitmap);
        EXPECT(whiteAt(bitmap, 60, 80) > 0.95);
        EXPECT(whiteAt(bitmap, 140, 80) < 0.05);
        [window orderOut:nil];
        fprintf(stderr, "QuartzCore backdrop: %u failures\n", failures);
    }
    return !!failures;
}
