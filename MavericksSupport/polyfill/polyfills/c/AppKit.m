// AppKit: constants modern WebKit references that 10.9's AppKit does not export.
#include "wk_polyfill.h"

#import <AppKit/AppKit.h>

// WK_POLYFILL_CONST spells the type ahead of the name ("const TYPE NAME"), so a pointer constant
// needs a typedef for the const to land on the POINTER -- the "NSString * const" shape the SDK
// declares these with, rather than a pointer to const.
typedef NSString *PolyNSStringConst;

#pragma mark - NSPopUpMenu constants
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonBounds, @"NSPopUpMenuPopupButtonBounds");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonOrigin, @"NSPopUpMenuPopupButtonOrigin");

#pragma mark - NSTouchBar notifications
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTouchBarDidExitCustomization, @"NSTouchBarDidExitCustomization");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTouchBarWillEnterCustomization, @"NSTouchBarWillEnterCustomization");

#pragma mark - NSText constants (10.12+)
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextCheckingInsertionPointKey, @"NSTextCheckingInsertionPointKey");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextCheckingSuppressInitialCapitalizationKey, @"NSTextCheckingSuppressInitialCapitalizationKey");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextInsertionUndoableAttributeName, @"NSTextInsertionUndoableAttributeName");

#pragma mark - Additional NSPopUpMenu constants
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonLabelOffset, @"NSPopUpMenuPopupButtonLabelOffset");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonSize, @"NSPopUpMenuPopupButtonSize");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonWidget, @"NSPopUpMenuPopupButtonWidget");

#pragma mark - NSAccessibility attribute constants
// NSAccessibilityRequiredAttribute is declared API_AVAILABLE(macos(10.12)) and is absent from 10.9's
// AppKit. Unlike most weak-imported symbols it is a data constant, and because it post-dates the 10.9
// deployment target it weak-links to NULL rather than failing the load: -[WebAccessibilityObjectWrapper
// accessibilityAttributeNames] builds its attribute-name arrays by dereferencing each such extern
// (movq (%rax)), so the NULL address SIGSEGVs the process (EXC_BAD_ACCESS at 0x0) the instant an
// assistive/AX client enumerates a form field's attributes -- a login page's text or secure (password)
// field, hence "settings/password" crashes (github #100). The value is AppKit's own interpreted string,
// which assistive technologies match on, so it must be the real "AXRequired" (same convention as this
// header's sibling AX constants and WebCore's NSAccessibilityInvalidAttribute -> @"AXInvalid"), not the
// symbol's spelling. NSAccessibilityInvalidAttribute needs no entry: WebCore #defines it itself because
// AppKit never declares it.
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAccessibilityRequiredAttribute, @"AXRequired");

// The 26.1 build SDK declares the following but the 10.9 AppKit does not export them. The features
// are unused or inert on 10.9, so only the SYMBOL needs to exist with the right type; the values are
// low-stakes.

// --- NSTextList marker format constants (10.13+) -------------------------
// Documented "{...}" CSS-list-style marker strings.
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerCircle, @"{circle}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerDecimal, @"{decimal}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerDisc, @"{disc}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerLowercaseAlpha, @"{lower-alpha}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerLowercaseHexadecimal, @"{lower-hexadecimal}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerLowercaseLatin, @"{lower-latin}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerLowercaseRoman, @"{lower-roman}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerOctal, @"{octal}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerSquare, @"{square}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerUppercaseAlpha, @"{upper-alpha}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerUppercaseHexadecimal, @"{upper-hexadecimal}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerUppercaseLatin, @"{upper-latin}");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextListMarkerUppercaseRoman, @"{upper-roman}");

// --- NSPasteboard name / type constants (10.13+) -------------------------
// The SDK declares the four names without const, so they are defined with WK_PF_ENTRY
// (WK_POLYFILL_CONST would spell them "NSString * const").
#define WK_PASTEBOARD_NAME(NAME, VALUE) \
    NSPasteboardName NAME = VALUE; \
    WK_PF_ENTRY(NAME, "AppKit", &NAME, WK_POLYFILL_CONSTANT, WK_POLYFILL_GAP_FILL)
WK_PASTEBOARD_NAME(NSPasteboardNameGeneral, @"Apple CFPasteboard general");
WK_PASTEBOARD_NAME(NSPasteboardNameFind, @"Apple CFPasteboard find");
WK_PASTEBOARD_NAME(NSPasteboardNameFont, @"Apple CFPasteboard font");
WK_PASTEBOARD_NAME(NSPasteboardNameDrag, @"Apple CFPasteboard drag");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardTypeURL, @"public.url");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardTypeFileURL, @"public.file-url");

