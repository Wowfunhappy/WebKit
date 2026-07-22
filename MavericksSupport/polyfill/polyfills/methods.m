// methods.m — Objective-C methods on system classes that macOS 10.9 does not have (or gets wrong),
// implemented with the APIs 10.9 does have.
//
// To add one: implement the method as a category on the real system class under a `wk_`-prefixed name,
// then register it with WK_POLYFILL_SEL("<name>", "wk_<name>"). WebKit's call sites keep saying
// `[obj <name>]` and get the polyfill. That is the whole recipe.
//
// VALUES: prefer a SEMANTIC 10.9 equivalent (a real API that still exists and adapts) over a frozen
// literal. Hardcoded sRGB is used only for the system tint palette (systemBlue…systemYellow) and the
// fill hierarchy, which have no 10.9 equivalent — those constants are Apple's documented values. A
// polyfill's contract is the system API's modern behavior, so it is correct at every caller.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <PDFKit/PDFKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

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
// -[NSButtonCell _setState:animated:] / _setHighlighted:animated: (10.10+) animate the transition; the
// plain -setState: / -setHighlighted: 10.9 already has make it instantly. Every call site passes
// animated:NO, so the instant form is exactly what they ask for.
@interface NSButtonCell (WKPolyfillScope)
- (void)wk__setState:(NSInteger)state animated:(BOOL)animated;
- (void)wk__setHighlighted:(BOOL)highlighted animated:(BOOL)animated;
@end
@implementation NSButtonCell (WKPolyfillScope)
- (void)wk__setState:(NSInteger)state animated:(BOOL)animated { (void)animated; [self setState:state]; }
- (void)wk__setHighlighted:(BOOL)highlighted animated:(BOOL)animated { (void)animated; [self setHighlighted:highlighted]; }
@end
WK_POLYFILL_SEL("_setState:animated:", "wk__setState:animated:");
WK_POLYFILL_SEL("_setHighlighted:animated:", "wk__setHighlighted:animated:");

// ---------------------------------------------------------------------------------------------------
// -[NSError underlyingErrors] (10.14+) is the array-valued successor to the single NSUnderlyingErrorKey
// that 10.9's NSError already carries, so return that one error when the userInfo has it and an empty
// array otherwise — the same shape callers iterate, carrying the real underlying error 10.9 records.
@interface NSError (WKPolyfillScope)
- (NSArray<NSError *> *)wk_underlyingErrors;
@end
@implementation NSError (WKPolyfillScope)
- (NSArray<NSError *> *)wk_underlyingErrors
{
    NSError *underlying = [[self userInfo] objectForKey:NSUnderlyingErrorKey];
    return [underlying isKindOfClass:[NSError class]] ? @[underlying] : @[];
}
@end
WK_POLYFILL_SEL("underlyingErrors", "wk_underlyingErrors");

// ---------------------------------------------------------------------------------------------------
// -[NSProcessInfo isLowPowerModeEnabled] (10.12+). Low Power Mode is a battery-saver state 10.9 has no
// concept of, so the honest answer on this OS is not-enabled. NSProcessInfoPowerStateDidChangeNotification
// (constants.m) is the paired notification; nothing on 10.9 posts it, so an observer of it simply never
// fires.
@interface NSProcessInfo (WKPolyfillScope)
- (BOOL)wk_isLowPowerModeEnabled;
@end
@implementation NSProcessInfo (WKPolyfillScope)
- (BOOL)wk_isLowPowerModeEnabled { return NO; }
@end
WK_POLYFILL_SEL("isLowPowerModeEnabled", "wk_isLowPowerModeEnabled");

