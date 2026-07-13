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
#import <PDFKit/PDFKit.h>
#import <mach/mach.h>

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
+ (NSColor *)wk_alternateSelectedControlTextColor;
+ (NSColor *)wk_unemphasizedSelectedContentBackgroundColor; + (NSColor *)wk_unemphasizedSelectedTextBackgroundColor;
+ (NSColor *)wk_selectedTextBackgroundColor;
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
+ (NSColor *)wk_selectedContentBackgroundColor          { return SRGB(56, 117, 215, 255); } // list-box active selection (sRGB; see note)
+ (NSColor *)wk_alternateSelectedControlTextColor       { return SRGB(255, 255, 255, 255); } // list-box active selection text
+ (NSColor *)wk_unemphasizedSelectedTextColor           { return [NSColor textColor]; }
+ (NSColor *)wk_unemphasizedSelectedContentBackgroundColor { return SRGB(220, 220, 220, 255); }
+ (NSColor *)wk_selectedTextBackgroundColor            { return SRGB(166, 207, 252, 255); } // 10.9 active text-selection (see note)
+ (NSColor *)wk_unemphasizedSelectedTextBackgroundColor { return SRGB(220, 220, 220, 255); }
+ (NSColor *)wk_controlAccentColor                      { return [NSColor alternateSelectedControlColor]; } // 10.9 system blue
+ (NSColor *)wk_separatorColor                          { return [NSColor gridColor]; }
+ (NSColor *)wk_containerBorderColor                    { return [NSColor gridColor]; }
+ (NSColor *)wk_findHighlightColor                      { return SRGB(255, 237, 102, 255); } // real find-highlight yellow
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
WK_POLYFILL_SEL("alternateSelectedControlTextColor", "wk_alternateSelectedControlTextColor");
WK_POLYFILL_SEL("unemphasizedSelectedTextColor", "wk_unemphasizedSelectedTextColor");
WK_POLYFILL_SEL("unemphasizedSelectedContentBackgroundColor", "wk_unemphasizedSelectedContentBackgroundColor");
WK_POLYFILL_SEL("unemphasizedSelectedTextBackgroundColor", "wk_unemphasizedSelectedTextBackgroundColor");
// selectedTextBackgroundColor EXISTS on 10.9, but WebKit's colorFromCocoaColor() conversion of it (and the
// other selection/highlight catalog colors) yields BLACK on 10.9 (a colorspace-conversion gap). Returning
// an explicit sRGB color converts cleanly — so these behavior overrides are given fixed sRGB values that
// match the classic OS X 10.9 selection palette, letting RenderThemeMac revert to its pristine calls.
WK_POLYFILL_SEL("selectedTextBackgroundColor", "wk_selectedTextBackgroundColor");
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

// ---------------------------------------------------------------------------------------------------
// -[NSString containsString:] (10.10+) via the classic -rangeOfString:.
@interface NSString (WKPolyfillScope)
- (BOOL)wk_containsString:(NSString *)str;
@end
@implementation NSString (WKPolyfillScope)
- (BOOL)wk_containsString:(NSString *)str { return [self rangeOfString:str].location != NSNotFound; }
@end
WK_POLYFILL_SEL("containsString:", "wk_containsString:");

// ---------------------------------------------------------------------------------------------------
// +[NSMenu menuTypeForEvent:] (10.10+): classify a mouse event into a menu type. On 10.9, reproduce the
// documented mapping — right-click or control+left-click opens a context menu, otherwise none.
// NSMenuType is not in the public AppKit headers (WebKit declares it in pal/spi/mac/NSMenuSPI.h); this
// polyfill lives outside WebKit's include paths, so forward-declare the enum to match.
typedef NS_ENUM(NSInteger, NSMenuType) {
    NSMenuTypeNone = 0,
    NSMenuTypeContextMenu = 1,
};
@interface NSMenu (WKPolyfillScope)
+ (NSMenuType)wk_menuTypeForEvent:(NSEvent *)event;
@end
@implementation NSMenu (WKPolyfillScope)
+ (NSMenuType)wk_menuTypeForEvent:(NSEvent *)event
{
    if (event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp)
        return NSMenuTypeContextMenu;
    if ((event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp)
        && (event.modifierFlags & NSEventModifierFlagControl))
        return NSMenuTypeContextMenu;
    return NSMenuTypeNone;
}
@end
WK_POLYFILL_SEL("menuTypeForEvent:", "wk_menuTypeForEvent:");

