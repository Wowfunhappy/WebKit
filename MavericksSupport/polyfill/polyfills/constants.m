// Every data constant the polyfill layer defines: the CFString / NSString keys, notification names
// and numeric values modern WebKit references and the 10.9 frameworks do not export. Most are a
// CFString whose value is its own name: a unique token used as a dictionary key or identifier that
// the 10.9 frameworks predate and never interpret, so the exact string is immaterial. Where a value
// IS interpreted by the system, the comment says so and gives the real one.
//
// Declaring a constant here asserts 10.9 LACKS the symbol; the declared value is what WebKit gets, with
// no mirroring. If 10.9 turns out to export it, the build gate (check-polyfill-shadows.sh) rejects the
// declaration — delete it, or use WK_POLYFILL_CONST_REPLACES to override a present one on purpose. So a
// placeholder can never silently shadow a value the system interprets, and absence is proven at build
// rather than assumed.
//
// Two functions live here too, at the end: TCCAccessPreflight and its audit-token spelling, kept
// beside the TCC service identifiers, whose value-is-their-own-name invariant is what they answer by.
#include "wk_polyfill.h"

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>        // task_info/mach_task_self, for the TCC audit-token entry point
#include <mach/mach_port.h>
#include <mach/message.h>     // audit_token_t, for the TCC entry points at the end
#include <mach/task_info.h>   // TASK_AUDIT_TOKEN
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// The 10.9 CoreText headers declare kCTFontDownloadedAttribute CT_AVAILABLE_IOS(7_0) — unavailable on
// macOS — and merely naming an unavailable symbol is a hard error with no -W group to disable, which
// the registry entry's &name triggers. Re-declare it as available so the polyfill can own the name.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wavailability"
extern const CFStringRef kCTFontDownloadedAttribute __attribute__((availability(macos, introduced=10.0)));
#pragma clang diagnostic pop

// WK_POLYFILL_CONST spells the type ahead of the name ("const TYPE NAME"), so a pointer constant
// needs a typedef for the const to land on the POINTER — the "NSString * const" / "const char * const"
// shape the SDK declares these with, rather than a pointer to const.
typedef NSString *PolyNSStringConst;
typedef const char *PolyCStringConst;

WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceDifferentiateWithoutColorKey, CFSTR("kAXInterfaceDifferentiateWithoutColorKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceIncreaseContrastKey, CFSTR("kAXInterfaceIncreaseContrastKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXInterfaceReduceMotionKey, CFSTR("kAXInterfaceReduceMotionKey"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXSAccessibilityPreferenceDomain, CFSTR("kAXSAccessibilityPreferenceDomain"));
WK_POLYFILL_CONST("ApplicationServices", CFStringRef, kAXSEnhanceTextLegibilityChangedNotification, CFSTR("kAXSEnhanceTextLegibilityChangedNotification"));
WK_POLYFILL_CONST("CFNetwork", CFStringRef, kCFURLRequestContentDecoderSkipURLCheck, CFSTR("kCFURLRequestContentDecoderSkipURLCheck"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceGenericXYZ, CFSTR("kCGColorSpaceGenericXYZ"));
// kCGColorSpaceExtendedRange (SDK-declared, macOS 10.12+; ABSENT on the 10.9 runtime CoreGraphics).
// WebKit2's CoreIPCCGColorSpace::toCF() references it (upstream, in the extended-range-ICC deserialize
// branch). It is a DATA constant, which does NOT auto-weak-link, so a bare reference makes WebKit2
// fail to load on 10.9 (dyld: Symbol not found: _kCGColorSpaceExtendedRange). Define it here so the
// reference binds to the polyfill. The value is immaterial: that branch is DEAD on 10.9 (the serialize
// side never emits an extended-range derivative — CopyPropertyList returns CFData/NULL, never a dict).
// The sibling keys (kCGColorSpaceICCData/kCGIndexed* etc.) are NOT here — upstream defines those
// `static` in CoreIPCCGColorSpace.h, so they carry no dyld reference.
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedRange, CFSTR("kCGColorSpaceExtendedRange"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGGradientInterpolatesPremultiplied, CFSTR("kCGGradientInterpolatesPremultiplied"));
// kCGImagePropertyWebPDictionary (ImageIO, macOS 11.0) is a key WebKit passes to
// CFDictionaryGetValue on a *system-provided* CGImageSource properties dict — so unlike the
// round-tripped token keys above, its value must be ImageIO's REAL value, not the symbol
// name. ImageIO's per-format dictionary keys are "{TYPE}" with
// the format's canonical mixed casing (verified on-host across 20 sibling keys: {GIF} {PNG} {Exif}
// {ExifAux} {MakerApple} …), so WebP is "{WebP}". Behavior-neutral on 10.9 (that ImageIO has no WebP
// animation dict, so the lookup returns NULL and the caller falls through to the PNG dict either way).
WK_POLYFILL_CONST("ImageIO", CFStringRef, kCGImagePropertyWebPDictionary, CFSTR("{WebP}"));
WK_POLYFILL_CONST("ImageIO", CFStringRef, kCGImageSourceUseHardwareAcceleration, CFSTR("kCGImageSourceUseHardwareAcceleration"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilyCursive, CFSTR("kCTFontCSSFamilyCursive"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilyFantasy, CFSTR("kCTFontCSSFamilyFantasy"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilyMonospace, CFSTR("kCTFontCSSFamilyMonospace"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilySansSerif, CFSTR("kCTFontCSSFamilySansSerif"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilySerif, CFSTR("kCTFontCSSFamilySerif"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSWeightAttribute, CFSTR("kCTFontCSSWeightAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSWidthAttribute, CFSTR("kCTFontCSSWidthAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontContentSizeCategoryL, CFSTR("kCTFontContentSizeCategoryL"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontDescriptorLanguageAttribute, CFSTR("kCTFontDescriptorLanguageAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontDescriptorTextStyleAttribute, CFSTR("kCTFontDescriptorTextStyleAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontFallbackOptionAttribute, CFSTR("kCTFontFallbackOptionAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontGradeTrait, CFSTR("kCTFontGradeTrait"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontIgnoreLegibilityWeightAttribute, CFSTR("kCTFontIgnoreLegibilityWeightAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontPaletteAttribute, CFSTR("kCTFontPaletteAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontPaletteColorsAttribute, CFSTR("kCTFontPaletteColorsAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontSizeCategoryAttribute, CFSTR("kCTFontSizeCategoryAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontTrackAttribute, CFSTR("kCTFontTrackAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUIFontDesignDefault, CFSTR("kCTFontUIFontDesignDefault"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUIFontDesignMonospaced, CFSTR("kCTFontUIFontDesignMonospaced"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUIFontDesignRounded, CFSTR("kCTFontUIFontDesignRounded"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUIFontDesignSerif, CFSTR("kCTFontUIFontDesignSerif"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUIFontDesignTrait, CFSTR("kCTFontUIFontDesignTrait"));
// kCTFontVariationAxesAttribute (CoreText, macOS 10.13; absent on 10.9) is a key WebKit passes to
// CTFontDescriptorCopyAttribute on a *system* descriptor, so it needs CoreText's REAL value, not the
// symbol-name token. CoreText-native descriptor keys are "NSCT" + (name minus "kCT") — verified
// on-host across 15 sibling keys incl. the directly-analogous kCTFontVariationAttribute="NSCTFont
// VariationAttribute" — hence "NSCTFontVariationAxesAttribute". Behavior-neutral on 10.9 (an unknown
// key yields NULL, exactly the deployment-gated nullptr the call site previously returned).
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontVariationAxesAttribute, CFSTR("NSCTFontVariationAxesAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUnscaledTrackingAttribute, CFSTR("kCTFontUnscaledTrackingAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUserInstalledAttribute, CFSTR("kCTFontUserInstalledAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightBlack, CFSTR("kCTFontWeightBlack"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightBold, CFSTR("kCTFontWeightBold"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightHeavy, CFSTR("kCTFontWeightHeavy"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightLight, CFSTR("kCTFontWeightLight"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightMedium, CFSTR("kCTFontWeightMedium"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightRegular, CFSTR("kCTFontWeightRegular"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightSemibold, CFSTR("kCTFontWeightSemibold"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightThin, CFSTR("kCTFontWeightThin"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWeightUltraLight, CFSTR("kCTFontWeightUltraLight"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthCondensed, CFSTR("kCTFontWidthCondensed"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthExpanded, CFSTR("kCTFontWidthExpanded"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthExtraCompressed, CFSTR("kCTFontWidthExtraCompressed"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthExtraCondensed, CFSTR("kCTFontWidthExtraCondensed"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthExtraExpanded, CFSTR("kCTFontWidthExtraExpanded"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthSemiCondensed, CFSTR("kCTFontWidthSemiCondensed"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthSemiExpanded, CFSTR("kCTFontWidthSemiExpanded"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthStandard, CFSTR("kCTFontWidthStandard"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontWidthUltraCompressed, CFSTR("kCTFontWidthUltraCompressed"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleBody, CFSTR("kCTUIFontTextStyleBody"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleCaption1, CFSTR("kCTUIFontTextStyleCaption1"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleCaption2, CFSTR("kCTUIFontTextStyleCaption2"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleFootnote, CFSTR("kCTUIFontTextStyleFootnote"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleHeadline, CFSTR("kCTUIFontTextStyleHeadline"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortBody, CFSTR("kCTUIFontTextStyleShortBody"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortCaption1, CFSTR("kCTUIFontTextStyleShortCaption1"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortFootnote, CFSTR("kCTUIFontTextStyleShortFootnote"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortHeadline, CFSTR("kCTUIFontTextStyleShortHeadline"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortSubhead, CFSTR("kCTUIFontTextStyleShortSubhead"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleSubhead, CFSTR("kCTUIFontTextStyleSubhead"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTallBody, CFSTR("kCTUIFontTextStyleTallBody"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle0, CFSTR("kCTUIFontTextStyleTitle0"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle1, CFSTR("kCTUIFontTextStyleTitle1"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle2, CFSTR("kCTUIFontTextStyleTitle2"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle3, CFSTR("kCTUIFontTextStyleTitle3"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle4, CFSTR("kCTUIFontTextStyleTitle4"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchBorder, CFSTR("kCUIWidgetSwitchBorder"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchFill, CFSTR("kCUIWidgetSwitchFill"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchFillMask, CFSTR("kCUIWidgetSwitchFillMask"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchKnob, CFSTR("kCUIWidgetSwitchKnob"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", CFStringRef, kCUIWidgetSwitchOnOffLabel, CFSTR("kCUIWidgetSwitchOnOffLabel"));
// NSHTTPCookie SameSite property key (NSString, 10.13+). WebKit only reads it behind a
// respondsToSelector(@selector(sameSitePolicy)) guard that fails on 10.9, so it is never dereferenced.
WK_POLYFILL_CONST("Foundation", CFStringRef, NSHTTPCookieSameSitePolicy, CFSTR("SameSitePolicy"));

// NSError userInfo key NSLocalizedFailureErrorKey (NSString, 10.13+). CoreIPCError reads and writes
// it when round-tripping NSErrors over IPC. REAL Foundation value, not the name-string: the key is
// interpreted by -[NSError localizedDescription] on OSes that know it, and both IPC sides must agree.
WK_POLYFILL_CONST("Foundation", CFStringRef, NSLocalizedFailureErrorKey, CFSTR("NSLocalizedFailure"));

// ---------------------------------------------------------------------------------------------
// CoreMedia format-description constants (below).
//
// 10.9's CoreMedia exports exactly ONE of the colour-description constants modern WebKit uses
// (kCMFormatDescriptionColorPrimaries_P22); the other 60 CFStringRefs PAL soft-links are absent —
// runtime-verified by dlopen'ing CoreMedia and dlsym'ing all 111 names PAL declares, which is
// precisely what SOFT_LINK_CONSTANT does. That macro is unconditional: it RELEASE_ASSERTs the
// moment a missing constant is first read, so e.g. Google Meet killed the WebContent process
// within seconds of enabling the camera (canvas.captureStream -> WebGL surfaceBufferToVideoFrame
// -> VideoFrameCV::create -> computeVideoFrameColorSpace -> ...ColorPrimaries_DCI_P3). Defining
// them here makes the soft-link resolve instead of trapping.
//
// Two value regimes, same rule as the CoreText/ImageIO keys above — a value the SYSTEM interprets
// must be the real one; a value only round-tripped through our own code may be a unique token.
//
// (1) REAL values. Every constant in this group is a documented synonym of a CoreVideo constant
// that 10.9 DOES export, and the value was read off this host rather than assumed
// (kCVImageBufferColorPrimaries_ITU_R_709_2 == "ITU_R_709_2", ...PixelAspectRatioKey ==
// "CVPixelAspectRatio", and so on). They are load-bearing in both directions: WebCore compares
// them against attachments 10.9's CoreVideo/VideoToolbox put on pixel buffers, and
// setVideoFrameColorSpace() writes them back as attachment values that 10.9 then interprets.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_ColorPrimaries, CFSTR("CVImageBufferColorPrimaries"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_TransferFunction, CFSTR("CVImageBufferTransferFunction"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_YCbCrMatrix, CFSTR("CVImageBufferYCbCrMatrix"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_PixelAspectRatio, CFSTR("CVPixelAspectRatio"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing, CFSTR("HorizontalSpacing"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing, CFSTR("VerticalSpacing"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_ITU_R_709_2, CFSTR("ITU_R_709_2"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_EBU_3213, CFSTR("EBU_3213"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_SMPTE_C, CFSTR("SMPTE_C"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_ITU_R_709_2, CFSTR("ITU_R_709_2"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995, CFSTR("SMPTE_240M_1995"));

// (2) Colour identifiers whose CoreVideo twins are ALSO absent on 10.9 (wide gamut, HDR, and the
// bit-depth key). Nothing on this OS emits or understands them, so the value cannot round-trip
// through the system either way — but they follow the identical, fully regular naming the group
// above was verified against (the identifier is the name's suffix: "ITU_R_709_2", "SMPTE_C",
// "P22", "SMPTE_240M_1995", "UseGamma" ...), so the real values are used rather than tokens. That
// keeps the classification in computeVideoFrameColorSpace() correct if a frame ever does arrive
// tagged by non-system code, and costs nothing if none does.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_DCI_P3, CFSTR("DCI_P3"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_P3_D65, CFSTR("P3_D65"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionColorPrimaries_ITU_R_2020, CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_ITU_R_2020, CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, CFSTR("SMPTE_ST_2084_PQ"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, CFSTR("ITU_R_2100_HLG"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_Linear, CFSTR("Linear"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1, CFSTR("SMPTE_ST_428_1"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMFormatDescriptionExtension_BitsPerComponent, CFSTR("BitsPerComponent"));

// (3) The two sample-attachment keys that are genuinely LIVE on this build. WebCore WRITES both
// into a CMSampleBuffer's attachments dictionary that it then hands to the system
// (CMUtilities.mm:561 and :598), so a name-string token would be a fabricated value inside a
// system-interpreted structure -- these need the real ones. The kCMSampleAttachmentKey_* naming
// rule was verified on this host across eight siblings that 10.9 DOES export (NotSync ==
// "NotSync", DoNotDisplay == "DoNotDisplay", IsDependedOnByOthers == "IsDependedOnByOthers",
// DependsOnOthers, HasRedundantCoding, DisplayImmediately, and the CMSampleBufferAttachmentKey_
// pair TrimDurationAtStart / EmptyMedia): the value is the name's suffix, verbatim.
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMSampleAttachmentKey_HDR10PlusPerFrameData, CFSTR("HDR10PlusPerFrameData"));
WK_POLYFILL_CONST("CoreMedia", CFStringRef, kCMSampleAttachmentKey_CryptorSubsampleAuxiliaryData, CFSTR("CryptorSubsampleAuxiliaryData"));

// NOT defined here, deliberately: the stereoscopic / immersive-video / per-lens camera-calibration
// keys. Every reference to them in FormatDescriptionUtilities.cpp sits inside
// #if HAVE(IMMERSIVE_VIDEO_METADATA_SUPPORT), which requires a 16.0 deployment target and is OFF on
// this 10.9 build (verified by walking the guard regions), so they can never be dlsym'd -- exactly
// the reasoning that keeps the four absent kCMTag* constants out too. Defining them with invented
// values would be worse than omitting them: FormatDescriptionUtilities.cpp bare-references those
// names, so enabling the flag would silently bind live code to fake keys with no diagnostic.

// kCTFontOpenTypeFeatureTag / ...Value (10.10 SDK) are the CFDictionary keys for OpenType font features.
// They have no 10.9 symbol; building a feature dictionary with a NULL key would crash CFDictionary, so
// define them with CoreText's documented key strings. (10.9 CoreText may not honor the new-style feature
// dictionary, but the code links and runs without crashing.)
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontOpenTypeFeatureTag, CFSTR("CTFeatureOpenTypeTag"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontOpenTypeFeatureValue, CFSTR("CTFeatureOpenTypeValue"));

// QuartzCore/CoreText string constants with no 10.9 symbol. Define them non-NULL (documented values) so
// the corner-curve / downloaded-font features degrade gracefully and never feed a NULL key to a
// CFDictionary/CTFontDescriptor (which would crash). 10.9 won't honor the values, which is fine.
WK_POLYFILL_CONST("QuartzCore", CFStringRef, kCACornerCurveCircular, CFSTR("circular"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontDownloadedAttribute, CFSTR("kCTFontDownloadedAttribute"));

// CoreVideo color-space constants added in 10.11 / 10.13 (referenced by the bundled libwebrtc H.264/
// H.265 decoders, and by GStreamer's video plugins, to tag HDR / wide-gamut frames). Absent on 10.9;
// provide the canonical CFString values so the dependent code links and never feeds a NULL key/value
// into a CoreVideo attachment dictionary.
WK_POLYFILL_CONST("CoreVideo", CFStringRef, kCVImageBufferColorPrimaries_ITU_R_2020,         CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreVideo", CFStringRef, kCVImageBufferColorPrimaries_P3_D65,             CFSTR("P3_D65"));
WK_POLYFILL_CONST("CoreVideo", CFStringRef, kCVImageBufferColorPrimaries_DCI_P3,             CFSTR("DCI_P3"));
WK_POLYFILL_CONST("CoreVideo", CFStringRef, kCVImageBufferTransferFunction_ITU_R_2020,       CFSTR("ITU_R_2020"));
WK_POLYFILL_CONST("CoreVideo", CFStringRef, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, CFSTR("SMPTE_ST_2084_PQ"));
WK_POLYFILL_CONST("CoreVideo", CFStringRef, kCVImageBufferTransferFunction_sRGB,             CFSTR("IEC_sRGB"));
WK_POLYFILL_CONST("CoreVideo", CFStringRef, kCVImageBufferYCbCrMatrix_ITU_R_2020,            CFSTR("ITU_R_2020"));

#pragma mark - NSPopUpMenu constants
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonBounds, @"NSPopUpMenuPopupButtonBounds");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonOrigin, @"NSPopUpMenuPopupButtonOrigin");

#pragma mark - NSTouchBar notifications
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTouchBarDidExitCustomization, @"NSTouchBarDidExitCustomization");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTouchBarWillEnterCustomization, @"NSTouchBarWillEnterCustomization");

#pragma mark - CGColorSpace name constants (10.11.2+)
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceDisplayP3, CFSTR("kCGColorSpaceDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedSRGB, CFSTR("kCGColorSpaceExtendedSRGB"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceLinearSRGB, CFSTR("kCGColorSpaceLinearSRGB"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedLinearSRGB, CFSTR("kCGColorSpaceExtendedLinearSRGB"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedDisplayP3, CFSTR("kCGColorSpaceExtendedDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceLinearDisplayP3, CFSTR("kCGColorSpaceLinearDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedLinearDisplayP3, CFSTR("kCGColorSpaceExtendedLinearDisplayP3"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceITUR_2020, CFSTR("kCGColorSpaceITUR_2020"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceExtendedITUR_2020, CFSTR("kCGColorSpaceExtendedITUR_2020"));
WK_POLYFILL_CONST("CoreGraphics", CFStringRef, kCGColorSpaceROMMRGB, CFSTR("kCGColorSpaceROMMRGB"));

#pragma mark - IOSurface property keys (10.12+)
// kIOSurfaceName is the debug/identification name key IOSurface::optionsForSurface() adds to every
// surface-creation options dictionary (Source/WebCore/platform/graphics/cocoa/IOSurface.mm). It is
// 10.12+ and absent from 10.9's IOSurface.framework (every OTHER key that dictionary uses —
// kIOSurfaceWidth/Height/PixelFormat/BytesPerElement/BytesPerRow/AllocSize/ElementHeight — is present),
// so reading the absent extern under -undefined dynamic_lookup faulted on a null GOT load, SIGSEGVing
// WebContent inside WebGL/accelerated-canvas drawing-buffer allocation. It only labels the surface;
// IOSurfaceCreate ignores unknown keys on 10.9, so a valid CFString key restores creation with no
// behavioural change. The value matches the modern constant.
WK_POLYFILL_CONST("IOSurface", CFStringRef, kIOSurfaceName, CFSTR("IOSurfaceName"));

#pragma mark - NSText constants (10.12+)
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextCheckingInsertionPointKey, @"NSTextCheckingInsertionPointKey");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextCheckingSuppressInitialCapitalizationKey, @"NSTextCheckingSuppressInitialCapitalizationKey");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSTextInsertionUndoableAttributeName, @"NSTextInsertionUndoableAttributeName");

#pragma mark - Additional NSPopUpMenu constants
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonLabelOffset, @"NSPopUpMenuPopupButtonLabelOffset");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonSize, @"NSPopUpMenuPopupButtonSize");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPopUpMenuPopupButtonWidget, @"NSPopUpMenuPopupButtonWidget");

// 10.9 backport: kVTVideoEncoderSpecification_RequiredLowLatency is a 10.13+
// VideoToolbox encoder-spec key. libwebrtc's VTB H.264/VP9 encoder (built with
// ENABLE_WEB_RTC) references it; WebCore resolves it via flat-namespace dynamic
// lookup, so without a definition dyld aborts Safari at launch ("Symbol not
// found: _kVTVideoEncoderSpecification_RequiredLowLatency"). Provide the real
// CFString value; on 10.9 the encoder simply ignores this unknown spec key.
WK_POLYFILL_CONST("VideoToolbox", CFStringRef, kVTVideoEncoderSpecification_RequiredLowLatency, CFSTR("RequiredLowLatency"));

#pragma mark - macOS 26.1 SDK symbols absent on the 10.9 runtime
// The 26.1 build SDK declares these but the 10.9 frameworks do not export them.
// The features are unused or inert on 10.9, so only the SYMBOL needs to exist
// with the right type; the values are low-stakes.

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
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardNameGeneral, @"Apple CFPasteboard general");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardNameFind, @"Apple CFPasteboard find");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardNameFont, @"Apple CFPasteboard font");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardNameDrag, @"Apple CFPasteboard drag");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardTypeURL, @"public.url");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSPasteboardTypeFileURL, @"public.file-url");

// --- CoreAnimation CAFilter HSL (non-separable) blend-mode names (10.10+) -----------------
// 10.9's QuartzCore has the separable blend modes (multiply/overlay/screen/...) but not the four HSL
// ones (CSS mix-blend-mode: hue/saturation/color/luminosity). PlatformCAFiltersCocoa references all of
// them; define the missing four so it links. 10.9's CoreAnimation does not implement these filters, so
// CAFilter rejects the unknown name and the blend degrades to normal compositing — the separable modes
// (which 10.9 does support) are unaffected.
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterHueBlendMode, @"hueBlendMode");
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterSaturationBlendMode, @"saturationBlendMode");
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterColorBlendMode, @"colorBlendMode");
WK_POLYFILL_CONST("QuartzCore", PolyNSStringConst, kCAFilterLuminosityBlendMode, @"luminosityBlendMode");

// --- XPC activity keys added after 10.9 (referenced via WTF XPCSPI.h) ----------------------
// 10.9's libxpc has the other XPC_ACTIVITY_* criteria keys but not these two; 10.9's xpc_activity
// ignores an unknown criterion, so the activity simply runs without that requirement.
WK_POLYFILL_CONST(NULL, PolyCStringConst, XPC_ACTIVITY_REQUIRE_NETWORK_CONNECTIVITY, "RequireNetworkConnectivity");
WK_POLYFILL_CONST(NULL, PolyCStringConst, XPC_ACTIVITY_RANDOM_INITIAL_DELAY, "RandomInitialDelay");

// --- Other AppKit / Foundation string constants --------------------------
// The dark-appearance names. An NSAppearance name's value is its own spelling, which is what
// -bestMatchFromAppearancesWithNames: compares against, so each is supplied under that spelling.
// WebExtensionCocoa.mm collects all four into an @[] literal, and an array literal raises on a nil
// element, so a name missing here takes down the extension icon path rather than degrading it.
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameDarkAqua, @"NSAppearanceNameDarkAqua");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameVibrantDark, @"NSAppearanceNameVibrantDark");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameAccessibilityHighContrastDarkAqua, @"NSAppearanceNameAccessibilityHighContrastDarkAqua");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSAppearanceNameAccessibilityHighContrastVibrantDark, @"NSAppearanceNameAccessibilityHighContrastVibrantDark");
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSPresentationIntentAttributeName, @"NSPresentationIntent");
// NSURLContentTypeKey (Foundation, 11.0+): the resource key answered with a UTType. 10.9's Foundation
// does not interpret it; the NSURL getResourceValue:forKey:error: polyfill (methods.m) recognizes this
// key and answers it from the classic NSURLTypeIdentifierKey.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSURLContentTypeKey, @"NSURLContentTypeKey");
WK_POLYFILL_CONST("AppKit", PolyNSStringConst, NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification, @"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification");
// NSProcessInfoPowerStateDidChangeNotification (Foundation, 10.12+): the Low Power Mode change
// notification. A unique name used only to register and match an observer; nothing on 10.9 posts it,
// so the observer never fires. Paired with -[NSProcessInfo isLowPowerModeEnabled] in methods.m.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSProcessInfoPowerStateDidChangeNotification, @"NSProcessInfoPowerStateDidChangeNotification");
// NSLanguageIdentifierAttributeName (Foundation, macos(12.0); absent on 10.9) is Foundation's public
// name for the long-standing NSAttributedString/CoreText language attribute. Its runtime value is
// PROVABLY @"NSLanguage": on 10.9, kCTLanguageAttributeName (present, the single CoreText language
// key) reads as "NSLanguage" (verified on-host), and Foundation's constant must resolve to the same
// key to influence CoreText layout. WebKit already uses kCTLanguageAttributeName directly elsewhere.
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSLanguageIdentifierAttributeName, @"NSLanguage");

