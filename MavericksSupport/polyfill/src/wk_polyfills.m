// wk_polyfills.m — THE POLYFILL LIST for the WebKit-scoped selector mechanism (wk_selref_scope.m).
//
// Each entry is (1) a category method `wk_<name>` on a real system class, implemented via the classic
// 10.9-era API, and (2) a WK_POLYFILL_SEL("<name>", "wk_<name>") registration. At load the patcher
// rewrites WebKit images' selrefs for `<name>` to `wk_<name>`, so WebKit's call sites dispatch the
// polyfill while the public selector stays absent on the class — invisible to a host app that embeds
// WebKit. Force-loaded into WebCore only (with the mechanism), so it loads early in every rendering
// process. To add a polyfill: add the method + WK_POLYFILL_SEL here and rebuild. Nothing else.
//
// VALUES: prefer a SEMANTIC 10.9 equivalent (a real API that still exists and adapts) over a frozen
// literal. Hardcoded sRGB is used only for the system tint palette (systemBlue…systemYellow) and the
// fill hierarchy, which have no 10.9 equivalent — those constants are Apple's documented values. A
// polyfill's contract is the system API's modern behavior, so it is correct at every caller.
//
// RECEIVER SCOPE: the selref rewrite is selector-scoped (every WebKit send of `<name>`, any class),
// unlike a class-scoped class_addMethod. Only register a selector here after confirming WebKit sends it
// to just the intended class on macOS (iOS-only sends and C++ field accesses of the same name do not
// create Mac ObjC selrefs and are irrelevant).

#import "wk_selref_scope.h"
#import <AppKit/AppKit.h>

#define SRGB(r, g, b, a) [NSColor colorWithSRGBRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:(a)/255.0]

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// NSGraphicsContext CGContext accessors (10.10+) via the classic 10.9 graphics-port SPI. -CGContext and
// +graphicsContextWithCGContext:flipped: are the 10.10 renames of -graphicsPort and
// +graphicsContextWithGraphicsPort:flipped:.
@interface NSGraphicsContext (WKPolyfillScope)
- (CGContextRef)wk_CGContext;
+ (NSGraphicsContext *)wk_graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped;
@end
@implementation NSGraphicsContext (WKPolyfillScope)
- (CGContextRef)wk_CGContext { return (CGContextRef)[self graphicsPort]; }
+ (NSGraphicsContext *)wk_graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped
{
    return [NSGraphicsContext graphicsContextWithGraphicsPort:(void *)context flipped:flipped];
}
@end
WK_POLYFILL_SEL("CGContext", "wk_CGContext");
WK_POLYFILL_SEL("graphicsContextWithCGContext:flipped:", "wk_graphicsContextWithCGContext:flipped:");

