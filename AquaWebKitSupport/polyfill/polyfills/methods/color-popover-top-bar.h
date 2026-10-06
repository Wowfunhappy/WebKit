// The suggested-colors strip of the color popover, shared (as one static definition) between the
// polyfill proper (methods/AppKit.m, which answers WebKit's -[NSColorPopoverController topBarMatrixView]
// send with it) and its proof, tests/behaviour/AppKit-color-popover-top-bar.m — so the probe exercises
// the very code WebKit runs.
//
// 10.9's NSColorPopover nib holds a color grid and a "Show Colors…" button, so the strip is built here
// out of NSColorPickerMatrixView, the class the nib's grid is, with the controller as its delegate:
// that is what carries a click to -[NSColorPopoverController matrixColorPicker:selectedColor:], which
// sets the color well's color and fires its action, the same path a click on the grid takes.
//
// The caller sizes the swatches after taking the view, so the strip is a dynamic subclass whose three
// configuration setters re-fit it. NSColorPickerMatrixView draws the swatch at (row, column) on a
// swatchSize + 1 pitch starting 1 point in, so a matrix fits its colors in
// numberOfColumns * (swatchSize.width + 1) + 1 by numberOfRows * (swatchSize.height + 1) + 1 — the size
// the nib cuts its own grid to. The popover's content view grows by the strip's height and NSPopover
// reads its content size off the view controller's view, so the popover opens with room for both.
//
// The class is resolved by name: NSColorPickerMatrixView and NSColorPopoverController both have local
// _OBJC_CLASS_$_ symbols in 10.9's AppKit, so neither can be named at compile time.
#ifndef WK_COLOR_POPOVER_TOP_BAR_H
#define WK_COLOR_POPOVER_TOP_BAR_H

#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>

static const char wkColorTopBarKey;
static const char wkColorTopBarBaseHeightKey;
static const char wkColorTopBarClassName[] = "WKMavPolyfillColorSuggestionMatrix";

@protocol WKColorSwatchMatrix <NSObject>
- (NSSize)swatchSize;
- (NSUInteger)numberOfColumns;
- (NSUInteger)numberOfRows;
- (void)setDelegate:(id)delegate;
@end

// Re-fit the strip to its current configuration and give it room at the top of the popover.
static void wkColorTopBarLayOut(NSView *strip)
{
    NSView *host = [strip superview];
    NSView *root = [host superview];
    if (!host || !root)
        return;

    id<WKColorSwatchMatrix> matrix = (id<WKColorSwatchMatrix>)strip;
    NSSize swatch = [matrix swatchSize];
    NSSize fitted = NSMakeSize([matrix numberOfColumns] * (swatch.width + 1) + 1,
                               [matrix numberOfRows] * (swatch.height + 1) + 1);

    NSNumber *stored = objc_getAssociatedObject(host, &wkColorTopBarBaseHeightKey);
    CGFloat width = NSWidth([host frame]);
    CGFloat height = [stored doubleValue] + fitted.height;

    // The nib's grid is height-sizable and would stretch into the space the strip is claiming.
    BOOL autoresizes = [host autoresizesSubviews];
    [host setAutoresizesSubviews:NO];
    [root setFrameSize:NSMakeSize(width, height)];
    [host setFrame:NSMakeRect(0, 0, width, height)];
    [host setAutoresizesSubviews:autoresizes];

    // Centering spends the matrix's one-point outer border on the popover's edges, so the swatches
    // themselves span the full width the caller sized them for.
    [strip setFrame:NSMakeRect(round((width - fitted.width) / 2), height - fitted.height,
                               fitted.width, fitted.height)];
}

static Class wkColorTopBarClass(void)
{
    Class existing = objc_getClass(wkColorTopBarClassName);
    if (existing)
        return existing;

    Class parent = objc_getClass("NSColorPickerMatrixView");
    if (!parent)
        return Nil;
    Class matrix = objc_allocateClassPair(parent, wkColorTopBarClassName, 0);
    if (!matrix)
        return Nil;

    // Anchored super-dispatch: each block closes over the class that DEFINES the override, so the super
    // send starts above the definition whatever is stacked on the instance later.
    char types[64];
    snprintf(types, sizeof(types), "%s%s%s%s", @encode(void), @encode(id), @encode(SEL), @encode(NSUInteger));
    class_addMethod(matrix, @selector(setNumberOfColumns:), imp_implementationWithBlock(^(NSView *strip, NSUInteger columns) {
        struct objc_super superContext = { strip, parent };
        ((void (*)(struct objc_super *, SEL, NSUInteger))objc_msgSendSuper)(&superContext, @selector(setNumberOfColumns:), columns);
        wkColorTopBarLayOut(strip);
    }), types);

    snprintf(types, sizeof(types), "%s%s%s%s", @encode(void), @encode(id), @encode(SEL), @encode(NSSize));
    class_addMethod(matrix, @selector(setSwatchSize:), imp_implementationWithBlock(^(NSView *strip, NSSize swatch) {
        struct objc_super superContext = { strip, parent };
        ((void (*)(struct objc_super *, SEL, NSSize))objc_msgSendSuper)(&superContext, @selector(setSwatchSize:), swatch);
        wkColorTopBarLayOut(strip);
    }), types);

    snprintf(types, sizeof(types), "%s%s%s%s", @encode(void), @encode(id), @encode(SEL), @encode(id));
    class_addMethod(matrix, @selector(setColorList:), imp_implementationWithBlock(^(NSView *strip, NSColorList *colors) {
        struct objc_super superContext = { strip, parent };
        ((void (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&superContext, @selector(setColorList:), colors);
        wkColorTopBarLayOut(strip);
    }), types);

    objc_registerClassPair(matrix);
    return matrix;
}

// The strip for this controller, built and installed at the first ask.
static NSView *wkColorTopBarMatrixView(NSViewController *controller)
{
    NSView *strip = objc_getAssociatedObject(controller, &wkColorTopBarKey);
    if (strip)
        return strip;

    NSBox *root = (NSBox *)[controller view];
    NSView *host = [root contentView];
    Class matrix = wkColorTopBarClass();
    if (!host || !matrix)
        return nil;

    strip = [[matrix alloc] initWithFrame:NSZeroRect];
    [(id<WKColorSwatchMatrix>)strip setDelegate:controller];

    objc_setAssociatedObject(host, &wkColorTopBarBaseHeightKey,
        [NSNumber numberWithDouble:NSHeight([host frame])], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addSubview:strip];
    objc_setAssociatedObject(controller, &wkColorTopBarKey, strip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [strip release];

    wkColorTopBarLayOut(strip);
    return strip;
}

#endif // WK_COLOR_POPOVER_TOP_BAR_H
