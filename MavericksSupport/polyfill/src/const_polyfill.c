// CFString constants for framework keys (CoreText/CoreGraphics/Accessibility/CFNetwork)
// that 10.9 does not define but modern WebKit references. Each is a CFString whose value
// is its own name: a unique token used as a dictionary key/identifier. The 10.9 frameworks
// predate these keys and never interpret them, so the exact string is immaterial.
//
// The tail of the file also defines a few trivial libSystem SPI functions that the 26.1 SDK resolves
// against libSystem (recording a two-level bind that fails to load on the 10.9 runtime, which lacks
// them). Defining them here makes the linker satisfy WebKit's reference from libpolyfill.a instead.
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdbool.h>

const CFStringRef kAXInterfaceDifferentiateWithoutColorKey = CFSTR("kAXInterfaceDifferentiateWithoutColorKey");
const CFStringRef kAXInterfaceIncreaseContrastKey = CFSTR("kAXInterfaceIncreaseContrastKey");
const CFStringRef kAXInterfaceReduceMotionKey = CFSTR("kAXInterfaceReduceMotionKey");
const CFStringRef kAXSAccessibilityPreferenceDomain = CFSTR("kAXSAccessibilityPreferenceDomain");
const CFStringRef kAXSEnhanceTextLegibilityChangedNotification = CFSTR("kAXSEnhanceTextLegibilityChangedNotification");
// kCFHTTPCookieLocalFileDomain / kCFStreamPropertyHTTP(S)Proxy* are NOT defined here:
// the 10.9 runtime exports them (real values ".^filecookies^", "HTTPProxy", ...) and the
// modern SDK still links them — a name-string copy here silently shadowed the real values
// (local-file cookie domain and proxy stream keys never matched CFNetwork's).
const CFStringRef kCFURLRequestContentDecoderSkipURLCheck = CFSTR("kCFURLRequestContentDecoderSkipURLCheck");
const CFStringRef kCGColorSpaceGenericXYZ = CFSTR("kCGColorSpaceGenericXYZ");
const CFStringRef kCGGradientInterpolatesPremultiplied = CFSTR("kCGGradientInterpolatesPremultiplied");
// The ImageIO kCGImageProperty*/kCGImageSource* keys 10.9 already exports (Exif pixel
// dimensions, TIFF resolution unit, thumbnail/cache/skip-metadata/subsample options) are
// NOT defined here: the name-string copies shadowed ImageIO's real values ("PixelXDimension"
// et al.), so EXIF dimension lookups silently missed. The SDK links them; 10.9 provides them.
// kCGImagePropertyWebPDictionary (ImageIO, macOS 11.0; absent on 10.9) is a key WebKit passes to
// CFDictionaryGetValue on a *system-provided* CGImageSource properties dict — so unlike the
// round-tripped token keys above, its value must be ImageIO's REAL value, not the symbol name
// (the same lesson as the EXIF note above). ImageIO's per-format dictionary keys are "{TYPE}" with
// the format's canonical mixed casing (verified on-host across 20 sibling keys: {GIF} {PNG} {Exif}
// {ExifAux} {MakerApple} …), so WebP is "{WebP}". Behavior-neutral on 10.9 (that ImageIO has no WebP
// animation dict, so the lookup returns NULL and the caller falls through to the PNG dict either way).
const CFStringRef kCGImagePropertyWebPDictionary = CFSTR("{WebP}");
const CFStringRef kCGImageSourceUseHardwareAcceleration = CFSTR("kCGImageSourceUseHardwareAcceleration");
const CFStringRef kCTFontCSSFamilyCursive = CFSTR("kCTFontCSSFamilyCursive");
const CFStringRef kCTFontCSSFamilyFantasy = CFSTR("kCTFontCSSFamilyFantasy");
const CFStringRef kCTFontCSSFamilyMonospace = CFSTR("kCTFontCSSFamilyMonospace");
const CFStringRef kCTFontCSSFamilySansSerif = CFSTR("kCTFontCSSFamilySansSerif");
const CFStringRef kCTFontCSSFamilySerif = CFSTR("kCTFontCSSFamilySerif");
const CFStringRef kCTFontCSSWeightAttribute = CFSTR("kCTFontCSSWeightAttribute");
const CFStringRef kCTFontCSSWidthAttribute = CFSTR("kCTFontCSSWidthAttribute");
const CFStringRef kCTFontContentSizeCategoryL = CFSTR("kCTFontContentSizeCategoryL");
const CFStringRef kCTFontDescriptorLanguageAttribute = CFSTR("kCTFontDescriptorLanguageAttribute");
const CFStringRef kCTFontDescriptorTextStyleAttribute = CFSTR("kCTFontDescriptorTextStyleAttribute");
const CFStringRef kCTFontFallbackOptionAttribute = CFSTR("kCTFontFallbackOptionAttribute");
const CFStringRef kCTFontGradeTrait = CFSTR("kCTFontGradeTrait");
const CFStringRef kCTFontIgnoreLegibilityWeightAttribute = CFSTR("kCTFontIgnoreLegibilityWeightAttribute");
const CFStringRef kCTFontPaletteAttribute = CFSTR("kCTFontPaletteAttribute");
const CFStringRef kCTFontPaletteColorsAttribute = CFSTR("kCTFontPaletteColorsAttribute");
const CFStringRef kCTFontSizeCategoryAttribute = CFSTR("kCTFontSizeCategoryAttribute");
const CFStringRef kCTFontTrackAttribute = CFSTR("kCTFontTrackAttribute");
const CFStringRef kCTFontUIFontDesignDefault = CFSTR("kCTFontUIFontDesignDefault");
const CFStringRef kCTFontUIFontDesignMonospaced = CFSTR("kCTFontUIFontDesignMonospaced");
const CFStringRef kCTFontUIFontDesignRounded = CFSTR("kCTFontUIFontDesignRounded");
const CFStringRef kCTFontUIFontDesignSerif = CFSTR("kCTFontUIFontDesignSerif");
const CFStringRef kCTFontUIFontDesignTrait = CFSTR("kCTFontUIFontDesignTrait");
// kCTFontVariationAxesAttribute (CoreText, macOS 10.13; absent on 10.9) is a key WebKit passes to
// CTFontDescriptorCopyAttribute on a *system* descriptor, so it needs CoreText's REAL value, not the
// symbol-name token. CoreText-native descriptor keys are "NSCT" + (name minus "kCT") — verified
// on-host across 15 sibling keys incl. the directly-analogous kCTFontVariationAttribute="NSCTFont
// VariationAttribute" — hence "NSCTFontVariationAxesAttribute". Behavior-neutral on 10.9 (an unknown
// key yields NULL, exactly the deployment-gated nullptr the call site previously returned).
const CFStringRef kCTFontVariationAxesAttribute = CFSTR("NSCTFontVariationAxesAttribute");
const CFStringRef kCTFontUnscaledTrackingAttribute = CFSTR("kCTFontUnscaledTrackingAttribute");
const CFStringRef kCTFontUserInstalledAttribute = CFSTR("kCTFontUserInstalledAttribute");
const CFStringRef kCTFontWeightBlack = CFSTR("kCTFontWeightBlack");
const CFStringRef kCTFontWeightBold = CFSTR("kCTFontWeightBold");
const CFStringRef kCTFontWeightHeavy = CFSTR("kCTFontWeightHeavy");
const CFStringRef kCTFontWeightLight = CFSTR("kCTFontWeightLight");
const CFStringRef kCTFontWeightMedium = CFSTR("kCTFontWeightMedium");
const CFStringRef kCTFontWeightRegular = CFSTR("kCTFontWeightRegular");
const CFStringRef kCTFontWeightSemibold = CFSTR("kCTFontWeightSemibold");
const CFStringRef kCTFontWeightThin = CFSTR("kCTFontWeightThin");
const CFStringRef kCTFontWeightUltraLight = CFSTR("kCTFontWeightUltraLight");
const CFStringRef kCTFontWidthCondensed = CFSTR("kCTFontWidthCondensed");
const CFStringRef kCTFontWidthExpanded = CFSTR("kCTFontWidthExpanded");
const CFStringRef kCTFontWidthExtraCompressed = CFSTR("kCTFontWidthExtraCompressed");
const CFStringRef kCTFontWidthExtraCondensed = CFSTR("kCTFontWidthExtraCondensed");
const CFStringRef kCTFontWidthExtraExpanded = CFSTR("kCTFontWidthExtraExpanded");
const CFStringRef kCTFontWidthSemiCondensed = CFSTR("kCTFontWidthSemiCondensed");
const CFStringRef kCTFontWidthSemiExpanded = CFSTR("kCTFontWidthSemiExpanded");
const CFStringRef kCTFontWidthStandard = CFSTR("kCTFontWidthStandard");
const CFStringRef kCTFontWidthUltraCompressed = CFSTR("kCTFontWidthUltraCompressed");
const CFStringRef kCTUIFontTextStyleBody = CFSTR("kCTUIFontTextStyleBody");
const CFStringRef kCTUIFontTextStyleCaption1 = CFSTR("kCTUIFontTextStyleCaption1");
const CFStringRef kCTUIFontTextStyleCaption2 = CFSTR("kCTUIFontTextStyleCaption2");
const CFStringRef kCTUIFontTextStyleFootnote = CFSTR("kCTUIFontTextStyleFootnote");
const CFStringRef kCTUIFontTextStyleHeadline = CFSTR("kCTUIFontTextStyleHeadline");
const CFStringRef kCTUIFontTextStyleShortBody = CFSTR("kCTUIFontTextStyleShortBody");
const CFStringRef kCTUIFontTextStyleShortCaption1 = CFSTR("kCTUIFontTextStyleShortCaption1");
const CFStringRef kCTUIFontTextStyleShortFootnote = CFSTR("kCTUIFontTextStyleShortFootnote");
const CFStringRef kCTUIFontTextStyleShortHeadline = CFSTR("kCTUIFontTextStyleShortHeadline");
const CFStringRef kCTUIFontTextStyleShortSubhead = CFSTR("kCTUIFontTextStyleShortSubhead");
const CFStringRef kCTUIFontTextStyleSubhead = CFSTR("kCTUIFontTextStyleSubhead");
const CFStringRef kCTUIFontTextStyleTallBody = CFSTR("kCTUIFontTextStyleTallBody");
const CFStringRef kCTUIFontTextStyleTitle0 = CFSTR("kCTUIFontTextStyleTitle0");
const CFStringRef kCTUIFontTextStyleTitle1 = CFSTR("kCTUIFontTextStyleTitle1");
const CFStringRef kCTUIFontTextStyleTitle2 = CFSTR("kCTUIFontTextStyleTitle2");
const CFStringRef kCTUIFontTextStyleTitle3 = CFSTR("kCTUIFontTextStyleTitle3");
const CFStringRef kCTUIFontTextStyleTitle4 = CFSTR("kCTUIFontTextStyleTitle4");
const CFStringRef kCUIWidgetSwitchBorder = CFSTR("kCUIWidgetSwitchBorder");
const CFStringRef kCUIWidgetSwitchFill = CFSTR("kCUIWidgetSwitchFill");
const CFStringRef kCUIWidgetSwitchFillMask = CFSTR("kCUIWidgetSwitchFillMask");
const CFStringRef kCUIWidgetSwitchKnob = CFSTR("kCUIWidgetSwitchKnob");
const CFStringRef kCUIWidgetSwitchOnOffLabel = CFSTR("kCUIWidgetSwitchOnOffLabel");
// kSCDynamicStorePropNetInterfaces is NOT defined here: 10.9 SystemConfiguration exports it
// (real value "Interfaces"); the name-string copy broke online/offline detection.
// NSHTTPCookie SameSite property key (NSString, 10.13+). WebKit only reads it behind a
// respondsToSelector(@selector(sameSitePolicy)) guard that fails on 10.9, so it is never dereferenced;
// defined here so the weak import resolves rather than dangling.
const CFStringRef NSHTTPCookieSameSitePolicy = CFSTR("SameSitePolicy");