// --- Other AppKit / Foundation string constants --------------------------
// The post-10.9 appearance names. An NSAppearance name's value is its own spelling, which is what
// -bestMatchFromAppearancesWithNames: compares against, so each is supplied under that spelling.
// WebExtensionCocoa.mm collects the four dark ones into an @[] literal, and an array literal raises on
// a nil element, so a name missing here takes down the extension icon path rather than degrading it.
//
// A missing name is worse than nil elsewhere. These are weak-imported DATA symbols: dyld binds an
// absent one to address 0, and reading the NSString* then dereferences NULL rather than yielding nil.
// Both members of the Vibrant pair (10.10+) therefore have to be declared, not just the dark one:
// AVOutputDeviceMenuControllerTargetPicker::showPlaybackTargetPicker evaluates
// `useDarkAppearance ? NSAppearanceNameVibrantDark : NSAppearanceNameVibrantLight` to build the
// -showMenuForRect:appearanceName:... argument, so whichever branch it takes faults if that name is
// absent, and it faults on the ARGUMENT, before the message. (The receiver is nil on 10.9 --
// AVOutputDeviceMenuController is 10.11+ -- so the picker is an honest no-route no-op either way;
// only the argument is fatal. Clicking the AirPlay button on a video is the path that reaches it.)
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameDarkAqua, @"NSAppearanceNameDarkAqua");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameVibrantDark, @"NSAppearanceNameVibrantDark");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameVibrantLight, @"NSAppearanceNameVibrantLight");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameAccessibilityHighContrastDarkAqua, @"NSAppearanceNameAccessibilityHighContrastDarkAqua");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameAccessibilityHighContrastVibrantDark, @"NSAppearanceNameAccessibilityHighContrastVibrantDark");
// NSFontWeightRegular (AppKit, 10.11+) is a CGFloat, not a token: 0.0 is the documented midpoint of
// the NSFontWeight scale (ultraLight -0.8 ... black 0.62), which is what the name means wherever it is
// read. On 10.9 nothing reads it -- its only WebKit callers pass it to +[NSImageSymbolConfiguration
// configurationWithPointSize:weight:scale:], and that class is 11.0+, so the message goes to a nil
// class. It is declared here because the ARGUMENT is evaluated before the message: as a weak-imported
// data symbol it binds to address 0, so loading the CGFloat faults before the nil receiver can absorb
// the call. Same failure shape as NSAppearanceNameVibrantLight above; the two live sites are
// RenderThemeMac.mm's attachment-placeholder glyph and _WKWarningView.mm.
WK_POLYFILL_CONST("AppKit", CGFloat, NSFontWeightRegular, 0.0);

WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification, @"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification");

// --- NSViewNoIntrinsicMetric (correct spelling, macos(10.11)) ------------
// AppKit ships two symbols: NSViewNoInstrinsicMetric (the historical typo,
// macos(10.7) — PRESENT on 10.9, so we must NOT shadow it) and the
// correctly-spelled NSViewNoIntrinsicMetric (macos(10.11) — ABSENT on 10.9,
// value -1). WebKit references the correct-spelling symbol directly in
// several places (WKView, WebViewImpl, _WKWarningView's intrinsicContentSize).
// Against the 26.1 SDK that is a weak DATA import: on 10.9 the symbol's
// ADDRESS resolves to NULL, so reading the const dereferences NULL and
// crashes (EXC_BAD_ACCESS) — not merely a wrong value. Defining it here
// (pulled into every framework alongside the other stubs) satisfies the
// reference with the correct -1.
WK_POLYFILL_CONST("AppKit", CGFloat, NSViewNoIntrinsicMetric, -1);

// --- NSInitializeCGFocusRingStyleForTime (absent on 10.9) ----------------
// Fills a CGFocusRingStyle with AppKit's focus-ring parameters for `placement`, as of `time` seconds
// into the ring's appearance animation. 10.9's ring does not animate, so every time answers the same
// settled style. The values are the ones this OS's own -NSSetFocusRingStyle hands
// CGStyleCreateFocusRingWithColor, read off that call: version 0, blue tint, alpha 0.8, radius 2,
// threshold 0.5, zero bounds, no accumulation, and an ordering that tracks the placement.
//
// CoreGraphics' layout for the struct AppKit's callers pass; CGFocusRingStyle is in no public header.
typedef int32_t PolyCGFocusRingTint;
typedef int32_t PolyCGFocusRingOrdering;
struct PolyCGFocusRingStyle {
    unsigned int version;
    PolyCGFocusRingTint tint;
    PolyCGFocusRingOrdering ordering;
    CGFloat alpha;
    CGFloat radius;
    CGFloat threshold;
    CGRect bounds;
    int accumulate;
};
enum { PolyCGFocusRingTintBlue = 0 };

WK_POLYFILL_ABSENT("AppKit", BOOL, NSInitializeCGFocusRingStyleForTime,
    (NSFocusRingPlacement placement, struct PolyCGFocusRingStyle *style, NSTimeInterval time))
{
    (void)time;
    if (!style)
        return NO;
    switch (placement) {
    case NSFocusRingBelow: style->ordering = 1; break;
    case NSFocusRingAbove: style->ordering = 2; break;
    default:              style->ordering = 0; break;
    }
    style->version = 0;
    style->tint = PolyCGFocusRingTintBlue;
    style->alpha = 0.8;
    style->radius = 2;
    style->threshold = 0.5;
    style->bounds = CGRectZero;
    style->accumulate = 0;
    return YES;
}