// ---------------------------------------------------------------------------------------------------
// -[NSControl setMaximumNumberOfLines:] (10.11+) and -[NSView sizeThatFits:] (10.10+). maximumNumberOfLines
// caps how many wrapped lines a label lays out; sizeThatFits: measures the label at a target width.
// 10.9's -sizeToFit already does the wrapped measurement, so sizeThatFits: reuses it (saving and
// restoring the frame so the measure has no side effect) and then clamps the height to the stored
// line cap. maximumNumberOfLines stores the cap on the control; 0 (the default) means no cap.
static const char kWKMaxLinesKey;
@interface NSControl (WKPolyfillScope)
- (void)wk_setMaximumNumberOfLines:(NSInteger)maximumNumberOfLines;
- (NSSize)wk_sizeThatFits:(NSSize)size;
@end
@implementation NSControl (WKPolyfillScope)
- (void)wk_setMaximumNumberOfLines:(NSInteger)maximumNumberOfLines
{
    objc_setAssociatedObject(self, &kWKMaxLinesKey, @(maximumNumberOfLines), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSSize)wk_sizeThatFits:(NSSize)size
{
    NSRect saved = [self frame];
    [self setFrameSize:NSMakeSize(size.width, size.height)];
    [self sizeToFit];
    NSSize fit = [self frame].size;
    [self setFrame:saved];

    NSInteger maxLines = [objc_getAssociatedObject(self, &kWKMaxLinesKey) integerValue];
    if (maxLines > 0) {
        NSFont *font = [self respondsToSelector:@selector(font)] ? [(id)self font] : nil;
        if (font) {
            NSLayoutManager *lm = [[NSLayoutManager alloc] init];
            CGFloat cap = maxLines * [lm defaultLineHeightForFont:font];
            if (fit.height > cap)
                fit.height = cap;
        }
    }
    return fit;
}
@end
WK_POLYFILL_SEL("setMaximumNumberOfLines:", "wk_setMaximumNumberOfLines:");
WK_POLYFILL_SEL("sizeThatFits:", "wk_sizeThatFits:");

// ---------------------------------------------------------------------------------------------------
// -[CALayerHost setPreservesFlip:] (10.10+). It controls whether a hosted remote layer tree inherits
// the hosting tree's ambient geometry flip. 10.9's CALayerHost has no such method — a direct send
// throws unrecognized-selector — and 10.9's compositor has no host-flip-flag concept, so accept the
// value and leave the host as its default (unflipped) self. Every TiledCoreAnimation host passes NO,
// which is that default; the RemoteLayerTreeHost custom/AVPlayerLayer path can pass YES, which this OS
// cannot honor.
@interface CALayerHost : CALayer
- (void)wk_setPreservesFlip:(BOOL)preservesFlip;
@end
@implementation CALayerHost (WKPolyfillScope)
- (void)wk_setPreservesFlip:(BOOL)preservesFlip { (void)preservesFlip; }
@end
WK_POLYFILL_SEL("setPreservesFlip:", "wk_setPreservesFlip:");

// ---------------------------------------------------------------------------------------------------
// -[NSSearchFieldCell setCenteredLook:] (10.10+). The centered look is the Yosemite rounded search
// field; 10.9's search field cell is the earlier bezeled style, which is the look setCenteredLook:NO
// selects. WebKit only ever passes NO, so this reaches 10.9's state without doing anything.
@interface NSSearchFieldCell (WKPolyfillScope)
- (void)wk_setCenteredLook:(BOOL)centeredLook;
@end
@implementation NSSearchFieldCell (WKPolyfillScope)
- (void)wk_setCenteredLook:(BOOL)centeredLook { (void)centeredLook; }
@end
WK_POLYFILL_SEL("setCenteredLook:", "wk_setCenteredLook:");

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
+ (NSColor *)wk_selectedContentBackgroundColor          { return SRGB(56, 117, 215, 255); } // list-box active selection (sRGB; see note)
+ (NSColor *)wk_unemphasizedSelectedTextColor           { return [NSColor textColor]; }
+ (NSColor *)wk_unemphasizedSelectedContentBackgroundColor { return SRGB(220, 220, 220, 255); }
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
WK_POLYFILL_SEL("unemphasizedSelectedTextColor", "wk_unemphasizedSelectedTextColor");
WK_POLYFILL_SEL("unemphasizedSelectedContentBackgroundColor", "wk_unemphasizedSelectedContentBackgroundColor");
WK_POLYFILL_SEL("unemphasizedSelectedTextBackgroundColor", "wk_unemphasizedSelectedTextBackgroundColor");
// selectedTextBackgroundColor and alternateSelectedControlTextColor stay 10.9's own: both are present
// here, both convert cleanly through makeSimpleColorFromNSColor (measured: rgb(181,213,255) and
// rgb(255,255,255)), and 10.9's answer tracks the highlight colour set in System Preferences, which a
// fixed value cannot. The catalog colours whose deviceRGB conversion does return nil are the patterned
// controlColor and windowBackgroundColor, and upstream already reads those through its swatch fallback.
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
// The NSAppearance drawing API. 10.9 has the whole appearance mechanism — +currentAppearance,
// +setCurrentAppearance: (both PER THREAD, verified on 10.9.5, exactly like their 10.14+ successors),
// +appearanceNamed:, -name and the CoreUI-backed -_drawInRect:context:options:… family. What it lacks is
// the RENAMES and the two capabilities below, which is what these polyfills supply.
//
// The gap is spelling, not capability. 10.9 reaches the same CoreUI entry point through
// -_drawInRect:context:options:inView: / :delegate: / :inWindow:; the 3-argument
// -_drawInRect:context:options: is the 10.14+ name for it. -bestMatchFromAppearancesWithNames: (10.14+)
// and -_usesMetricsAppearance (11.0+) are renames in the same sense. Supplying all four as renames is
// what lets a real appearance reach CoreUI, and none of it involves the tint.
//
// With them supplied, 10.9's CoreUI draws the real widgets — measured on 10.9.5 (13F34) via
// -_drawInRect:context:options:inView:, kCUIWidgetScrollBarTrackCorner fills 900/1024 bytes of a 16x16
// bitmap, kCUIWidgetProgressBar 7600/8000 of a 100x20, kCUIWidgetButtonLittleArrows 935/1536 of a 16x24.
// A widget key this CoreUI does not know draws nothing and throws nothing. The only such key WebCore
// would ever pass is the 12.0+ kCUIWidgetSwitch* family — the one widget family this CoreUI has never
// heard of — and that never arrives, because the switch control is disabled at the WebCore layer on
// this port (see SwitchControlEnabled) and renders as the checkbox it is. Every other key is a real
// 10.9 widget and goes through to CoreUI untouched.
//
// BEHAVIOURAL DIVERGENCE, from two capabilities 10.9's AppKit genuinely does not have:
//   - Dark Aqua. 10.9 ships no dark appearance. +appearanceNamed:NSAppearanceNameDarkAqua returns a
//     stand-in object that carries the name but renders as Aqua, so a dark-appearance draw comes out
//     light. Nothing crashes and no call site is guarded; dark form controls simply look light.
//   - Per-appearance tint. -appearanceByApplyingTintColor: (11.0+) has no 10.9 equivalent: CoreUI on 10.9
//     draws with the system-wide accent (blue/graphite) and takes no per-appearance tint, so the polyfill
//     returns the receiver unchanged and a requested tint is ignored. On this OS the only tint that ever
//     reaches it is the one -tintColor below just handed out — the system accent — so the round trip is
//     exact for every value WebKit actually passes; a tint from anywhere else would be dropped.

// 10.9's spelling of the CoreUI draw, which no SDK we build against declares.
@interface NSAppearance (WKMavericksSPI)
- (void)_drawInRect:(NSRect)rect context:(CGContextRef)context options:(NSDictionary *)options inView:(NSView *)view;
@end

// ---------------------------------------------------------------------------------------------------
// kCUIIsFlippedKey, resolved from CoreUI itself so the option dictionary is keyed by the very string
// CoreUI uses. It is the one CoreUI option this layer supplies; every widget key WebCore passes names a
// real 10.9 CoreUI widget that the real -_drawInRect: below draws. (The switch — the one control family
// 10.9's CoreUI has never heard of — is disabled at the WebCore layer on this port and renders as the
// checkbox it is, so no switch key ever reaches here.)
static NSString *wkCoreUIIsFlippedKey(void)
{
    static void *cache;
    CFStringRef *slot = (CFStringRef *)wk_polyfill_system_symbol(
        "/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", "kCUIIsFlippedKey", &cache);
    return slot ? (__bridge NSString *)*slot : nil;
}

// A negative determinant means the caller's context puts the origin at the top left and grows y
// downwards, which is the transform WebCore's ImageBuffer contexts arrive with. This is what
// kCUIIsFlippedKey below is derived from.
static BOOL wkContextYGrowsDown(CGContextRef context)
{
    CGAffineTransform ctm = CGContextGetCTM(context);
    return (ctm.a * ctm.d - ctm.b * ctm.c) < 0;
}

@interface NSAppearance (WKPolyfillScope)
+ (NSAppearance *)wk_currentDrawingAppearance;
- (NSColor *)wk_tintColor;
- (void)wk__drawInRect:(NSRect)rect context:(CGContextRef)context options:(NSDictionary *)options;
- (NSString *)wk_bestMatchFromAppearancesWithNames:(NSArray *)names;
- (BOOL)wk__usesMetricsAppearance;
- (NSAppearance *)wk_appearanceByApplyingTintColor:(NSColor *)tintColor;
@end
@implementation NSAppearance (WKPolyfillScope)
// 10.14 renamed +currentAppearance (which it deprecated for the setter's sake) to +currentDrawingAppearance;
// the value is the same one -setCurrentAppearance:/-_performWithCurrentAppearance: install for the calling
// thread. 10.9 never leaves it unset, but fall back to Aqua rather than hand back nil, as 10.14+ does not.
+ (NSAppearance *)wk_currentDrawingAppearance
{
    NSAppearance *current = [NSAppearance currentAppearance];
    return current ?: [NSAppearance appearanceNamed:NSAppearanceNameAqua];
}
- (NSColor *)wk_tintColor { return [NSColor alternateSelectedControlColor]; } // 10.9 accent
// 10.9's name for the same CoreUI draw. The view argument only supplies a backing-scale/geometry context
// the callers here do not have either (they pass a bare CGContext), so nil is the faithful mapping. Every
// widget key WebCore passes is one this CoreUI knows (the switch is disabled at the WebCore layer, so it
// never reaches here — see the section note above).
//
// ORIENTATION. kCUIIsFlippedKey is how CoreUI is told which way up the destination runs, and it composes
// with the CTM exactly: measured on 10.9.5, a y-down context drawing kCUIWidgetProgressBar with
// is.flipped:YES is byte-identical to the same widget drawn y-up, and byte-mirrored without it. The
// 10.14+ entry point this stands in for takes no such key and infers the orientation, so deriving it from
// the CTM supplies what the caller no longer says. A caller that does set it is describing its own
// destination and is left alone — ScrollbarTrackCornerSystemImageMac passes YES and InnerSpinButtonMac
// passes NO, and overriding either would mirror a widget CoreUI has already landed correctly.
- (void)wk__drawInRect:(NSRect)rect context:(CGContextRef)context options:(NSDictionary *)options
{
    NSString *isFlippedKey = wkCoreUIIsFlippedKey();
    if (context && isFlippedKey && ![options objectForKey:isFlippedKey]) {
        NSMutableDictionary *oriented = [options mutableCopy] ?: [NSMutableDictionary dictionary];
        oriented[isFlippedKey] = @(wkContextYGrowsDown(context));
        options = oriented;
    }
    [self _drawInRect:rect context:context options:options inView:nil];
}
// 10.9's appearances (Aqua and LightContent) all descend from Aqua and none of them is dark, so the
// receiver's own name wins when it is offered and Aqua is the best match otherwise — the same resolution
// 10.14+ performs over its inheritance graph, on the graph this OS has.
- (NSString *)wk_bestMatchFromAppearancesWithNames:(NSArray *)names
{
    NSString *name = [self name];
    if (name && [names containsObject:name])
        return name;
    for (NSString *candidate in names) {
        if ([candidate isEqualToString:NSAppearanceNameAqua])
            return candidate;
    }
    return nil;
}
// The metrics appearance is the 11.0 large-control geometry. 10.9 has no such appearance, so NO is the
// answer, not a missing one.
- (BOOL)wk__usesMetricsAppearance { return NO; }
// 10.9's CoreUI has no per-appearance tint — see the divergence note above.
- (NSAppearance *)wk_appearanceByApplyingTintColor:(NSColor *)tintColor
{
    (void)tintColor;
    return self;
}
@end
WK_POLYFILL_SEL("currentDrawingAppearance", "wk_currentDrawingAppearance");
WK_POLYFILL_SEL("tintColor", "wk_tintColor");
WK_POLYFILL_SEL("_drawInRect:context:options:", "wk__drawInRect:context:options:");
WK_POLYFILL_SEL("bestMatchFromAppearancesWithNames:", "wk_bestMatchFromAppearancesWithNames:");
WK_POLYFILL_SEL("_usesMetricsAppearance", "wk__usesMetricsAppearance");
WK_POLYFILL_SEL("appearanceByApplyingTintColor:", "wk_appearanceByApplyingTintColor:");

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
- (NSRect)wk_contentLayoutRect;
@end
@implementation NSWindow (WKPolyfillScope)
- (NSPoint)wk_convertPointToScreen:(NSPoint)point { return [self convertBaseToScreen:point]; }
- (NSPoint)wk_convertPointFromScreen:(NSPoint)point { return [self convertScreenToBase:point]; }
// -[NSWindow contentLayoutRect] is 10.10+: the content region not obscured by a full-size-content-view
// title bar, in window coordinates. 10.9 has no full-size content view, so that region is exactly the
// content view's frame -- which is also the fallback the WebKit call sites used before this polyfill.
- (NSRect)wk_contentLayoutRect { return [[self contentView] frame]; }
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
WK_POLYFILL_SEL("contentLayoutRect", "wk_contentLayoutRect");

// ---------------------------------------------------------------------------------------------------
// NSURL -_lp_simplifiedDisplayString (LinkPresentation, 10.15+). LinkPresentation is absent on 10.9, so
// createDragImageForLink (DragImageCocoa) would send an unrecognized selector to NSURL. Return the host
// (nearest 10.9 meaning of a "simplified" display URL), falling back to the absolute string.
//
// +URLByResolvingAliasFileAtURL:options:error: (10.10+). A Finder alias file has been a bookmark file
// since 10.6, so resolve it with the bookmark API 10.9 has; the NSURLBookmarkResolutionOptions bits are
// the same ones the modern method takes. Per the modern contract, a URL that is not an alias file
// (NSURLIsAliasFileKey, which also covers symlinks) comes back unchanged, and symlinks — which carry no
// bookmark data — resolve to their destination.
@interface NSURL (WKPolyfillScope)
- (NSString *)wk__lp_simplifiedDisplayString;
+ (NSURL *)wk_URLByResolvingAliasFileAtURL:(NSURL *)url options:(NSURLBookmarkResolutionOptions)options error:(NSError **)error;
- (instancetype)wk_initWithString:(NSString *)string;
+ (instancetype)wk_URLWithString:(NSString *)string;
@end
@implementation NSURL (WKPolyfillScope)
- (NSString *)wk__lp_simplifiedDisplayString
{
    NSString *host = [self host];
    return host.length ? host : [self absoluteString];
}
+ (NSURL *)wk_URLByResolvingAliasFileAtURL:(NSURL *)url options:(NSURLBookmarkResolutionOptions)options error:(NSError **)error
{
    NSNumber *isAlias = nil;
    [url getResourceValue:&isAlias forKey:NSURLIsAliasFileKey error:NULL];
    if (![isAlias boolValue])
        return url;
    NSError *bookmarkError = nil;
    NSData *bookmarkData = [NSURL bookmarkDataWithContentsOfURL:url error:&bookmarkError];
    if (!bookmarkData) {
        NSNumber *isSymlink = nil;
        if ([url getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:NULL] && [isSymlink boolValue])
            return [url URLByResolvingSymlinksInPath];
        if (error)
            *error = bookmarkError;
        return nil;
    }
    BOOL stale = NO;
    return [NSURL URLByResolvingBookmarkData:bookmarkData options:options relativeToURL:nil bookmarkDataIsStale:&stale error:error];
}
// -getResourceValue:forKey:error: exists on 10.9 but does not know the modern NSURLContentTypeKey
// (11.0+, answered with a UTType). REPLACE it for WebKit's callers: that one key is answered from the
// classic NSURLTypeIdentifierKey wrapped in the UTType polyfill class; every other key forwards to
// 10.9's implementation (reached through a runtime-built selector, which the selref rewrite cannot
// touch, so this cannot recurse into itself).
- (BOOL)wk_getResourceValue:(id *)value forKey:(NSString *)key error:(NSError **)error
{
    typedef BOOL (*WKGetResourceValueFn)(id, SEL, id *, NSString *, NSError **);
    WKGetResourceValueFn original = (WKGetResourceValueFn)objc_msgSend;
    SEL originalSelector = sel_registerName("getResourceValue:forKey:error:");
    if ([key isEqualToString:NSURLContentTypeKey]) {
        NSString *typeIdentifier = nil;
        if (!original(self, originalSelector, (id *)&typeIdentifier, NSURLTypeIdentifierKey, error))
            return NO;
        if (value)
            *value = typeIdentifier ? [UTType typeWithIdentifier:typeIdentifier] : nil;
        return YES;
    }
    return original(self, originalSelector, value, key, error);
}
// -[NSURL initWithString:] and +[NSURL URLWithString:] throw NSInvalidArgumentException on a nil string
// on 10.9 (modern Foundation returns nil). REPLACE both for WebKit's callers with the modern contract:
// nil in -> nil out; any non-nil string forwards to 10.9's real implementation, reached through a
// runtime-built selector the selref rewrite cannot touch (so this cannot recurse into itself). The init
// consumes its already-alloc'd receiver on the nil path to keep the alloc/init ownership contract (methods.m
// is MRR). +URLWithString: is not an init-family selector, so it just returns nil/the autoreleased URL.
- (instancetype)wk_initWithString:(NSString *)string
{
    if (!string) {
        [self release];
        return nil;
    }
    typedef id (*WKURLInitFn)(id, SEL, NSString *);
    WKURLInitFn original = (WKURLInitFn)objc_msgSend;
    return original(self, sel_registerName("initWithString:"), string);
}
+ (instancetype)wk_URLWithString:(NSString *)string
{
    if (!string)
        return nil;
    typedef id (*WKURLWithStringFn)(id, SEL, NSString *);
    WKURLWithStringFn original = (WKURLWithStringFn)objc_msgSend;
    return original(self, sel_registerName("URLWithString:"), string);
}
@end
WK_POLYFILL_SEL("_lp_simplifiedDisplayString", "wk__lp_simplifiedDisplayString");
WK_POLYFILL_SEL("URLByResolvingAliasFileAtURL:options:error:", "wk_URLByResolvingAliasFileAtURL:options:error:");
WK_POLYFILL_SEL_REPLACES("getResourceValue:forKey:error:", "wk_getResourceValue:forKey:error:");
WK_POLYFILL_SEL_REPLACES("initWithString:", "wk_initWithString:");
WK_POLYFILL_SEL_REPLACES("URLWithString:", "wk_URLWithString:");

// ---------------------------------------------------------------------------------------------------
// -[NSAttributedString _htmlDocumentFragmentString:documentAttributes:subresources:] (returns interchange
// HTML fragment markup + collects WebArchive subresources) is ABSENT on 10.9 (verified on-host:
// instancesRespondToSelector == NO; the older -_documentFromRange:document:documentAttributes:subresources:
// exists but yields a WebKit1 DOMDocumentFragment, not a string). WebContentReaderCocoa's
// createFragmentInternal(NSAttributedString*) needs the STRING form when pasting RTF / attributed-string
// content from a native app (TextEdit, Mail, Notes) that puts NO html on the pasteboard; without it rich
// paste is silently stripped to plain text. Reimplement from the PUBLIC exporter
// -dataFromRange:documentAttributes:error: (present on 10.9): NSHTMLTextDocumentType output honors the
// caller's NSExcludedElementsDocumentAttribute, which already excludes doctype/html/head/body/style/xml, so
// the result is fragment markup rather than a full document. Subresources (embedded images) are not
// collected by the public path — return an empty array; inline text formatting (bold/italic/color/underline/
// lists/links) is preserved, which is the overwhelming majority of native-app rich paste.
@interface NSAttributedString (WKPolyfillScope)
- (NSString *)wk__htmlDocumentFragmentString:(NSRange)range documentAttributes:(NSDictionary *)dict subresources:(NSArray **)subresources;
@end
@implementation NSAttributedString (WKPolyfillScope)
- (NSString *)wk__htmlDocumentFragmentString:(NSRange)range documentAttributes:(NSDictionary *)dict subresources:(NSArray **)subresources
{
    if (subresources)
        *subresources = @[];
    NSMutableDictionary *docAttributes = [NSMutableDictionary dictionary];
    [docAttributes setObject:NSHTMLTextDocumentType forKey:NSDocumentTypeDocumentAttribute];
    // Carry over only the public exclusion list; drop the private WebResourceHandler/OutputBaseURL/
    // InterchangeNewline/CoalesceTabSpans keys the public exporter does not understand.
    id excluded = [dict objectForKey:NSExcludedElementsDocumentAttribute];
    if (excluded)
        [docAttributes setObject:excluded forKey:NSExcludedElementsDocumentAttribute];
    NSData *data = [self dataFromRange:range documentAttributes:docAttributes error:NULL];
    if (!data)
        return @"";
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}
@end
WK_POLYFILL_SEL("_htmlDocumentFragmentString:documentAttributes:subresources:", "wk__htmlDocumentFragmentString:documentAttributes:subresources:");

// ---------------------------------------------------------------------------------------------------
// NSView -_subviewsIvar / -_setSubviewsIvar: (10.12+ SPI): raw accessors for the _subviews ivar, used
// by WebHTMLView's set-aside/restore dance during drawing. The ivar itself exists on 10.9's NSView;
// the SPI is only the accessor pair, with raw-assign semantics (no retain/release, no layout side
// effects) — which is exactly what object_getIvar/object_setIvar do under MRR.
@interface NSView (WKPolyfillScope)
- (NSMutableArray *)wk__subviewsIvar;
- (void)wk__setSubviewsIvar:(NSMutableArray *)subviews;
@end
@implementation NSView (WKPolyfillScope)
- (NSMutableArray *)wk__subviewsIvar
{
    Ivar ivar = class_getInstanceVariable([NSView class], "_subviews");
    return ivar ? object_getIvar(self, ivar) : nil;
}
- (void)wk__setSubviewsIvar:(NSMutableArray *)subviews
{
    Ivar ivar = class_getInstanceVariable([NSView class], "_subviews");
    if (ivar)
        object_setIvar(self, ivar, subviews);
}
@end
WK_POLYFILL_SEL("_subviewsIvar", "wk__subviewsIvar");
WK_POLYFILL_SEL("_setSubviewsIvar:", "wk__setSubviewsIvar:");

// ---------------------------------------------------------------------------------------------------
// NSTextAttachment modern accessors: -initWithData:ofType: and the image property are 10.11+ on Mac;
// -accessibilityLabel / -setAccessibilityLabel: are 10.10+ (NSTextAttachment adopts NSAccessibility
// then). 10.9 stores the same ideas elsewhere: contents live in the attachment's NSFileWrapper, and a
// displayed image lives in an NSTextAttachmentCell. The polyfills store through those, so an attachment
// built here renders identically in 10.9's own text system; the explicitly-set image object and the
// accessibility label — values 10.9 has no storage for — ride along as associated objects, so the
// getters answer exactly what was set, like the modern properties.
static char kWKTextAttachmentImageKey;
static char kWKTextAttachmentAccessibilityLabelKey;
static char kWKTextAttachmentContentsKey;
static char kWKTextAttachmentFileTypeKey;
@interface NSTextAttachment (WKPolyfillScope)
- (id)wk_initWithData:(NSData *)contentData ofType:(NSString *)uti;
- (NSData *)wk_contents;
- (void)wk_setContents:(NSData *)contents;
- (NSString *)wk_fileType;
- (void)wk_setFileType:(NSString *)fileType;
- (NSImage *)wk_image;
- (void)wk_setImage:(NSImage *)image;
- (NSString *)wk_accessibilityLabel;
- (void)wk_setAccessibilityLabel:(NSString *)label;
@end
@implementation NSTextAttachment (WKPolyfillScope)
- (id)wk_initWithData:(NSData *)contentData ofType:(NSString *)uti
{
    // Modern AppKit keeps (data, type) directly, answerable back through the contents/fileType
    // properties; 10.9 renders from a file wrapper. Store both ways: the pair as associated objects
    // (the modern properties' storage) and the data in a wrapper so 10.9's own text system draws it.
    // nil data makes an attachment with no contents yet (the caller sets an image or a wrapper after).
    NSFileWrapper *wrapper = nil;
    if (contentData) {
        wrapper = [[[NSFileWrapper alloc] initRegularFileWithContents:contentData] autorelease];
        CFStringRef extension = uti ? UTTypeCopyPreferredTagWithClass((CFStringRef)uti, kUTTagClassFilenameExtension) : NULL;
        if (extension) {
            [wrapper setPreferredFilename:[@"attachment" stringByAppendingPathExtension:(NSString *)extension]];
            CFRelease(extension);
        }
    }
    self = [self initWithFileWrapper:wrapper];
    if (self) {
        objc_setAssociatedObject(self, &kWKTextAttachmentContentsKey, contentData, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, &kWKTextAttachmentFileTypeKey, uti, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return self;
}
- (NSData *)wk_contents
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentContentsKey);
}
- (void)wk_setContents:(NSData *)contents
{
    objc_setAssociatedObject(self, &kWKTextAttachmentContentsKey, contents, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSString *)wk_fileType
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentFileTypeKey);
}
- (void)wk_setFileType:(NSString *)fileType
{
    objc_setAssociatedObject(self, &kWKTextAttachmentFileTypeKey, fileType, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSImage *)wk_image
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentImageKey);
}
- (void)wk_setImage:(NSImage *)image
{
    objc_setAssociatedObject(self, &kWKTextAttachmentImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Also store it where 10.9's text system actually draws from.
    if (image) {
        NSTextAttachmentCell *cell = [[[NSTextAttachmentCell alloc] initImageCell:image] autorelease];
        [self setAttachmentCell:cell];
    } else
        [self setAttachmentCell:nil];
}
- (NSString *)wk_accessibilityLabel
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentAccessibilityLabelKey);
}
- (void)wk_setAccessibilityLabel:(NSString *)label
{
    objc_setAssociatedObject(self, &kWKTextAttachmentAccessibilityLabelKey, label, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
@end
WK_POLYFILL_SEL("initWithData:ofType:", "wk_initWithData:ofType:");
WK_POLYFILL_SEL("contents", "wk_contents");
WK_POLYFILL_SEL("setContents:", "wk_setContents:");
WK_POLYFILL_SEL("fileType", "wk_fileType");
WK_POLYFILL_SEL("setFileType:", "wk_setFileType:");
WK_POLYFILL_SEL("image", "wk_image");
WK_POLYFILL_SEL("setImage:", "wk_setImage:");
WK_POLYFILL_SEL("accessibilityLabel", "wk_accessibilityLabel");
WK_POLYFILL_SEL("setAccessibilityLabel:", "wk_setAccessibilityLabel:");

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
- (BOOL)wk_titlebarAppearsTransparent;
- (void)wk_setTitleVisibility:(NSInteger)visibility;
@end
@implementation NSWindow (WKPolyfillScopeChrome)
- (void)wk_setTitlebarAppearsTransparent:(BOOL)flag { (void)flag; }
// The getter pairs with the no-op setter above: WebKit reads it (e.g. PageClientImpl::
// computeAutomaticTopObscuredInset) and on 10.9 the titlebar is never transparent, so answer NO. Without
// this, the call is an unrecognized selector that throws (caught by ObjC forwarding, but logged).
- (BOOL)wk_titlebarAppearsTransparent { return NO; }
- (void)wk_setTitleVisibility:(NSInteger)visibility { (void)visibility; }
@end
WK_POLYFILL_SEL("setTitlebarAppearsTransparent:", "wk_setTitlebarAppearsTransparent:");
WK_POLYFILL_SEL("titlebarAppearsTransparent", "wk_titlebarAppearsTransparent");
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
// (Do not polyfill "handleEvent:" itself: this body calls it.)
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
- (void)_saveCookies;   // 10.9 argument-less private SPI (do not polyfill it: this body calls it)
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

// ---------------------------------------------------------------------------------------------------
// Secure-coding archiver convenience API (10.11+/10.13+) built on the classic secure-coding primitives
// present since 10.8. EVERY polyfill enforces requiresSecureCoding:YES (or honors the caller's BOOL) — never
// a secure->insecure downgrade. The modern convenience methods return nil + *error on a malformed archive
// rather than raising; the classic primitives RAISE (NSInvalidUnarchiveOperationException etc.). The
// @try/@catch here is therefore REQUIRED to implement the modern non-throwing contract faithfully — it
// converts the classic exception into the nil+error the caller expects (it is not a blanket swallow: the
// callers explicitly branch on nil/error). -[NSKeyedUnarchiver initForReadingWithData:] and
// -[NSKeyedArchiver initForWritingWithMutableData:] are deprecated (hence the -Wdeprecated push above).
@interface NSKeyedUnarchiver (WKPolyfillScope)
- (instancetype)wk_initForReadingFromData:(NSData *)data error:(NSError **)error;
- (void)wk_setDecodingFailurePolicy:(NSInteger)policy;
+ (id)wk_unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error;
+ (id)wk_unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error;
@end
@implementation NSKeyedUnarchiver (WKPolyfillScope)
- (instancetype)wk_initForReadingFromData:(NSData *)data error:(NSError **)error
{
    if (error)
        *error = nil;
    @try {
        self = [self initForReadingWithData:data];
        [self setRequiresSecureCoding:YES];   // initForReadingFromData:error: defaults to secure — never downgrade
    } @catch (NSException *exception) {
        // Modern initForReadingFromData:error: is NON-throwing (returns nil + *error). The classic
        // initForReadingWithData: RAISES "incomprehensible archive" on malformed/truncated input, so it must
        // be inside the @try or an untrusted-IPC/.webarchive decode would crash instead of failing cleanly.
        // (self was consumed by the throwing initializer; releasing a half-initialized archiver is unsafe, so
        // return nil directly — the rare-error-path leak of the alloc'd shell is preferable to a crash.)
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"incomprehensible archive" }];
        return nil;
    }
    return self;
}
- (void)wk_setDecodingFailurePolicy:(NSInteger)policy
{
    // 10.9's sole decoding-failure behavior is NSDecodingFailurePolicyRaiseException — exactly what every
    // WebKit caller requests; the decode polyfills @catch that raise. Nothing to configure.
    (void)policy;
}
+ (id)wk_unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error
{
    if (error)
        *error = nil;
    NSKeyedUnarchiver *unarchiver = nil;
    id object = nil;
    @try {
        // Modern +unarchivedObjectOfClasses:fromData:error: is NON-throwing (nil + *error). Both the classic
        // initForReadingWithData: (RAISES "incomprehensible archive" on malformed/truncated input) and
        // decodeObjectOfClasses: (raises on a class/format violation) are inside the @try, or an untrusted
        // IPC/on-disk decode would crash instead of failing cleanly.
        unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:data];
        [unarchiver setRequiresSecureCoding:YES];   // secure + class-restricted, matching the modern convenience
        object = [unarchiver decodeObjectOfClasses:classes forKey:NSKeyedArchiveRootObjectKey];
    } @catch (NSException *exception) {
        object = nil;
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"decode failed" }];
    } @finally {
        [unarchiver finishDecoding];   // send-to-nil no-op if the init raised (unarchiver stays nil)
        [unarchiver release];
    }
    return object;
}
+ (id)wk_unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error
{
    return [self wk_unarchivedObjectOfClasses:(cls ? [NSSet setWithObject:cls] : nil) fromData:data error:error];
}
@end
WK_POLYFILL_SEL("initForReadingFromData:error:", "wk_initForReadingFromData:error:");
WK_POLYFILL_SEL("setDecodingFailurePolicy:", "wk_setDecodingFailurePolicy:");
WK_POLYFILL_SEL("unarchivedObjectOfClass:fromData:error:", "wk_unarchivedObjectOfClass:fromData:error:");
WK_POLYFILL_SEL("unarchivedObjectOfClasses:fromData:error:", "wk_unarchivedObjectOfClasses:fromData:error:");