// NSError userInfo key NSLocalizedFailureErrorKey (NSString, 10.13+). CoreIPCError reads and writes
// it when round-tripping NSErrors over IPC. REAL Foundation value, not the name-string: the key is
// interpreted by -[NSError localizedDescription] on OSes that know it, and both IPC sides must agree.
const CFStringRef NSLocalizedFailureErrorKey = CFSTR("NSLocalizedFailure");

// SecTrustCopyCertificateChain (Security, 12.0+): rebuild the evaluated chain via the per-index
// accessors 10.9 ships. CANONICAL definition (was duplicated in graphics_shims.c and
// legacy-support/security.c). It must live in THIS object: callers reference the symbol as a WEAK
// import (12.0+ availability), and weak references do not pull archive members — the definition is
// only seen because every target's link already pulls const_polyfill.o for the constants above.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
CFArrayRef SecTrustCopyCertificateChain(SecTrustRef trust) {
    if (!trust)
        return NULL;
    CFIndex count = SecTrustGetCertificateCount(trust);
    if (count <= 0)
        return NULL;
    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    if (!chain)
        return NULL;
    for (CFIndex i = 0; i < count; i++) {
        SecCertificateRef cert = SecTrustGetCertificateAtIndex(trust, i);
        if (cert)
            CFArrayAppendValue(chain, cert);
    }
    return chain;
}
#pragma clang diagnostic pop

// os_feature_enabled(domain, feature) — libSystem feature-flag query (10.13+). Every WebKit call site
// gates a feature that postdates 10.9 (VisualIntelligence/Translate/TextComposer post-editing/the
// redesigned text cursor), so the faithful answer on this OS is "not enabled".
bool _os_feature_enabled_impl(const char *domain, const char *feature)
{
    (void)domain;
    (void)feature;
    return false;
}
