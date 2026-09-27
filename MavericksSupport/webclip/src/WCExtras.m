#import "WCThemes.h"

static NSString * const WCPlugInBundleIdentifier = @"com.apple.widget.webclip.plugin";

NSString *WCLocalizedString(const char *key)
{
    static NSBundle *bundle;
    if (!bundle)
        bundle = [NSBundle bundleWithIdentifier:WCPlugInBundleIdentifier];
    CFStringRef keyString = CFStringCreateWithCStringNoCopy(NULL, key, kCFStringEncodingUTF8, kCFAllocatorNull);
    NSString *result = [bundle localizedStringForKey:(__bridge NSString *)keyString value:@"localized string not found" table:nil];
    CFRelease(keyString);
    return result;
}

@implementation NSImage (WCExtras)

+ (NSImage *)wc_PNGNamed:(NSString *)name
{
    return [[NSBundle bundleWithIdentifier:WCPlugInBundleIdentifier] imageForResource:name];
}

+ (NSImage *)wc_flippedPNGNamed:(NSString *)name
{
    NSImage *image = [self wc_PNGNamed:name];
    [image setFlipped:YES];
    return image;
}

- (NSImage *)wc_tintedImageWithColor:(NSColor *)color operation:(NSCompositingOperation)operation
{
    NSSize size = [self size];
    NSRect rect = { NSZeroPoint, size };
    NSImage *tinted = [[NSImage alloc] initWithSize:size];
    [tinted lockFocus];
    [self compositeToPoint:NSZeroPoint operation:NSCompositingOperationSourceOver];
    [color set];
    NSRectFillUsingOperation(rect, operation);
    [tinted unlockFocus];
    return tinted;
}

- (NSImage *)wc_tintedImageWithColor:(NSColor *)color
{
    return [self wc_tintedImageWithColor:color operation:NSCompositingOperationDestinationIn];
}

- (void)wc_drawInRect:(NSRect)rect dirtyRect:(NSRect)dirtyRect fraction:(float)fraction
{
    if (!NSIntersectsRect(dirtyRect, rect))
        return;
    NSRect fromRect = { NSZeroPoint, [self size] };
    [self drawInRect:rect fromRect:fromRect operation:NSCompositingOperationSourceOver fraction:fraction];
}

- (void)wc_drawInRect:(NSRect)rect dirtyRect:(NSRect)dirtyRect
{
    [self wc_drawInRect:rect dirtyRect:dirtyRect fraction:1.0f];
}

- (void)wc_drawAtPoint:(NSPoint)point dirtyRect:(NSRect)dirtyRect fraction:(float)fraction
{
    NSRect rect = { point, [self size] };
    [self wc_drawInRect:rect dirtyRect:dirtyRect fraction:fraction];
}

- (void)wc_drawAtPoint:(NSPoint)point dirtyRect:(NSRect)dirtyRect
{
    [self wc_drawAtPoint:point dirtyRect:dirtyRect fraction:1.0f];
}

@end

@implementation NSView (WCExtras)

- (NSRect)wc_convertRect:(NSRect)rect toView:(NSView *)view
{
    if (!view)
        return [self convertRect:rect toView:nil];

    NSWindow *window = [self window];
    if (!window)
        return [self convertRect:rect toView:view];

    NSWindow *viewWindow = [view window];
    if (!viewWindow)
        return [self convertRect:rect toView:view];

    // Cross-window conversion goes through screen coordinates.
    NSRect converted = [self convertRect:rect toView:nil];
    converted.origin = [window convertBaseToScreen:converted.origin];
    converted.origin = [viewWindow convertScreenToBase:converted.origin];
    return [view convertRect:converted fromView:nil];
}

// Draws a three-part horizontal strip: left and right caps at their natural widths, and the middle image
// stretched between them. middlePinning 0 pins the middle to the strip's top at its natural height, 1 pins
// it to the strip's bottom at its natural height, and any other value fills the strip's full height.
- (void)wc_drawLeftImage:(NSImage *)left middleImage:(NSImage *)middle rightImage:(NSImage *)right inRect:(NSRect)rect dirtRect:(NSRect)dirtyRect operation:(NSCompositingOperation)operation middlePinning:(int)middlePinning
{
    NSSize leftSize = [left size];
    CGFloat middleY = rect.origin.y;
    NSRect leftRect = NSMakeRect(rect.origin.x, rect.origin.y, leftSize.width, rect.size.height);
    if (NSIntersectsRect(dirtyRect, leftRect))
        [left drawInRect:leftRect fromRect:NSMakeRect(0, 0, leftSize.width, leftSize.height) operation:operation fraction:1.0];

    NSSize rightSize = [right size];
    NSRect rightRect = NSMakeRect(rect.size.width - rightSize.width, rect.origin.y, rightSize.width, rect.size.height);
    if (NSIntersectsRect(dirtyRect, rightRect))
        [right drawInRect:rightRect fromRect:NSMakeRect(0, 0, rightSize.width, rightSize.height) operation:operation fraction:1.0];

    if (!middle)
        return;

    NSSize middleSize = [middle size];
    float middleHeight;
    if (middlePinning == 1) {
        middleHeight = middleSize.height;
        middleY = (rect.origin.y + rect.size.height) - middleHeight;
    } else if (!middlePinning)
        middleHeight = middleSize.height;
    else
        middleHeight = rect.size.height;

    NSRect middleRect;
    middleRect.origin.x = leftRect.origin.x + leftRect.size.width;
    middleRect.origin.y = (float)middleY;
    middleRect.size.width = rect.size.width - leftSize.width - rightSize.width - rect.origin.x;
    middleRect.size.height = middleHeight;
    if (NSIntersectsRect(dirtyRect, middleRect))
        [middle drawInRect:middleRect fromRect:NSMakeRect(0, 0, middleSize.width, middleSize.height) operation:operation fraction:1.0];
}

@end