// ---------------------------------------------------------------------------------------------------
// NSColor semantic + system palette (10.10+/10.14+). Semantic names map to the 10.9 control-text /
// selection semantics (a real color that still adapts); the systemXxx tint palette and systemFill
// hierarchy have no 10.9 equivalent, so use Apple's documented sRGB constants.
@interface NSColor (WKPolyfillScope)
+ (NSColor *)wk_labelColor; + (NSColor *)wk_secondaryLabelColor; + (NSColor *)wk_tertiaryLabelColor;
+ (NSColor *)wk_quaternaryLabelColor; + (NSColor *)wk_quinaryLabelColor; + (NSColor *)wk_placeholderTextColor;
+ (NSColor *)wk_selectedContentBackgroundColor; + (NSColor *)wk_unemphasizedSelectedTextColor;
+ (NSColor *)wk_unemphasizedSelectedContentBackgroundColor; + (NSColor *)wk_unemphasizedSelectedTextBackgroundColor;
+ (NSColor *)wk_controlAccentColor; + (NSColor *)wk_separatorColor; + (NSColor *)wk_containerBorderColor;
+ (NSColor *)wk_findHighlightColor;
+ (NSColor *)wk_systemBlueColor; + (NSColor *)wk_systemBrownColor; + (NSColor *)wk_systemGrayColor;
+ (NSColor *)wk_systemGreenColor; + (NSColor *)wk_systemOrangeColor; + (NSColor *)wk_systemPinkColor;
+ (NSColor *)wk_systemPurpleColor; + (NSColor *)wk_systemRedColor; + (NSColor *)wk_systemYellowColor;
+ (NSColor *)wk_systemFillColor; + (NSColor *)wk_secondarySystemFillColor; + (NSColor *)wk_tertiarySystemFillColor;
@end
@implementation NSColor (WKPolyfillScope)
+ (NSColor *)wk_labelColor                              { return [NSColor controlTextColor]; }
+ (NSColor *)wk_secondaryLabelColor                     { return [NSColor disabledControlTextColor]; }
+ (NSColor *)wk_tertiaryLabelColor                      { return [NSColor disabledControlTextColor]; }
+ (NSColor *)wk_quaternaryLabelColor                    { return [NSColor gridColor]; }
+ (NSColor *)wk_quinaryLabelColor                       { return [NSColor gridColor]; }
+ (NSColor *)wk_placeholderTextColor                    { return [NSColor disabledControlTextColor]; }
+ (NSColor *)wk_selectedContentBackgroundColor          { return [NSColor alternateSelectedControlColor]; }
+ (NSColor *)wk_unemphasizedSelectedTextColor           { return [NSColor textColor]; }
+ (NSColor *)wk_unemphasizedSelectedContentBackgroundColor { return [NSColor secondarySelectedControlColor]; }
+ (NSColor *)wk_unemphasizedSelectedTextBackgroundColor { return [NSColor secondarySelectedControlColor]; }
+ (NSColor *)wk_controlAccentColor                      { return [NSColor alternateSelectedControlColor]; } // 10.9 system blue
+ (NSColor *)wk_separatorColor                          { return [NSColor gridColor]; }
+ (NSColor *)wk_containerBorderColor                    { return [NSColor gridColor]; }
+ (NSColor *)wk_findHighlightColor                      { return [NSColor yellowColor]; }
+ (NSColor *)wk_systemBlueColor   { return SRGB(0, 122, 255, 255); }
+ (NSColor *)wk_systemBrownColor  { return SRGB(162, 132, 94, 255); }
+ (NSColor *)wk_systemGrayColor   { return SRGB(142, 142, 147, 255); }
+ (NSColor *)wk_systemGreenColor  { return SRGB(52, 199, 89, 255); }
+ (NSColor *)wk_systemOrangeColor { return SRGB(255, 149, 0, 255); }
+ (NSColor *)wk_systemPinkColor   { return SRGB(255, 45, 85, 255); }
+ (NSColor *)wk_systemPurpleColor { return SRGB(175, 82, 222, 255); }
+ (NSColor *)wk_systemRedColor    { return SRGB(255, 59, 48, 255); }
+ (NSColor *)wk_systemYellowColor { return SRGB(255, 204, 0, 255); }
+ (NSColor *)wk_systemFillColor          { return SRGB(0, 0, 0, 26); }
+ (NSColor *)wk_secondarySystemFillColor { return SRGB(0, 0, 0, 20); }
+ (NSColor *)wk_tertiarySystemFillColor  { return SRGB(0, 0, 0, 13); }
@end
WK_POLYFILL_SEL("labelColor", "wk_labelColor");
WK_POLYFILL_SEL("secondaryLabelColor", "wk_secondaryLabelColor");
WK_POLYFILL_SEL("tertiaryLabelColor", "wk_tertiaryLabelColor");
WK_POLYFILL_SEL("quaternaryLabelColor", "wk_quaternaryLabelColor");
WK_POLYFILL_SEL("quinaryLabelColor", "wk_quinaryLabelColor");
WK_POLYFILL_SEL("placeholderTextColor", "wk_placeholderTextColor");
WK_POLYFILL_SEL("selectedContentBackgroundColor", "wk_selectedContentBackgroundColor");
WK_POLYFILL_SEL("unemphasizedSelectedTextColor", "wk_unemphasizedSelectedTextColor");
WK_POLYFILL_SEL("unemphasizedSelectedContentBackgroundColor", "wk_unemphasizedSelectedContentBackgroundColor");
WK_POLYFILL_SEL("unemphasizedSelectedTextBackgroundColor", "wk_unemphasizedSelectedTextBackgroundColor");
WK_POLYFILL_SEL("controlAccentColor", "wk_controlAccentColor");
WK_POLYFILL_SEL("separatorColor", "wk_separatorColor");
WK_POLYFILL_SEL("containerBorderColor", "wk_containerBorderColor");
WK_POLYFILL_SEL("findHighlightColor", "wk_findHighlightColor");
WK_POLYFILL_SEL("systemBlueColor", "wk_systemBlueColor");
WK_POLYFILL_SEL("systemBrownColor", "wk_systemBrownColor");
WK_POLYFILL_SEL("systemGrayColor", "wk_systemGrayColor");
WK_POLYFILL_SEL("systemGreenColor", "wk_systemGreenColor");
WK_POLYFILL_SEL("systemOrangeColor", "wk_systemOrangeColor");
WK_POLYFILL_SEL("systemPinkColor", "wk_systemPinkColor");
WK_POLYFILL_SEL("systemPurpleColor", "wk_systemPurpleColor");
WK_POLYFILL_SEL("systemRedColor", "wk_systemRedColor");
WK_POLYFILL_SEL("systemYellowColor", "wk_systemYellowColor");
WK_POLYFILL_SEL("systemFillColor", "wk_systemFillColor");
WK_POLYFILL_SEL("secondarySystemFillColor", "wk_secondarySystemFillColor");
WK_POLYFILL_SEL("tertiarySystemFillColor", "wk_tertiarySystemFillColor");

