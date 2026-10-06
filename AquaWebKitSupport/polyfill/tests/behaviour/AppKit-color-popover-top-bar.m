// The suggested-colors strip (polyfills/methods/color-popover-top-bar.h, wired to WebKit's
// -[NSColorPopoverController topBarMatrixView] send by polyfills/methods/AppKit.m). This probe compiles
// that same single definition, configures the strip the way WebColorPickerMac does for an
// <input type="color" list="..."> and checks what the popover then contains:
//
//   1. the strip is a real NSColorPickerMatrixView in the popover's content view, with the controller as
//      its delegate — the wiring that carries a swatch click to -matrixColorPicker:selectedColor:;
//   2. it fits its swatches exactly, on the swatchSize + 1 pitch the class draws on, and spans the
//      popover's full width with the caller's sizing;
//   3. the popover's content grows by the strip's height and the nib's own grid and button keep their
//      geometry — they are height-sizable and would otherwise stretch into the strip's space;
//   4. asking twice hands back the same strip, and re-configuring it re-fits rather than re-growing.
#import "color-popover-top-bar.h"

// What the caller sends the strip, beyond what the layout itself reads.
@protocol WKColorSwatchMatrixProbe <WKColorSwatchMatrix>
- (void)setNumberOfColumns:(NSUInteger)columns;
- (void)setSwatchSize:(NSSize)size;
- (void)setColorList:(NSColorList *)colors;
- (NSRect)rectForColorAtIndex:(NSUInteger)index;
- (id)delegate;
@end

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// WebColorPickerMac's sizing: every suggestion in one row, filling a 12-column matrix of 13pt swatches.
static void configureLikeWebKit(id<WKColorSwatchMatrixProbe> strip, NSColorList *suggestions)
{
    NSUInteger count = [[suggestions allKeys] count];
    [strip setNumberOfColumns:count];
    [strip setSwatchSize:NSMakeSize((12 * 13.0 + (12 * 1.0 - count)) / count, 13.0)];
    [strip setColorList:suggestions];
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];

        NSViewController *controller = [[NSClassFromString(@"NSColorPopoverController") alloc] init];
        NSBox *root = (NSBox *)[controller view];
        NSView *host = [root contentView];
        NSView *grid = [[host subviews] objectAtIndex:0];
        NSView *button = [[host subviews] objectAtIndex:1];
        CGFloat baseHeight = NSHeight([host frame]);
        NSRect gridFrame = [grid frame];
        NSRect buttonFrame = [button frame];

        NSColorList *suggestions = [[NSColorList alloc] init];
        NSArray *colors = [NSArray arrayWithObjects:[NSColor redColor], [NSColor greenColor],
                                                    [NSColor blueColor], [NSColor yellowColor], nil];
        for (NSUInteger i = 0; i < [colors count]; i++)
            [suggestions insertColor:[colors objectAtIndex:i] key:[[NSNumber numberWithUnsignedInteger:i] stringValue] atIndex:i];

        id<WKColorSwatchMatrixProbe> strip = (id<WKColorSwatchMatrixProbe>)wkColorTopBarMatrixView(controller);
        check(strip != nil, "the controller hands back a strip");
        check([strip isKindOfClass:NSClassFromString(@"NSColorPickerMatrixView")],
              "the strip is an NSColorPickerMatrixView");
        check([(NSView *)strip superview] == host, "the strip is in the popover's content view");
        check([strip delegate] == controller, "the controller is the strip's delegate");

        configureLikeWebKit(strip, suggestions);

        NSRect stripFrame = [(NSView *)strip frame];
        NSSize swatch = [strip swatchSize];
        check([strip numberOfRows] == 1 && [strip numberOfColumns] == [colors count],
              "the suggestions occupy a single row");
        check(NSWidth(stripFrame) == [colors count] * (swatch.width + 1) + 1
              && NSHeight(stripFrame) == swatch.height + 2, "the strip fits its swatches exactly");
        NSRect first = [strip rectForColorAtIndex:0];
        NSRect last = [strip rectForColorAtIndex:[colors count] - 1];
        check(NSMinX(stripFrame) + NSMinX(first) >= 0
              && NSMinX(stripFrame) + NSMaxX(last) <= NSWidth([host frame]),
              "every swatch lands inside the popover");

        check(NSHeight([host frame]) == baseHeight + NSHeight(stripFrame)
              && NSHeight([root frame]) == NSHeight([host frame]),
              "the popover's content grew by the strip's height");
        check(NSMaxY(stripFrame) == NSHeight([host frame]), "the strip sits at the top");
        check(NSEqualRects([grid frame], gridFrame) && NSEqualRects([button frame], buttonFrame),
              "the nib's grid and button keep their geometry");

        check((id)wkColorTopBarMatrixView(controller) == (id)strip, "asking twice hands back the same strip");
        configureLikeWebKit(strip, suggestions);
        check(NSHeight([host frame]) == baseHeight + NSHeight(stripFrame),
              "re-configuring re-fits rather than re-growing");
    }

    printf("%s\n", failures ? "FAILED" : "color popover: the suggested-colors strip fits and the popover makes room");
    return failures ? 1 : 0;
}