static char kWKKeyedArchiverDataKey;
static char kWKKeyedArchiverFinishedKey;
@interface NSKeyedArchiver (WKPolyfillScope)
+ (NSData *)wk_archivedDataWithRootObject:(id)root requiringSecureCoding:(BOOL)requireSecure error:(NSError **)error;
- (instancetype)wk_initRequiringSecureCoding:(BOOL)requireSecure;
- (NSData *)wk_encodedData;
@end
@implementation NSKeyedArchiver (WKPolyfillScope)
// -initRequiringSecureCoding: / -encodedData (10.13+): the classic pairing is an explicit mutable
// data buffer plus finishEncoding. The buffer rides along as an associated object so encodedData can
// answer it; encodedData finishes encoding on first read, exactly the modern property's contract.
- (instancetype)wk_initRequiringSecureCoding:(BOOL)requireSecure
{
    NSMutableData *data = [NSMutableData data];
    self = [self initForWritingWithMutableData:data];
    if (self) {
        [self setRequiresSecureCoding:requireSecure];   // honor the caller's flag; never silently downgrade
        objc_setAssociatedObject(self, &kWKKeyedArchiverDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}
- (NSData *)wk_encodedData
{
    if (!objc_getAssociatedObject(self, &kWKKeyedArchiverFinishedKey)) {
        [self finishEncoding];
        objc_setAssociatedObject(self, &kWKKeyedArchiverFinishedKey, (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // nil for an archiver built through some other initializer: only the paired init above records a
    // buffer, and that pairing is the modern API's own (initRequiringSecureCoding: -> encodedData).
    return objc_getAssociatedObject(self, &kWKKeyedArchiverDataKey);
}
+ (NSData *)wk_archivedDataWithRootObject:(id)root requiringSecureCoding:(BOOL)requireSecure error:(NSError **)error
{
    if (error)
        *error = nil;
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
    [archiver setRequiresSecureCoding:requireSecure];   // honor the caller's flag; never silently downgrade
    NSData *result = nil;
    @try {
        [archiver encodeObject:root forKey:NSKeyedArchiveRootObjectKey];
        [archiver finishEncoding];
        result = data;
    } @catch (NSException *exception) {
        result = nil;
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderInvalidValueError userInfo:@{ NSLocalizedDescriptionKey: [exception reason] ?: @"archive failed" }];
    }
    [archiver release];
    return result;
}
@end
WK_POLYFILL_SEL("archivedDataWithRootObject:requiringSecureCoding:error:", "wk_archivedDataWithRootObject:requiringSecureCoding:error:");
WK_POLYFILL_SEL("initRequiringSecureCoding:", "wk_initRequiringSecureCoding:");
WK_POLYFILL_SEL("encodedData", "wk_encodedData");

// ---------------------------------------------------------------------------------------------------
// -[NSHTTPURLResponse valueForHTTPHeaderField:] (10.13+): 10.9 lacks it, but -allHeaderFields is present;
// look the field up there case-insensitively (HTTP header names are case-insensitive), matching the modern
// method's contract.
@interface NSHTTPURLResponse (WKPolyfillScope)
- (NSString *)wk_valueForHTTPHeaderField:(NSString *)field;
@end
@implementation NSHTTPURLResponse (WKPolyfillScope)
- (NSString *)wk_valueForHTTPHeaderField:(NSString *)field
{
    NSDictionary *headers = [self allHeaderFields];
    NSString *direct = [headers objectForKey:field];
    if (direct)
        return direct;
    for (NSString *key in headers)
        if ([key isKindOfClass:[NSString class]] && [key caseInsensitiveCompare:field] == NSOrderedSame)
            return [headers objectForKey:key];
    return nil;
}
@end
WK_POLYFILL_SEL("valueForHTTPHeaderField:", "wk_valueForHTTPHeaderField:");

// ---------------------------------------------------------------------------------------------------
// -[NSScrollerImp/NSMenu setUserInterfaceLayoutDirection:] + getter (10.10+/10.11+, absent on these two
// classes on 10.9). 10.9 has no RTL platform scroller/menu layout, so the value has no visual effect
// here; store it via an associated object so WebKit's own read-back
// (ScrollerMac/ScrollbarThemeMac/ScrollbarsControllerMac/PopupMenu) is faithful, defaulting to
// LeftToRight when unset. (Vertical-scrollbar-on-left is positioned by WebCore geometry independently.)
// NSScrollerImp is SPI (absent from public AppKit headers), so declare it here.
@interface NSScrollerImp : NSObject
- (CALayer *)layer;   // real 10.9 NSScrollerImp accessor (the layer WebKit assigns it via -setLayer:)
@end
static const void *const wk_uildScrollerKey = &wk_uildScrollerKey;
static const void *const wk_uildMenuKey = &wk_uildMenuKey;
@interface NSScrollerImp (WKPolyfillScope)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction;
- (NSInteger)wk_userInterfaceLayoutDirection;
// -[NSScrollerImp setNeedsDisplay:] (a later-macOS addition). On 10.9 the scroller imp WebKit uses (e.g.
// NSRegularOverlayScrollerImp) does not respond to it, so an unconditional send would raise
// doesNotRecognizeSelector (ScrollbarsControllerMac::invalidateScrollbarPartLayers and
// ScrollerMac::setNeedsDisplay both send it; the latter killed WebContent in a loop on Slack's dark
// theme). The modern method marks the imp's backing for redraw; on 10.9 the imp draws into the layer
// WebKit assigns it (-[NSScrollerImp setLayer:], present here), so marking THAT layer dirty is the
// faithful 10.9 equivalent — exactly what ScrollerMac's fallback did by hand. -layer is nil in the WK1
// path (no imp layer set), where [nil setNeedsDisplay] is a harmless no-op and the repaint comes from
// ScrollbarThemeMac::paint. (GAP_FILL: 10.9 lacks -setNeedsDisplay: on NSScrollerImp — the build gate
// confirms the absence — and the body always runs.)
- (void)wk_setNeedsDisplay:(BOOL)flag;
@end
@implementation NSScrollerImp (WKPolyfillScope)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction
{ objc_setAssociatedObject(self, wk_uildScrollerKey, @(direction), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSInteger)wk_userInterfaceLayoutDirection
{ NSNumber *v = objc_getAssociatedObject(self, wk_uildScrollerKey); return v ? [v integerValue] : NSUserInterfaceLayoutDirectionLeftToRight; }
- (void)wk_setNeedsDisplay:(BOOL)flag { if (flag) [[self layer] setNeedsDisplay]; }
@end
WK_POLYFILL_SEL("setNeedsDisplay:", "wk_setNeedsDisplay:");
@interface NSMenu (WKPolyfillScopeUILD)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction;
- (NSInteger)wk_userInterfaceLayoutDirection;
@end
@implementation NSMenu (WKPolyfillScopeUILD)
- (void)wk_setUserInterfaceLayoutDirection:(NSInteger)direction
{ objc_setAssociatedObject(self, wk_uildMenuKey, @(direction), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSInteger)wk_userInterfaceLayoutDirection
{ NSNumber *v = objc_getAssociatedObject(self, wk_uildMenuKey); return v ? [v integerValue] : NSUserInterfaceLayoutDirectionLeftToRight; }
@end
WK_POLYFILL_SEL("setUserInterfaceLayoutDirection:", "wk_setUserInterfaceLayoutDirection:");
WK_POLYFILL_SEL("userInterfaceLayoutDirection", "wk_userInterfaceLayoutDirection");

// ---------------------------------------------------------------------------------------------------
// -[NSLocale languageCode]/scriptCode/countryCode (10.12+) via the classic component keys (10.4+).
// (Do not polyfill "objectForKey:": these bodies call it.)
@interface NSLocale (WKPolyfillScope)
- (NSString *)wk_languageCode;
- (NSString *)wk_scriptCode;
- (NSString *)wk_countryCode;
@end
@implementation NSLocale (WKPolyfillScope)
- (NSString *)wk_languageCode { return [self objectForKey:NSLocaleLanguageCode]; }
- (NSString *)wk_scriptCode   { return [self objectForKey:NSLocaleScriptCode]; }
- (NSString *)wk_countryCode  { return [self objectForKey:NSLocaleCountryCode]; }
@end
WK_POLYFILL_SEL("languageCode", "wk_languageCode");
WK_POLYFILL_SEL("scriptCode", "wk_scriptCode");
WK_POLYFILL_SEL("countryCode", "wk_countryCode");

// ---------------------------------------------------------------------------------------------------
// +[NSURLProtocol _protocolClassForRequest:skipAppSSO:] (10.10+ SPI). WebCoreNSURLExtras sends it
// unconditionally to decide whether a request is claimed by a registered NSURLProtocol before it takes
// the App SSO path; on 10.9 the selector does not exist and the send throws. App SSO (the Kerberos/AAA
// extension point the flag names) does not exist on 10.9 at all, so no protocol class can be the App SSO
// one: Nil is the whole answer, and WebCoreNSURLExtras falls back to the standard URL-loading path.
//
// A plain category, not WK_POLYFILL_ADD: NSURLProtocol is a class this build's SDK and the 10.9 runtime
// agree on (both home _OBJC_CLASS_$_NSURLProtocol in Foundation — checked in MacOSX26.1.sdk's
// Foundation.tbd and in 10.9.5's Foundation export table), so there is no moved-framework classref to
// avoid, and a category is what expresses a CLASS method here: WK_POLYFILL_ADD installs through
// objc_getClass(), i.e. on the class, so it can only add INSTANCE methods.
@interface NSURLProtocol (WKPolyfillScopeAppSSO)
+ (Class)wk__protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skipAppSSO;
@end
@implementation NSURLProtocol (WKPolyfillScopeAppSSO)
+ (Class)wk__protocolClassForRequest:(NSURLRequest *)request skipAppSSO:(BOOL)skipAppSSO
{
    (void)request;
    (void)skipAppSSO;
    return Nil;
}
@end
WK_POLYFILL_SEL("_protocolClassForRequest:skipAppSSO:", "wk__protocolClassForRequest:skipAppSSO:");

// ---------------------------------------------------------------------------------------------------
// -[NSURLSessionTask priority]/-setPriority: (10.10+, absent on 10.9's NSURLSessionTask). NSURLSessionTask
// is a MOVED-FRAMEWORK class (CFNetwork on the 26.1 SDK, Foundation at 10.9 runtime), so it must be
// resolved at runtime BY NAME — hence WK_POLYFILL_ADD (runtime class_addMethod) rather than a compile-time
// category. 10.9's URL loading has no per-task scheduling priority, so the value can't affect
// scheduling; store it in an associated object so the property round-trips for its only reader (the Web
// Inspector task metrics), defaulting to NSURLSessionTaskPriorityDefault (0.5). On 10.9 the concrete task
// instances do NOT subclass the public NSURLSessionTask class — their hierarchy is
// __NSCFLocalDataTask : __NSCFLocalSessionTask : __NSCFURLSessionTask : NSObject (CFNetwork) — so the
// methods must be added to __NSCFURLSessionTask, the root of the concrete hierarchy, to reach real
// instances (adding only to NSURLSessionTask leaves them unrecognized -> NetworkProcess crash in the
// NetworkDataTaskCocoa constructor). NSURLSessionTask keeps the registration too, for the abstract class
// itself and for any OS variant whose concrete tasks do inherit from it.
static const void *const wk_taskPriorityKey = &wk_taskPriorityKey;
static float wk_urlSessionTask_priority(id self, SEL _cmd)
{
    (void)_cmd;
    NSNumber *v = objc_getAssociatedObject(self, wk_taskPriorityKey);
    return v ? [v floatValue] : 0.5f;
}
static void wk_urlSessionTask_setPriority(id self, SEL _cmd, float priority)
{
    (void)_cmd;
    objc_setAssociatedObject(self, wk_taskPriorityKey, @(priority), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
WK_POLYFILL_ADD("NSURLSessionTask", "wk_priority", wk_urlSessionTask_priority, "f@:");
WK_POLYFILL_ADD("NSURLSessionTask", "wk_setPriority:", wk_urlSessionTask_setPriority, "v@:f");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_priority", wk_urlSessionTask_priority, "f@:");
WK_POLYFILL_ADD("__NSCFURLSessionTask", "wk_setPriority:", wk_urlSessionTask_setPriority, "v@:f");
WK_POLYFILL_SEL("priority", "wk_priority");
WK_POLYFILL_SEL("setPriority:", "wk_setPriority:");

// ---------------------------------------------------------------------------------------------------
// -[CALayer presentationLayer] and the implicit CATransaction it begins.
//
// Reading presentation state is the one CALayer accessor that needs a transaction. Measured on 10.9.5
// (13F34) from a thread holding none: -bounds, -frame, -position, -transform, -masksToBounds, -mask,
// -sublayers, -animationKeys, -containsPoint:, -convertPoint:fromLayer: and -modelLayer all leave
// +[CATransaction currentState] at 0, while -presentationLayer takes it to 1 (implicit) and installs
// CA's commit observer — order 2000000, kCFRunLoopBeforeWaiting|kCFRunLoopExit, callout
// CA::Transaction::observer_callback — on the calling thread's run loop.
//
// That observer is the only thing that commits an implicit transaction, and it runs only while the
// thread is inside its run loop. On a thread that never runs one — a dispatch queue's worker, any
// thread that does its work outside a run loop — the transaction therefore stays open: measured, it is
// still pending when the block that read the layer returns, still pending inside the NEXT block the
// queue runs on that thread, and it lasts until the thread itself is destroyed, which is what
// "CoreAnimation: warning, deleted thread with uncommitted CATransaction" reports. An open transaction
// is thread-affine CA state that every later piece of work on that thread inherits.
//
// So this gives such a thread the boundary it is missing, and the boundary is the scope of the value the
// read hands back. The transaction is what attaches the snapshot to the presentation tree: measured,
// once it commits the snapshot's -superlayer is nil, and -convertPoint:fromLayer: on a detached snapshot
// answers the point unchanged rather than the converted one, which silently changes any geometry a
// caller computes through it. (Its own values survive: -position, -frame, -opacity and -transform read
// the same before and after.) Committing inside the read is therefore not available — it has to outlive the
// call that produced the snapshot, and end where the snapshot's own lifetime ends. CA autoreleases the
// snapshot, so that is the enclosing autorelease pool, and this commits from an object autoreleased
// alongside it: whatever the thread is doing, the pool it is doing it in drains, and the transaction
// goes with it. Measured on 10.9.5, that is per block on a dispatch queue fed one block at a time, once
// per burst when blocks are enqueued back to back, and at thread exit for a thread that pushes no pool
// of its own — bounded in every case, where the transaction otherwise lasts as long as the thread.
//
// Each part of the condition is observed rather than assumed:
//   - CFRunLoopCopyCurrentMode is non-NULL exactly while the thread is inside its run loop (measured
//     NULL on a dispatch worker and on a thread that has not entered its loop, non-NULL inside a
//     run-loop callout on any thread, main or not). Non-NULL means the thread is inside the run loop CA
//     put its observer on, so ending the transaction is CA's job and this leaves it to CA — including on
//     the main thread, whose observer this must not race.
//   - Only a read that finds NO transaction and leaves an implicit one has one of its own to close, so
//     one boundary is planted per transaction rather than per read, and a transaction the caller began
//     explicitly is never touched.
//   - At the boundary, an implicit transaction is what CA's own commit observer would commit and this
//     commits exactly that: everything the thread has left pending, the read's own contribution and
//     whatever the caller added to it, which is the same batch and the same order CA commits on a thread
//     that has a run loop.
@interface CATransaction (WKPolyfillTransactionState)
+ (unsigned int)currentState;   // 0 none, 1 implicit, 2 explicit — read off 10.9.5 (encoding "I16@0:8")
@end

enum { wkNoTransaction = 0, wkImplicitTransaction = 1 };

// Autoreleased into the pool the reader is running in; its dealloc is the end of that scope.
@interface WKCATransactionScopeEnd : NSObject
@end
@implementation WKCATransactionScopeEnd
- (void)dealloc
{
    if ([CATransaction currentState] == wkImplicitTransaction)
        [CATransaction flush];
    [super dealloc];
}
@end

@interface CALayer (WKPolyfillScope)
- (CALayer *)wk_presentationLayer;
// -[CALayer setCornerCurve:] (10.13+, a CACornerCurve) and -[CALayer setContentsFormat:] (10.12+, a
// CAContentsFormat NSString). 10.9's CALayer has neither. Corners on 10.9 are always the classic circular
// curve, which is exactly the value PlatformCALayerCocoa requests (kCACornerCurveCircular, supplied in
// constants.m), so honoring the curve is a no-op. The contents format selects a layer's backing pixel
// format (wide-gamut / 16-bit); 10.9's compositor has only the fixed sRGB 8-bit backing, so there is
// nothing to opt into and the set is a no-op. (Per-class GAP_FILLs: WebKit's own WebTiledBackingLayer
// -setContentsFormat:(ContentsFormat) keeps its real method via the patcher's class-correct aliasing;
// only a plain CALayer, which lacks the selector on 10.9, gets this body.)
- (void)wk_setCornerCurve:(NSString *)curve;
- (void)wk_setContentsFormat:(NSString *)format;
@end
@implementation CALayer (WKPolyfillScope)
- (void)wk_setCornerCurve:(NSString *)curve { (void)curve; }
- (void)wk_setContentsFormat:(NSString *)format { (void)format; }
- (CALayer *)wk_presentationLayer
{
    // sel_registerName rather than @selector: this file is compiled into WebCore, whose __objc_selrefs
    // are rewritten, so a compiled `presentationLayer` selref arrives here as wk_presentationLayer.
    // The assignment is idempotent — sel_registerName answers the same SEL on every thread and call.
    static SEL presentationLayerSelector;
    if (!presentationLayerSelector)
        presentationLayerSelector = sel_registerName("presentationLayer");
    CALayer *(*readPresentationLayer)(id, SEL) = (CALayer *(*)(id, SEL))objc_msgSend;

    CFStringRef modeThisThreadIsRunning = CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent());
    if (modeThisThreadIsRunning) {
        CFRelease(modeThisThreadIsRunning);
        return readPresentationLayer(self, presentationLayerSelector);
    }

    unsigned int stateBeforeRead = [CATransaction currentState];
    CALayer *presentationSnapshot = readPresentationLayer(self, presentationLayerSelector);
    if (stateBeforeRead == wkNoTransaction && [CATransaction currentState] == wkImplicitTransaction)
        [[[WKCATransactionScopeEnd alloc] init] autorelease];
    return presentationSnapshot;
}
@end
// 10.9 HAS -presentationLayer and it answers correctly; what it leaves behind is the transaction above.
WK_POLYFILL_SEL_REPLACES("presentationLayer", "wk_presentationLayer");
WK_POLYFILL_SEL("setCornerCurve:", "wk_setCornerCurve:");
WK_POLYFILL_SEL("setContentsFormat:", "wk_setContentsFormat:");

// ---------------------------------------------------------------------------------------------------
// -[NSPopover showRelativeToRect:ofView:preferredEdge:] and the anchor window's first responder.
//
// 10.9's NSPopover, as part of presenting, runs -[NSWindow _makeParentWindowHaveFirstResponder:] and
// forces the popover's content view to become the ANCHOR window's first responder. Modern NSPopover
// leaves the anchor window's responder state untouched — the contract every caller since 10.10 is
// written against. On 10.9 the forced change makes any focused control in the anchor window resign
// first responder, which drops that window's key-view focus and delivers a blur to the control. This
// polyfill restores the anchor window's first responder immediately after the popover is shown, so the
// modern no-change contract holds for any caller. The restore is synchronous within the same call, and
// the popover's own content (a label taking no key input, transient/ESC dismissal) does not depend on
// owning the anchor window's first responder.
@interface NSPopover (WKPolyfillScope)
- (void)wk_showRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView preferredEdge:(NSRectEdge)preferredEdge;
@end
@implementation NSPopover (WKPolyfillScope)
- (void)wk_showRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView preferredEdge:(NSRectEdge)preferredEdge
{
    NSWindow *window = [positioningView window];
    NSResponder *savedFirstResponder = [window firstResponder];

    // sel_registerName rather than @selector: this file is compiled into WebCore, whose __objc_selrefs
    // are rewritten, so a compiled `showRelativeToRect:ofView:preferredEdge:` selref arrives here as the
    // wk_ name and would recurse. The assignment is idempotent — sel_registerName answers the same SEL
    // on every thread and call.
    static SEL showRelativeToRectSelector;
    if (!showRelativeToRectSelector)
        showRelativeToRectSelector = sel_registerName("showRelativeToRect:ofView:preferredEdge:");
    void (*showRelativeToRect)(id, SEL, NSRect, NSView *, NSRectEdge) = (void (*)(id, SEL, NSRect, NSView *, NSRectEdge))objc_msgSend;
    showRelativeToRect(self, showRelativeToRectSelector, positioningRect, positioningView, preferredEdge);

    if (window && [window firstResponder] != savedFirstResponder)
        [window makeFirstResponder:savedFirstResponder];
}
@end
// 10.9 HAS -showRelativeToRect:ofView:preferredEdge:; it shows the popover correctly and additionally
// steals the anchor window's first responder, which is the behavior this replacement undoes.
WK_POLYFILL_SEL_REPLACES("showRelativeToRect:ofView:preferredEdge:", "wk_showRelativeToRect:ofView:preferredEdge:");

// ---------------------------------------------------------------------------------------------------
// +[CATransaction addCommitHandler:forPhase:] (10.10+, absent on 10.9's CATransaction — sending it
// throws NSInvalidArgumentException, which aborted Safari from TiledCoreAnimationDrawingAreaProxy::
// createFence and permanently wedged window-resize propagation).
//
// 10.9's CoreAnimation has NO hook inside a commit. Audited on 10.9.5 (13F34): CATransaction's whole
// method list is +begin/+commit/+flush/+synchronize/+activate/+lock/+setCompletionBlock: and friends —
// nothing phase-related — and QuartzCore exports no commit callback either; the commit itself is
// CA::Transaction::commit, an internal C++ entry point. What IS observable is WHERE that commit happens:
// it runs from CA's own run-loop observer (CA::Transaction::observer_callback,
// kCFRunLoopBeforeWaiting|kCFRunLoopExit, order 2000000 — read straight off the run loop on 10.9.5, and
// the same number upstream WebKit hardcodes as `coreAnimationCommit` in
// WebCore/platform/cf/RunLoopObserverCF.cpp). A commit therefore has a position in the run loop, and
// both sides of this polyfill are run-loop observers placed around it: the pre side one order below
// CA's, the post side one order above. Order, not the registrant's identity, is what puts each handler
// on its side of the commit.
//
// WHAT THIS GUARANTEES: a PreLayout/PreCommit handler runs at the end of the run-loop pass it is
// registered in, immediately before CA's commit observer — after everything its registrant does in that
// pass, and before the commit that carries those changes. A PostCommit handler runs once a commit has
// actually been observed to happen (see the commit-counter gate below), from an observer ordered above
// CA's. The bracket is never inverted, and neither side depends on HOW the commit is triggered: it holds
// for the run-loop drain, for an explicit [CATransaction flush] or [CATransaction commit], and for a
// commit some other framework performs.
//
// The residual differences, all in the "wider" direction:
//   - PreLayout and PreCommit run at the same point, and that point is immediately before the commit
//     rather than inside it, so neither observes the layout CA does while committing. This OS offers no
//     callout between the two, so one slot is what there is.
//   - A pre handler registered before this thread's observers can fire — the pass in which the thread's
//     first handler is registered, or a thread that never runs a run loop — runs at registration
//     instead. That is earlier than the commit, never after it (CFRunLoop collects the observers for an
//     activity ONCE, as that activity's callouts begin, so an observer created during them first fires
//     in the NEXT pass; measured on 10.9.5).
//   - A post handler on a thread that commits explicitly and then never returns to its run loop does not
//     run.
//   - A handler registered from inside another handler runs at the next commit rather than at the end of
//     the current one, which upstream CA prohibits outright.
static const CFIndex wk_coreAnimationCommitOrder = 2000000;

// THE COMMIT GATE. "After the commit" is only a bracket if a commit happened. A PostCommit handler is the
// tail of a pair whose head is some change the caller has just made and expects to be on screen; running it
// on a pass where nothing committed hands the caller a completion for work that has not happened, which is
// an inversion rather than a wider bracket. Nothing about registering a handler makes a transaction exist,
// so a pass with no commit is an ordinary case that has to be recognised, not assumed away.
//
// The signal is CA's own commit counter. 10.9's QuartzCore exports CAGetTransactionCounter(), which returns a
// process-global int that CA increments once per COMMITTED transaction. Measured on 10.9.5 (13F34): reading
// it creates no transaction; [CATransaction begin] and layer mutations leave it alone; each [CATransaction
// commit] and each [CATransaction flush] that had a transaction to flush adds one; a flush with nothing
// pending adds nothing. That is exactly "a commit happened", observed rather than predicted — which is why
// this is used in preference to probing +[CATransaction currentState] for a PENDING transaction: the counter
// also catches a commit performed explicitly during the pass, and it does not depend on where the probe sits
// relative to WebKit's own RenderingUpdate observer (which shares order 2000000-1 and is where the pending
// transaction is usually created).
//
// So each queued handler records the counter at registration, and a second per-thread observer records it
// again each time the thread WAKES (kCFRunLoopAfterWaiting). The drain observer, at CA's order + 1, runs a
// handler only when the counter has advanced past BOTH:
//   - the value at that handler's registration — the commit must have come after the handler was queued; and
//   - the value read when this thread last woke — the commit must have happened while this thread was
//     running, not while it slept.
// Everything else stays queued and is carried to the next pass. Nothing here enumerates callers.
//
// The second test is what keeps the counter's one weakness in check: it is a single QuartzCore global, not a
// per-thread count (10.9 has no per-thread one), so ANY thread's commit moves it. Commits by the other thread
// that registers handlers here — ScrollingThread, whose transactions land while the main thread is between
// passes — are therefore rejected outright. What remains is a commit on another thread landing while this
// thread happens to be awake, which opens the gate one pass early: the old unconditional behaviour for that
// one pass, not a systematic inversion.
//
// The wake reading, rather than one taken just below CA's commit observer, is what makes an EXPLICIT commit
// count: [CATransaction commit]/[CATransaction flush] happens in the middle of a pass, so a reading taken
// below CA's commit observer is already past it and the handler would sit queued until some later implicit
// commit. Both readings were built and run against this translation unit on 10.9.5: the below-CA reading
// strands a handler registered before an explicit commit, the wake reading releases it on the same pass.
// If a thread's run loop never sleeps, the wake reading simply goes stale and the gate falls back to the
// registration test alone — later than CA, never earlier.
WK_SYSTEM_FN("QuartzCore", unsigned int, CAGetTransactionCounter, (void));

static unsigned int wk_caTransactionCounter(void)
{
    return WK_SYSTEM(CAGetTransactionCounter) ? WK_SYSTEM(CAGetTransactionCounter)() : 0;
}

// The queues and their observers are per thread (CA transactions are per thread) and the observers are
// REPEATING and kept for the life of the thread. That is not an optimization: CFRunLoop collects the
// observers for an activity ONCE, when that activity's callouts begin, so an observer created from inside a
// BeforeWaiting callout does not fire until the NEXT pass (measured on 10.9.5). Handlers are routinely
// registered from exactly there — a run-loop observer one order below CA's commit is where a caller
// preparing a commit belongs — so a fresh observer per registration would run every handler a full
// run-loop cycle late. The one pass that still has no live observers is the one in which a thread's first
// handler is registered, and `observersAreLive` is what says so.
typedef struct {
    NSMutableArray *preHandlers;        // pending pre-commit blocks, in registration order
    NSMutableArray *postHandlers;       // pending PostCommit blocks, in registration order
    NSMutableArray *postRegisteredAt;   // CA commit counter when each post handler was queued, same order
    CFRunLoopObserverRef wakeObserver;  // AfterWaiting: samples the counter as the pass starts
    CFRunLoopObserverRef preObserver;   // below CA's commit observer: runs the pre handlers
    CFRunLoopObserverRef postObserver;  // above CA's commit observer: drains what a commit released
    unsigned int counterAtWake;
    bool observersAreLive;              // a pass has begun since the observers were created
} WKCommitHandlerQueue;

static pthread_key_t wk_commitHandlerQueueKey;
static pthread_once_t wk_commitHandlerQueueOnce = PTHREAD_ONCE_INIT;

static void wk_invalidateObserver(CFRunLoopObserverRef observer)
{
    if (!observer)
        return;
    CFRunLoopObserverInvalidate(observer);
    CFRelease(observer);
}

static void wk_commitHandlerQueueDestroy(void *value)
{
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)value;
    wk_invalidateObserver(queue->wakeObserver);
    wk_invalidateObserver(queue->preObserver);
    wk_invalidateObserver(queue->postObserver);
    [queue->preHandlers release];
    [queue->postHandlers release];
    [queue->postRegisteredAt release];
    free(queue);
}

static void wk_commitHandlerQueueKeyInit(void)
{
    pthread_key_create(&wk_commitHandlerQueueKey, wk_commitHandlerQueueDestroy);
}

// Runs as the thread wakes, before anything else the pass does. It records the commit count this pass
// starts from, so that the post drain can tell a commit made while this thread was running from one
// another thread made while it slept; it marks the observers live, since reaching here means a pass has
// begun with them already collected; and it re-inserts the pre observer.
//
// The re-insertion is what makes the pre observer's position independent of when it was created. CFRunLoop
// runs observers of EQUAL order in the order they were added (measured on 10.9.5), and CA's commit sits at
// the next integer up, so there is no order between the two: being last among the observers at CA's order
// minus one is the only way to run after every one of them and still before the commit. Removing and
// re-adding during AfterWaiting takes effect for this pass, because BeforeWaiting collects its observers
// later.
static void wk_beginRunLoopPass(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    queue->counterAtWake = wk_caTransactionCounter();
    queue->observersAreLive = true;
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFRunLoopRemoveObserver(runLoop, queue->preObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(runLoop, queue->preObserver, kCFRunLoopCommonModes);
}

// Immediately below CA's commit observer: everything the pass did has happened, and the commit that will
// carry it has not. Unlike the post side there is nothing to gate on — a handler that runs here runs before
// the next commit whether or not this pass has one.
static void wk_runPendingPreCommitHandlers(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    if (![queue->preHandlers count])
        return;
    // Take the batch out first: a handler that registers another one queues it for the next commit instead
    // of extending this callout (upstream CA rejects that registration outright, so no caller can be
    // relying on either behaviour).
    NSArray *batch = [queue->preHandlers copy];
    [queue->preHandlers removeAllObjects];
    @autoreleasepool {
        for (void (^handler)(void) in batch)
            handler();
    }
    [batch release];
}

static void wk_runPendingPostCommitHandlers(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
    (void)observer;
    (void)activity;
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)info;
    if (![queue->postHandlers count])
        return;
    unsigned int now = wk_caTransactionCounter();
    if (now == queue->counterAtWake)
        return; // Nothing committed while this thread ran. Carry the queue to the next pass.
    // Drain the handlers registered before that commit — the leading run of the array, since the counters
    // are recorded in registration order. Anything registered at the current value was queued after the
    // commit (a CATransaction completion block can do that) and waits for the next one.
    NSUInteger drainCount = 0, queued = [queue->postHandlers count];
    while (drainCount < queued && [[queue->postRegisteredAt objectAtIndex:drainCount] unsignedIntValue] != now)
        drainCount++;
    if (!drainCount)
        return;
    NSRange range = NSMakeRange(0, drainCount);
    NSArray *batch = [[queue->postHandlers subarrayWithRange:range] copy];
    [queue->postHandlers removeObjectsInRange:range];
    [queue->postRegisteredAt removeObjectsInRange:range];
    @autoreleasepool {
        for (void (^handler)(void) in batch)
            handler();
    }
    [batch release];
}

static WKCommitHandlerQueue *wk_commitHandlerQueueForCurrentThread(void)
{
    pthread_once(&wk_commitHandlerQueueOnce, wk_commitHandlerQueueKeyInit);
    WKCommitHandlerQueue *queue = (WKCommitHandlerQueue *)pthread_getspecific(wk_commitHandlerQueueKey);
    if (queue)
        return queue;
    queue = (WKCommitHandlerQueue *)calloc(1, sizeof(WKCommitHandlerQueue));
    queue->preHandlers = [[NSMutableArray alloc] init];
    queue->postHandlers = [[NSMutableArray alloc] init];
    queue->postRegisteredAt = [[NSMutableArray alloc] init];
    CFRunLoopObserverContext context = { 0, queue, NULL, NULL, NULL };
    // The wake sampler takes the lowest order there is, so that it reads the counter before anything else
    // the pass does. The two drain observers carry CA's own activities and sit one below and one above its
    // commit; one above is also where CA's own PostCommit handlers land relative to WebKit's
    // PostRenderingUpdate observer (2000002), so the post handler keeps running before it, as upstream.
    queue->wakeObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAfterWaiting,
                                                  true, LONG_MIN,
                                                  wk_beginRunLoopPass, &context);
    queue->preObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                 true, wk_coreAnimationCommitOrder - 1,
                                                 wk_runPendingPreCommitHandlers, &context);
    queue->postObserver = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit,
                                                  true, wk_coreAnimationCommitOrder + 1,
                                                  wk_runPendingPostCommitHandlers, &context);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->wakeObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->preObserver, kCFRunLoopCommonModes);
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), queue->postObserver, kCFRunLoopCommonModes);
    pthread_setspecific(wk_commitHandlerQueueKey, queue);
    return queue;
}