// ---------------------------------------------------------------------------------------------------
// -[NSPasteboard _setExpirationDate:] (11.0+ private SPI): auto-clears ephemeral pasteboard data after a
// delay. 10.9 has no such pasteboard-server mechanism, so the faithful 10.9 behavior is a no-op (the data
// simply persists, exactly as when the guard skipped the call).
@interface NSPasteboard (WKPolyfillScope)
- (void)wk__setExpirationDate:(NSDate *)date;
@end
@implementation NSPasteboard (WKPolyfillScope)
- (void)wk__setExpirationDate:(NSDate *)date { (void)date; }
@end
WK_POLYFILL_SEL("_setExpirationDate:", "wk__setExpirationDate:");

// ---------------------------------------------------------------------------------------------------
// -[PDFPage drawWithBox:toContext:] (10.12+) via the classic -[PDFPage drawWithBox:] (10.4+), which
// renders into the CURRENT NSGraphicsContext. Wrap the passed CGContext as current for the duration of
// the draw, restoring the prior context after — the CTM the caller applied to `context` is honored.
@interface PDFPage (WKPolyfillScope)
- (void)wk_drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context;
@end
@implementation PDFPage (WKPolyfillScope)
- (void)wk_drawWithBox:(PDFDisplayBox)box toContext:(CGContextRef)context
{
    NSGraphicsContext *priorContext = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithGraphicsPort:(void *)context flipped:NO]];
    [self drawWithBox:box];
    [NSGraphicsContext setCurrentContext:priorContext];
}
@end
WK_POLYFILL_SEL("drawWithBox:toContext:", "wk_drawWithBox:toContext:");

// ---------------------------------------------------------------------------------------------------
// Post-10.9 side-effect-only SPIs with no 10.9 equivalent — faithful no-ops (identical to the current
// guarded skip). NSURLSession +_disableAppSSO (10.13), NSApplication +_preventDockConnections (10.10) /
// -_setAccentColor: (10.14), NSWindow -setTitlebarAppearsTransparent: (10.10) / -setTitleVisibility:
// (10.10) — 10.9 has no App-SSO, no dock-connection control, no window accent, no transparent titlebar,
// and the window title is always shown.
@interface NSURLSession (WKPolyfillScope)
+ (void)wk__disableAppSSO;
@end
@implementation NSURLSession (WKPolyfillScope)
+ (void)wk__disableAppSSO { }
@end
WK_POLYFILL_SEL("_disableAppSSO", "wk__disableAppSSO");

@interface NSApplication (WKPolyfillScope)
+ (void)wk__preventDockConnections;
- (void)wk__setAccentColor:(NSColor *)color;
@end
@implementation NSApplication (WKPolyfillScope)
+ (void)wk__preventDockConnections { }
- (void)wk__setAccentColor:(NSColor *)color { (void)color; }
@end
WK_POLYFILL_SEL("_preventDockConnections", "wk__preventDockConnections");
WK_POLYFILL_SEL("_setAccentColor:", "wk__setAccentColor:");

@interface NSWindow (WKPolyfillScopeChrome)
- (void)wk_setTitlebarAppearsTransparent:(BOOL)flag;
- (void)wk_setTitleVisibility:(NSInteger)visibility;
@end
@implementation NSWindow (WKPolyfillScopeChrome)
- (void)wk_setTitlebarAppearsTransparent:(BOOL)flag { (void)flag; }
- (void)wk_setTitleVisibility:(NSInteger)visibility { (void)visibility; }
@end
WK_POLYFILL_SEL("setTitlebarAppearsTransparent:", "wk_setTitlebarAppearsTransparent:");
WK_POLYFILL_SEL("setTitleVisibility:", "wk_setTitleVisibility:");

// ---------------------------------------------------------------------------------------------------
// -[NSString stringByApplyingTransform:reverse:] (10.11+) via CFStringTransform (10.4+), which accepts
// the same ICU transform IDs (e.g. @"Hans-Hant"). Returns the transformed string, or nil if the
// transform fails — matching the modern method's contract. (Verified CFStringTransform(@"Hans-Hant")
// works on 10.9.)
@interface NSString (WKPolyfillScopeTransform)
- (NSString *)wk_stringByApplyingTransform:(NSString *)transform reverse:(BOOL)reverse;
@end
@implementation NSString (WKPolyfillScopeTransform)
- (NSString *)wk_stringByApplyingTransform:(NSString *)transform reverse:(BOOL)reverse
{
    NSMutableString *result = [[self mutableCopy] autorelease];
    CFRange range = CFRangeMake(0, result.length);
    if (CFStringTransform((CFMutableStringRef)result, &range, (CFStringRef)transform, reverse))
        return result;
    return nil;
}
@end
WK_POLYFILL_SEL("stringByApplyingTransform:reverse:", "wk_stringByApplyingTransform:reverse:");