// --- NSHTTPCookie SameSite policy constants (10.15+) ----------------------
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSHTTPCookieSameSiteLax, @"lax");
WK_POLYFILL_CONST("Foundation", PolyNSStringConst, NSHTTPCookieSameSiteStrict, @"strict");

// --- NSURLSessionTask priority constants (float, macos(10.10)) -----------
// Absent on 10.9's Foundation/CFNetwork. WebKit uses them as plain KVC float
// values (NetworkSessionCocoa/NetworkDataTaskCocoa). The values are the
// documented modern defaults, correct for any caller.
WK_POLYFILL_CONST("Foundation", float, NSURLSessionTaskPriorityDefault, 0.5f);
WK_POLYFILL_CONST("Foundation", float, NSURLSessionTaskPriorityLow, 0.0f);
WK_POLYFILL_CONST("Foundation", float, NSURLSessionTaskPriorityHigh, 1.0f);

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

#pragma mark - IOKit

// kIOMainPortDefault (12.0) is the current name of kIOMasterPortDefault, which 10.9 does ship. Both
// are the same value — MACH_PORT_NULL, the "use the default master port" sentinel IOKit resolves
// internally — so the rename is the whole of the difference.
WK_POLYFILL_CONST("IOKit", mach_port_t, kIOMainPortDefault, 0);