// ---------------------------------------------------------------------------------------------------
// NSAppearance -tintColor (11.0+). 10.9 has no per-appearance tint; map to the 10.9 accent color (the
// same value wk_controlAccentColor returns). On macOS the `tintColor` ObjC selector is sent only to
// NSAppearance (AppKitControlSystemImage); the other tintColor sites are iOS-only (UIColor/UIView).
//
// DELIBERATELY NOT POLYFILLED: +[NSAppearance currentDrawingAppearance] (10.14+). Supplying it would make
// WebKit's `respondsToSelector:@selector(currentDrawingAppearance)` guards (ControlMac, Switch*Mac,
// ProgressBarMac, ScrollbarTrackCornerSystemImageMac, WebControlView, ScrollbarsControllerMac, …) return
// YES on 10.9, which then send the 10.14+ -_drawInRect:context:options: / 11.0+
// -appearanceByApplyingTintColor: to the returned appearance and crash. With it absent those guards
// correctly take the nil branch (controls draw via the classic path). _usesMetricsAppearance is likewise
// left absent (supportsLargeFormControls short-circuits on the now-NO currentDrawingAppearance probe).
@interface NSAppearance (WKPolyfillScope)
- (NSColor *)wk_tintColor;
@end
@implementation NSAppearance (WKPolyfillScope)
- (NSColor *)wk_tintColor { return [NSColor alternateSelectedControlColor]; } // 10.9 accent
@end
WK_POLYFILL_SEL("tintColor", "wk_tintColor");

// ---------------------------------------------------------------------------------------------------
// NSWorkspace accessibility display options (10.10+). 10.9 has no such preferences → report NO, letting
// WebCore's ReducedMotion/increased-contrast/invert queries run unguarded.
@interface NSWorkspace (WKPolyfillScope)
- (BOOL)wk_accessibilityDisplayShouldIncreaseContrast;
- (BOOL)wk_accessibilityDisplayShouldDifferentiateWithoutColor;
- (BOOL)wk_accessibilityDisplayShouldReduceMotion;
- (BOOL)wk_accessibilityDisplayShouldInvertColors;
@end
@implementation NSWorkspace (WKPolyfillScope)
- (BOOL)wk_accessibilityDisplayShouldIncreaseContrast          { return NO; }
- (BOOL)wk_accessibilityDisplayShouldDifferentiateWithoutColor { return NO; }
- (BOOL)wk_accessibilityDisplayShouldReduceMotion              { return NO; }
- (BOOL)wk_accessibilityDisplayShouldInvertColors              { return NO; }
@end
WK_POLYFILL_SEL("accessibilityDisplayShouldIncreaseContrast", "wk_accessibilityDisplayShouldIncreaseContrast");
WK_POLYFILL_SEL("accessibilityDisplayShouldDifferentiateWithoutColor", "wk_accessibilityDisplayShouldDifferentiateWithoutColor");
WK_POLYFILL_SEL("accessibilityDisplayShouldReduceMotion", "wk_accessibilityDisplayShouldReduceMotion");
WK_POLYFILL_SEL("accessibilityDisplayShouldInvertColors", "wk_accessibilityDisplayShouldInvertColors");