// ---------------------------------------------------------------------------------------------------
// -[NSRunLoop performBlock:] (10.13+) via CFRunLoopPerformBlock (10.6+): enqueue the block to run on the
// next iteration of this run loop in the common modes, then wake the loop so it fires promptly. This is
// exactly what the modern method does, and (like it) is safe to call from another thread — WebKit uses it
// from async completion handlers (spell-check results, XPC teardown) to hop back onto a run loop.
@interface NSRunLoop (WKPolyfillScope)
- (void)wk_performBlock:(void (^)(void))block;
@end
@implementation NSRunLoop (WKPolyfillScope)
- (void)wk_performBlock:(void (^)(void))block
{
    CFRunLoopRef runLoop = [self getCFRunLoop];
    CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(runLoop);
}
@end
WK_POLYFILL_SEL("performBlock:", "wk_performBlock:");

// ---------------------------------------------------------------------------------------------------
// -[NSColorWell setSupportsAlpha:] (14.0+): 10.9 honors alpha through the shared color panel's alpha slider
// (NSPopoverColorWell, the receiver, is backed by +[NSColorPanel sharedColorPanel]).
@interface NSColorWell (WKPolyfillScope)
- (void)wk_setSupportsAlpha:(BOOL)flag;
@end
@implementation NSColorWell (WKPolyfillScope)
- (void)wk_setSupportsAlpha:(BOOL)flag { [[NSColorPanel sharedColorPanel] setShowsAlpha:flag]; }
@end
WK_POLYFILL_SEL("setSupportsAlpha:", "wk_setSupportsAlpha:");

// ---------------------------------------------------------------------------------------------------
// -[NSApplication _effectiveAccentColor] (10.14+ SPI): the default macOS accent/control-tint blue. Must be an
// EXPLICIT sRGB color, NOT a catalog color like alternateSelectedControlColor: PageClientImpl::accentColor()
// feeds this through colorFromCocoaColor() -> [color colorUsingColorSpace:], which resolves 10.9 catalog
// colors to BLACK (same trap as the text-selection colors above). colorWithSRGBRed: is already concrete, so
// the downstream space conversion is a no-op and the accent stays blue.
@interface NSApplication (WKPolyfillScopeAccent)
- (NSColor *)wk__effectiveAccentColor;
@end
@implementation NSApplication (WKPolyfillScopeAccent)
- (NSColor *)wk__effectiveAccentColor { return SRGB(0, 122, 255, 255); }
@end
WK_POLYFILL_SEL("_effectiveAccentColor", "wk__effectiveAccentColor");

// ---------------------------------------------------------------------------------------------------
// -[NSTextInputContext handleEvent:completionHandler:] (10.10+ SPI): delegate to the synchronous 10.6
// -handleEvent: and report its result — routing the event through the input context first, as upstream does.
// ("handleEvent:" is intentionally NOT registered, so the inner call is not itself rewritten.)
@interface NSTextInputContext (WKPolyfillScope)
- (void)wk_handleEvent:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler;
@end
@implementation NSTextInputContext (WKPolyfillScope)
- (void)wk_handleEvent:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler
{
    BOOL handled = [self handleEvent:event];
    if (completionHandler)
        completionHandler(handled);
}
@end
WK_POLYFILL_SEL("handleEvent:completionHandler:", "wk_handleEvent:completionHandler:");

// ---------------------------------------------------------------------------------------------------
// SF Symbols (11.0+): no system symbols exist on 10.9, so +imageWithSystemSymbolName: (and the private
// variant) return nil for every name — matching the real API's unknown-symbol contract. Callers that pass the
// result to -setImage:/-_setActionImage:/+imageViewWithImage: tolerate nil; the one caller that dereferences
// the image (RenderThemeMac's attachment-progress placeholder) carries its own MAVERICKS_BACKPORT nil-guard.
// +[NSImageView imageViewWithImage:] (10.12+) builds the view the classic way; -setSymbolConfiguration: and
// -setContentTintColor: are cosmetic template-image properties with nothing to configure for a nil image.
@interface NSImage (WKPolyfillScope)
+ (NSImage *)wk_imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc;
+ (NSImage *)wk_imageWithPrivateSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc;
@end
@implementation NSImage (WKPolyfillScope)
+ (NSImage *)wk_imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc { return nil; }
+ (NSImage *)wk_imageWithPrivateSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc { return nil; }
@end
WK_POLYFILL_SEL("imageWithSystemSymbolName:accessibilityDescription:", "wk_imageWithSystemSymbolName:accessibilityDescription:");
WK_POLYFILL_SEL("imageWithPrivateSystemSymbolName:accessibilityDescription:", "wk_imageWithPrivateSystemSymbolName:accessibilityDescription:");