@interface CATransaction (WKPolyfillScope)
+ (void)wk_addCommitHandler:(void (^)(void))handler forPhase:(NSInteger)phase;
@end
@implementation CATransaction (WKPolyfillScope)
+ (void)wk_addCommitHandler:(void (^)(void))handler forPhase:(NSInteger)phase
{
    if (!handler)
        return;
    // kCATransactionPhasePreLayout = 0, PreCommit = 1, PostCommit = 2.
    enum { wkPostCommitPhase = 2 };
    WKCommitHandlerQueue *queue = wk_commitHandlerQueueForCurrentThread();
    // With no observer that can fire before the next commit, the last moment this thread offers that is
    // still on the pre side of that commit is now.
    if (phase != wkPostCommitPhase && !queue->observersAreLive) {
        handler();
        return;
    }
    void (^copied)(void) = [handler copy];
    if (phase == wkPostCommitPhase) {
        [queue->postHandlers addObject:copied];
        [queue->postRegisteredAt addObject:[NSNumber numberWithUnsignedInt:wk_caTransactionCounter()]];
    } else
        [queue->preHandlers addObject:copied];
    [copied release];
}
@end
WK_POLYFILL_SEL("addCommitHandler:forPhase:", "wk_addCommitHandler:forPhase:");

// -[CASpringAnimation setInitialVelocity:] (the property is public 10.11+, absent on 10.9). 10.9 ships a
// fully-functional private CASpringAnimation (mass/stiffness/damping/velocity settable + the internal
// _copyRenderAnimationForLayer:/_timeFunction: spring machinery) whose pre-10.11 name for the same
// concept is -velocity/-setVelocity:. Forward the modern setter to it (via KVC on "velocity", verified
// settable on-host) so PlatformCAAnimation*'s upstream `.initialVelocity = ...` works and those sources
// revert to pristine.
@interface CASpringAnimation (WKPolyfillScope)
- (void)wk_setInitialVelocity:(CGFloat)velocity;
@end
@implementation CASpringAnimation (WKPolyfillScope)
- (void)wk_setInitialVelocity:(CGFloat)velocity
{
    [self setValue:@(velocity) forKey:@"velocity"];
}
@end
WK_POLYFILL_SEL("setInitialVelocity:", "wk_setInitialVelocity:");