#pragma mark - os_log

// _os_log_default is the storage behind OS_LOG_DEFAULT (10.12+). Call sites only ever take its
// ADDRESS and hand that to _os_log_internal / _os_log_impl, which on 10.9 ignore the log handle
// (see runtime.m), so nothing reads the storage — it exists so that taking its address yields a
// valid, stable pointer rather than dereferencing a NULL weak import.
static struct { int unused; } wkOSLogDefaultStorage;
typedef void *PolyVoidPtrConst;
WK_POLYFILL_CONST(NULL, PolyVoidPtrConst, _os_log_default, &wkOSLogDefaultStorage);

#pragma mark - Security (10.12+)

// Key-type and keychain attribute values. kSecAttrKeyTypeECSECPrimeRandom is the CFNumber-shaped
// string "73" — Security's algorithm id for ECDSA/EC keys (CSSM_ALGID_ECDSA), which is the value
// keychain queries are matched against.
WK_POLYFILL_CONST("Security", CFStringRef, kSecAttrKeyTypeECSECPrimeRandom, CFSTR("73"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecUseDataProtectionKeychain, CFSTR("u-DataProtectionKeychain"));

// SecKeyAlgorithm identifiers (10.12+). Each is Security's documented "algid:..." string, the value
// SecKey* functions parse to select padding and digest. They are used as opaque selectors here
// (10.9's Security has no SecKey algorithm API — see the SecKey entry points in system-spi.m), so
// the strings only need to be the real ones for any caller that compares them.
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDHKeyExchangeStandard, CFSTR("algid:ecdh:standard"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmECDSASignatureDigestX962, CFSTR("algid:ecdsa:digest-x962"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA1, CFSTR("algid:encrypt:RSA:OAEP-SHA1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA256, CFSTR("algid:encrypt:RSA:OAEP-SHA256"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA384, CFSTR("algid:encrypt:RSA:OAEP-SHA384"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionOAEPSHA512, CFSTR("algid:encrypt:RSA:OAEP-SHA512"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionPKCS1, CFSTR("algid:encrypt:RSA:PKCS1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSAEncryptionRaw, CFSTR("algid:encrypt:RSA:raw"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA256"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA384, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA384"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA512, CFSTR("algid:sign:RSA:digest-PKCS1v15:SHA512"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA1, CFSTR("algid:sign:RSA:digest-PSS:SHA1"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA256, CFSTR("algid:sign:RSA:digest-PSS:SHA256"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA384, CFSTR("algid:sign:RSA:digest-PSS:SHA384"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureDigestPSSSHA512, CFSTR("algid:sign:RSA:digest-PSS:SHA512"));
WK_POLYFILL_CONST("Security", CFStringRef, kSecKeyAlgorithmRSASignatureRaw, CFSTR("algid:sign:RSA:raw"));

// --- TCC (Transparency, Consent and Control) service identifiers ---------
//
// TCC is a private framework, so the provider is spelled as a path. Per-application camera and
// microphone gating arrived in macOS 10.14 and photo-library and cross-website-tracking gating later
// still, so 10.9's TCC exports none of those four identifiers. Its own set is thirteen:
// Accessibility, AddressBook, All, Calendar, Location, Reminders, Ubiquity and the six
// social-network ones (Facebook, LinkedIn, Liverpool, SinaWeibo, TencentWeibo, Twitter).
//
// A TCC identifier's value IS its own name on every macOS -- read off all thirteen of 10.9's on this
// host -- so these carry the same CFStrings the system framework would, and that same invariant is
// what lets mav_tccImplementsService below turn any service string back into the symbol name that
// would name it.
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServiceCamera, CFSTR("kTCCServiceCamera"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServiceMicrophone, CFSTR("kTCCServiceMicrophone"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServicePhotos, CFSTR("kTCCServicePhotos"));
WK_POLYFILL_CONST("/System/Library/PrivateFrameworks/TCC.framework/TCC", CFStringRef, kTCCServiceWebKitIntelligentTrackingPrevention, CFSTR("kTCCServiceWebKitIntelligentTrackingPrevention"));

// The two functions in this file, kept beside the identifiers they take as their argument.
//
// 10.9 HAS TCCAccessPreflight, and it fails closed: handed a service it does not know it returns
// Denied (measured on this host). There is no per-app camera, microphone, photo-library or
// cross-website-tracking gating on 10.9 at all, so "denied" is not an answer the system ever meant
// to give for those: it is the absence of the question. UserMediaPermissionRequestManagerProxy
// compares against kTCCAccessPreflightGranted, so left alone this silently disables getUserMedia.
//
// What separates a service 10.9 gates from one it merely does not recognise is not a list kept here:
// 10.9's TCC implements exactly the services whose identifier constants it exports. So ask its
// export table, and answer Granted only where the question does not exist on this OS.

// Mirrors TCCAccessPreflightResult and its enumerators in <TCC/TCC.h>, as PAL's TCCSPI.h declares
// them for WebKit's side of the same call.
typedef int TCCAccessPreflightResult;
enum {
    kTCCAccessPreflightGranted = 0,
    kTCCAccessPreflightDenied = 1,
    kTCCAccessPreflightUnknown = 2,
};

// Does 10.9's TCC implement this service, i.e. does it export the service's identifier constant?
//
// No service is named here, and none is answered for from this file. A service identifier's VALUE is
// its own name (the invariant the constants above rest on, measured across all thirteen identifiers
// 10.9's TCC exports), so the string a caller hands in is also the symbol name that would name it in
// TCC's export table. Asking that table is the whole of the test, which is what makes the answer
// right for a service nobody here anticipated -- AddressBook, Calendar, Location, Reminders and
// Ubiquity are gated on 10.9 and reach TCC's own verdict by exactly the same route Camera and
// Microphone take to Granted.
//
// The lookup goes through wk_polyfill_system_symbol rather than dlsym on purpose: this layer answers
// dlsym for a polyfilled name with OUR storage, so that WebKit's soft-linking sees what the linker
// sees -- which would make every identifier this file polyfills look present. wk_polyfill_system_symbol
// reaches the real one.
//
// Which way an unrecognised string falls matters, so it falls the safe way: a string that cannot BE
// a symbol name is reported unimplemented (there is no gate, so the answer is Granted), while a
// string that happens to name some other TCC export is reported implemented and gets TCC's own
// verdict, which for a service it does not know is Denied. Only "no such export" can produce
// Granted, and that is exactly the case where 10.9 has no gate to consult.
static bool mav_tccImplementsService(CFStringRef service)
{
    if (!service)
        return false;

    // A symbol name is ASCII and fixed-length, so a conversion that fits and whose result is as long
    // as the string rules out both non-ASCII and an embedded NUL -- the latter would otherwise
    // truncate to a shorter name that may well exist.
    char name[128];
    if (!CFStringGetCString(service, name, sizeof name, kCFStringEncodingASCII))
        return false;
    if ((CFIndex)strlen(name) != CFStringGetLength(service))
        return false;
    for (const char *c = name; *c; c++) {
        bool identifierCharacter = (*c >= 'A' && *c <= 'Z') || (*c >= 'a' && *c <= 'z')
            || (*c >= '0' && *c <= '9') || *c == '_';
        if (!identifierCharacter)
            return false;
    }

    // The name is the caller's, so there is no fixed slot to cache it in and the lookup is made per
    // call. A preflight runs when something asks for a capability, not in a loop.
    void *cache = NULL;
    return wk_polyfill_system_symbol("/System/Library/PrivateFrameworks/TCC.framework/TCC",
                                     name, &cache) != NULL;
}

// This process's own audit token. Two tokens name the same process exactly when they are equal: a
// token carries auid, euid, egid, ruid, rgid, pid, session id and pid version, all fixed for the
// life of the process.
static bool mav_ownAuditToken(audit_token_t *out)
{
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    return task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)out, &count) == KERN_SUCCESS
        && count == TASK_AUDIT_TOKEN_COUNT;
}

WK_POLYFILL_REPLACES("/System/Library/PrivateFrameworks/TCC.framework/TCC", TCCAccessPreflightResult, TCCAccessPreflight,
                     (CFStringRef service, CFDictionaryRef options))
{
    if (mav_tccImplementsService(service) && WK_ORIGINAL(TCCAccessPreflight))
        return WK_ORIGINAL(TCCAccessPreflight)(service, options);
    // A capability this OS does not gate. The honest answer to "may I" where there is no gate is yes.
    return kTCCAccessPreflightGranted;
}

// The same question asked about another process, by audit token. 10.9's TCC predates this spelling
// and exports nothing for it, and TCCSoftLink.mm declares it with the non-optional
// SOFT_LINK_FUNCTION_FOR_SOURCE, whose initializer ends in RELEASE_ASSERT_WITH_MESSAGE(function,
// dlerror()) -- so without this the first call kills the process. That call is real and reachable:
// doesParentProcessHaveTrackingPreventionEnabled() (Shared/Cocoa/DefaultWebBrowserChecks.mm) asks it
// about the parent's audit token from inside a static initializer in every child process.
//
// Whether the token can change the answer depends on the service, so the token is consulted exactly
// where it matters:
//
//  * A service this OS does not gate has no gate for any process at all, so no token can change the
//    answer and it is Granted. Every service WebKit asks about is in this case.
//  * A service it does gate is gated PER BUNDLE -- 10.9 holds Accessibility and AddressBook grants in
//    the TCC database against the requesting application -- so the token does change the answer. When
//    it is this process's own token the question is literally the one TCCAccessPreflight above
//    answers, and it is forwarded there so the two spellings cannot disagree.
//  * For a gated service and somebody else's token, the answer is kTCCAccessPreflightUnknown: 10.9
//    cannot be asked. Its only by-token entry point is TCCAccessCheckAuditToken, the CHECK spelling,
//    which takes kTCCAccessCheckOptionPrompt and so may put a dialog in front of the user -- which a
//    preflight must never do -- and which answers a bare granted/not-granted that cannot carry the
//    undetermined state (measured on this host: TCCAccessPreflight answers Unknown for AddressBook,
//    Calendar, Location and Reminders, where the check answers not-granted). Unknown is a verdict
//    10.9's own TCCAccessPreflight returns, so it asks nothing of callers that they do not already
//    handle, and it is never mistaken for permission.
//
// The sibling TCCAccessCheckAuditToken needs nothing here: 10.9 does export it (dlsym on the TCC
// handle answers, and it returns the real per-process Accessibility verdict), and its argument
// layout matches the declaration in TCCSoftLink.h -- service in the first integer register, options
// in the second, the 32-byte audit token in memory either way.
WK_POLYFILL_ABSENT("/System/Library/PrivateFrameworks/TCC.framework/TCC", TCCAccessPreflightResult,
                   TCCAccessPreflightWithAuditToken,
                   (CFStringRef service, audit_token_t token, CFDictionaryRef options))
{
    if (!mav_tccImplementsService(service))
        return kTCCAccessPreflightGranted;
    audit_token_t self;
    if (mav_ownAuditToken(&self) && !memcmp(&self, &token, sizeof self))
        return TCCAccessPreflight(service, options);
    return kTCCAccessPreflightUnknown;
}

// AVFoundation's speech-synthesis constants (10.14+, absent here). AVSpeechSynthesizer itself is
// polyfilled over NSSpeechSynthesizer in polyfills/classes.m; these are the values that go with it.
//
// The three rates are the documented endpoints of AVSpeechUtterance.rate's scale and are the values
// the framework exports on a modern OS. PlatformSpeechSynthesizerCocoa reads Default and Maximum by
// dlsym and interpolates the Web Speech API's rate onto them, so they have to be these numbers for
// the mapping to come out right -- there is nothing OS-specific about them to derive.
WK_POLYFILL_CONST("AVFoundation", float, AVSpeechUtteranceMinimumSpeechRate, 0.0f);
WK_POLYFILL_CONST("AVFoundation", float, AVSpeechUtteranceDefaultSpeechRate, 0.5f);
WK_POLYFILL_CONST("AVFoundation", float, AVSpeechUtteranceMaximumSpeechRate, 1.0f);

// The notification AVSpeechSynthesisVoice posts when the installed voice set changes. 10.9's
// NSSpeechSynthesizer has no equivalent notification, so nothing posts this one and an observer
// simply never fires -- which is the same thing that happens on a modern OS whose voice set never
// changes. It still needs a name: PlatformSpeechSynthesizerCocoa registers for it through a required
// soft-link, which RELEASE_ASSERTs on a missing constant.
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSpeechSynthesisAvailableVoicesDidChangeNotification,
                  @"AVSpeechSynthesisAvailableVoicesDidChangeNotification");

// AVSampleBuffer renderer/layer notification names (10.10-15+, all absent here). WebAVSampleBufferListener
// registers for these by name; an absent name weak-imports to NULL, and -addObserver:selector:name:object:
// treats a nil name as "every notification for this object", which is a different and much broader
// registration than upstream asked for. So they are supplied rather than left NULL.
//
// The two AVSampleBufferAudioRenderer ones can never fire on 10.9 (the class is absent, so no instance
// exists to post them) and the AVSampleBufferDisplayLayer ones are posted by a class 10.9 DOES have but
// whose 10.10+ failure/flush notifications it never sends. Either way nothing on this OS posts them, so
// what matters is that each name is a distinct, stable string — which is exactly what a notification name
// is. The values are the constants' own spelling, as Apple's are.
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerFailedToDecodeNotification,
                  @"AVSampleBufferDisplayLayerFailedToDecodeNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey,
                  @"AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification,
                  @"AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification,
                  @"AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification,
                  @"AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification");
WK_POLYFILL_CONST("AVFoundation", NSString * const, AVSampleBufferAudioRendererFlushTimeKey,
                  @"AVSampleBufferAudioRendererFlushTimeKey");

// ---------------------------------------------------------------------------------------------------
// libSystem (sandbox) -- two extension flags absent on 10.9.
//
// 10.9 has SANDBOX_EXTENSION_CANONICAL (0x2) and SANDBOX_BUILD_ID (both bind from libsandbox.1.dylib),
// but neither flag below. Both request behavior this sandbox has no notion of -- suppressing violation
// reports for an extension, and tagging one as issued on explicit user intent -- so define them as no
// bits: WebKit ORs them into the flags word it passes to sandbox_extension_issue_*, and an unrecognized
// bit would risk the 10.9 issuer rejecting the request, whereas 0 leaves it at this OS's default handling.
WK_POLYFILL_CONST(NULL, uint32_t, SANDBOX_EXTENSION_NO_REPORT, 0);
WK_POLYFILL_CONST(NULL, uint32_t, SANDBOX_EXTENSION_USER_INTENT, 0);