@interface NSImageView (WKPolyfillScope)
+ (NSImageView *)wk_imageViewWithImage:(NSImage *)image;
- (void)wk_setSymbolConfiguration:(id)configuration;
- (void)wk_setContentTintColor:(NSColor *)color;
@end
@implementation NSImageView (WKPolyfillScope)
+ (NSImageView *)wk_imageViewWithImage:(NSImage *)image
{
    NSImageView *view = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
    [view setImage:image];
    return view;
}
- (void)wk_setSymbolConfiguration:(id)configuration { (void)configuration; }
- (void)wk_setContentTintColor:(NSColor *)color { (void)color; }
@end
WK_POLYFILL_SEL("imageViewWithImage:", "wk_imageViewWithImage:");
WK_POLYFILL_SEL("setSymbolConfiguration:", "wk_setSymbolConfiguration:");
WK_POLYFILL_SEL("setContentTintColor:", "wk_setContentTintColor:");

// ---------------------------------------------------------------------------------------------------
// CAContext cross-process fence ports (createFencePort/setFencePort:/invalidateFences, ~10.10+): 10.9's
// QuartzCore has no cross-process CA fencing. A null port end-to-end (producer's createFencePort plus every
// consumer's setFencePort:/invalidateFences) is behavior-identical to the pre-fence path: no live-resize
// flicker suppression, correct eventual rendering, and — because nobody waits on a real port — no hang.
// CAContext is SPI (absent from the public QuartzCore headers), so it is declared here.
@interface CAContext : NSObject
@end
@interface CAContext (WKPolyfillScope)
- (mach_port_t)wk_createFencePort;
- (void)wk_setFencePort:(mach_port_t)port;
- (void)wk_invalidateFences;
@end
@implementation CAContext (WKPolyfillScope)
- (mach_port_t)wk_createFencePort { return MACH_PORT_NULL; }
- (void)wk_setFencePort:(mach_port_t)port { (void)port; }
- (void)wk_invalidateFences { }
@end
WK_POLYFILL_SEL("createFencePort", "wk_createFencePort");
WK_POLYFILL_SEL("setFencePort:", "wk_setFencePort:");
WK_POLYFILL_SEL("invalidateFences", "wk_invalidateFences");

// ---------------------------------------------------------------------------------------------------
// -[NSOperationQueue underlyingQueue] (10.10+): the main operation queue is backed by the main dispatch
// queue on 10.9; any other queue has no underlying dispatch queue (nil) — the honest 10.9 answer.
@interface NSOperationQueue (WKPolyfillScope)
- (dispatch_queue_t)wk_underlyingQueue;
@end
@implementation NSOperationQueue (WKPolyfillScope)
- (dispatch_queue_t)wk_underlyingQueue
{
    return self == [NSOperationQueue mainQueue] ? dispatch_get_main_queue() : nil;
}
@end
WK_POLYFILL_SEL("underlyingQueue", "wk_underlyingQueue");

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPCookieStorage _saveCookies:] (block variant, ~10.13+): 10.9 has the argument-less -_saveCookies,
// which hands the cookies to nsurlstoraged for the on-disk write. Call it, then run the completion (the
// caller's block redispatches to the main run loop itself).
@interface NSHTTPCookieStorage (WKPolyfillScope)
- (void)_saveCookies;   // 10.9 argument-less private SPI (not registered, so this send is not rewritten)
- (void)wk__saveCookies:(dispatch_block_t)completionHandler;
@end
@implementation NSHTTPCookieStorage (WKPolyfillScope)
- (void)wk__saveCookies:(dispatch_block_t)completionHandler
{
    [self _saveCookies];
    if (completionHandler)
        completionHandler();
}
@end
WK_POLYFILL_SEL("_saveCookies:", "wk__saveCookies:");

#pragma clang diagnostic pop
