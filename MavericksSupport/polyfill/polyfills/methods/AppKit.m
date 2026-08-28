// AppKit: Objective-C methods on AppKit classes that macOS 10.9 does not have (or gets wrong),
// implemented with the APIs 10.9 does have.
//
// To add one: implement the method under its real name inside a WK_POLYFILL_ADD_METHODS(Class) block
// (or WK_POLYFILL_REPLACE_METHODS for a method 10.9 has). WebKit's call sites keep saying `[obj <name>]`
// and get the polyfill. That is the whole recipe.
//
// VALUES: prefer a SEMANTIC 10.9 equivalent (a real API that still exists and adapts) over a frozen
// literal. A polyfill's contract is the system API's modern behavior, so it is correct at every caller.
// Hardcoded sRGB is used only for the system tint palette (systemBlue...systemYellow) and the fill
// hierarchy, which have no 10.9 equivalent -- those constants are Apple's documented values.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <AppKit/AppKit.h>
#import <ColorSync/ColorSync.h>
#import <CoreServices/CoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
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
WK_POLYFILL_ADD_METHODS(NSGraphicsContext)
- (CGContextRef)CGContext { return (CGContextRef)[self graphicsPort]; }
+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped
{
    return [NSGraphicsContext graphicsContextWithGraphicsPort:(void *)context flipped:flipped];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSButtonCell _setState:animated:] / _setHighlighted:animated: (10.10+) animate the transition; the
