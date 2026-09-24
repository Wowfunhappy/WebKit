// -[NSLevelIndicatorCell drawWithFrame:inView:] (polyfills/methods/AppKit.m): a cell whose
// userInterfaceLayoutDirection is right-to-left fills from the right edge, leaves its control clean and
// keeps its own baseWritingDirection.
#import <AppKit/AppKit.h>
#include <stdio.h>

static int failures;

static void check(BOOL ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

// How much green outweighs red at x in the middle row of an 80x16 draw: the fill is green, the track grey.
static int greenAt(NSBitmapImageRep *rep, NSInteger x)
{
    NSUInteger pixel[4] = { 0 };
    [rep getPixel:pixel atX:x y:8];
    return (int)pixel[1] - (int)pixel[0];
}

static NSBitmapImageRep *render(NSLevelIndicatorCell *cell, NSView *view)
{
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:80 pixelsHigh:16
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0] autorelease];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [cell drawWithFrame:NSMakeRect(0, 0, 80, 16) inView:view];
    [NSGraphicsContext restoreGraphicsState];
    return rep;
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 120, 40) styleMask:NSBorderlessWindowMask
            backing:NSBackingStoreBuffered defer:NO];
        NSLevelIndicator *control = [[NSLevelIndicator alloc] initWithFrame:NSMakeRect(0, 0, 80, 16)];
        [[window contentView] addSubview:control];
        NSLevelIndicatorCell *cell = [control cell];
        [cell setLevelIndicatorStyle:NSContinuousCapacityLevelIndicatorStyle];
        [cell setMinValue:0];
        [cell setMaxValue:100];
        [cell setWarningValue:71];
        [cell setCriticalValue:72];
        [cell setObjectValue:@30];

        NSBitmapImageRep *leftToRight = render(cell, control);
        check(greenAt(leftToRight, 5) > greenAt(leftToRight, 75) + 40, "a left-to-right cell fills from the left edge");

        [cell setUserInterfaceLayoutDirection:NSUserInterfaceLayoutDirectionRightToLeft];
        NSWritingDirection before = [cell baseWritingDirection];
        [window display];
        [control setNeedsDisplay:NO];
        NSBitmapImageRep *rightToLeft = render(cell, control);
        check(greenAt(rightToLeft, 75) > greenAt(rightToLeft, 5) + 40, "a right-to-left cell fills from the right edge");
        check(![control needsDisplay], "drawing a right-to-left cell leaves its control clean");
        check([cell baseWritingDirection] == before, "drawing a right-to-left cell keeps its baseWritingDirection");

        [control release];
        [window release];
    }
    if (!failures)
        printf("PASS\n");
    return failures ? 1 : 0;
}