// ---------------------------------------------------------------------------------------------------
// NSScreen -canRepresentDisplayGamut: (10.11+). 10.9 displays are sRGB → NO. Lets PlatformScreenMac
// (collectScreenProperties / screenSupportsExtendedColor) call it unguarded.
@interface NSScreen (WKPolyfillScope)
- (BOOL)wk_canRepresentDisplayGamut:(NSInteger)gamut;
@end
@implementation NSScreen (WKPolyfillScope)
- (BOOL)wk_canRepresentDisplayGamut:(NSInteger)gamut { (void)gamut; return NO; }
@end
WK_POLYFILL_SEL("canRepresentDisplayGamut:", "wk_canRepresentDisplayGamut:");

// ---------------------------------------------------------------------------------------------------
// NSEvent -stage (Force Touch click stage, 10.10.3+). 10.9 has no Force Touch hardware → 0. Lets the
// pressure-event code (PlatformEventFactoryMac) read event.stage unguarded.
@interface NSEvent (WKPolyfillScope)
- (NSInteger)wk_stage;
@end
@implementation NSEvent (WKPolyfillScope)
- (NSInteger)wk_stage { return 0; }
@end
WK_POLYFILL_SEL("stage", "wk_stage");

// ---------------------------------------------------------------------------------------------------
// NSWindow -performWindowDragWithEvent: (10.11+). 10.9 has no native window drag from web content, so
// WebViewImpl::startWindowDrag() (Web Inspector unified toolbar, -webkit-app-region:drag) never moved
// the window. Provide the classic pre-10.11 manual drag loop: follow the mouse until mouse-up.
// -[NSWindow convertPointToScreen:] / -convertPointFromScreen: (10.12+) are the point-based renames of
// the classic -convertBaseToScreen: / -convertScreenToBase: (present, deprecated, on 10.9).
@interface NSWindow (WKPolyfillScope)
- (NSPoint)wk_convertPointToScreen:(NSPoint)point;
- (NSPoint)wk_convertPointFromScreen:(NSPoint)point;
- (void)wk_performWindowDragWithEvent:(NSEvent *)event;
@end
@implementation NSWindow (WKPolyfillScope)
- (NSPoint)wk_convertPointToScreen:(NSPoint)point { return [self convertBaseToScreen:point]; }
- (NSPoint)wk_convertPointFromScreen:(NSPoint)point { return [self convertScreenToBase:point]; }
- (void)wk_performWindowDragWithEvent:(NSEvent *)event
{
    (void)event;
    NSPoint startMouse = [NSEvent mouseLocation];
    NSRect startFrame = [self frame];
    while (YES) {
        @autoreleasepool {
            NSEvent *e = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)
                                            untilDate:[NSDate distantFuture]
                                               inMode:NSEventTrackingRunLoopMode
                                              dequeue:YES];
            if (!e || e.type == NSEventTypeLeftMouseUp)
                break;
            NSPoint now = [NSEvent mouseLocation];
            [self setFrameOrigin:NSMakePoint(startFrame.origin.x + (now.x - startMouse.x),
                                             startFrame.origin.y + (now.y - startMouse.y))];
        }
    }
}
@end
WK_POLYFILL_SEL("performWindowDragWithEvent:", "wk_performWindowDragWithEvent:");
WK_POLYFILL_SEL("convertPointToScreen:", "wk_convertPointToScreen:");
WK_POLYFILL_SEL("convertPointFromScreen:", "wk_convertPointFromScreen:");

// ---------------------------------------------------------------------------------------------------
// NSURL -_lp_simplifiedDisplayString (LinkPresentation, 10.15+). LinkPresentation is absent on 10.9, so
// createDragImageForLink (DragImageCocoa) would send an unrecognized selector to NSURL. Return the host
// (nearest 10.9 meaning of a "simplified" display URL), falling back to the absolute string.
@interface NSURL (WKPolyfillScope)
- (NSString *)wk__lp_simplifiedDisplayString;
@end
@implementation NSURL (WKPolyfillScope)
- (NSString *)wk__lp_simplifiedDisplayString
{
    NSString *host = [self host];
    return host.length ? host : [self absoluteString];
}
@end
WK_POLYFILL_SEL("_lp_simplifiedDisplayString", "wk__lp_simplifiedDisplayString");

#pragma clang diagnostic pop
