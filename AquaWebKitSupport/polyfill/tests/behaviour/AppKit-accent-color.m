#import <AppKit/AppKit.h>
#include <math.h>
#include <stdio.h>

@interface NSApplication (AccentProbe)
- (NSColor *)_effectiveAccentColor;
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSColor *color = [NSApp _effectiveAccentColor];
        if (!color || ![[color colorSpace] isEqual:[NSColorSpace sRGBColorSpace]]) {
            fprintf(stderr, "FAIL accent is not concrete sRGB\n");
            return 1;
        }
        CGFloat r, g, b, a;
        [color getRed:&r green:&g blue:&b alpha:&a];
        BOOL graphite = [NSColor currentControlTint] == NSGraphiteControlTint;
        printf("accent %s class=%s rgba=%.6f %.6f %.6f %.6f\n", graphite ? "graphite" : "blue", NSStringFromClass([color class]).UTF8String, r, g, b, a);
        if (!isfinite(r) || !isfinite(g) || !isfinite(b) || !isfinite(a) || a != 1 || fmax(r, fmax(g, b)) <= 0)
            return 1;
        NSColor *selected = [[NSColor alternateSelectedControlColor] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        CGFloat expectedR, expectedG, expectedB, expectedA;
        [selected getRed:&expectedR green:&expectedG blue:&expectedB alpha:&expectedA];
        if (r != expectedR || g != expectedG || b != expectedB || a != expectedA)
            return 1;
        return 0;
    }
}