// plain -setState: / -setHighlighted: 10.9 already has make it instantly. Every call site passes
// animated:NO, so the instant form is exactly what they ask for.
WK_POLYFILL_ADD_METHODS(NSButtonCell)
- (void)_setState:(NSInteger)state animated:(BOOL)animated { (void)animated; [self setState:state]; }
- (void)_setHighlighted:(BOOL)highlighted animated:(BOOL)animated { (void)animated; [self setHighlighted:highlighted]; }
// -_stateAnimationRunning (10.10+ SPI) reports the checkbox/radio state-change animation the two
// setters above would have started; on 10.9 no such animation exists, so it is never running.
// ToggleButtonMac then takes its ordinary drawCell path (its animation branch, including
// -_renderCurrentAnimationFrameInContext:atLocation:, is only reachable when this answers YES).
- (BOOL)_stateAnimationRunning { return NO; }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSControl setMaximumNumberOfLines:] (10.11+) and -[NSView sizeThatFits:] (10.10+). maximumNumberOfLines
// caps how many wrapped lines a label lays out; sizeThatFits: measures the label at a target width.
// 10.9's -sizeToFit already does the wrapped measurement, so sizeThatFits: reuses it (saving and
// restoring the frame so the measure has no side effect) and then clamps the height to the stored
// line cap. maximumNumberOfLines stores the cap on the control; 0 (the default) means no cap.
static const char kWKMaxLinesKey;
WK_POLYFILL_ADD_METHODS(NSControl)
- (void)setMaximumNumberOfLines:(NSInteger)maximumNumberOfLines
{
    objc_setAssociatedObject(self, &kWKMaxLinesKey, @(maximumNumberOfLines), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSSize)sizeThatFits:(NSSize)size
{
    NSRect saved = [self frame];
    [self setFrameSize:NSMakeSize(size.width, size.height)];
    [self sizeToFit];
    NSSize fit = [self frame].size;
    [self setFrame:saved];

    NSInteger maxLines = [objc_getAssociatedObject(self, &kWKMaxLinesKey) integerValue];
    if (maxLines > 0) {
        NSFont *font = [self font];
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

// ---------------------------------------------------------------------------------------------------
// -[NSSearchFieldCell setCenteredLook:] (10.10+). The centered look is the Yosemite rounded search
// field; 10.9's search field cell is the earlier bezeled style, which is the look setCenteredLook:NO
// selects. WebKit only ever passes NO, so this reaches 10.9's state without doing anything.
WK_POLYFILL_ADD_METHODS(NSSearchFieldCell)
- (void)setCenteredLook:(BOOL)centeredLook { (void)centeredLook; }
@end

// ---------------------------------------------------------------------------------------------------
// NSColor semantic + system palette (10.10+/10.14+). Semantic names map to the 10.9 control-text /
// selection semantics (a real color that still adapts); the systemXxx tint palette and systemFill
// hierarchy have no 10.9 equivalent, so use Apple's documented sRGB constants.
WK_POLYFILL_ADD_METHODS(NSColor)
+ (NSColor *)labelColor                              { return [NSColor controlTextColor]; }
+ (NSColor *)secondaryLabelColor                     { return [NSColor disabledControlTextColor]; }
+ (NSColor *)tertiaryLabelColor                      { return [NSColor disabledControlTextColor]; }
+ (NSColor *)quaternaryLabelColor                    { return [NSColor gridColor]; }
+ (NSColor *)quinaryLabelColor                       { return [NSColor gridColor]; }
+ (NSColor *)placeholderTextColor                    { return [NSColor disabledControlTextColor]; }
+ (NSColor *)selectedContentBackgroundColor          { return SRGB(56, 117, 215, 255); } // list-box active selection (sRGB; see note)
+ (NSColor *)unemphasizedSelectedTextColor           { return [NSColor textColor]; }
+ (NSColor *)unemphasizedSelectedContentBackgroundColor { return SRGB(220, 220, 220, 255); }
+ (NSColor *)unemphasizedSelectedTextBackgroundColor { return SRGB(220, 220, 220, 255); }
+ (NSColor *)controlAccentColor                      { return [NSColor alternateSelectedControlColor]; } // 10.9 system blue
+ (NSColor *)separatorColor                          { return [NSColor gridColor]; }
+ (NSColor *)containerBorderColor                    { return [NSColor gridColor]; }
+ (NSColor *)findHighlightColor                      { return SRGB(255, 237, 102, 255); } // real find-highlight yellow
+ (NSColor *)systemBlueColor   { return SRGB(0, 122, 255, 255); }
+ (NSColor *)systemBrownColor  { return SRGB(162, 132, 94, 255); }
+ (NSColor *)systemGrayColor   { return SRGB(142, 142, 147, 255); }
+ (NSColor *)systemGreenColor  { return SRGB(52, 199, 89, 255); }
+ (NSColor *)systemOrangeColor { return SRGB(255, 149, 0, 255); }
+ (NSColor *)systemPinkColor   { return SRGB(255, 45, 85, 255); }
+ (NSColor *)systemPurpleColor { return SRGB(175, 82, 222, 255); }
+ (NSColor *)systemRedColor    { return SRGB(255, 59, 48, 255); }
+ (NSColor *)systemYellowColor { return SRGB(255, 204, 0, 255); }
+ (NSColor *)systemFillColor          { return SRGB(0, 0, 0, 26); }
+ (NSColor *)secondarySystemFillColor { return SRGB(0, 0, 0, 20); }
+ (NSColor *)tertiarySystemFillColor  { return SRGB(0, 0, 0, 13); }
@end
// selectedTextBackgroundColor and alternateSelectedControlTextColor stay 10.9's own: both are present
// here, both convert cleanly through makeSimpleColorFromNSColor (measured: rgb(181,213,255) and
// rgb(255,255,255)), and 10.9's answer tracks the highlight colour set in System Preferences, which a
// fixed value cannot. The catalog colours whose deviceRGB conversion does return nil are the patterned
// controlColor and windowBackgroundColor, and upstream already reads those through its swatch fallback.

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

WK_POLYFILL_ADD_METHODS(NSAppearance)
// 10.14 renamed +currentAppearance (which it deprecated for the setter's sake) to +currentDrawingAppearance;
// the value is the same one -setCurrentAppearance:/-_performWithCurrentAppearance: install for the calling
// thread. 10.9 never leaves it unset, but fall back to Aqua rather than hand back nil, as 10.14+ does not.
+ (NSAppearance *)currentDrawingAppearance
{
    NSAppearance *current = [NSAppearance currentAppearance];
    return current ?: [NSAppearance appearanceNamed:NSAppearanceNameAqua];
}
- (NSColor *)tintColor { return [NSColor alternateSelectedControlColor]; } // 10.9 accent
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
- (void)_drawInRect:(NSRect)rect context:(CGContextRef)context options:(NSDictionary *)options
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
- (NSAppearanceName)bestMatchFromAppearancesWithNames:(NSArray<NSAppearanceName> *)appearances
{
    NSString *name = [self name];
    if (name && [appearances containsObject:name])
        return name;
    for (NSString *candidate in appearances) {
        if ([candidate isEqualToString:NSAppearanceNameAqua])
            return candidate;
    }
    return nil;
}
// The metrics appearance is the 11.0 large-control geometry. 10.9 has no such appearance, so NO is the
// answer, not a missing one.
- (BOOL)_usesMetricsAppearance { return NO; }
// 10.9's CoreUI has no per-appearance tint — see the divergence note above.
- (NSAppearance *)appearanceByApplyingTintColor:(NSColor *)tintColor
{
    (void)tintColor;
    return self;
}
@end

// ---------------------------------------------------------------------------------------------------
// NSWorkspace accessibility display options (10.10+), each read from the 10.9 setting behind it.
// Invert colours is CoreGraphics' display polarity, the same state the Accessibility pane's checkbox
// drives. "Enhance contrast" is that pane's slider, stored as a 0..1 number under com.apple.universalaccess.
// 10.9's Accessibility pane has no reduce-motion and no differentiate-without-colour setting, so those
// two report NO.
extern bool CGDisplayUsesInvertedPolarity(void);

WK_POLYFILL_ADD_METHODS(NSWorkspace)
- (BOOL)accessibilityDisplayShouldIncreaseContrast
{
    CFTypeRef value = CFPreferencesCopyAppValue(CFSTR("contrast"), CFSTR("com.apple.universalaccess"));
    if (!value)
        return NO;
    float contrast = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberFloatType, &contrast);
    CFRelease(value);
    return contrast > 0;
}
- (BOOL)accessibilityDisplayShouldDifferentiateWithoutColor { return NO; }
- (BOOL)accessibilityDisplayShouldReduceMotion              { return NO; }
- (BOOL)accessibilityDisplayShouldInvertColors              { return CGDisplayUsesInvertedPolarity(); }
@end
// The 10.10 workspace notification that says one of those options changed. 10.9's settings each post
// their own distributed notification instead — libUAPreferences' UAContrastDidChangeNotification and
// UADomainScreenPolarityDidChangeNotification — so an observer on those two posts the workspace name
// WebKit listens for (WebProcessPoolCocoa, RenderThemeMac, WebViewImpl), and the values above are
// re-read when the user changes them.
static void wk_accessibilityDisplayOptionDidChange(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
// The notification name is 10.10+ in the SDK and absent on the 10.9 runtime; c/AppKit.m supplies it,
// so this posts under the layer's own definition.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        postNotificationName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                      object:[NSWorkspace sharedWorkspace]];
#pragma clang diagnostic pop
}

__attribute__((constructor)) static void wk_observeAccessibilityDisplayOptions(void)
{
    CFNotificationCenterRef distributed = CFNotificationCenterGetDistributedCenter();
    if (!distributed)
        return;
    CFNotificationCenterAddObserver(distributed, NULL, wk_accessibilityDisplayOptionDidChange,
        CFSTR("com.apple.UAContrastDidChange"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(distributed, NULL, wk_accessibilityDisplayOptionDidChange,
        CFSTR("com.apple.universalaccess.screenPolarityDidChange"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

// ---------------------------------------------------------------------------------------------------
// NSScreen -canRepresentDisplayGamut: (10.11+) — whether the display covers the gamut being asked
// about. The answer is in the display's own ColorSync profile: the red, green and blue colorant tags
// every RGB display profile carries give the chromaticities of its primaries, and a gamut is covered
// when each of its primaries falls inside the triangle they span. The reference primaries below are
// the two gamuts AppKit names, as chromaticities of their D50-adapted colorants — the space ICC
// stores colorants in, so the two sides are comparable. A profile with no colorants (a table-based
// one) states no primaries, and a display whose coverage cannot be read is not claimed to cover.
enum { WKPolyfillDisplayGamutSRGB = 1, WKPolyfillDisplayGamutP3 = 2 };

static BOOL wk_readColorantChromaticity(ColorSyncProfileRef profile, CFStringRef signature, double chromaticity[2])
{
    CFDataRef tag = ColorSyncProfileCopyTag(profile, signature);
    if (!tag)
        return NO;
    // XYZType: the type signature 'XYZ ', 4 reserved bytes, then X, Y and Z as big-endian s15Fixed16.
    // Any other type states its numbers in another form and is not read as colorants.
    BOOL read = NO;
    if (CFDataGetLength(tag) >= 20 && !memcmp(CFDataGetBytePtr(tag), "XYZ ", 4)) {
        const UInt8 *bytes = CFDataGetBytePtr(tag);
        double xyz[3];
        for (int component = 0; component < 3; component++) {
            const UInt8 *field = bytes + 8 + component * 4;
            uint32_t raw = ((uint32_t)field[0] << 24) | ((uint32_t)field[1] << 16) | ((uint32_t)field[2] << 8) | field[3];
            xyz[component] = (double)(int32_t)raw / 65536.0;
        }
        double sum = xyz[0] + xyz[1] + xyz[2];
        if (sum > 0) {
            chromaticity[0] = xyz[0] / sum;
            chromaticity[1] = xyz[1] / sum;
            read = YES;
        }
    }
    CFRelease(tag);
    return read;
}

// How far outside an edge a point may sit and still count as on it. Colorants are s15Fixed16, so a
// chromaticity carries about 1/65536 of quantisation; twice that covers the division that derives it.
static const double wk_chromaticityTolerance = 2.0 / 65536.0;

static BOOL wk_chromaticityIsInsideTriangle(const double a[2], const double b[2], const double c[2], const double point[2])
{
    // A triangle with no area spans no gamut, whatever its vertices are: three colorants on one
    // line, or all three equal, describe a display that states no primaries to compare against.
    double area = fabs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) / 2;
    if (area <= wk_chromaticityTolerance)
        return NO;

    const double *vertices[3] = { a, b, c };
    int side = 0;
    for (int edge = 0; edge < 3; edge++) {
        const double *from = vertices[edge];
        const double *to = vertices[(edge + 1) % 3];
        double dx = to[0] - from[0], dy = to[1] - from[1];
        double length = sqrt(dx * dx + dy * dy);
        // A triangle with a zero-length edge spans no area and states no gamut.
        if (length <= wk_chromaticityTolerance)
            return NO;
        // Perpendicular distance from the edge, signed by which side the point is on, so the
        // tolerance means the same thing whatever the triangle's scale.
        double distance = (dx * (point[1] - from[1]) - dy * (point[0] - from[0])) / length;
        if (distance > wk_chromaticityTolerance) {
            if (side < 0)
                return NO;
            side = 1;
        } else if (distance < -wk_chromaticityTolerance) {
            if (side > 0)
                return NO;
            side = -1;
        }
    }
    return YES;
}

WK_POLYFILL_ADD_METHODS(NSScreen)
- (BOOL)canRepresentDisplayGamut:(NSDisplayGamut)gamut
{
    static const double sRGBPrimaries[3][2] = { { 0.648450, 0.330863 }, { 0.321199, 0.597841 }, { 0.155887, 0.066039 } };
    static const double displayP3Primaries[3][2] = { { 0.682051, 0.319348 }, { 0.284551, 0.674627 }, { 0.155893, 0.066059 } };

    const double (*gamutPrimaries)[2];
    if (gamut == WKPolyfillDisplayGamutSRGB)
        gamutPrimaries = sRGBPrimaries;
    else if (gamut == WKPolyfillDisplayGamutP3)
        gamutPrimaries = displayP3Primaries;
    else
        return NO;

    ColorSyncProfileRef profile = ColorSyncProfileCreateWithDisplayID(
        [[[self deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue]);
    if (!profile)
        return NO;
    double red[2], green[2], blue[2];
    BOOL haveColorants = wk_readColorantChromaticity(profile, kColorSyncSigRedColorantTag, red)
        && wk_readColorantChromaticity(profile, kColorSyncSigGreenColorantTag, green)
        && wk_readColorantChromaticity(profile, kColorSyncSigBlueColorantTag, blue);
    CFRelease(profile);
    if (!haveColorants)
        return NO;

    for (int primary = 0; primary < 3; primary++) {
        if (!wk_chromaticityIsInsideTriangle(red, green, blue, gamutPrimaries[primary]))
            return NO;
    }
    return YES;
}
@end

// ---------------------------------------------------------------------------------------------------
// NSScreen -colorSpace answers nil on 10.9 whenever the display's ColorSync profile is not an RGB one:
// the stock Black & White, Sepia Tone, Gray Tone and Blue Tone display profiles, and every Gray, CMYK,
// Lab or XYZ profile (measured on-host; CGDisplayCopyColorSpace returns NULL for the same displays).
// ColorSync still holds the profile, and CoreGraphics builds a colour space from its ICC data for each
// of those models, so the display's own profile is the answer. PlatformScreenMac's
// collectScreenProperties hands it to DestinationColorSpace, which requires a non-null CGColorSpaceRef.
WK_POLYFILL_REPLACE_METHODS(NSScreen)
- (NSColorSpace *)colorSpace
{
    NSColorSpace *colorSpace = WK_ORIGINAL_METHOD(NSColorSpace *, ());
    if (colorSpace)
        return colorSpace;

    ColorSyncProfileRef profile = ColorSyncProfileCreateWithDisplayID(
        [[[self deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue]);
    if (!profile)
        return nil;
    CFDataRef iccData = ColorSyncProfileCopyData(profile, NULL);
    CFRelease(profile);
    if (!iccData)
        return nil;
    CGColorSpaceRef displayColorSpace = CGColorSpaceCreateWithICCProfile(iccData);
    CFRelease(iccData);
    if (!displayColorSpace)
        return nil;
    NSColorSpace *fromProfile = [[NSColorSpace alloc] initWithCGColorSpace:displayColorSpace];
    CGColorSpaceRelease(displayColorSpace);
    return [fromProfile autorelease];
}
@end

// ---------------------------------------------------------------------------------------------------
// NSScrollView content insets (10.10+): -contentInsets / -setContentInsets: and
// -setAutomaticallyAdjustsContentInsets:. WebKit1's WebDynamicScrollBarsView is an NSScrollView subclass,
// and ScrollViewMac.mm both reads and writes these on it — FrameView::obscuredContentInsets(WebCoreOrPlatformInset)
// round-trips WebCore's own inset back out through platformContentInsets()/platformSetContentInsets().
// 10.9's NSScrollView has none of them: an unpolyfilled -contentInsets send is an unrecognized-selector
// throw that WebCore's BEGIN/END_BLOCK_OBJC_EXCEPTIONS discards, leaving platformVisibleContentRect /
// platformSetScrollPosition to bail out mid-computation in Mail's WebKit1 view.
//
// The getter returns exactly what the setter stored (zero by default), so WebCore's value round-trips the
// way the real property does — and the stored value is APPLIED, not just parroted back: the datalist
// suggestions dropdown (WebDataListSuggestionsDropdownMac) insets its scroll view (4,0,4,0) for the
// dropdown's vertical padding, which only exists on screen if the emulation lays it out (#115).
// Application works by re-classing the scroll view (at first non-zero set) into a dynamic subclass whose
// -tile — the one AppKit layout pass that places the clip view, rerun on every resize and scroller
// change — insets the clip view's frame by the stored insets after the standard layout. That padding is
// constant at every scroll position, where AppKit's real insets are margins beyond the content revealed
// fully only at the scroll extremes; for the few points of padding WebKit asks for, the difference is
// invisible. Only WebKit's own selrefs are rewritten to these methods, so only WebKit-configured
// scroll views ever get re-classed. The WK1 web scroll view stores zero on this port (no
// titlebar-overlapping full-size content view, no translucent overlay toolbar over web content), and a
// zero inset leaves -tile's layout untouched.
// -setAutomaticallyAdjustsContentInsets: gates AppKit's automatic titlebar-overlap adjustment, which 10.9's
// scroll view never performs; the insets above are honored explicitly regardless, so accepting and ignoring
// the flag is faithful.
//
// The application mechanism — the dynamic -tile-overriding subclass, and its KVO-coexistence contract —
// lives in scrollview-inset-tile.h, one static definition shared with its proof,
// tests/behaviour/AppKit-scrollview-insets.m, so the probe exercises the very code these methods run.
#import "scrollview-inset-tile.h"

WK_POLYFILL_ADD_METHODS(NSScrollView)
- (NSEdgeInsets)contentInsets
{
    return wkScrollViewContentInsets(self);
}
- (void)setContentInsets:(NSEdgeInsets)contentInsets
{
    wkScrollViewSetContentInsets(self, contentInsets);
}
- (void)setAutomaticallyAdjustsContentInsets:(BOOL)automaticallyAdjustsContentInsets { (void)automaticallyAdjustsContentInsets; }
@end

// ---------------------------------------------------------------------------------------------------
// NSEvent -stage (Force Touch click stage, 10.10.3+). 10.9 has no Force Touch hardware → 0. Lets the
// pressure-event code (PlatformEventFactoryMac) read event.stage unguarded.
WK_POLYFILL_ADD_METHODS(NSEvent)
- (NSInteger)stage { return 0; }
@end

// ---------------------------------------------------------------------------------------------------
// NSWindow -performWindowDragWithEvent: (10.11+). 10.9 has no native window drag from web content, so
// WebViewImpl::startWindowDrag() (Web Inspector unified toolbar, -webkit-app-region:drag) never moved
// the window. Provide the classic pre-10.11 manual drag loop: follow the mouse until mouse-up.
// -[NSWindow convertPointToScreen:] / -convertPointFromScreen: (10.12+) are the point-based renames of
// the classic -convertBaseToScreen: / -convertScreenToBase: (present, deprecated, on 10.9).
enum { WKFullSizeContentViewStyleMask = 1 << 15 };   // NSWindowStyleMaskFullSizeContentView
WK_POLYFILL_ADD_METHODS(NSWindow)
- (NSPoint)convertPointToScreen:(NSPoint)point { return [self convertBaseToScreen:point]; }
- (NSPoint)convertPointFromScreen:(NSPoint)point { return [self convertScreenToBase:point]; }
// -[NSWindow contentLayoutRect] is 10.10+: the content region NOT obscured by the title bar, in content-
// view coordinates. This layer implements full-size content for real (the adapter below), so the answer
// is not simply the content view's frame: once the content view spans the whole frame, the top strip
// under the title bar is obscured, and subtracting it is the entire reason callers ask
// (PageClientImpl::computeAutomaticTopObscuredInset derives its inset from exactly this difference).
// With the full-size bit clear, 10.9 already places the content view below the title bar, so nothing is
// obscured and the content view's own bounds are the answer.
- (NSRect)contentLayoutRect
{
    NSRect contentFrame = [[self contentView] frame];
    if (!([self styleMask] & WKFullSizeContentViewStyleMask))
        return contentFrame;

    // How much of the full-size content view the title bar covers: the difference between the window's
    // frame height and the height 10.9 would have given the content view without the full-size bit.
    CGFloat titleBarHeight = NSHeight([self frame]) - NSHeight([self contentRectForFrameRect:[self frame]]);
    if (titleBarHeight <= 0 || titleBarHeight >= NSHeight(contentFrame))
        return contentFrame;

    // Content view coordinates are bottom-left origin, so the obscured strip comes off the top.
    contentFrame.size.height -= titleBarHeight;
    return contentFrame;
}
- (void)performWindowDragWithEvent:(NSEvent *)event
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

// ---------------------------------------------------------------------------------------------------
// NSView -_subviewsIvar / -_setSubviewsIvar: (10.12+ SPI): raw accessors for the _subviews ivar, used
// by WebHTMLView's set-aside/restore dance during drawing. The ivar itself exists on 10.9's NSView;
// the SPI is only the accessor pair, with raw-assign semantics (no retain/release, no layout side
// effects) — which is exactly what object_getIvar/object_setIvar do under MRR.
WK_POLYFILL_ADD_METHODS(NSView)
- (NSMutableArray *)_subviewsIvar
{
    Ivar ivar = class_getInstanceVariable([NSView class], "_subviews");
    return ivar ? object_getIvar(self, ivar) : nil;
}
- (void)_setSubviewsIvar:(NSMutableArray *)subviews
{
    Ivar ivar = class_getInstanceVariable([NSView class], "_subviews");
    if (ivar)
        object_setIvar(self, ivar, subviews);
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSView addGestureRecognizer:] / -removeGestureRecognizer: / -gestureRecognizers (10.10+): the
// NSGestureRecognizer system does not exist on 10.9, so a view can never have a recognizer attached.
// WebViewImpl's only recognizer is the immediate-action one, whose class resolves via NSClassFromString
// to nil here — but setAllowsLinkPreview(false) and setIgnoresNonWheelEvents(true) send
// removeGestureRecognizer: UNCONDITIONALLY (WebViewImpl.mm:3818, 3876), nil argument or not, which is
// an unrecognized selector on 10.9. With no recognizer system there is never anything to add, remove,
// or list: add/remove are faithful no-ops and the list is empty.
WK_POLYFILL_ADD_METHODS(NSView)
- (void)addGestureRecognizer:(NSGestureRecognizer *)gestureRecognizer { (void)gestureRecognizer; }
- (void)removeGestureRecognizer:(NSGestureRecognizer *)gestureRecognizer { (void)gestureRecognizer; }
- (NSArray<NSGestureRecognizer *> *)gestureRecognizers { return [NSArray array]; }
@end

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
WK_POLYFILL_ADD_METHODS(NSTextAttachment)
- (instancetype)initWithData:(NSData *)contentData ofType:(NSString *)uti
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
- (NSData *)contents
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentContentsKey);
}
- (void)setContents:(NSData *)contents
{
    objc_setAssociatedObject(self, &kWKTextAttachmentContentsKey, contents, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSString *)fileType
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentFileTypeKey);
}
- (void)setFileType:(NSString *)fileType
{
    objc_setAssociatedObject(self, &kWKTextAttachmentFileTypeKey, fileType, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSImage *)image
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentImageKey);
}
- (void)setImage:(NSImage *)image
{
    objc_setAssociatedObject(self, &kWKTextAttachmentImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Also store it where 10.9's text system actually draws from.
    if (image) {
        NSTextAttachmentCell *cell = [[[NSTextAttachmentCell alloc] initImageCell:image] autorelease];
        [self setAttachmentCell:cell];
    } else
        [self setAttachmentCell:nil];
}
- (NSString *)accessibilityLabel
{
    return objc_getAssociatedObject(self, &kWKTextAttachmentAccessibilityLabelKey);
}
- (void)setAccessibilityLabel:(NSString *)label
{
    objc_setAssociatedObject(self, &kWKTextAttachmentAccessibilityLabelKey, label, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
@end

// ---------------------------------------------------------------------------------------------------
// +[NSMenu menuTypeForEvent:] (10.10+): classify a mouse event into a menu type. On 10.9, reproduce the
// documented mapping — right-click or control+left-click opens a context menu, otherwise none.
// NSMenuType is not in the public AppKit headers (WebKit declares it in pal/spi/mac/NSMenuSPI.h); this
// polyfill lives outside WebKit's include paths, so forward-declare the enum to match.
typedef NS_ENUM(NSInteger, NSMenuType) {
    NSMenuTypeNone = 0,
    NSMenuTypeContextMenu = 1,
};
WK_POLYFILL_ADD_METHODS(NSMenu)
+ (NSMenuType)menuTypeForEvent:(NSEvent *)event
{
    if (event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeRightMouseUp)
        return NSMenuTypeContextMenu;
    if ((event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp)
        && (event.modifierFlags & NSEventModifierFlagControl))
        return NSMenuTypeContextMenu;
    return NSMenuTypeNone;
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSPasteboard _setExpirationDate:] (11.0+ private SPI): auto-clears ephemeral pasteboard data after a
// delay. 10.9 has no such pasteboard-server mechanism, so the faithful 10.9 behavior is a no-op (the data
// simply persists, exactly as when the guard skipped the call).
WK_POLYFILL_ADD_METHODS(NSPasteboard)
- (void)_setExpirationDate:(NSDate *)date { (void)date; }
@end

// ---------------------------------------------------------------------------------------------------
// +[NSLayoutConstraint activateConstraints:] / +deactivateConstraints: and -isActive (all 10.10+).
//
// 10.10 replaced "add this constraint to the right view" with "activate it, and let AppKit work out
// which view that is". The rule it uses is public and unchanged: a constraint is installed on the
// NEAREST COMMON ANCESTOR of its two items — or, for a constraint with only a first item (a width or
// height on a single view), on that view itself. 10.9 has the installation half of that API,
// -[NSView addConstraint:]/-removeConstraint:; what it lacks is the ancestor computation and the
// activate/deactivate spelling. So this is a real implementation of the 10.10 behavior in terms of
// 10.9's own constraint machinery, not a stand-in: any caller gets the constraint installed where
// 10.10 would have installed it.
//
// This matters beyond tidiness: -removeFromSuperview destroys every constraint referencing the view,
// so WebKit's full-screen paths save a view's constraints and re-activate them on the way back
// (WKFullScreenWindowController's _saveConstraintsOf: / activateConstraints:). Without the polyfill
// that call raised "unrecognized selector sent to class" inside WebKit's BEGIN/END_BLOCK_OBJC_EXCEPTIONS,
// which swallowed it — so the restore silently did nothing and a constraint-driven host (Mail's
// autolayout-driven MUIWKView is one) got its web view back unconstrained.
// The view a constraint belongs on, by 10.10's rule.
static NSView *wk_constraintHostView(NSLayoutConstraint *constraint)
{
    id first = [constraint firstItem];
    id second = [constraint secondItem];
    if (![first isKindOfClass:[NSView class]])
        return nil;
    NSView *firstView = (NSView *)first;
    if (!second)
        return firstView;
    if (![second isKindOfClass:[NSView class]])
        return firstView;
    return [firstView ancestorSharedWithView:(NSView *)second];
}

WK_POLYFILL_ADD_METHODS(NSLayoutConstraint)

+ (void)activateConstraints:(NSArray<NSLayoutConstraint *> *)constraints
{
    for (NSLayoutConstraint *constraint in constraints) {
        NSView *host = wk_constraintHostView(constraint);
        if (!host) {
            // What real AppKit does with this input, rather than dropping the constraint and saying
            // nothing -- a silent no-op here is the same failure mode that made the absent
            // +activateConstraints: so hard to see in the first place.
            [NSException raise:NSInvalidArgumentException
                        format:@"Unable to activate constraint with items %@ and %@ because they have no common ancestor.",
                               [constraint firstItem], [constraint secondItem]];
            return;
        }
        if (![[host constraints] containsObject:constraint])
            [host addConstraint:constraint];
    }
}

+ (void)deactivateConstraints:(NSArray<NSLayoutConstraint *> *)constraints
{
    for (NSLayoutConstraint *constraint in constraints) {
        // Deactivation must find the constraint wherever it was installed, which is not necessarily
        // where the ancestor rule would put it today (the view tree may have changed since).
        NSView *host = wk_constraintHostView(constraint);
        if (host && [[host constraints] containsObject:constraint]) {
            [host removeConstraint:constraint];
            continue;
        }
        // host is nil exactly when firstItem is not an NSView, so there is nothing to walk from and
        // nothing to remove the constraint from -- casting it to NSView and messaging it would be an
        // unrecognized selector in the polyfill itself.
        if (!host)
            continue;
        for (NSView *view = host; view; view = [view superview]) {
            if ([[view constraints] containsObject:constraint]) {
                [view removeConstraint:constraint];
                break;
            }
        }
    }
}

- (BOOL)isActive
{
    NSView *host = wk_constraintHostView(self);
    for (NSView *view = host; view; view = [view superview]) {
        if ([[view constraints] containsObject:self])
            return YES;
    }
    return NO;
}

- (void)setActive:(BOOL)active
{
    NSArray *one = [NSArray arrayWithObject:self];
    // Both class methods are 10.10+ and absent on the 10.9 runtime; the NSLayoutConstraint block above
    // supplies them.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    if (active)
        [NSLayoutConstraint activateConstraints:one];
    else
        [NSLayoutConstraint deactivateConstraints:one];
#pragma clang diagnostic pop
}

@end

// NOT polyfilled: +[NSCursor hideUntilChanged] (10.13+). Its contract is "hidden until the app-global
// cursor SHAPE next changes", which survives pointer motion. 10.9's nearest call,
// +setHiddenUntilMouseMoves:, un-hides on the next mouse MOVE instead -- a different API. Mapping one to
// the other would hide the pointer for `cursor: none` until the user moved it and then never again,
// because WebKit's call sites bail early when the cursor already matches and so never re-set it. Both
// call sites are upstream's own respondsToSelector: guards with upstream's own fallback (a transparent
// cursor image), so leaving this unpolyfilled is upstream behaviour rather than a gap.

// ---------------------------------------------------------------------------------------------------
// Post-10.9 side-effect-only SPIs with no 10.9 equivalent -- faithful no-ops. NSApplication
// +_preventDockConnections (10.10) / -_setAccentColor: (10.14), NSWindow -setTitlebarAppearsTransparent:
// (10.10) / -setTitleVisibility: (10.10) -- 10.9 has no dock-connection control, no window accent, no
// transparent titlebar, and the window title is always shown.

// -[NSWindow setTitlebarAlphaValue:] (10.14+) fades a window's title bar out and back in.
// -setTitlebarAppearsTransparent: above already implements "the title bar does not paint, content runs
// underneath" for 10.9, via the full-size-content adapter; an alpha of 0 asks for exactly that, so it
// routes to the same adapter rather than to a second mechanism. A non-zero alpha asks for the ordinary
// title bar back, which is the adapter's absence. 10.9 cannot render the intermediate alphas an
// animation would step through, so those round to "visible" -- the endpoints are what callers depend on.
//
// (The value is also stored and returned, so a caller that reads back what it set gets it, and so the
// getter does not have to lie.)
static const char wkTitlebarAlphaValueKey;
static const char wkTitlebarChromeHiddenStateKey;   // each button's own isHidden, captured at alpha 0

WK_POLYFILL_ADD_METHODS(NSWindow)

- (void)setTitlebarAlphaValue:(CGFloat)alpha
{
    objc_setAssociatedObject(self, (const void *)&wkTitlebarAlphaValueKey,
                             [NSNumber numberWithDouble:(double)alpha], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // DRAWING only -- never the content view's geometry, which follows
    // NSWindowStyleMaskFullSizeContentView (see wk_installFullSizeContentAdapterIfNeeded). 10.9's
    // NSThemeFrame has no title-bar alpha channel to vary continuously, but it does have the chrome the
    // property makes invisible at 0 and visible above it, and that chrome is separately addressable
    // here. So the ENDPOINTS are implemented -- which is what callers depend on: WebKit hides the title
    // bar for the duration of the full-screen transition and shows it afterwards. Intermediate alphas an
    // animation would step through round to "visible", the closest 10.9 can render.
    //
    // Restoring means putting back WHAT WAS THERE, not asserting "visible": a window is free to hide
    // its own traffic lights, and unhiding those at alpha 1 would be this polyfill inventing state the
    // caller never asked for. Each button's own isHidden is captured at the transition INTO alpha 0 and
    // replayed at the transition back out; the saved record is what marks the window as hidden-by-this-
    // polyfill, so repeated 0 -> 0 cannot overwrite it with the state it just imposed, repeated 1 -> 1
    // is a no-op, and a window this polyfill never hid is never touched.
    BOOL chromeHidden = (alpha <= 0);
    NSWindowButton buttons[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton,
                                 NSWindowFullScreenButton, NSWindowDocumentIconButton };
    size_t buttonCount = sizeof(buttons) / sizeof(buttons[0]);
    NSArray *saved = objc_getAssociatedObject(self, (const void *)&wkTitlebarChromeHiddenStateKey);

    if (chromeHidden) {
        if (saved)
            return;   // already hidden by this polyfill; the record is the caller's state, keep it
        NSMutableArray *record = [NSMutableArray arrayWithCapacity:buttonCount];
        for (size_t i = 0; i < buttonCount; i++) {
            NSButton *button = [self standardWindowButton:buttons[i]];
            [record addObject:[NSNumber numberWithBool:button ? [button isHidden] : NO]];
        }
        objc_setAssociatedObject(self, (const void *)&wkTitlebarChromeHiddenStateKey, record,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (size_t i = 0; i < buttonCount; i++)
            [[self standardWindowButton:buttons[i]] setHidden:YES];
        return;
    }

    if (!saved)
        return;   // this polyfill never hid this window's chrome, so it has nothing to restore
    for (size_t i = 0; i < buttonCount && i < [saved count]; i++)
        [[self standardWindowButton:buttons[i]] setHidden:[[saved objectAtIndex:i] boolValue]];
    objc_setAssociatedObject(self, (const void *)&wkTitlebarChromeHiddenStateKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)titlebarAlphaValue
{
    NSNumber *stored = objc_getAssociatedObject(self, (const void *)&wkTitlebarAlphaValueKey);
    return stored ? (CGFloat)[stored doubleValue] : 1;
}

@end
WK_POLYFILL_ADD_METHODS(NSApplication)
+ (void)_preventDockConnections { }
// +_accessibilityInitialize (10.13+) forces AppKit to stand its accessibility server up EARLY, rather
// than waiting for the first AX client to connect. WebKit's WebContent process calls it so an AX client
// finds a live tree the moment it asks. 10.9's AppKit has no such entry point (absent from this host's
// AppKit; calling it raised "unrecognized selector sent to class" and took the WebContent process down
// with SIGILL), so this supplies the same effect through the path 10.9 actually uses.
//
// That path was read out of this host's AppKit rather than guessed. -[NSApplication finishLaunching]
// contains the ONLY call to the local function _NSAccessibilityInit, and _NSAccessibilityInit contains
// the only call to _AXUIElementRegisterServerWithRunLoop (HIServices) — which is what registers the
// process's accessibility server with the run loop. Nothing else in AppKit reaches it. In particular
// +sharedApplication does NOT: merely allocating the NSApplication leaves the process with no AX server,
// which is why a remote element built from such a process answers kAXErrorCannotComplete no matter how
// correctly the UI side is wired.
//
// So "initialize accessibility now" on 10.9 is: make sure there is an NSApplication, then finish
// launching it -- but only in a process that has not launched one already. -finishLaunching registers
// the required Apple Event handlers, posts NSApplicationWillFinishLaunching/DidFinishLaunching, and
// runs the document-reopening path; it is written to be called once, by -run. In a HOST process whose
// application is already up (Safari, Mail, iBooks all load WebKit), sending it again would re-run all
// of that behind the host's back -- and the AX server it exists to register is already registered
// there, so there is nothing to gain either. -[NSApplication isRunning] (present on 10.9) is the
// system's own answer to "has this application launched", which is the state that actually matters;
// the static is the second half of the same guard, for the never-launched process this is FOR, where
// isRunning stays NO because nothing ever calls -run. (isRunning turns YES inside -run, just after it
// sends -finishLaunching, so it does not cover a host that is mid-launch at this instant. Nothing can
// be mid-launch here: WebKit's two callers -- WebProcess::platformInitializeWebProcess and
// WebPage::platformInitialize -- both run in the WebContent process, off an IPC message from a UI
// process that has long since launched.)
+ (void)_accessibilityInitialize
{
    static BOOL didFinishLaunching = NO;
    NSApplication *app = [NSApplication sharedApplication];
    if (didFinishLaunching || [app isRunning])
        return;
    didFinishLaunching = YES;
    [app finishLaunching];
}
- (void)_setAccentColor:(NSColor *)color { (void)color; }
@end

// NSWindowStyleMaskFullSizeContentView + -setTitlebarAppearsTransparent: (both 10.10+), implemented for
// real rather than stubbed.
//
// The 10.10 behaviour is: the content view is laid out over the FULL window frame, extending up behind the
// titlebar, and the titlebar stops drawing its own background so the content shows through. 10.9 ignores
// the style-mask bit and lacks the setter, so a window asking for it gets an ordinary titled window with
// its content pushed below the titlebar.
//
// Measured on this host, which rules out the easy implementations:
//   * overriding -contentRectForFrameRect: (and the class version) does NOT move the content view --
//     it stays 400pt tall inside a 422pt frame view; and
//   * placing the content view over the frame view by hand DOES work, but NSThemeFrame re-lays-it-out on
//     the very next resize (600x422 full-size -> 800x578 back under the titlebar).
// So the behaviour is reproducible only by placing the content view AND re-placing it whenever the window
// resizes. That is what the adapter below does, keeping the standard window buttons above the content view
// so the traffic lights stay visible and clickable, exactly as they float over a full-size content view on
// 10.10+.
//
// Trigger: the style mask's full-size-content bit, and nothing else -- see the hooks below. Not
// -setTitlebarAppearsTransparent:, which is a separate property AppKit lets a caller set independently
// (WebKit itself reads the two independently in PageClientImpl::computeAutomaticTopObscuredInset).
static const char wkTitlebarAppearsTransparentKey;
static const char wkFullSizeContentAdapterKey;

@interface WKPolyfillFullSizeContentAdapter : NSObject {
    NSWindow *_window;   // unretained: the window owns this adapter through an associated object
    BOOL _didEnableContentViewLayer;   // so -unapply only undoes layer-backing this adapter turned on
    NSView *_adaptedContentView;       // unretained: compared by pointer to spot a content-view swap
}
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)apply;
- (void)unapply;
- (void)contentViewDidChangeIfNeeded;
@end

@implementation WKPolyfillFullSizeContentAdapter

- (instancetype)initWithWindow:(NSWindow *)window
{
    if (!(self = [super init]))
        return nil;
    _window = window;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(wkWindowDidResize:)
                                                 name:NSWindowDidResizeNotification object:window];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)apply
{
    NSView *contentView = [_window contentView];
    NSView *frameView = [contentView superview];
    if (!contentView || !frameView)
        return;

    _adaptedContentView = contentView;
    [contentView setFrame:[frameView bounds]];

    // The traffic lights are siblings of the content view inside the frame view. A full-size content view
    // covers the whole frame, so without this they would be painted over.
    //
    // Reorder with remove + append, NOT -addSubview:positioned:relativeTo:. 10.9's move path for an
    // already-parented view computes the insertion index and mutates the subviews array inside one call;
    // when NSThemeFrame's own button management mutates that array mid-call (seen on real hardware opening
    // the Web Inspector), the insert lands out of bounds and throws NSRangeException. That throw happens
    // after the button has been pulled out of the array but before -removeFromSuperview bookkeeping, so it
    // strands the button with a dangling _window; the exception then unwinds window creation, the window is
    // freed, and the button's later dealloc messages the freed window (crash in -[NSControl currentEditor]
    // under fieldEditor:forObject:). Two separate whole calls each keep AppKit's invariants and cannot
    // leave a stale index. Appending puts the button after the content view in the subview order, which is
    // exactly the "drawn above the full-size content view" placement being restored.
    NSWindowButton buttons[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton,
                                 NSWindowFullScreenButton };
    BOOL raisedAnyButton = NO;
    for (size_t i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++) {
        NSButton *button = [_window standardWindowButton:buttons[i]];
        if (!button || [button superview] != frameView)
            continue;
        [[button retain] autorelease];   // keep the button alive across its removal
        [button removeFromSuperview];
        [frameView addSubview:button];
        raisedAnyButton = YES;
    }

    // On 10.9 a layer-backed subview (the Web Inspector's frontend web view is one) is a standalone
    // layer ISLAND whose surface composites above every non-layer view in the window regardless of
    // subview order, so the buttons raised above are covered anyway, and the island's square-edged
    // surface paints over NSThemeFrame's rounded titlebar corners. Layer-backing the content view makes
    // AppKit promote the overlapping frame-view subviews (the buttons) into one layer tree with it, so
    // subview z-order holds and transparent content corners reveal the native rounded corners — which is
    // how a full-size content view composites on 10.10+. Verified load-bearing by live view-tree dump
    // (buttons present but covered without it); scoped to windows with raised buttons so buttonless
    // full-size-content windows (e.g. the datalist dropdown) keep non-layer-backed text rendering.
    if (raisedAnyButton && ![contentView wantsLayer]) {
        [contentView setWantsLayer:YES];
        _didEnableContentViewLayer = YES;
    }
}

- (void)wkWindowDidResize:(NSNotification *)notification
{
    (void)notification;
    [self apply];   // NSThemeFrame has just re-laid-out the content view under the titlebar; undo that
}

// If the window swapped its content view out from under us, the layer-backing this adapter turned on
// belonged to the old view (going away with its own layer), so stop tracking it and give the new view
// the full-size treatment the style mask asks for. Cheap enough to ask on every window update: it is a
// pointer comparison until something actually changes.
- (void)contentViewDidChangeIfNeeded
{
    NSView *current = [_window contentView];
    if (current == _adaptedContentView)
        return;
    _adaptedContentView = current;
    _didEnableContentViewLayer = NO;
    [self apply];
}

// Put the window back the way 10.9 would have it for a window that turns full-size content back off:
// content view below the title bar, and the two things -apply changed to keep the traffic lights visible
// over a full-size content view undone as well. Stopping at "stop re-applying" would leave the last
// full-size layout in place until something else resized the window, so the caller would see the bit
// ignored; stopping at geometry would leave the buttons re-ordered and the content view layer-backed for
// a window that no longer has any reason to be either.
- (void)unapply
{
    NSView *contentView = [_window contentView];
    if (!contentView)
        return;

    NSSize contentSize = [_window contentRectForFrameRect:[_window frame]].size;
    [contentView setFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];

    // -apply moved the standard window buttons to the end of the frame view's subviews so they painted
    // above the full-size content view. With the content view back under the title bar they no longer
    // overlap it, and NSThemeFrame re-places them itself on the next layout, so putting them back at the
    // front of the list restores the order it maintains. (Remove + append/insert as whole calls, for the
    // NSRangeException reason -apply documents.)
    NSView *frameView = [contentView superview];
    NSWindowButton buttons[] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton,
                                 NSWindowFullScreenButton };
    for (size_t i = 0; i < sizeof(buttons) / sizeof(buttons[0]); i++) {
        NSButton *button = [_window standardWindowButton:buttons[i]];
        if (!button || !frameView || [button superview] != frameView)
            continue;
        [[button retain] autorelease];
        [button removeFromSuperview];
        [frameView addSubview:button positioned:NSWindowBelow relativeTo:contentView];
    }

    if (_didEnableContentViewLayer && [contentView wantsLayer]) {
        [contentView setWantsLayer:NO];
        _didEnableContentViewLayer = NO;
    }
}

@end

WK_POLYFILL_ADD_METHODS(NSWindow)

// Records the property. It does NOT move the content view: whether the content view spans the full
// frame follows NSWindowStyleMaskFullSizeContentView alone (see wk_installFullSizeContentAdapterIfNeeded
// and the style-mask hooks), which is what AppKit documents -- "If set, the contentView will consume the
// full size of the window" is a property of the STYLE MASK. titlebarAppearsTransparent only stops the
// title bar drawing its own background. Tying geometry to this setter made the two inseparable and was
// wrong for any caller that sets one without the other; WebKit itself has such a call site
// (PageClientImpl::computeAutomaticTopObscuredInset tests the mask and this property independently).
- (void)setTitlebarAppearsTransparent:(BOOL)flag
{
    objc_setAssociatedObject(self, (const void *)&wkTitlebarAppearsTransparentKey,
                             flag ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Reports what the setter stored, rather than a fixed NO that would contradict its own setter: a
// caller that set the property and read it back was told its request had been ignored. WebKit reads it
// (PageClientImpl::computeAutomaticTopObscuredInset), independently of the style mask.
- (BOOL)titlebarAppearsTransparent
{
    return objc_getAssociatedObject(self, (const void *)&wkTitlebarAppearsTransparentKey) != nil;
}

// -setTitleVisibility: (10.10+) hides the title STRING while keeping the titlebar. 10.9 draws the title
// as part of NSThemeFrame's titlebar with no separate control over it.
- (void)setTitleVisibility:(NSWindowTitleVisibility)visibility { (void)visibility; }

@end

// The full-size-content layout follows the STYLE MASK, which is where AppKit puts it: "If set, the
// contentView will consume the full size of the window" (NSWindow.h, NSWindowStyleMaskFullSizeContentView).
// Nothing else -- not -setTitlebarAppearsTransparent:, not the title bar's alpha -- decides it.
//
// The trigger is the three places the answer can change: the window is BORN with the bit, the bit is
// set or cleared later, or the content view is swapped (WKDataListSuggestionWindow swaps its own right
// after construction). Hooking construction is what makes the layout right the FIRST time a caller
// measures the window — before it is ordered in, which is when WebKit reads its size to tell the web
// content how big the viewport is.
//
// These are REPLACE bodies, and they reach every NSWindow SUBCLASS: wk_alias_class does not alias a
// class's own IMP over a REPLACE body already in its chain, so NSPanel/NSSavePanel/_NSPopoverWindow/
// NSCarbonWindow — all of which implement these selectors themselves on 10.9 — run the body, which then
// calls through via WK_ORIGINAL_METHOD, landing on that subclass's own implementation.
@interface NSWindow (WKPolyfillFullSizeContent)
- (void)wk_installFullSizeContentAdapterIfNeeded;
@end

@implementation NSWindow (WKPolyfillFullSizeContent)

- (void)wk_installFullSizeContentAdapterIfNeeded
{
    BOOL wantsFullSize = ([self styleMask] & WKFullSizeContentViewStyleMask) != 0;
    WKPolyfillFullSizeContentAdapter *installed = objc_getAssociatedObject(self, (const void *)&wkFullSizeContentAdapterKey);

    if (wantsFullSize && !installed) {
        WKPolyfillFullSizeContentAdapter *adapter = [[[WKPolyfillFullSizeContentAdapter alloc] initWithWindow:self] autorelease];
        objc_setAssociatedObject(self, (const void *)&wkFullSizeContentAdapterKey, adapter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [adapter apply];
        return;
    }

    if (!wantsFullSize && installed) {
        // -unapply FIRST. OBJC_ASSOCIATION_RETAIN_NONATOMIC releases synchronously and does not
        // autorelease, so clearing the association is what deallocates the adapter -- messaging it
        // afterwards is a use-after-free (the association holds the only reference).
        [installed unapply];
        objc_setAssociatedObject(self, (const void *)&wkFullSizeContentAdapterKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (wantsFullSize && installed)
        [installed contentViewDidChangeIfNeeded];
}

@end

// Calling through, for a REPLACE body that wins on subclasses. The public selector is never touched by
// the selref rewrite (nothing is ever installed under it), so the real implementations are all reachable
// by name; the only question is WHICH one this body stands in for, and there are two answers:
//
//   * This body is the receiver's own entry point -- a system subclass such as NSPanel, NSSavePanel,
//     _NSPopoverWindow or NSCarbonWindow, which wk_alias_class deliberately leaves un-aliased so the
//     polyfill is not shadowed. Standing in for the RECEIVER's real method, so call that.
//   * The receiver's class resolves the private selector to something else -- its own aliased
//     implementation. That happens only for a class from a WEBKIT image (wk_alias_class keeps those
//     aliased), so its override is the entry point and we are here because that override said
//     [super ...], which the rewrite turned into a private-selector super-send. Standing in for what
//     super means there: NSWindow's own implementation. Dispatching the public selector instead would
//     land back on the override and recurse forever -- WebCoreFullScreenWindow and
//     WKDataListSuggestionWindow both call super.
//
// Which implementation each stands in for comes from WK_ORIGINAL_METHOD (see wk_original_of in the
// mechanism): the answer is derived from the BODY's class, not the receiver's, so it stays right when
// an aliased override sits several levels below the receiver.
WK_POLYFILL_REPLACE_METHODS(NSWindow)

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backingStoreType defer:(BOOL)flag
{
    id window = WK_ORIGINAL_METHOD(id, (NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL),
                                   contentRect, style, backingStoreType, flag);
    // A failed initializer has already released the receiver, and returns nil; nothing to adapt.
    [window wk_installFullSizeContentAdapterIfNeeded];
    return window;
}

- (void)setStyleMask:(NSWindowStyleMask)styleMask
{
    WK_ORIGINAL_METHOD(void, (NSWindowStyleMask), styleMask);
    [self wk_installFullSizeContentAdapterIfNeeded];   // the bit may have just been set OR cleared
}

- (void)setContentView:(NSView *)view
{
    WK_ORIGINAL_METHOD(void, (NSView *), view);
    [self wk_installFullSizeContentAdapterIfNeeded];   // notices the swap and adapts the new view
}

@end

// ---------------------------------------------------------------------------------------------------
// -[NSColorWell setSupportsAlpha:] (14.0+): 10.9 honors alpha through the shared color panel's alpha slider
// (NSPopoverColorWell, the receiver, is backed by +[NSColorPanel sharedColorPanel]).
WK_POLYFILL_ADD_METHODS(NSColorWell)
- (void)setSupportsAlpha:(BOOL)flag { [[NSColorPanel sharedColorPanel] setShowsAlpha:flag]; }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSApplication _effectiveAccentColor] (10.14+ SPI): the default macOS accent/control-tint blue. Must be an
// EXPLICIT sRGB color, NOT a catalog color like alternateSelectedControlColor: PageClientImpl::accentColor()
// feeds this through colorFromCocoaColor() -> [color colorUsingColorSpace:], which resolves 10.9 catalog
// colors to BLACK (same trap as the text-selection colors above). colorWithSRGBRed: is already concrete, so
// the downstream space conversion is a no-op and the accent stays blue.
WK_POLYFILL_ADD_METHODS(NSApplication)
- (NSColor *)_effectiveAccentColor { return SRGB(0, 122, 255, 255); }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSTextInputContext handleEvent:completionHandler:] and
// -[NSTextInputContext handleEventByInputMethod:completionHandler:] (10.10+ SPI): delegate to the
// synchronous 10.6 -handleEvent: and report its result — routing the event through the input context
// first, as upstream does. (Do not polyfill "handleEvent:" itself: this body calls it.)
//
// The KEY-EVENT pair, -handleEventByInputMethod:completionHandler: and -handleEventByKeyboardLayout:
// (both 10.10+), split what 10.6's -handleEvent: does in one step: first offer the event to the input
// method alone, then, if the input method did not consume it, translate it through the keyboard layout
// and key bindings. 10.9 has no entry point for the first half on its own. Emulating it with
// -handleEvent: is WRONG — that performs the whole translation, and WebKit then runs the
// keyboard-layout half as well, so every keystroke was inserted TWICE (typing 1234 in the Web
// Inspector console produced 11223344).
//
// So: report that the input method did not consume the event (translating nothing), and do the single
// translation in the keyboard-layout half, where -handleEvent: belongs. Composition still works,
// because -handleEvent: consults the input method itself — this is exactly the pre-10.10 flow, which
// is what WebKit did on this OS before the SPI existed. Without these two, the sends raised
// unrecognized-selector exceptions and no completion handler ever ran, so key input on every
// WKWebView-backed surface in the process — the Web Inspector front end above all — went nowhere.
WK_POLYFILL_ADD_METHODS(NSTextInputContext)
- (void)handleEvent:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler
{
    BOOL handled = [self handleEvent:event];
    if (completionHandler)
        completionHandler(handled);
}
- (void)handleEventByInputMethod:(NSEvent *)event completionHandler:(void (^)(BOOL))completionHandler
{
    (void)event;
    if (completionHandler)
        completionHandler(NO);
}
- (BOOL)handleEventByKeyboardLayout:(NSEvent *)event
{
    return [self handleEvent:event];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSTextInputContext textInputClientWillStartScrollingOrZooming] /
// -textInputClientDidEndScrollingOrZooming (10.11+) and -textInputClientDidUpdateSelection (10.11+ SPI):
// courtesy notifications WebViewImpl sends the input context so the active input method can hide or
// reposition its candidate window around scrolling and selection changes. The scrolling pair fires from
// pageScrollingHysteresisFired whenever the MAIN FRAME's scroll position changes while the view's input
// context is active — any normally-scrolling page in a WKWebView-backed view with an editable focused
// (the Web Inspector's own main frame never scrolls, so the sends are latent there; verified by
// scrolling its panels with a style edit focused, which only moves overflow boxes). The selection one
// fires on process swap/exit with an editable focused (WebViewImpl.mm:1466) and, pref-gated, on
// selection change. 10.9's input-method machinery has no such hooks — a candidate window there tracks
// the insertion point on its own — so there is nothing to notify: faithful no-ops.
WK_POLYFILL_ADD_METHODS(NSTextInputContext)
- (void)textInputClientWillStartScrollingOrZooming { }
- (void)textInputClientDidEndScrollingOrZooming { }
- (void)textInputClientDidUpdateSelection { }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSSpellChecker deletesAutospaceBeforeString:language:] (10.12+): asks whether the space that
// accepting a completion candidate auto-inserted (the "soft space") should be removed before the text
// being inserted next (e.g. punctuation). Reached from WebViewImpl::insertText only when
// m_softSpaceRange is set, which happens on the candidate-acceptance paths; 10.9 has no completion
// candidates and never auto-inserts a soft space, so there is never a space to delete: NO.
WK_POLYFILL_ADD_METHODS(NSSpellChecker)
- (BOOL)deletesAutospaceBeforeString:(NSString *)string language:(NSString *)language
{
    (void)string;
    (void)language;
    return NO;
}
@end

// ---------------------------------------------------------------------------------------------------
// SF Symbols (11.0+): no system symbols exist on 10.9, so +imageWithSystemSymbolName: (and the private
// variant) return nil for every name — matching the real API's unknown-symbol contract. Callers that pass the
// result to -setImage:/-_setActionImage:/+imageViewWithImage: tolerate nil; the one caller that dereferences
// the image (RenderThemeMac's attachment-progress placeholder) carries its own nil-guard.
// +[NSImageView imageViewWithImage:] (10.12+) builds the view the classic way; -setSymbolConfiguration: and
// -setContentTintColor: are cosmetic template-image properties with nothing to configure for a nil image.
WK_POLYFILL_ADD_METHODS(NSImage)
+ (NSImage *)imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc { (void)name; (void)desc; return nil; }
+ (NSImage *)imageWithPrivateSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)desc { (void)name; (void)desc; return nil; }
@end

WK_POLYFILL_ADD_METHODS(NSImageView)
+ (instancetype)imageViewWithImage:(NSImage *)image
{
    id view = [[[NSImageView alloc] initWithFrame:NSZeroRect] autorelease];
    [view setImage:image];
    return view;
}
- (void)setSymbolConfiguration:(NSImageSymbolConfiguration *)configuration { (void)configuration; }
- (void)setContentTintColor:(NSColor *)color { (void)color; }
@end

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
WK_POLYFILL_ADD_METHODS(NSScrollerImp)
- (void)setUserInterfaceLayoutDirection:(NSInteger)direction
{ objc_setAssociatedObject(self, wk_uildScrollerKey, @(direction), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSInteger)userInterfaceLayoutDirection
{ NSNumber *v = objc_getAssociatedObject(self, wk_uildScrollerKey); return v ? [v integerValue] : NSUserInterfaceLayoutDirectionLeftToRight; }
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
- (void)setNeedsDisplay:(BOOL)flag { if (flag) [[self layer] setNeedsDisplay]; }
@end
WK_POLYFILL_ADD_METHODS(NSMenu)
- (void)setUserInterfaceLayoutDirection:(NSUserInterfaceLayoutDirection)direction
{ objc_setAssociatedObject(self, wk_uildMenuKey, @(direction), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSUserInterfaceLayoutDirection)userInterfaceLayoutDirection
{ NSNumber *v = objc_getAssociatedObject(self, wk_uildMenuKey); return v ? [v integerValue] : NSUserInterfaceLayoutDirectionLeftToRight; }
@end

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
//
// 10.9 HAS -showRelativeToRect:ofView:preferredEdge:; it shows the popover correctly and additionally
// steals the anchor window's first responder, which is the behavior this replacement undoes.
WK_POLYFILL_REPLACE_METHODS(NSPopover)
- (void)showRelativeToRect:(NSRect)positioningRect ofView:(NSView *)positioningView preferredEdge:(NSRectEdge)preferredEdge
{
    NSWindow *window = [positioningView window];
    NSResponder *savedFirstResponder = [window firstResponder];

    WK_ORIGINAL_METHOD(void, (NSRect, NSView *, NSRectEdge), positioningRect, positioningView, preferredEdge);

    if (window && [window firstResponder] != savedFirstResponder)
        [window makeFirstResponder:savedFirstResponder];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSWorkspace URLsForApplicationsToOpenURL:] (12.0+). LSCopyApplicationURLsForURL is the same query
// under its pre-12.0 name (it is what the modern method wraps), present since 10.3.
WK_POLYFILL_ADD_METHODS(NSWorkspace)
- (NSArray<NSURL *> *)URLsForApplicationsToOpenURL:(NSURL *)url
{
    CFArrayRef urls = LSCopyApplicationURLsForURL((__bridge CFURLRef)url, kLSRolesAll);
    if (urls) return [(__bridge NSArray *)urls autorelease];
    return @[];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSWorkspace URLForApplicationToOpenContentType:] (12.0+). The pre-12.0 route to the same answer is
// LSCopyDefaultRoleHandlerForContentType, which returns the default handler's BUNDLE IDENTIFIER rather
// than a URL, so the identifier is resolved through -URLForApplicationWithBundleIdentifier: (10.6+).
// kLSRolesViewer is the role the modern method reports for a content type — "the app that opens this to
// look at it" — and is what its only WebKit caller (the PDF save-and-open panel naming the default PDF
// viewer) is asking about. The argument is a UTType, whose -identifier is the same UTI CFString the
// classic LaunchServices call takes. Returns nil when no handler is registered, exactly as the modern
// method does, which callers already handle.
WK_POLYFILL_ADD_METHODS(NSWorkspace)
- (NSURL *)URLForApplicationToOpenContentType:(UTType *)contentType
{
    // -[UTType identifier] is 11.0+; classes/UniformTypeIdentifiers.m supplies the class and this
    // property.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    NSString *identifier = [contentType identifier];
#pragma clang diagnostic pop
    if (![identifier length])
        return nil;
    CFStringRef bundleID = LSCopyDefaultRoleHandlerForContentType((__bridge CFStringRef)identifier, kLSRolesViewer);
    if (!bundleID)
        return nil;
    NSURL *url = [self URLForApplicationWithBundleIdentifier:(__bridge NSString *)bundleID];
    CFRelease(bundleID);
    return url;
}
@end

// +[NSSharingService getSharingServicesForItems:mask:completion:] — the asynchronous, mask-filtered SPI
// form, absent on 10.9 (probed on-host). The class is present, and so is the PUBLIC 10.8 API that answers
// the same question synchronously, +sharingServicesForItems:, so this is a translation rather than a stub.
//
// Getting this wrong is not a quiet degradation: ServicesController::hasCompatibleServicesForItems does
// dispatch_group_enter, calls this, and leaves the group in the completion. With the selector absent the
// completion never runs, the group is entered three times and never left, and destroying it aborts the
// process in _dispatch_semaphore_dispose (SIGILL) — which is exactly how Safari died once
// ENABLE(SERVICE_CONTROLS) was restored.
//
// The mask (viewer/editor) cannot be applied here: 10.8's API takes no mask and returns everything that
// can handle the items. Over-reporting is the safe direction — callers use the result to decide whether to
// OFFER a services menu, and the menu itself is built by NSSharingServicePicker, which does its own
// filtering. The completion is delivered asynchronously because that is the shape of the API being
// replaced; a caller that leaves a dispatch group in it must not be called back before it returns.
//
// The enumeration runs on a dedicated, persistent, OFF-MAIN thread that owns a CoreFoundation run loop —
// NOT a global dispatch worker, and NOT the main thread. +sharingServicesForItems: brings up a ShareKit
// helper over XPC (SHKHelperController), and on 10.9 that xpc_connection_resume requires the calling
// thread to have a run loop: on a runloop-less global worker it hits _xpc_api_misuse and SIGILLs the
// process. The main thread has a run loop, but the real 10.10 async SPI does not run its XPC round-trip on
// the caller's main thread, and neither should this — a main-queue hop would block the UI thread and be
// correct only for the current, happens-to-be-non-blocking caller. A dedicated run-loop thread meets both
// constraints for any caller.
static CFRunLoopRef wkSharingEnumerationRunLoopRef; // published by the thread once it is up
static dispatch_semaphore_t wkSharingEnumerationReady;

static void *wkSharingEnumerationThreadMain(void *unused)
{
    (void)unused;
    wkSharingEnumerationRunLoopRef = CFRunLoopGetCurrent();
    // A source that is never signaled keeps CFRunLoopRun() from returning while the thread is idle.
    CFRunLoopSourceContext context = { 0 };
    CFRunLoopSourceRef keepAlive = CFRunLoopSourceCreate(NULL, 0, &context);
    CFRunLoopAddSource(wkSharingEnumerationRunLoopRef, keepAlive, kCFRunLoopCommonModes);
    CFRelease(keepAlive);
    dispatch_semaphore_signal(wkSharingEnumerationReady);
    CFRunLoopRun();
    return NULL;
}

static CFRunLoopRef wkSharingEnumerationRunLoop(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        wkSharingEnumerationReady = dispatch_semaphore_create(0);
        pthread_t thread;
        if (!pthread_create(&thread, NULL, wkSharingEnumerationThreadMain, NULL)) {
            pthread_detach(thread);
            dispatch_semaphore_wait(wkSharingEnumerationReady, DISPATCH_TIME_FOREVER);
        }
    });
    return wkSharingEnumerationRunLoopRef;
}

WK_POLYFILL_ADD_METHODS(NSSharingService)

+ (void)getSharingServicesForItems:(NSArray *)items mask:(NSUInteger)mask completion:(void (^)(NSArray *))completion
{
    (void)mask;
    if (!completion)
        return;
    CFRunLoopRef runLoop = wkSharingEnumerationRunLoop();
    if (!runLoop) {
        // Thread could not be created; fail closed by reporting no services rather than never calling back.
        completion(@[]);
        return;
    }
    // items/completion are retained by the block copy CFRunLoopPerformBlock makes, and released after it runs.
    CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes, ^{
        NSArray *services = [NSSharingService sharingServicesForItems:items];
        completion(services ?: @[]);
    });
    CFRunLoopWakeUp(runLoop);
}

@end

// +[NSMenuItem standardShareMenuItemForItems:] — the one-call "Share" menu-item constructor, absent on
// 10.9 (probed on-host: unrecognized selector sent to class NSMenuItem). WebKitLegacy's context-menu
// build (createShareMenuItem in WebHTMLView.mm) calls it whenever the hit test has anything shareable —
// which is every text selection — and the NSException unwound the whole menu build, so right-clicking
// text in a WK1 host (Notes) produced no menu at all.
//
// 10.9 presents Share as an inline submenu of services (Email/Messages/…) — TextEdit's editable context
// menu is the reference — so reconstruct that native form: a "Share" parent item whose submenu is
// NSSharingServicePicker's own services menu (-menu, SPI present and fully wired on 10.9 with a
// per-service image/target/action). representedObject keeps the picker alive so those actions can fire.
// The title is the system's localized "Share" (ShareKit's strings table) so the menu reads correctly in
// every language. Returns nil when no service can handle the items, the real constructor's "no item"
// answer, which the caller already handles. The WK2 UIProcess builds its Share item from the
// picker-anchored variant of the same 10.10 API, polyfilled just below in the same form.
@interface NSSharingServicePicker (WKPolyfillShareMenuSPI)
- (NSMenu *)menu;
- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)preferredEdge;
@end

WK_POLYFILL_ADD_METHODS(NSMenuItem)

+ (NSMenuItem *)standardShareMenuItemForItems:(NSArray *)items
{
    if (![items count])
        return nil;
    NSSharingServicePicker *picker = [[[NSSharingServicePicker alloc] initWithItems:items] autorelease];
    NSMenu *servicesMenu = [picker menu];
    if (![servicesMenu numberOfItems])
        return nil;
    NSBundle *shareKitBundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ShareKit.framework"];
    NSString *shareTitle = [shareKitBundle localizedStringForKey:@"Share" value:@"Share" table:@"ShareKit"];
    NSMenuItem *shareItem = [[[NSMenuItem alloc] initWithTitle:([shareTitle length] ? shareTitle : @"Share") action:NULL keyEquivalent:@""] autorelease];
    [shareItem setEnabled:YES];
    [shareItem setSubmenu:servicesMenu];
    [shareItem setRepresentedObject:picker];
    return shareItem;
}

@end

// -[NSSharingServicePicker standardShareMenuItemRelativeToRect:ofView:preferredEdge:] — the picker's own
// "Share" menu-item constructor, 10.10+ and absent on 10.9 (probed on-host: unrecognized selector). The
// WK2 UIProcess context-menu build (WebContextMenuProxyMac::createShareMenuItem) calls it for anything
// shareable, and the NSException unwound the whole menu build, so every editable right-click in Safari
// produced no menu at all.
//
// Same 10.9-native form as +[NSMenuItem standardShareMenuItemForItems:] above — a localized "Share"
// parent whose submenu is the picker's own services menu — because that is what a Share item looks like
// on this OS. The rect/view/edge describe where the real 10.10 item anchors its share popover when
// invoked; 10.9 shows the services inline in the submenu instead, so they are only needed for the second
// half of the contract: a caller that ignores the submenu and performs the item's action (upstream's
// placeholder path does exactly that, via -performShare:) must still get the picker on screen. The item's
// action therefore drives -showRelativeToRect:ofView:preferredEdge: — present and wired on 10.9 — with
// the arguments the caller passed. AppKit ignores an action on an item that has a submenu, so the two
// halves do not fight. The anchor object owns the picker and rides along as an associated object of the
// item, since -[NSMenuItem setTarget:] does not retain. It RETAINS the view: an unretained pointer would
// dangle for a caller that keeps the item past the view, and a zeroing weak slot is not an option on 10.9
// — objc_storeWeak aborts the process outright for the runtime's no-weak classes ("Cannot form weak
// reference to instance of class NSTextView", SIGILL), and an NSTextView is a perfectly ordinary view to
// anchor a Share item to. Retaining closes no cycle: a context menu is owned by whoever pops it up, not
// by the view, so the item — and with it this anchor and its retain on the view — goes away with the menu.
@interface WKPolyfillSharePickerAnchor : NSObject {
    NSSharingServicePicker *_picker;
    NSView *_view;
    NSRect _rect;
    NSRectEdge _preferredEdge;
}
- (id)initWithPicker:(NSSharingServicePicker *)picker rect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)preferredEdge;
- (void)wk_showSharePicker:(id)sender;
@end

@implementation WKPolyfillSharePickerAnchor

- (id)initWithPicker:(NSSharingServicePicker *)picker rect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)preferredEdge
{
    if (!(self = [super init]))
        return nil;
    _picker = [picker retain];
    _view = [view retain];
    _rect = rect;
    _preferredEdge = preferredEdge;
    return self;
}

- (void)dealloc
{
    [_view release];
    [_picker release];
    [super dealloc];
}

- (void)wk_showSharePicker:(id)sender
{
    (void)sender;
    if (_view)
        [_picker showRelativeToRect:_rect ofView:_view preferredEdge:_preferredEdge];
}

@end

static const void *kWKSharePickerAnchorKey = &kWKSharePickerAnchorKey;

WK_POLYFILL_ADD_METHODS(NSSharingServicePicker)

- (NSMenuItem *)standardShareMenuItemRelativeToRect:(NSRect)rect ofView:(NSView *)view preferredEdge:(NSRectEdge)preferredEdge
{
    NSMenu *servicesMenu = [self menu];
    if (![servicesMenu numberOfItems])
        return nil;
    NSBundle *shareKitBundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ShareKit.framework"];
    NSString *shareTitle = [shareKitBundle localizedStringForKey:@"Share" value:@"Share" table:@"ShareKit"];
    NSMenuItem *shareItem = [[[NSMenuItem alloc] initWithTitle:([shareTitle length] ? shareTitle : @"Share")
                                                        action:@selector(wk_showSharePicker:)
                                                 keyEquivalent:@""] autorelease];
    [shareItem setEnabled:YES];
    [shareItem setSubmenu:servicesMenu];
    [shareItem setRepresentedObject:self];

    WKPolyfillSharePickerAnchor *anchor = [[[WKPolyfillSharePickerAnchor alloc] initWithPicker:self
                                                                                          rect:rect
                                                                                        ofView:view
                                                                                 preferredEdge:preferredEdge] autorelease];
    [shareItem setTarget:anchor];
    objc_setAssociatedObject(shareItem, kWKSharePickerAnchorKey, anchor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return shareItem;
}

@end

// ---------------------------------------------------------------------------------------------
// AppKit pieces the Web Inspector's window/panel code needs, all absent on 10.9 (probed on-host).

// +[NSTextField labelWithString:] (10.12+) is a convenience constructor for a non-editable,
// non-bezeled, non-drawing label. That IS its implementation — the modern one configures exactly these
// properties on a plain NSTextField — so this is the real thing, not an approximation.
WK_POLYFILL_ADD_METHODS(NSTextField)
+ (instancetype)labelWithString:(NSString *)stringValue
{
    NSTextField *label = [[[self alloc] initWithFrame:NSZeroRect] autorelease];
    [label setStringValue:stringValue ?: @""];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    // -setLineBreakMode: is 10.10+ on NSControl and absent on the 10.9 runtime; the NSControl block
    // below supplies it.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    [label setLineBreakMode:NSLineBreakByClipping];
#pragma clang diagnostic pop
    [label sizeToFit];
    return (id)label;
}
@end

// -[NSControl usesSingleLineMode] and -[NSControl lineBreakMode] (both 10.10+, declared three lines
// apart) are cell-forwarding conveniences: they read and write the control's cell, which has carried
// both properties since 10.6. Forwarding is the whole of them, so a control with no cell -- an
// NSTableView is one -- answers the cell's default and ignores the set, exactly as on a system that
// has the methods.
WK_POLYFILL_ADD_METHODS(NSControl)
- (BOOL)usesSingleLineMode
{
    return [[self cell] usesSingleLineMode];
}

- (void)setUsesSingleLineMode:(BOOL)usesSingleLineMode
{
    [[self cell] setUsesSingleLineMode:usesSingleLineMode];
}

- (NSLineBreakMode)lineBreakMode
{
    return [[self cell] lineBreakMode];
}

- (void)setLineBreakMode:(NSLineBreakMode)lineBreakMode
{
    [[self cell] setLineBreakMode:lineBreakMode];
}
@end

// -[NSView safeAreaInsets] (11.0+) and -[NSScreen safeAreaInsets] (12.0+). A safe-area inset describes
// screen furniture (notch, home indicator) intruding on a view or a screen. 10.9 has none, and
// NSEdgeInsetsZero is exactly what modern AppKit returns when nothing intrudes — so this is the correct
// answer here, not a placeholder. For the screen it means WebCore's safeScreenFrame() is the full screen
// frame, which is the truth on this hardware.
//
// BOTH classes need it. A polyfilled selector is rewritten wherever WebKit sends it, not on one class
// only, so every receiver class WebKit sends it to must implement it or that
// send raises "unrecognized selector". WebCore sends it to NSView (RenderThemeMac) and, via
// safeScreenFrame(), to NSScreen — the NSScreen half was missing, and it took the UI process's
// full-screen entry down with an exception the moment WKFullScreenWindowController asked for the screen
// frame.
WK_POLYFILL_ADD_METHODS(NSView)
- (NSEdgeInsets)safeAreaInsets { return NSEdgeInsetsMake(0, 0, 0, 0); }
@end

WK_POLYFILL_ADD_METHODS(NSScreen)
- (NSEdgeInsets)safeAreaInsets { return NSEdgeInsetsMake(0, 0, 0, 0); }
@end

// -[NSWindow setMinFullScreenContentSize:] (10.11+) constrains a window's size in a tiled full-screen
// split. 10.9 has no tiling — NSWindowCollectionBehaviorFullScreenAllowsTiling is 10.11 too — so there is
// no split for a minimum to apply to, and storing nothing is the whole behaviour on this OS.
WK_POLYFILL_ADD_METHODS(NSWindow)
- (void)setMinFullScreenContentSize:(NSSize)size { (void)size; }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSMenu setItemArray:] (10.10+): wholesale item replacement. 10.9 composes the same state from the
// primitives it has always had — remove everything, add each item in order. Callers:
// WebContextMenuProxyMac's sparse-menu rebuild, MenuUtilities' proposed-items filter,
// WKRevealItemPresenter.
WK_POLYFILL_ADD_METHODS(NSMenu)
- (void)setItemArray:(NSArray<NSMenuItem *> *)items
{
    [self removeAllItems];
    for (NSMenuItem *item in items)
        [self addItem:item];
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSPopover _setRequiresCorrectContentAppearance:] (10.10+ SPI) pins the popover's content to the
// correct light/dark appearance instead of the vibrant default. 10.9 has one appearance and its
// popovers already render content in it, so the requested state is the only state.
WK_POLYFILL_ADD_METHODS(NSPopover)
- (void)_setRequiresCorrectContentAppearance:(BOOL)requires { (void)requires; }
@end

// ---------------------------------------------------------------------------------------------------
// -[NSViewController isViewLoaded] (10.10+): whether the view is loaded, WITHOUT triggering the load
// the way -view does. 10.9's controller keeps the loaded view in its `view` ivar (nil until
// -loadView), so reading the ivar directly is the same no-side-effect answer.
WK_POLYFILL_ADD_METHODS(NSViewController)
- (BOOL)isViewLoaded
{
    Ivar viewIvar = class_getInstanceVariable([NSViewController class], "view");
    return viewIvar && object_getIvar(self, viewIvar);
}
@end

#import "color-popover-top-bar.h"

// ---------------------------------------------------------------------------------------------------
// -[NSColorPopoverController topBarMatrixView] (10.10+): the suggested-colors swatch matrix across the
// top of the color popover, which an <input type="color" list="..."> fills with the page's suggestions.
// The strip and its layout live in color-popover-top-bar.h, one static definition shared with its proof,
// tests/behaviour/AppKit-color-popover-top-bar.m. The class is named by string: it exists in 10.9's
// AppKit but its _OBJC_CLASS_$_ symbol is local there, so nothing compiled can bind it.
WK_POLYFILL_ADD_METHODS_ON(NSViewController, "NSColorPopoverController")
- (id)topBarMatrixView
{
    return wkColorTopBarMatrixView(self);
}
@end

// ---------------------------------------------------------------------------------------------------
// -[NSTableView setStyle:] (11.0+) picks a Big-Sur table inset/padding style. A 10.9 table has only
// the classic metrics — the same ones the pre-11.0 default gave every caller — so there is no state to
// set and the classic look is the answer.
WK_POLYFILL_ADD_METHODS(NSTableView)
- (void)setStyle:(NSTableViewStyle)style { (void)style; }
@end

// ---------------------------------------------------------------------------------------------------
// -setAccessibilityTitle: (10.10+ NSAccessibility protocol). 10.9 exposes the same capability as the
// override API this rewrote: accessibilitySetOverrideValue:forAttribute: stores a value that answers
// NSAccessibilityTitleAttribute queries, which is precisely what the 10.10 setter does for the title.
// Installed on NSObject (where 10.10 declares the protocol) so any accessibility element WebKit sends
// it to — WebDateTimePickerMac's picker window today — gets the real store.
WK_POLYFILL_ADD_METHODS(NSObject)
- (void)setAccessibilityTitle:(NSString *)title
{
    [self accessibilitySetOverrideValue:title forAttribute:NSAccessibilityTitleAttribute];
}
@end

#pragma clang diagnostic pop