// ---------------------------------------------------------------------------------------------------
// -[NSWorkspace URLsForApplicationsToOpenURL:] (12.0+). LSCopyApplicationURLsForURL is the same query
// under its pre-12.0 name (it is what the modern method wraps), present since 10.3.
@interface NSWorkspace (WKPolyfillScopeAppURLs)
- (NSArray *)wk_URLsForApplicationsToOpenURL:(NSURL *)url;
@end
@implementation NSWorkspace (WKPolyfillScopeAppURLs)
- (NSArray *)wk_URLsForApplicationsToOpenURL:(NSURL *)url
{
    CFArrayRef urls = LSCopyApplicationURLsForURL((__bridge CFURLRef)url, kLSRolesAll);
    if (urls) return [(__bridge NSArray *)urls autorelease];
    return @[];
}
@end
WK_POLYFILL_SEL("URLsForApplicationsToOpenURL:", "wk_URLsForApplicationsToOpenURL:");

// ---------------------------------------------------------------------------------------------------
// MAVERICKS_BACKPORT (#68): +[NSLocale matchedLanguagesFromAvailableLanguages:forPreferredLanguages:] is
// 10.12+. WTF::indexOfBestMatchingLanguageInList (Source/WTF/wtf/cocoa/LanguageCocoa.mm) calls it
// UNCONDITIONALLY to pick the best caption/subtitle-track language, so on 10.9 the absent selector throws
// (unrecognized selector -> SIGILL) the instant any media element's caption menu is built
// (CaptionUserPreferencesMediaAF::sortedTrackListForMenu).
//
// We reproduce the 10.12+ contract faithfully: return the availableLanguages that GENUINELY match a
// preferred language (BCP-47 primary language subtag, canonicalized), in preference order, and an EMPTY
// array when none match. The empty-on-no-match behaviour is load-bearing: callers such as
// CaptionUserPreferencesMediaAF (matchesDefaultLanguage / sortedTrackListForMenu),
// AccessibilitySVGObject and WebExtension test `if (![matched count]) return notFound;` (or negate the
// index) and would otherwise treat a non-matching language as a match. +[NSBundle
// preferredLocalizationsFromArray:forPreferences:] (10.0+) does the same BCP-47 best-match and returns
// entries verbatim from availableLanguages, BUT it falls back to the development region (the first
// available language) when nothing matches, so its result must be filtered down to real language matches.
static NSString *wk_primaryLanguageSubtag(NSString *languageTag)
{
    if (![languageTag isKindOfClass:[NSString class]] || !languageTag.length)
        return nil;
    // Canonicalize (e.g. iw->he, EN-us->en-US) then take the primary subtag before the first "-"/"_".
    NSString *canonical = [NSLocale canonicalLanguageIdentifierFromString:languageTag];
    if (!canonical.length)
        canonical = languageTag;
    NSRange sep = [canonical rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]];
    NSString *code = (sep.location == NSNotFound) ? canonical : [canonical substringToIndex:sep.location];
    return code.lowercaseString;
}
@interface NSLocale (WKPolyfillScopeLangMatch)
+ (NSArray *)wk_matchedLanguagesFromAvailableLanguages:(NSArray *)availableLanguages forPreferredLanguages:(NSArray *)preferredLanguages;
@end
@implementation NSLocale (WKPolyfillScopeLangMatch)
+ (NSArray *)wk_matchedLanguagesFromAvailableLanguages:(NSArray *)availableLanguages forPreferredLanguages:(NSArray *)preferredLanguages
{
    NSArray *ordered = [NSBundle preferredLocalizationsFromArray:availableLanguages forPreferences:preferredLanguages];
    if (!ordered.count)
        return @[];
    NSMutableSet *preferredCodes = [NSMutableSet set];
    for (NSString *preferred in preferredLanguages) {
        NSString *code = wk_primaryLanguageSubtag(preferred);
        if (code)
            [preferredCodes addObject:code];
    }
    // Keep only entries that are (a) genuine members of availableLanguages and (b) whose primary language
    // subtag is actually among the preferred languages. (a) drops the value preferredLocalizationsFromArray:
    // echoes back when availableLanguages is empty (it returns the preferred string itself, which is NOT a
    // member); (b) drops the development-region fallback it adds on a non-empty total no-match. Together they
    // reproduce +matchedLanguagesFromAvailableLanguages:'s empty-on-no-match result and guarantee every
    // returned entry is a member of availableLanguages (WTF::indexOfBestMatchingLanguageInList relies on
    // languageList.find(firstObject) resolving).
    NSMutableArray *matched = [NSMutableArray array];
    for (NSString *available in ordered) {
        NSString *code = wk_primaryLanguageSubtag(available);
        if (code && [preferredCodes containsObject:code] && [availableLanguages containsObject:available])
            [matched addObject:available];
    }
    return matched;
}
@end
WK_POLYFILL_SEL("matchedLanguagesFromAvailableLanguages:forPreferredLanguages:", "wk_matchedLanguagesFromAvailableLanguages:forPreferredLanguages:");

#pragma clang diagnostic pop

// -[NSProgress fileOperationKind]/-fileURL and their setters (10.13+) are thin wrappers over
// userInfo keys 10.9 already defines, so implement them that way. NSProgress itself ships in 10.9;
// only these convenience accessors postdate it. WKDownloadProgress sets both when publishing a
// download's progress to the Finder.
//
// fileURL/setFileURL: are generic names -- WebKit sends them to other classes too. That is handled:
// a class that implements the real method has wk_fileURL aliased to its own IMP when its image
// loads, so only NSProgress reaches this polyfill.
@interface NSProgress (WKPolyfillScopeFileProgress)
- (void)wk_setFileOperationKind:(NSString *)kind;
- (NSString *)wk_fileOperationKind;
- (void)wk_setFileURL:(NSURL *)url;
- (NSURL *)wk_fileURL;
@end
@implementation NSProgress (WKPolyfillScopeFileProgress)
- (void)wk_setFileOperationKind:(NSString *)kind { [self setUserInfoObject:kind forKey:NSProgressFileOperationKindKey]; }
- (NSString *)wk_fileOperationKind { return [[self userInfo] objectForKey:NSProgressFileOperationKindKey]; }
- (void)wk_setFileURL:(NSURL *)url { [self setUserInfoObject:url forKey:NSProgressFileURLKey]; }
- (NSURL *)wk_fileURL { return [[self userInfo] objectForKey:NSProgressFileURLKey]; }
@end
WK_POLYFILL_SEL("setFileOperationKind:", "wk_setFileOperationKind:");
WK_POLYFILL_SEL("fileOperationKind", "wk_fileOperationKind");
WK_POLYFILL_SEL("setFileURL:", "wk_setFileURL:");
WK_POLYFILL_SEL("fileURL", "wk_fileURL");
