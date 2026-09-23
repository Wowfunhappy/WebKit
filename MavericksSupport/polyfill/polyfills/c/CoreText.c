// CoreText: entry points and constants modern WebKit references that 10.9's CoreText does not
// export, or exports with behaviour that has to be replaced.
#include "wk_polyfill.h"
#include "wk_clusters.h"
#include <unicode/ubidi.h>
#include <unicode/uchar.h>
#include <unicode/uscript.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>
#include "wk_font_catalog.h"
#include "wk_helpers.h"
#include "VariableFontInstancer.h"
#include "wk_colr.h"
#include "wk_font_image.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <CoreText/SFNTLayoutTypes.h>
#include <math.h>
#include <objc/objc-sync.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ots_font_parser.cpp: the memory-safe font parser, and the test for a CFData that parser already
// produced, which the entry points realize without sanitizing it again.
extern CFDataRef wk_ots_sanitize_font(CFDataRef data);
extern CFDataRef wk_copy_gpos_with_reachable_last_pair_sets(CFDataRef data);
static CTFontRef wk_shapingFont(CTFontRef, bool rightToLeft);
static CGFontRef wk_createGraphicsFontFromSfnt(CFDataRef);
extern CFArrayRef wk_ots_copy_font_faces(CFDataRef sanitized);
extern bool wk_font_is_ots_sanitized(CFDataRef data);

WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilyCursive, CFSTR("kCTFontCSSFamilyCursive"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilyFantasy, CFSTR("kCTFontCSSFamilyFantasy"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilyMonospace, CFSTR("kCTFontCSSFamilyMonospace"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilySansSerif, CFSTR("kCTFontCSSFamilySansSerif"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSFamilySerif, CFSTR("kCTFontCSSFamilySerif"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSWeightAttribute, CFSTR("kCTFontCSSWeightAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontCSSWidthAttribute, CFSTR("kCTFontCSSWidthAttribute"));
// The content-size categories are CoreText's own identifiers, spelled "UICTContentSizeCategory" + the
// category's short name -- the values UIContentSizeCategoryLarge and UIContentSizeCategoryExtraExtra
// ExtraLarge carry.
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontContentSizeCategoryL, CFSTR("UICTContentSizeCategoryL"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontContentSizeCategoryXXXL, CFSTR("UICTContentSizeCategoryXXXL"));
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
// VariationAttribute" — hence "NSCTFontVariationAxesAttribute". 10.9's CoreText does not answer the
// key; the CTFontDescriptorCopyAttribute replacement below supplies the array from the realized font.
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontVariationAxesAttribute, CFSTR("NSCTFontVariationAxesAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUnscaledTrackingAttribute, CFSTR("kCTFontUnscaledTrackingAttribute"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontUserInstalledAttribute, CFSTR("kCTFontUserInstalledAttribute"));
// kCTFontWeight* and kCTFontWidth* are CGFloats on CoreText's normalized trait scales, not tokens: they
// are the named points of the -1.0...1.0 ranges kCTFontWeightTrait and kCTFontWidthTrait carry, and are
// read as numbers wherever they appear. Weight runs ultraLight -0.8 through black 0.62 with 0.0 regular
// (the NSFontWeight/UIFontWeight scale, the same nine values Source/ThirdParty/skia's SkCTFont dlsym
// table falls back to). Width is that scale's linear image of the CSS font-stretch percentage,
// ct = (percentage - 100) / 125: condensed 75% -> -0.2, standard 100% -> 0.0, expanded 125% -> 0.2.
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightBlack, 0.62);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightBold, 0.4);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightHeavy, 0.56);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightLight, -0.4);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightMedium, 0.23);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightRegular, 0.0);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightSemibold, 0.3);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightThin, -0.6);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWeightUltraLight, -0.8);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthCondensed, -0.2);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthExpanded, 0.2);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthExtraCompressed, -0.4);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthExtraCondensed, -0.3);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthExtraExpanded, 0.4);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthSemiCondensed, -0.1);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthSemiExpanded, 0.1);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthStandard, 0.0);
WK_POLYFILL_CONST("CoreText", CGFloat, kCTFontWidthUltraCompressed, -0.5);
// The kCTUIFontTextStyle* values are CoreText's own text-style identifiers, spelled "UICTFontTextStyle"
// + the style name. They surface verbatim as the family name of a font realized from a text style.
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleBody, CFSTR("UICTFontTextStyleBody"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleCaption1, CFSTR("UICTFontTextStyleCaption1"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleCaption2, CFSTR("UICTFontTextStyleCaption2"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleFootnote, CFSTR("UICTFontTextStyleFootnote"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleHeadline, CFSTR("UICTFontTextStyleHeadline"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortBody, CFSTR("UICTFontTextStyleShortBody"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortCaption1, CFSTR("UICTFontTextStyleShortCaption1"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortFootnote, CFSTR("UICTFontTextStyleShortFootnote"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortHeadline, CFSTR("UICTFontTextStyleShortHeadline"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleShortSubhead, CFSTR("UICTFontTextStyleShortSubhead"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleSubhead, CFSTR("UICTFontTextStyleSubhead"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTallBody, CFSTR("UICTFontTextStyleTallBody"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle0, CFSTR("UICTFontTextStyleTitle0"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle1, CFSTR("UICTFontTextStyleTitle1"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle2, CFSTR("UICTFontTextStyleTitle2"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle3, CFSTR("UICTFontTextStyleTitle3"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTUIFontTextStyleTitle4, CFSTR("UICTFontTextStyleTitle4"));

// kCTFontOpenTypeFeatureTag / ...Value (10.10 SDK) are the CFDictionary keys for OpenType font features.
// They have no 10.9 symbol; building a feature dictionary with a NULL key would crash CFDictionary, so
// define them with CoreText's documented key strings. (10.9 CoreText may not honor the new-style feature
// dictionary, but the code links and runs without crashing.)
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontOpenTypeFeatureTag, CFSTR("CTFeatureOpenTypeTag"));
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontOpenTypeFeatureValue, CFSTR("CTFeatureOpenTypeValue"));

// kCTFontDownloadedAttribute (10.12+) has no 10.9 symbol; a defined value keeps the downloaded-font
// path from feeding a NULL key to a CTFontDescriptor. 10.9 does not honor it, which is fine.
WK_POLYFILL_CONST("CoreText", CFStringRef, kCTFontDownloadedAttribute, CFSTR("kCTFontDownloadedAttribute"));

static uint16_t wk_be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t wk_be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

// A glyph's colour bitmap, taken from the font's sbix table and placed where the sbix record puts it:
// the image's lower-left corner at the pen on the baseline, moved by the record's origin offset, with
// the strike scaled by the point size over its ppem. This OS's CTFontDrawGlyphs paints an sbix strike
// 0.075 em below that point, and CTFontGetBoundingRectsForGlyphs reports every glyph of a font that
// carries an sbix table the same distance low. The glyph drawing and bounds replacements use
// the record and outline coordinates.

// The strike image for a record, in each of the graphic types the sbix format defines for one. Page-
// supplied strikes are held to WebCore's own decode ceiling, ImageBackingStore::isOverSize
// ((1<<29)-1 pixels), so a small compressed strike cannot declare a multi-gigabyte pixel buffer.
static CGImageRef wk_sbixDecodeStrike(uint32_t graphicType, const uint8_t *bytes, size_t length)
{
    static const size_t maximumPixels = (1u << 29) - 1;
    switch (graphicType) {
    case 'png ':
        return wk_fontImageDecodePNG(bytes, length, maximumPixels);
    case 'jpg ':
        return wk_fontImageDecodeJPEG(bytes, length, maximumPixels);
    case 'tiff':
        return wk_fontImageDecodeTIFF(bytes, length, maximumPixels);
    }
    return NULL;
}

static pthread_mutex_t wkSbixLock = PTHREAD_MUTEX_INITIALIZER;
static const void *wk_sbixTableKey(void) { static char key; return &key; }
static const void *wk_sbixBitmapsKey(void) { static char key; return &key; }

// The font's sbix table. kCFNull records a font that has none, so an ordinary text font pays one
// CTFontCopyTable for the life of the CTFont. Call with wkSbixLock held.
static CFDataRef wk_sbixTable(CTFontRef font)
{
    CFTypeRef cached = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, wk_sbixTableKey());
    if (!cached) {
        CFDataRef table = CTFontCopyTable(font, kCTFontTableSbix, kCTFontTableOptionNoOptions);
        cached = table ? (CFTypeRef)table : (CFTypeRef)kCFNull;
        objc_setAssociatedObject((id)(void *)font, wk_sbixTableKey(), (id)cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (table)
            CFRelease(table);
    }
    return cached == (CFTypeRef)kCFNull ? NULL : (CFDataRef)cached;
}

// Whether the font carries an sbix table at all.
static bool wk_sbixFont(CTFontRef font)
{
    if (!font)
        return false;
    pthread_mutex_lock(&wkSbixLock);
    bool carriesTable = wk_sbixTable(font) != NULL;
    pthread_mutex_unlock(&wkSbixLock);
    return carriesTable;
}

// A font's COLR and CPAL tables, kept on the CTFont as its sbix table is; kCFNull records a table the font
// does not carry. The association is set once and never replaced, so a present value is read without a
// lock, and the first copy is made under objc_sync on the font, which every image in the process shares.
static const void *wk_colrTableKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_colrTable");
    return key;
}

static const void *wk_cpalTableKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_cpalTable");
    return key;
}

static CFDataRef wk_fontTable(CTFontRef font, const void *key, CTFontTableTag tag)
{
    CFTypeRef cached = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, key);
    if (!cached) {
        objc_sync_enter((id)(void *)font);
        cached = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, key);
        if (!cached) {
            CFDataRef table = CTFontCopyTable(font, tag, kCTFontTableOptionNoOptions);
            cached = table ? (CFTypeRef)table : (CFTypeRef)kCFNull;
            objc_setAssociatedObject((id)(void *)font, key, (id)cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (table)
                CFRelease(table);
        }
        objc_sync_exit((id)(void *)font);
    }
    return cached == (CFTypeRef)kCFNull ? NULL : (CFDataRef)cached;
}

WK_POLYFILL_REPLACES("CoreText", CTFontSymbolicTraits, CTFontGetSymbolicTraits, (CTFontRef font))
{
    CTFontSymbolicTraits traits = WK_ORIGINAL(CTFontGetSymbolicTraits) ? WK_ORIGINAL(CTFontGetSymbolicTraits)(font) : 0;
    if (font) {
        CFDataRef os2 = wk_fontTable(font, sel_registerName("wk_os2Style"), kCTFontTableOS2);
        CFDataRef head = wk_fontTable(font, sel_registerName("wk_headStyle"), kCTFontTableHead);
        bool haveSelection = os2 && CFDataGetLength(os2) >= 64;
        bool haveStyle = head && CFDataGetLength(head) >= 46;
        if (haveSelection || haveStyle) {
            bool italic = (haveSelection && (wk_be16(CFDataGetBytePtr(os2) + 62) & 0x201))
                || (haveStyle && (wk_be16(CFDataGetBytePtr(head) + 44) & 2));
            traits |= italic ? kCTFontTraitItalic : 0;
        }
    }
    if (font && wk_fontTable(font, wk_colrTableKey(), kCTFontTableCOLR))
        traits |= kCTFontTraitColorGlyphs;
    return traits;
}

static CFDictionaryRef wk_copyTraitsWithSymbolic(CFDictionaryRef traits, CTFontSymbolicTraits symbolic)
{
    CFMutableDictionaryRef result = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, traits);
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &symbolic);
    CFDictionarySetValue(result, kCTFontSymbolicTrait, value);
    CFRelease(value);
    return result;
}

WK_POLYFILL_REPLACES("CoreText", CFDictionaryRef, CTFontCopyTraits, (CTFontRef font))
{
    CFDictionaryRef traits = WK_ORIGINAL(CTFontCopyTraits)(font);
    CFDictionaryRef result = wk_copyTraitsWithSymbolic(traits, CTFontGetSymbolicTraits(font));
    CFRelease(traits);
    return result;
}

// The palette a font was realized with. This OS keeps kCTFontPaletteAttribute and
// kCTFontPaletteColorsAttribute on a descriptor and does not carry them onto the CTFont it realizes, so
// the font keeps them itself and answers them from CTFontCopyAttribute and CTFontCopyFontDescriptor.
static const void *wk_paletteKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_fontPalette");
    return key;
}

static const void *wk_paletteColorsKey(void)
{
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_fontPaletteColors");
    return key;
}

static const void *wk_fallbackOptionKey(void)
{
    return sel_registerName("wk_fontFallbackOption");
}

static long wk_fontFallbackOption(CTFontRef font)
{
    CFTypeRef attribute = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, wk_fallbackOptionKey());
    long option = 3;
    if (attribute)
        CFNumberGetValue((CFNumberRef)attribute, kCFNumberLongType, &option);
    return option;
}

// Native CTFont equality covers native attributes; the carried fallback policy is part of font identity.
WK_POLYFILL_REPLACES("CoreFoundation", Boolean, CFEqual, (CFTypeRef first, CFTypeRef second))
{
    if (!WK_ORIGINAL(CFEqual)(first, second))
        return false;
    if (first == second || CFGetTypeID(first) != CTFontGetTypeID())
        return true;
    return wk_fontFallbackOption((CTFontRef)first) == wk_fontFallbackOption((CTFontRef)second);
}

static void wk_recordPalette(CTFontRef font, CFTypeRef palette, CFTypeRef colors)
{
    if (!font)
        return;
    if (palette && CFGetTypeID(palette) == CFNumberGetTypeID())
        objc_setAssociatedObject((id)(void *)font, wk_paletteKey(), (id)palette, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (colors && CFGetTypeID(colors) == CFDictionaryGetTypeID())
        objc_setAssociatedObject((id)(void *)font, wk_paletteColorsKey(), (id)colors, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CTFontRef wk_recordDescriptorOptions(CTFontRef font, CTFontDescriptorRef descriptor)
{
    if (font && descriptor) {
        CFDictionaryRef carried = CTFontDescriptorCopyAttributes(descriptor);
        CFTypeRef owner = carried ? CFDictionaryGetValue(carried, CFSTR("WKFontGraphicsFont")) : NULL;
        if (owner)
            objc_setAssociatedObject((id)(void *)font, sel_registerName("wk_fontGraphicsFont"), (id)owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFTypeRef fallback = carried ? CFDictionaryGetValue(carried, kCTFontFallbackOptionAttribute) : NULL;
        if (fallback && CFGetTypeID(fallback) == CFNumberGetTypeID())
            objc_setAssociatedObject((id)(void *)font, wk_fallbackOptionKey(), (id)fallback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (carried)
            CFRelease(carried);
    }

    if (!font || !descriptor)
        return font;
    CFTypeRef palette = CTFontDescriptorCopyAttribute(descriptor, kCTFontPaletteAttribute);
    CFTypeRef colors = CTFontDescriptorCopyAttribute(descriptor, kCTFontPaletteColorsAttribute);
    wk_recordPalette(font, palette, colors);
    if (palette)
        CFRelease(palette);
    if (colors)
        CFRelease(colors);
    return font;
}

// A copy keeps its graphics-font binding, palette and fallback policy.
static void wk_inheritDescriptorOptions(CTFontRef copy, CTFontRef source, CTFontDescriptorRef attributes)
{
    if (!copy || copy == source)
        return;
    if (source) {
        CFTypeRef owner = (CFTypeRef)objc_getAssociatedObject((id)(void *)source, sel_registerName("wk_fontGraphicsFont"));
        if (owner)
            objc_setAssociatedObject((id)(void *)copy, sel_registerName("wk_fontGraphicsFont"), (id)owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFTypeRef fallback = (CFTypeRef)objc_getAssociatedObject((id)(void *)source, wk_fallbackOptionKey());
        if (fallback)
            objc_setAssociatedObject((id)(void *)copy, wk_fallbackOptionKey(), (id)fallback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        wk_recordPalette(copy, (CFTypeRef)objc_getAssociatedObject((id)(void *)source, wk_paletteKey()),
            (CFTypeRef)objc_getAssociatedObject((id)(void *)source, wk_paletteColorsKey()));
    }
    wk_recordDescriptorOptions(copy, attributes);
}

// The font's carried options laid over its descriptor. Consumes `descriptor`.
static CTFontDescriptorRef wk_descriptorWithCarriedOptions(CTFontRef font, CTFontDescriptorRef descriptor)
{
    if (!font || !descriptor)
        return descriptor;
    CFTypeRef palette = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, wk_paletteKey());
    CFTypeRef colors = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, wk_paletteColorsKey());
    CFTypeRef fallback = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, wk_fallbackOptionKey());
    if (!palette && !colors && !fallback)
        return descriptor;
    const void *keys[3];
    const void *values[3];
    CFIndex count = 0;
    if (palette) {
        keys[count] = kCTFontPaletteAttribute;
        values[count++] = palette;
    }
    if (colors) {
        keys[count] = kCTFontPaletteColorsAttribute;
        values[count++] = colors;
    }
    if (fallback) {
        keys[count] = kCTFontFallbackOptionAttribute;
        values[count++] = fallback;
    }
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, count,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef withPalette = attributes ? CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes) : NULL;
    if (attributes)
        CFRelease(attributes);
    if (!withPalette)
        return descriptor;
    CFRelease(descriptor);
    return withPalette;
}

// sbix layout (Apple TrueType reference): u16 version, u16 flags, u32 numStrikes,
// u32 strikeOffsets[numStrikes] from the table start; each strike is u16 ppem, u16 resolution,
// u32 glyphDataOffsets[numGlyphs + 1] from the strike start. A glyph record is s16 originOffsetX,
// s16 originOffsetY, u32 graphicType, then the image bytes.
//
// The record read here is the one in the strike wantedPPEM asks for: the smallest strike at least
// that big, else the largest the font has. A 'dupe' record names another glyph in the same strike.
static bool wk_sbixRecord(const uint8_t *bytes, CFIndex length, CFIndex glyphCount, CGGlyph glyph,
                          double wantedPPEM, uint16_t *outPPEM, int16_t *originX, int16_t *originY,
                          const uint8_t **data, size_t *dataLength, uint32_t *graphicType)
{
    if (!bytes || length < 8 || glyph >= glyphCount)
        return false;
    uint32_t strikeCount = wk_be32(bytes + 4);
    if ((CFIndex)strikeCount > (length - 8) / 4)
        return false;
    CFIndex needed = 4 + (glyphCount + 1) * 4;
    uint32_t chosenOffset = 0;
    double chosenPPEM = 0;
    double largestPPEM = 0;
    uint32_t largestOffset = 0;
    for (uint32_t i = 0; i < strikeCount; ++i) {
        uint32_t strikeOffset = wk_be32(bytes + 8 + i * 4);
        if ((CFIndex)strikeOffset > length - needed)
            continue;
        const uint8_t *strike = bytes + strikeOffset;
        if (wk_be32(strike + 4 + ((CFIndex)glyph + 1) * 4) <= wk_be32(strike + 4 + (CFIndex)glyph * 4))
            continue;
        double ppem = wk_be16(strike);
        if (ppem > largestPPEM) {
            largestPPEM = ppem;
            largestOffset = strikeOffset;
        }
        if (ppem >= wantedPPEM && (!chosenPPEM || ppem < chosenPPEM)) {
            chosenPPEM = ppem;
            chosenOffset = strikeOffset;
        }
    }
    if (!chosenPPEM) {
        chosenPPEM = largestPPEM;
        chosenOffset = largestOffset;
    }
    if (!chosenPPEM)
        return false;

    const uint8_t *strike = bytes + chosenOffset;
    *outPPEM = (uint16_t)chosenPPEM;
    CGGlyph target = glyph;
    // A dupe chain is bounded so a font that points a record at itself cannot spin here.
    for (unsigned hop = 0; hop < 8; ++hop) {
        if (target >= glyphCount)
            return false;
        uint32_t start = wk_be32(strike + 4 + (CFIndex)target * 4);
        uint32_t end = wk_be32(strike + 4 + ((CFIndex)target + 1) * 4);
        // Widened before they are added: both come from the font, and a 32-bit sum of them wraps.
        CFIndex recordStart = (CFIndex)chosenOffset + (CFIndex)start;
        CFIndex recordEnd = (CFIndex)chosenOffset + (CFIndex)end;
        if (end <= start || end - start < 8 || recordStart < 0 || recordEnd > length)
            return false;
        const uint8_t *record = bytes + recordStart;
        if (wk_be32(record + 4) == 'dupe') {
            if (end - start < 10)
                return false;
            target = (CGGlyph)wk_be16(record + 8);
            continue;
        }
        *originX = (int16_t)wk_be16(record);
        *originY = (int16_t)wk_be16(record + 2);
        if (graphicType)
            *graphicType = wk_be32(record + 4);
        *data = record + 8;
        *dataLength = (size_t)(end - start - 8);
        return true;
    }
    return false;
}

// The decoded strike image for a glyph and the rectangle it fills in glyph space, or false when the
// glyph has no bitmap this OS can decode -- in which case the caller leaves the glyph to CoreText.
// devicePixelsPerEm chooses the strike, so a scaled-up context draws from a denser one. The cache
// hangs off the CTFont, whose point size fixes the rectangle, and is keyed by glyph and strike.
// Call with wkSbixLock held.
static bool wk_sbixBitmap(CTFontRef font, CGGlyph glyph, CGFloat devicePixelsPerEm, CGImageRef *outImage, CGRect *outRect)
{
    CFDataRef table = wk_sbixTable(font);
    if (!table)
        return false;
    CFIndex glyphCount = CTFontGetGlyphCount(font);
    if (glyphCount <= 0)
        return false;

    const uint8_t *bytes = CFDataGetBytePtr(table);
    CFIndex length = CFDataGetLength(table);
    uint16_t ppem = 0;
    int16_t originX = 0, originY = 0;
    const uint8_t *data = NULL;
    size_t dataLength = 0;
    uint32_t graphicType = 0;
    if (!wk_sbixRecord(bytes, length, glyphCount, glyph, devicePixelsPerEm, &ppem, &originX, &originY, &data, &dataLength, &graphicType) || !ppem)
        return false;
    if (!outImage && !outRect)
        return true;

    CFMutableDictionaryRef cache = (CFMutableDictionaryRef)objc_getAssociatedObject((id)(void *)font, wk_sbixBitmapsKey());
    if (!cache) {
        cache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (!cache)
            return false;
        objc_setAssociatedObject((id)(void *)font, wk_sbixBitmapsKey(), (id)cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFRelease(cache);
    }

    long long identity = ((long long)ppem << 16) | glyph;
    CFNumberRef cacheKey = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &identity);
    if (!cacheKey)
        return false;
    // An entry is the image paired with its rectangle; an empty one records a strike that would not decode.
    CFArrayRef entry = (CFArrayRef)CFDictionaryGetValue(cache, cacheKey);
    if (!entry) {
        CGRect rect = CGRectZero;
        CGImageRef image = wk_sbixDecodeStrike(graphicType, data, dataLength);
        if (image) {
            CGFloat scale = CTFontGetSize(font) / ppem;
            rect = CGRectMake(originX * scale, originY * scale,
                              CGImageGetWidth(image) * scale, CGImageGetHeight(image) * scale);
        }
        CFDataRef rectData = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&rect, sizeof(rect));
        const void *members[2] = { image, rectData };
        CFArrayRef created = (image && rectData)
            ? CFArrayCreate(kCFAllocatorDefault, members, 2, &kCFTypeArrayCallBacks)
            : CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
        if (image)
            CGImageRelease(image);
        if (rectData)
            CFRelease(rectData);
        if (created) {
            CFDictionarySetValue(cache, cacheKey, created);
            CFRelease(created);
            entry = (CFArrayRef)CFDictionaryGetValue(cache, cacheKey);
        }
    }
    CFRelease(cacheKey);

    if (!entry || CFArrayGetCount(entry) != 2)
        return false;
    if (outImage)
        *outImage = (CGImageRef)CFArrayGetValueAtIndex(entry, 0);
    if (outRect)
        CFDataGetBytes((CFDataRef)CFArrayGetValueAtIndex(entry, 1), CFRangeMake(0, sizeof(*outRect)), (UInt8 *)outRect);
    return true;
}

// The end of the longest stretch of the run starting at `from` whose glyphs are all drawn the same
// way, and which way that is. Presence is the record alone -- a strike is only decoded where one is
// actually painted. Answering from the run itself rather than from a marks array means the split
// cannot fail: there is no allocation here to run out, and so no state in which the caller knows a
// glyph carries a record but has nowhere to write it down.
// CTFontGetSbixImageSizeForGlyphAndContentsScale (10.13+) reports the pixel size of the strike a
// glyph would be drawn from, and zero when the glyph has none -- which is what WebCore reads it for
// (Font::glyphHasComplexColorFormat).
WK_POLYFILL_ABSENT("CoreText", CGFloat, CTFontGetSbixImageSizeForGlyphAndContentsScale,
                   (CTFontRef font, const CGGlyph glyph, CGFloat contentsScale))
{
    if (!font)
        return 0;
    pthread_mutex_lock(&wkSbixLock);
    CGFloat strikeSize = 0;
    CFDataRef table = wk_sbixTable(font);
    CFIndex glyphCount = table ? CTFontGetGlyphCount(font) : 0;
    if (glyphCount > 0) {
        uint16_t ppem = 0;
        int16_t originX = 0, originY = 0;
        const uint8_t *data = NULL;
        size_t dataLength = 0;
        double wanted = CTFontGetSize(font) * (contentsScale > 0 ? contentsScale : 1);
        if (wk_sbixRecord(CFDataGetBytePtr(table), CFDataGetLength(table), glyphCount, glyph, wanted,
                          &ppem, &originX, &originY, &data, &dataLength, NULL))
            strikeSize = ppem;
    }
    pthread_mutex_unlock(&wkSbixLock);
    return strikeSize;
}

// Font and text matrices place both the glyph and its pen before the context transform.
// Bitmap glyphs carry their own colors independently of the context's fill and stroke.
static void wk_drawSbixGlyph(CTFontRef font, CGGlyph glyph, CGPoint position, CGContextRef context)
{
    CGAffineTransform textMatrix = CGAffineTransformConcat(CTFontGetMatrix(font), CGContextGetTextMatrix(context));
    CGAffineTransform glyphToDevice = CGAffineTransformConcat(textMatrix, CGContextGetCTM(context));
    CGSize unit = CGSizeApplyAffineTransform(CGSizeMake(1, 0), glyphToDevice);
    CGFloat scale = hypot(unit.width, unit.height);

    pthread_mutex_lock(&wkSbixLock);
    CGImageRef image = NULL;
    CGRect rect = CGRectZero;
    bool haveBitmap = wk_sbixBitmap(font, glyph, CTFontGetSize(font) * (scale > 0 ? scale : 1), &image, &rect);
    CGImageRef retained = haveBitmap && image ? CGImageRetain(image) : NULL;
    pthread_mutex_unlock(&wkSbixLock);
    if (!retained)
        return;

    CGContextSaveGState(context);
    CGContextConcatCTM(context, textMatrix);
    CGContextDrawImage(context, CGRectOffset(rect, position.x, position.y), retained);
    CGContextRestoreGState(context);
    CGImageRelease(retained);
}

// CTFontCreateForCharactersWithLanguage is itself CoreText SPI (declared in WebKit's PAL
// CoreTextSPI.h, not the public SDK headers); forward-declare it so the forwarding impl below compiles.
extern CTFontRef CTFontCreateForCharactersWithLanguage(CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, CFIndex *coveredLength);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// The fallback option restricts the fonts eligible for character matching.
static bool wk_fontIsUserInstalled(CTFontRef);
static CTFontRef wk_copySystemFallback(CTFontRef, const UniChar *, CFIndex, CFStringRef, CFIndex *);
static CTFontRef wk_inheritFontRequest(CTFontRef font, CTFontRef source);
WK_SYSTEM_FN("CoreText", bool, CTFontManagerRegisterFontsForURLs, (CFArrayRef, CTFontManagerScope, CFArrayRef *));
WK_SYSTEM_FN("CoreText", CFArrayRef, CTFontManagerCreateFontDescriptorsFromURL, (CFURLRef));
WK_SYSTEM_FN("CoreText", void, CTFontManagerEnableFontDescriptors, (CFArrayRef, bool));

WK_POLYFILL_ABSENT("CoreText", CTFontRef, CTFontCreateForCharactersWithLanguageAndOption,
    (CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, unsigned long option, CFIndex *coveredLength))
{
    CTFontRef result = CTFontCreateForCharactersWithLanguage(currentFont, characters, length, language, coveredLength);
    if (result && !(option & (1u << 1)) && wk_fontIsUserInstalled(result)) {
        CFRelease(result);
        result = wk_copySystemFallback(currentFont, characters, length, language, coveredLength);
    }
    return wk_inheritFontRequest(result, currentFont);
}

// Variable fonts. 10.9's CoreText cannot instance one. Two behaviours were measured on 10.9.5
// (with Amstelvar-Roman-VF104, whose 'H' advances 87.0 units at wght=400 and 97.1 at wght=900):
//
//   * realizing a descriptor that carries kCTFontVariationAttribute silently ignores it and
//     yields the fvar default master (advance 87.0 whatever wght is asked for), and
//   * the one path CoreText does route variations through — CTFontCreateWithGraphicsFont with
//     that attribute, which reaches CGFontCreateCopyWithVariations — collapses every outline:
//     advance 0, bounding box 0x0.
//
// CGFontCreateCopyWithVariations is the function that is actually broken, but replacing it would
// fix nothing: WebKit never calls it, and this layer is scoped to WebKit's own images (hidden
// visibility, force_load), so CoreText's internal call to it can never reach our definition.
// The reachable entry point is the descriptor realization below, and that is what is replaced.
//
// The two halves work together. CTFontManagerCreateFontDescriptorFromData is where the layer sees
// a web font's sfnt bytes, so it stashes them on the descriptor it returns under a private key;
// CTFontDescriptorCreateCopyWithAttributes, which is how every caller narrows a descriptor,
// carries unknown attributes through unchanged (measured), so the bytes are still there when the
// descriptor is realized with a variation dictionary. The realization then software-cuts a static
// instance at the requested axis values and builds the font from that.
#define WK_LEGACY_VARIABLE_FONT_SOURCE_KEY CFSTR("WKMavericksLegacyVariableFontSourceSFNT")

// Descriptors retain a CGFont binding: 10.9's descriptor-from-data route frees an object that
// TFontFeatures reads on realization. CFF uses the URL reader for exact vertical font units.
//
// For a variable font the descriptor describes the default master — the variation tables are
// stripped, so that CoreGraphics reads a plain static font — and the original bytes ride along
// under WK_LEGACY_VARIABLE_FONT_SOURCE_KEY for CTFontCreateWithFontDescriptor to instance from.
//
// The descriptor names a size of 0 — an explicit zero, which is what a size-0 request looks like
// and what carries `font-size: 0` through to realization. CTFontCopyFontDescriptor bakes in the
// size of the CTFont it is taken from, 12 here from realizing the CGFont to reach a descriptor, and
// UnrealizedCoreTextFont::getSize() reads a base descriptor's size attribute directly
// (UnrealizedCoreTextFont.cpp:62), so that 12 would become the realized size of every web font
// asked for at 0. Copying onto the descriptor keeps its CGFont binding.
static CTFontDescriptorRef wk_descriptorWithZeroSize(CTFontDescriptorRef descriptor)
{
    CGFloat noSize = 0;
    CFNumberRef zero = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &noSize);
    const void *keys[] = { kCTFontSizeAttribute };
    const void *values[] = { zero };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef result = attributes ? CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes) : NULL;
    if (attributes)
        CFRelease(attributes);
    CFRelease(zero);
    return result;
}

// Realize a descriptor from an already sanitized sfnt, including legacy variable-font handling.
// The native data-parser fallback is for non-CFF fonts; its CFF path crashes on valid subsets on 10.9.
// This never sanitizes; the sanitizing entry points call it once.
static CTFontDescriptorRef wk_realizeDescriptorFromSfnt(CFDataRef sfnt);

WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontManagerCreateFontDescriptorFromData, (CFDataRef data))
{
    // Every downloadable font on this port reaches CoreText through here, so the system parser never
    // sees the bytes off the network. OTS re-serialises the font from its own bounds-checked tables
    // (unwrapping a WOFF or WOFF2 container as it reads); a font it will not accept has no sanitized
    // form, and NULL is the answer. Bytes that parser already wrote -- FontCustomPlatformData::create
    // passes FPFontCreateFontsFromData's output straight here -- are realized as they are.
    if (wk_font_is_ots_sanitized(data))
        return wk_realizeDescriptorFromSfnt(data);
    CFDataRef sanitized = wk_ots_sanitize_font(data);
    if (!sanitized)
        return NULL;
    CTFontDescriptorRef descriptor = wk_realizeDescriptorFromSfnt(sanitized);
    CFRelease(sanitized);
    return descriptor;
}

static CTFontDescriptorRef wk_realizeDescriptorFromSfnt(CFDataRef sfnt)
{
    if (sfnt) {
        bool variable = wk_legacy_variable_font_is_instanceable(sfnt);
        CFDataRef master = variable ? wk_legacy_variable_font_strip_variations(sfnt) : (CFDataRef)CFRetain(sfnt);
        CGFontRef cgFont = master ? wk_createGraphicsFontFromSfnt(master) : NULL;
        if (master)
            CFRelease(master);
        if (cgFont) {
            CTFontRef ctFont = CTFontCreateWithGraphicsFont(cgFont, 12.0, NULL, NULL);
            CGFontRelease(cgFont);
            if (ctFont) {
                CTFontDescriptorRef realized = CTFontCopyFontDescriptor(ctFont);
                CFRelease(ctFont);
                CTFontDescriptorRef descriptor = realized ? wk_descriptorWithZeroSize(realized) : NULL;
                if (realized)
                    CFRelease(realized);
                if (descriptor && variable) {
                    CFMutableDictionaryRef source = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                    CFDictionarySetValue(source, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY, sfnt);
                    CTFontDescriptorRef withSource = CTFontDescriptorCreateCopyWithAttributes(descriptor, source);
                    CFRelease(source);
                    if (withSource) {
                        CFRelease(descriptor);
                        descriptor = withSource;
                    }
                }
                if (descriptor)
                    return descriptor;
            }
        }
    }
    if (sfnt && CFDataGetLength(sfnt) >= 4 && wk_be32(CFDataGetBytePtr(sfnt)) == 'OTTO')
        return NULL;
    return WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)
        ? WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)(sfnt) : NULL;
}

// The size CoreText would use for a descriptor realized at `size`: an explicit size wins, then the
// descriptor's own kCTFontSizeAttribute, then CoreText's 12pt default.
static CGFloat wk_sizeForRealizedFont(CTFontDescriptorRef descriptor, CGFloat size)
{
    if (size > 0)
        return size;
    CFNumberRef sizeAttribute = (CFNumberRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontSizeAttribute);
    if (sizeAttribute) {
        double descriptorSize = 0;
        bool valid = CFGetTypeID(sizeAttribute) == CFNumberGetTypeID()
            && CFNumberGetValue(sizeAttribute, kCFNumberDoubleType, &descriptorSize) && descriptorSize > 0;
        CFRelease(sizeAttribute);
        if (valid)
            return (CGFloat)descriptorSize;
    }
    return 12.0;
}

// The descriptor's attributes minus everything that names or sizes the font: what identity the cut
// instance has is settled by the CGFont it is built from, and the variations have been baked in.
// Whatever else the caller asked for (feature settings, palettes, …) is passed on untouched.
static CTFontDescriptorRef wk_descriptorAttributesToCarryOver(CTFontDescriptorRef descriptor)
{
    CFDictionaryRef attributes = CTFontDescriptorCopyAttributes(descriptor);
    if (!attributes)
        return NULL;
    CFMutableDictionaryRef remaining = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
    CFRelease(attributes);
    CFDictionaryRemoveValue(remaining, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY);
    CFDictionaryRemoveValue(remaining, kCTFontVariationAttribute);
    CFDictionaryRemoveValue(remaining, kCTFontNameAttribute);
    CFDictionaryRemoveValue(remaining, kCTFontFamilyNameAttribute);
    CFDictionaryRemoveValue(remaining, kCTFontSizeAttribute);
    CTFontDescriptorRef result = CFDictionaryGetCount(remaining) ? CTFontDescriptorCreateWithAttributes(remaining) : NULL;
    CFRelease(remaining);
    return result;
}

// Realizes a variable font at the axis values its descriptor asks for, or returns NULL to let
// 10.9's own realization run. NULL is the answer for every font that is not a variable web font
// this layer created the descriptor for, and for every request that lands on the fvar defaults.
// `carriesSource` says whether the descriptor is one of those.
static CFTypeRef wk_carriedAttribute(CTFontDescriptorRef descriptor, CFStringRef key);

static CTFontRef wk_realizeVariableFontInstance(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix,
                                               bool *carriesSource)
{
    *carriesSource = false;
    if (!descriptor)
        return NULL;
    // The key is one only descriptors this layer minted carry, so it is read off the descriptor's own
    // attributes; CTFontDescriptorCopyAttribute would answer it by matching, per realization, for the
    // overwhelming majority of descriptors that lack it.
    CFDataRef sourceData = (CFDataRef)wk_carriedAttribute(descriptor, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY);
    if (!sourceData)
        return NULL;
    *carriesSource = true;

    CTFontRef font = NULL;
    CFDictionaryRef variations = (CFDictionaryRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontVariationAttribute);
    CFDataRef instance = wk_legacy_variable_font_instance(sourceData, variations);
    if (instance) {
        CGFontRef cgFont = wk_createGraphicsFontFromSfnt(instance);
        if (cgFont) {
            CTFontDescriptorRef carriedOver = wk_descriptorAttributesToCarryOver(descriptor);
            font = CTFontCreateWithGraphicsFont(cgFont, wk_sizeForRealizedFont(descriptor, size), matrix, carriedOver);
            if (carriedOver)
                CFRelease(carriedOver);
            CGFontRelease(cgFont);
        }
        CFRelease(instance);
    }
    if (variations)
        CFRelease(variations);
    CFRelease(sourceData);
    return font;
}

// Fonts of size 0. Newer CoreText realizes a font from an explicitly requested size of 0 and
// answers with one whose ascent, descent, advances and bounding boxes are all 0; 10.9 substitutes
// its documented 12pt default for a size of 0, whether the 0 arrives in the size parameter or in a
// descriptor's own kCTFontSizeAttribute. WebCore zeroes glyph widths and font metrics for a size-0
// font itself (Font::platformWidthForGlyph, Font::platformInit), while its shaping and
// complex-text paths measure `font-size: 0` text with CTLine and CTFontShapeGlyphs on the CTFont
// and its ink overflow with CTFontGetBoundingRectsForGlyphs — the zero widths and zero heights
// LayoutTests/fast/text/font-size-zero.html and font-size-zero-complex.html require.
//
// Scaling the em square to nothing is how 10.9 expresses that font: every one of those CoreText
// calls answers exactly 0 through it, while glyph lookup and font identity stay intact. Size 0 and
// the identity matrix are the same linear map as size 12 and that matrix, and CTFontGetSize,
// CTFontGetMatrix and CTFontCopyAttribute answer with the first pair, which is the one newer
// CoreText hands back. Readers of it: upstream's own `CTFontCreateCopyWithAttributes(font,
// CTFontGetSize(font), …)` (FontCacheCoreText.cpp:792, :924, FontCoreText.cpp:526), the fallback
// font's realized size (UnrealizedCoreTextFont.cpp:62), the run font the complex-text path builds
// a FontPlatformData from (ComplexTextControllerCoreText.mm:279), the size a FontCascade takes from
// a CTFont (FontCascadeCoreText.cpp:52-53), the FontMetadata pointSize WebCore serializes and
// reconstructs from (FontPlatformDataCoreText.cpp:278, FontCoreText.cpp:1037, :1080, :1023), and
// the font size accessibility reports (AXCoreObjectCocoa.mm:103).
static const CGAffineTransform wk_zeroSizeFontMatrix = { 0, 0, 0, 0, 0, 0 };
static const CGAffineTransform wk_identityFontMatrix = { 1, 0, 0, 1, 0, 0 };

// The zero map, all four of a/b/c/d — not merely a singular one. A matrix like [1 0 1 0] collapses
// glyphs onto a line and is a map a caller can legitimately ask for, so it fails this test and is
// carried and reported unchanged.
static bool wk_matrixScalesToNothing(CGAffineTransform matrix)
{
    return matrix.a == 0 && matrix.b == 0 && matrix.c == 0 && matrix.d == 0;
}

// What the caller named, kept on the font this layer mints from it. CoreText is handed the composed
// map; the size and matrix a caller passed are separate facts, and they are the two newer CoreText
// answers CTFontGetSize / CTFontGetMatrix with. CTFontRef is toll-free bridged to NSFont, so the
// record lives and dies with the font.
typedef struct {
    CGFloat size;
    CGAffineTransform matrix;
} wk_font_request;

static const void *wk_fontRequestKey(void)
{
    // Cached: sel_registerName hashes under the runtime lock, and this runs per metric read.
    // The SEL is the one address every image's copy of this archive agrees on.
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_fontRequest");
    return key;
}

static void wk_setFontRequest(CTFontRef font, const wk_font_request *request)
{
    CFDataRef record = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)request, sizeof(*request));
    if (!record)
        return;
    objc_setAssociatedObject((id)(void *)font, wk_fontRequestKey(), (id)record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFRelease(record);
}

static bool wk_recordedFontRequest(CTFontRef font, wk_font_request *request)
{
    if (!font)
        return false;
    CFDataRef record = (CFDataRef)objc_getAssociatedObject((id)(void *)font, wk_fontRequestKey());
    if (!record || CFGetTypeID(record) != CFDataGetTypeID()
        || CFDataGetLength(record) != (CFIndex)sizeof(*request))
        return false;
    CFDataGetBytes(record, CFRangeMake(0, sizeof(*request)), (UInt8 *)request);
    return true;
}

static CTFontRef wk_inheritFontRequest(CTFontRef font, CTFontRef source)
{
    wk_font_request request;
    if (font && wk_recordedFontRequest(source, &request))
        wk_setFontRequest(font, &request);
    return font;
}

// The UI font type a font was created for. A realized font carries no attribute naming it on this
// OS, and CTFontCreateUIFontForLanguage is where the caller says it, so the type is recorded there
// and CTFontGetUIFontType reads it back. A font derived from a UI font -- the bold face a weight
// request selects, say -- is a different font and carries no record, which is what keeps it out of
// the system-UI serialization branch that would rebuild it from a type carrying the wrong weight.
static const void *wk_uiFontTypeKey(void)
{
    // Cached: sel_registerName hashes under the runtime lock, and this runs per metric read.
    // The SEL is the one address every image's copy of this archive agrees on.
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_uiFontType");
    return key;
}

static CTFontRef wk_recordUIFontType(CTFontRef font, uint32_t type)
{
    if (!font)
        return font;
    int32_t value = (int32_t)type;
    CFNumberRef record = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (!record)
        return font;
    objc_setAssociatedObject((id)(void *)font, wk_uiFontTypeKey(), (id)record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFRelease(record);
    return font;
}

static bool wk_recordedUIFontType(CTFontRef font, uint32_t *type)
{
    if (!font)
        return false;
    CFNumberRef record = (CFNumberRef)objc_getAssociatedObject((id)(void *)font, wk_uiFontTypeKey());
    int32_t value = 0;
    if (!record || CFGetTypeID(record) != CFNumberGetTypeID()
        || !CFNumberGetValue(record, kCFNumberSInt32Type, &value))
        return false;
    *type = (uint32_t)value;
    return true;
}

WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateUIFontForLanguage,
                     (CTFontUIFontType uiType, CGFloat size, CFStringRef language))
{
    CTFontRef font = WK_ORIGINAL(CTFontCreateUIFontForLanguage)
        ? WK_ORIGINAL(CTFontCreateUIFontForLanguage)(uiType, size, language) : NULL;
    return wk_recordUIFontType(font, (uint32_t)uiType);
}

WK_POLYFILL_REPLACES("CoreText", CGAffineTransform, CTFontGetMatrix, (CTFontRef font))
{
    CGAffineTransform matrix = WK_ORIGINAL(CTFontGetMatrix)
        ? WK_ORIGINAL(CTFontGetMatrix)(font) : wk_identityFontMatrix;
    if (!wk_matrixScalesToNothing(matrix))
        return matrix;
    // Only a font whose realized map scales to nothing can carry a record (wk_recordFontRequest).
    wk_font_request request;
    if (wk_recordedFontRequest(font, &request))
        return request.matrix;
    return wk_identityFontMatrix;
}

// Recorded for the fonts whose realized map scales to nothing, which are the only ones whose
// composed state differs from what the caller named.
static CTFontRef wk_recordFontRequest(CTFontRef font, CGFloat size, const CGAffineTransform *matrix)
{
    if (!font || !WK_ORIGINAL(CTFontGetMatrix)
        || !wk_matrixScalesToNothing(WK_ORIGINAL(CTFontGetMatrix)(font)))
        return font;
    wk_font_request request = { size, matrix ? *matrix : wk_identityFontMatrix };
    wk_setFontRequest(font, &request);
    return font;
}

// A font with no record scaled to nothing without a boundary this layer holds. CoreText cuts faces
// from a font's own scale as it goes — the fallback face's own next-hop fallback, and the faces it
// derives inside calls that take no font argument this layer replaces — and those inherit a
// scaled-to-nothing map with no caller having named a size or matrix for them. Identity and 0 are
// their honest answers, and this is the one case the answers come from the map rather than from a
// record. The first fallback hop is not one of them: it has a boundary and carries the record
// through it (CTFontCreateForCharactersWithLanguageAndOption above).
static bool wk_fontScalesToNothing(CTFontRef font)
{
    return font && WK_ORIGINAL(CTFontGetMatrix)
        && wk_matrixScalesToNothing(WK_ORIGINAL(CTFontGetMatrix)(font));
}

WK_POLYFILL_REPLACES("CoreText", CGFloat, CTFontGetSize, (CTFontRef font))
{
    // Only a font whose realized map scales to nothing can carry a record (wk_recordFontRequest),
    // so the cheap matrix test gates the associations lookup off every normal font's read.
    if (wk_fontScalesToNothing(font)) {
        wk_font_request request;
        if (wk_recordedFontRequest(font, &request))
            return request.size;
        return 0;
    }
    return WK_ORIGINAL(CTFontGetSize) ? WK_ORIGINAL(CTFontGetSize)(font) : 0;
}

// Vertical metrics. 10.9's CoreText reports hhea's ascender, descender and lineGap for every font --
// measured exact across all 501 faces this machine has installed, at size * hhea value / unitsPerEm --
// and ignores OS/2 fsSelection bit 7, USE_TYPO_METRICS, which asks that sTypoAscender, sTypoDescender
// and sTypoLineGap be used in their place. Newer CoreText honours the bit, and WebCore reads all three
// straight into the font's metrics (Font::platformInit), so on a font that sets it every line box,
// baseline and canvas text measurement is laid out against the wrong numbers.
//
// The three read the same pair of tables, so they share one lookup. The scale is the one CoreText
// applies to the hhea values: point size times the font matrix's vertical scale, over the units per em
// -- measured on a rotated, a skewed and an anisotropically scaled matrix, all of which move the
// reported ascent by exactly matrix.d. Size and matrix come from 10.9 rather than from the replacements
// above, which is what keeps a font whose realized map scales to nothing answering 0 for all three.
typedef struct {
    int16_t ascent;
    int16_t descent;
    int16_t lineGap;
    double scale;
} wk_typo_metrics;

static bool wk_typoMetrics(CTFontRef font, wk_typo_metrics *metrics)
{
    if (!font)
        return false;
    CFDataRef os2 = CTFontCopyTable(font, kCTFontTableOS2, kCTFontTableOptionNoOptions);
    if (!os2)
        return false;
    // fsSelection at 62, sTypoAscender/Descender/LineGap at 68/70/72, in every OS/2 version.
    bool useTypoMetrics = CFDataGetLength(os2) >= 74 && (wk_be16(CFDataGetBytePtr(os2) + 62) & 0x80);
    if (useTypoMetrics) {
        const uint8_t *table = CFDataGetBytePtr(os2);
        metrics->ascent = (int16_t)wk_be16(table + 68);
        metrics->descent = (int16_t)wk_be16(table + 70);
        metrics->lineGap = (int16_t)wk_be16(table + 72);
    }
    CFRelease(os2);
    if (!useTypoMetrics)
        return false;
    unsigned unitsPerEm = CTFontGetUnitsPerEm(font);
    if (!unitsPerEm)
        return false;
    CGFloat size = WK_ORIGINAL(CTFontGetSize) ? WK_ORIGINAL(CTFontGetSize)(font) : 0;
    CGAffineTransform matrix = WK_ORIGINAL(CTFontGetMatrix)
        ? WK_ORIGINAL(CTFontGetMatrix)(font) : wk_identityFontMatrix;
    metrics->scale = (double)size * matrix.d / unitsPerEm;
    return true;
}

WK_POLYFILL_REPLACES("CoreText", CGFloat, CTFontGetAscent, (CTFontRef font))
{
    wk_typo_metrics metrics;
    if (wk_typoMetrics(font, &metrics))
        return (CGFloat)(metrics.ascent * metrics.scale);
    return WK_ORIGINAL(CTFontGetAscent) ? WK_ORIGINAL(CTFontGetAscent)(font) : 0;
}

// CoreText's descent grows downward from zero, the opposite of sTypoDescender's sign.
WK_POLYFILL_REPLACES("CoreText", CGFloat, CTFontGetDescent, (CTFontRef font))
{
    wk_typo_metrics metrics;
    if (wk_typoMetrics(font, &metrics))
        return (CGFloat)(-metrics.descent * metrics.scale);
    return WK_ORIGINAL(CTFontGetDescent) ? WK_ORIGINAL(CTFontGetDescent)(font) : 0;
}

WK_POLYFILL_REPLACES("CoreText", CGFloat, CTFontGetLeading, (CTFontRef font))
{
    wk_typo_metrics metrics;
    if (wk_typoMetrics(font, &metrics))
        return (CGFloat)(metrics.lineGap * metrics.scale);
    return WK_ORIGINAL(CTFontGetLeading) ? WK_ORIGINAL(CTFontGetLeading)(font) : 0;
}

// The "none" request rides the descriptor the way wk_font_request rides a font. CTFontDescriptorRef
// is toll-free bridged to NSFontDescriptor, so the record lives and dies with the descriptor.
static const void *wk_opticalSizeIsDefaultKey(void)
{
    // Cached: sel_registerName hashes under the runtime lock, and this runs per metric read.
    // The SEL is the one address every image's copy of this archive agrees on.
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_opticalSizeIsDefault");
    return key;
}

static CTFontDescriptorRef wk_markOpticalSizeDefault(CTFontDescriptorRef descriptor)
{
    if (descriptor)
        objc_setAssociatedObject((id)(void *)descriptor, wk_opticalSizeIsDefaultKey(),
                                 (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return descriptor;
}

static bool wk_opticalSizeIsDefault(CTFontDescriptorRef descriptor)
{
    return descriptor && objc_getAssociatedObject((id)(void *)descriptor, wk_opticalSizeIsDefaultKey()) != NULL;
}

// An optical size of "none" is a request 10.9 has no attribute value for, so the descriptor entry
// points below leave it off the descriptor and mark it instead (the block on the optical size states
// why). A descriptor answers for what it was asked for, so the two readers put the request back.
WK_POLYFILL_REPLACES("CoreText", CFDictionaryRef, CTFontDescriptorCopyAttributes, (CTFontDescriptorRef descriptor))
{
    CFDictionaryRef attributes = WK_ORIGINAL(CTFontDescriptorCopyAttributes)
        ? WK_ORIGINAL(CTFontDescriptorCopyAttributes)(descriptor) : NULL;
    if (!wk_opticalSizeIsDefault(descriptor))
        return attributes;
    CFMutableDictionaryRef named = attributes
        ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes)
        : CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (attributes)
        CFRelease(attributes);
    if (named)
        CFDictionarySetValue(named, kCTFontOpticalSizeAttribute, CFSTR("none"));
    return named;
}

// A descriptor's own attributes -- the set it CARRIES. CTFontDescriptorCopyAttribute answers by
// MATCHING, so a descriptor holding nothing but a weight still answers kCTFontNameAttribute with the
// default face's name; only this entry point separates what a caller asked for from what a match
// would supply. It reads through CoreText's own implementation: the request this layer records on a
// descriptor is answered above, and the readers here act on the record itself.
static CFTypeRef wk_carriedAttribute(CTFontDescriptorRef descriptor, CFStringRef key)
{
    if (!descriptor || !WK_ORIGINAL(CTFontDescriptorCopyAttributes))
        return NULL;
    CFDictionaryRef attributes = WK_ORIGINAL(CTFontDescriptorCopyAttributes)(descriptor);
    if (!attributes)
        return NULL;
    CFTypeRef value = CFDictionaryGetValue(attributes, key);
    if (value)
        CFRetain(value);
    CFRelease(attributes);
    return value;
}

// kCTFontOpticalSizeAttribute takes a CFNumber here: the optical size, in points, that a realized
// font's advances and tracking are looked up at. The CFString forms "auto" and "none" are a later
// convention, and this CoreText reads the attribute as a number whatever it holds, so a string
// leaves the optical size uninitialized and every metric derived from it follows. Measured on-host
// at 19.8pt: Apple Color Emoji advances -5.3e8 rather than 22.88, a different value each run. The
// points named are their own state, distinct from naming none: Hoefler Text advances 29.360 at 40pt
// with no optical size named, 30.360 at 6 and 28.630 at 40; faces with no tracking table measure the
// same at every value.
//
// "auto" is the point size the font is realized at, and it stays "auto": a copy taken at another
// size looks the optical size up at THAT size, and the attribute reads back as the string. The
// resolution happens where a font is realized because that is where the point size is known, and
// because CoreText's own cascade fallback copies its attributes from the realized font.
//
// "none" is the optical axis at its default, which is the state of a descriptor that names no
// optical size at all, so the descriptor entry points below leave that form off the descriptor they
// build and mark the descriptor with the request instead. CoreText has no way to take an attribute
// back out of a descriptor -- a copy only ever adds -- and assembling a replacement from
// CTFontDescriptorCopyAttributes keeps the attributes and nothing else, where a descriptor minted
// from data is identified by the CGFont it is bound to.
typedef enum {
    WK_OPTICAL_SIZE_UNNAMED,        // the attributes carry none
    WK_OPTICAL_SIZE_EXPLICIT,       // a size in points, which 10.9 takes as it stands
    WK_OPTICAL_SIZE_POINT_SIZE,     // "auto"
    WK_OPTICAL_SIZE_DEFAULT         // "none"
} wk_optical_size_request;

// Whether an attributes dictionary names the axis default: a CFString other than "auto", which is
// every spelling of the request the descriptor entry points below do not carry through.
static bool wk_attributesNameOpticalSizeDefault(CFDictionaryRef attributes)
{
    CFTypeRef value = attributes && CFGetTypeID(attributes) == CFDictionaryGetTypeID()
        ? CFDictionaryGetValue(attributes, kCTFontOpticalSizeAttribute) : NULL;
    return value && CFGetTypeID(value) == CFStringGetTypeID() && !CFEqual((CFStringRef)value, CFSTR("auto"));
}

static wk_optical_size_request wk_opticalSizeRequest(CTFontDescriptorRef descriptor)
{
    if (wk_opticalSizeIsDefault(descriptor))
        return WK_OPTICAL_SIZE_DEFAULT;
    CFTypeRef value = wk_carriedAttribute(descriptor, kCTFontOpticalSizeAttribute);
    if (!value)
        return WK_OPTICAL_SIZE_UNNAMED;
    // "auto" is the one string form a descriptor built through this layer carries.
    wk_optical_size_request request = CFGetTypeID(value) == CFStringGetTypeID()
        ? WK_OPTICAL_SIZE_POINT_SIZE : WK_OPTICAL_SIZE_EXPLICIT;
    CFRelease(value);
    return request;
}

// A font realized for "auto" answers the string and re-resolves when it is copied to another size,
// so the request rides the font the way wk_font_request does.
static const void *wk_opticalSizeFollowsPointSizeKey(void)
{
    // Cached: sel_registerName hashes under the runtime lock, and this runs per metric read.
    // The SEL is the one address every image's copy of this archive agrees on.
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_opticalSizeFollowsPointSize");
    return key;
}

static CTFontRef wk_markOpticalSizeFollowsPointSize(CTFontRef font)
{
    if (font)
        objc_setAssociatedObject((id)(void *)font, wk_opticalSizeFollowsPointSizeKey(),
                                 (id)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return font;
}

static bool wk_opticalSizeFollowsPointSize(CTFontRef font)
{
    return font && objc_getAssociatedObject((id)(void *)font, wk_opticalSizeFollowsPointSizeKey()) != NULL;
}

// The point size a request realizes at: the caller's, else the descriptor's own, else `unnamedSize`,
// which is how every CoreText entry point taking a size and a descriptor resolves the pair.
static CGFloat wk_resolvedPointSize(CTFontDescriptorRef descriptor, CGFloat size, CGFloat unnamedSize)
{
    if (size != 0)
        return size;
    CGFloat resolved = unnamedSize;
    CFTypeRef named = wk_carriedAttribute(descriptor, kCTFontSizeAttribute);
    if (named) {
        double points = 0;
        if (CFGetTypeID(named) == CFNumberGetTypeID()
            && CFNumberGetValue((CFNumberRef)named, kCFNumberDoubleType, &points))
            resolved = (CGFloat)points;
        CFRelease(named);
    }
    return resolved;
}

// The descriptor to realize through: the caller's with the optical size written in as `points`. A
// copy carries everything the source descriptor is, its CGFont binding included, where a descriptor
// assembled from CTFontDescriptorCopyAttributes carries only what that dictionary holds and realizes
// as whichever installed face the attributes match. `descriptor` may be NULL, which is how a copy
// carries its source's "auto" forward without any attributes of its own.
static CTFontDescriptorRef wk_descriptorWithOpticalSize(CTFontDescriptorRef descriptor, CGFloat points)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &points);
    if (!number)
        return NULL;
    const void *keys[] = { kCTFontOpticalSizeAttribute };
    const void *values[] = { number };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    if (!attributes)
        return NULL;
    CTFontDescriptorRef result = descriptor
        ? CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
        : CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    return result;
}

// The attribute form of the same two answers. The size a system fallback face is read back at is
// FontCache::systemFallbackForCharacterCluster -> lookupFallbackFont -> preparePlatformFont, where
// UnrealizedCoreTextFont::getSize() takes it from CTFontCopyAttribute (UnrealizedCoreTextFont.cpp:62)
// and realizes the fallback at it, so a `font-size: 0` cluster outside the primary font — CJK, kana,
// emoji, symbols — stays at size 0 through the fallback.

static bool wk_fontIsUserInstalled(CTFontRef font);

// A variable font built from bytes, and the variation its source realizes at; defined with the
// replacements that answer for such a font.
static CTFontDescriptorRef wk_variableFontSource(CTFontRef font);
static CFDictionaryRef wk_copyRealizedVariation(CTFontDescriptorRef descriptor);

WK_POLYFILL_REPLACES("CoreText", CFTypeRef, CTFontCopyAttribute, (CTFontRef font, CFStringRef attribute))
{
    if (font && attribute && CFEqual(attribute, kCTFontTraitsAttribute))
        return CTFontCopyTraits(font);
    if (font && attribute && (CFEqual(attribute, kCTFontPaletteAttribute) || CFEqual(attribute, kCTFontPaletteColorsAttribute))) {
        CFTypeRef carried = (CFTypeRef)objc_getAssociatedObject((id)(void *)font,
            CFEqual(attribute, kCTFontPaletteAttribute) ? wk_paletteKey() : wk_paletteColorsKey());
        if (carried)
            return CFRetain(carried);
    }
    if (font && attribute && CFEqual(attribute, kCTFontUserInstalledAttribute))
        return CFRetain(wk_fontIsUserInstalled(font) ? (CFTypeRef)kCFBooleanTrue : (CFTypeRef)kCFBooleanFalse);
    if (font && attribute && CFEqual(attribute, kCTFontFallbackOptionAttribute)) {
        CFTypeRef fallback = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, wk_fallbackOptionKey());
        if (fallback)
            return CFRetain(fallback);
    }

    if (attribute && CFEqual(attribute, kCTFontVariationAttribute)) {
        CTFontDescriptorRef source = wk_variableFontSource(font);
        if (source)
            return wk_copyRealizedVariation(source);
    }

    // The attribute compares gate the matrix probe, and the matrix probe gates the associations
    // lookup: only a font whose realized map scales to nothing can carry a record.
    if (attribute && (CFEqual(attribute, kCTFontSizeAttribute) || CFEqual(attribute, kCTFontMatrixAttribute))
        && wk_fontScalesToNothing(font)) {
        wk_font_request request;
        bool recorded = wk_recordedFontRequest(font, &request);
        if (CFEqual(attribute, kCTFontSizeAttribute)) {
            CGFloat size = recorded ? request.size : 0;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &size);
        }
        CGAffineTransform matrix = recorded ? request.matrix : wk_identityFontMatrix;
        return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&matrix, sizeof(matrix));
    }
    // A font realized for an optical size of "auto" reports the request, not the points it resolved
    // to, because the points move with the size the font is copied to.
    if (attribute && CFEqual(attribute, kCTFontOpticalSizeAttribute) && wk_opticalSizeFollowsPointSize(font))
        return CFRetain(CFSTR("auto"));
    return WK_ORIGINAL(CTFontCopyAttribute) ? WK_ORIGINAL(CTFontCopyAttribute)(font, attribute) : NULL;
}

static const void *wk_userInstalledKey(void) { static char key; return &key; }

// A font is one the system provides when its family is one a stock macOS Tahoe installation makes available
// to web content, a hidden dot-prefixed system face, or the LastResort face CoreText falls back to for any
// character, and a file on disk registered beyond this process holds it. A font made from bytes or
// registered for this process alone is the user's.
static bool wk_fontIsUserInstalled(CTFontRef font)
{
    CFBooleanRef cached = (CFBooleanRef)objc_getAssociatedObject((id)(void *)font, wk_userInstalledKey());
    if (cached)
        return cached == kCFBooleanTrue;
    bool userInstalled = true;
    CFTypeRef url = WK_ORIGINAL(CTFontCopyAttribute)(font, kCTFontURLAttribute);
    CFTypeRef scope = url ? WK_ORIGINAL(CTFontCopyAttribute)(font, kCTFontRegistrationScopeAttribute) : NULL;
    int scopeValue = 0;
    if (scope && CFGetTypeID(scope) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)scope, kCFNumberIntType, &scopeValue);
    if (url && scopeValue != kCTFontManagerScopeProcess) {
        CFTypeRef family = WK_ORIGINAL(CTFontCopyAttribute)(font, kCTFontFamilyNameAttribute);
        char name[256];
        if (family && CFGetTypeID(family) == CFStringGetTypeID()
            && CFStringGetCString((CFStringRef)family, name, sizeof(name), kCFStringEncodingUTF8))
            userInstalled = !(name[0] == '.' || !strcmp(name, "LastResort") || wk_font_family_ships_with_tahoe(name));
        if (family)
            CFRelease(family);
    }
    if (scope)
        CFRelease(scope);
    if (url)
        CFRelease(url);
    objc_setAssociatedObject((id)(void *)font, wk_userInstalledKey(), (id)(userInstalled ? kCFBooleanTrue : kCFBooleanFalse), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return userInstalled;
}

static CTFontRef wk_copySystemFallback(CTFontRef current, const UniChar *characters, CFIndex length, CFStringRef language, CFIndex *coveredLength)
{
    CFArrayRef languages = language ? CFArrayCreate(kCFAllocatorDefault, (const void **)&language, 1, &kCFTypeArrayCallBacks) : NULL;
    CFArrayRef cascade = CTFontCopyDefaultCascadeListForLanguages(current, languages);
    if (languages)
        CFRelease(languages);
    CGGlyph *glyphs = malloc(sizeof(CGGlyph) * (size_t)length);
    if (!glyphs)
        abort();
    CTFontRef result = NULL;
    for (CFIndex i = 0; cascade && i < CFArrayGetCount(cascade); ++i) {
        CTFontRef candidate = CTFontCreateWithFontDescriptor((CTFontDescriptorRef)CFArrayGetValueAtIndex(cascade, i), CTFontGetSize(current), NULL);
        if (candidate && !wk_fontIsUserInstalled(candidate)
            && CTFontGetGlyphsForCharacters(candidate, characters, glyphs, length)
            && length > 0 && glyphs[0] && glyphs[0] != kCGFontIndexInvalid) {
            result = candidate;
            break;
        }
        if (candidate)
            CFRelease(candidate);
    }
    free(glyphs);
    if (cascade)
        CFRelease(cascade);
    if (coveredLength)
        *coveredLength = result ? length : 0;
    return result;
}

// A descriptor whose kCTFontUserInstalledAttribute is false, matched with that attribute mandatory, matches
// only the faces the system provides (wk_fontIsUserInstalled); 10.9's matcher does not know the key and
// matches every face.
static bool wk_descriptorRequiresSystemFont(CTFontDescriptorRef descriptor, CFSetRef mandatory)
{
    if (!descriptor || !mandatory || !CFSetContainsValue(mandatory, kCTFontUserInstalledAttribute))
        return false;
    CFTypeRef requested = wk_carriedAttribute(descriptor, kCTFontUserInstalledAttribute);
    bool result = requested == kCFBooleanFalse;
    if (requested)
        CFRelease(requested);
    return result;
}

static bool wk_descriptorIsUserInstalled(CTFontDescriptorRef descriptor)
{
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 0, NULL);
    bool result = font && wk_fontIsUserInstalled(font);
    if (font)
        CFRelease(font);
    return result;
}

// A macOS Tahoe family this system has no face of is matched as its stand-in family
// (wk_font_family_stand_in); a face of the family itself, wherever it is installed, is matched first.
static CTFontDescriptorRef wk_copyStandInDescriptor(CTFontDescriptorRef descriptor)
{
    CFTypeRef family = descriptor ? CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) : NULL;
    char name[256];
    const char *standIn = NULL;
    if (family && CFGetTypeID(family) == CFStringGetTypeID()
        && CFStringGetCString((CFStringRef)family, name, sizeof(name), kCFStringEncodingUTF8))
        standIn = wk_font_family_stand_in(name);
    if (family)
        CFRelease(family);
    if (!standIn)
        return NULL;
    CFStringRef standInFamily = CFStringCreateWithCString(kCFAllocatorDefault, standIn, kCFStringEncodingUTF8);
    const void *keys[] = { kCTFontFamilyNameAttribute };
    const void *values[] = { standInFamily };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef result = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes);
    CFRelease(attributes);
    CFRelease(standInFamily);
    return result;
}

static CTFontDescriptorRef wk_bestShippedMatch(CTFontDescriptorRef, CFArrayRef);

// The system's match for one descriptor, with user-installed faces dropped where the descriptor asks
// for system fonts only, and NULL for no match left. The stand-in fallbacks go through these rather
// than back through the entry points, so a stand-in target cannot re-enter the fallback.
static CFArrayRef wk_copyShippedMatchingDescriptors(CTFontDescriptorRef, CFSetRef);
static CTFontDescriptorRef wk_copyShippedMatchingDescriptor(CTFontDescriptorRef, CFSetRef);

WK_POLYFILL_REPLACES("CoreText", CFArrayRef, CTFontDescriptorCreateMatchingFontDescriptors,
    (CTFontDescriptorRef descriptor, CFSetRef mandatoryAttributes))
{
    CFArrayRef matches = wk_copyShippedMatchingDescriptors(descriptor, mandatoryAttributes);
    if (matches)
        return matches;
    CTFontDescriptorRef standIn = wk_copyStandInDescriptor(descriptor);
    if (!standIn)
        return NULL;
    matches = wk_copyShippedMatchingDescriptors(standIn, mandatoryAttributes);
    CFRelease(standIn);
    return matches;
}

WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateMatchingFontDescriptor,
    (CTFontDescriptorRef descriptor, CFSetRef mandatoryAttributes))
{
    CTFontDescriptorRef match = wk_copyShippedMatchingDescriptor(descriptor, mandatoryAttributes);
    if (match)
        return match;
    CTFontDescriptorRef standIn = wk_copyStandInDescriptor(descriptor);
    if (!standIn)
        return NULL;
    match = wk_copyShippedMatchingDescriptor(standIn, mandatoryAttributes);
    CFRelease(standIn);
    return match;
}

static CFArrayRef wk_copyShippedMatchingDescriptors(CTFontDescriptorRef descriptor, CFSetRef mandatoryAttributes)
{
    CFArrayRef matches = WK_ORIGINAL(CTFontDescriptorCreateMatchingFontDescriptors)
        ? WK_ORIGINAL(CTFontDescriptorCreateMatchingFontDescriptors)(descriptor, mandatoryAttributes) : NULL;
    if (matches && wk_descriptorRequiresSystemFont(descriptor, mandatoryAttributes)) {
        CFMutableArrayRef shipped = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0, count = CFArrayGetCount(matches); i < count; ++i) {
            CTFontDescriptorRef match = (CTFontDescriptorRef)CFArrayGetValueAtIndex(matches, i);
            if (!wk_descriptorIsUserInstalled(match))
                CFArrayAppendValue(shipped, match);
        }
        CFRelease(matches);
        matches = shipped;
    }
    if (matches && !CFArrayGetCount(matches)) {
        CFRelease(matches);
        return NULL;
    }
    return matches;
}

static CTFontDescriptorRef wk_copyShippedMatchingDescriptor(CTFontDescriptorRef descriptor, CFSetRef mandatoryAttributes)
{
    CTFontDescriptorRef match = WK_ORIGINAL(CTFontDescriptorCreateMatchingFontDescriptor)(descriptor, mandatoryAttributes);
    if (!match)
        return NULL;
    if (!wk_descriptorRequiresSystemFont(descriptor, mandatoryAttributes) || !wk_descriptorIsUserInstalled(match))
        return match;
    CFRelease(match);
    CFArrayRef matches = wk_copyShippedMatchingDescriptors(descriptor, mandatoryAttributes);
    if (!matches)
        return NULL;
    match = wk_bestShippedMatch(descriptor, matches);
    CFRelease(matches);
    return match;
}

static bool wk_descriptorScalesToNothing(CTFontDescriptorRef descriptor)
{
    if (!descriptor)
        return false;
    CFTypeRef value = CTFontDescriptorCopyAttribute(descriptor, kCTFontMatrixAttribute);
    if (!value)
        return false;
    bool scalesToNothing = false;
    if (CFGetTypeID(value) == CFDataGetTypeID()
        && CFDataGetLength((CFDataRef)value) >= (CFIndex)sizeof(CGAffineTransform)) {
        CGAffineTransform matrix;
        CFDataGetBytes((CFDataRef)value, CFRangeMake(0, sizeof(matrix)), (UInt8 *)&matrix);
        scalesToNothing = wk_matrixScalesToNothing(matrix);
    }
    CFRelease(value);
    return scalesToNothing;
}

static bool wk_descriptorNamesZeroSize(CTFontDescriptorRef descriptor)
{
    if (!descriptor)
        return false;
    CFTypeRef value = CTFontDescriptorCopyAttribute(descriptor, kCTFontSizeAttribute);
    if (!value)
        return false;
    double named = 1;
    bool zero = CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &named) && named == 0;
    CFRelease(value);
    return zero;
}

// The matrix a request realizes through, written into `composed` when the size folds into it. Size
// and matrix compose into one linear map, so a size of 0 takes the caller's matrix onto the zero
// scale: a request whose source is already scaled to nothing, or whose descriptor names a size of 0,
// realizes through that composition. Past that a caller-supplied matrix stands, and an explicit size
// supersedes a scaled-to-nothing source, re-deriving through the matrix that source recorded.
static const CGAffineTransform *wk_fontMatrixForRequest(bool sourceScalesToNothing, CTFontDescriptorRef sizeSource,
                                                        CGFloat size, const CGAffineTransform *matrix,
                                                        const CGAffineTransform *sourceMatrix,
                                                        CGAffineTransform *composed)
{
    if (size == 0 && (sourceScalesToNothing || wk_descriptorNamesZeroSize(sizeSource))) {
        *composed = matrix ? CGAffineTransformConcat(*matrix, wk_zeroSizeFontMatrix) : wk_zeroSizeFontMatrix;
        return composed;
    }
    if (matrix)
        return matrix;
    if (size != 0 && sourceScalesToNothing)
        return sourceMatrix ? sourceMatrix : &wk_identityFontMatrix;
    return NULL;
}

// The face a descriptor's weight, width and slant traits select, applied below with the
// trait-selection machinery this shares with CTFontCreateCopyWithAttributes.
// kCTFontDescriptorOptionSystemUIFont travels on the descriptor a font was realized from, and this
// layer substitutes faces and rebuilds descriptors: both have to carry it, because stock 10.9 keeps
// it across the same operations and WebCore::isSystemFont() reads it back off the result.
extern bool CTFontDescriptorIsSystemUIFont(CTFontDescriptorRef);
extern CTFontDescriptorRef CTFontDescriptorCreateWithAttributesAndOptions(CFDictionaryRef, uint32_t);

#define WK_SYSTEM_UI_FONT_OPTION (1u << 1) /* kCTFontDescriptorOptionSystemUIFont */

static bool wk_descriptorIsSystemUI(CTFontDescriptorRef descriptor)
{
    return descriptor && CTFontDescriptorIsSystemUIFont(descriptor);
}

static CTFontRef wkApplyTraitsToFace(CTFontRef copy, CTFontDescriptorRef attributes);

// The descriptor 10.9 can realize, out of the one the caller wrote, or NULL when they are the same.
//
// Two things in a descriptor 10.9 cannot use. A kCTFontWeightTrait, kCTFontWidthTrait or
// kCTFontSlantTrait whose value is not the default face's fails the WHOLE match and takes the rest of
// the descriptor down with it -- measured on this host, {family "Helvetica Neue", weight 0.4}
// realizes .LucidaGrandeUI, the family name gone along with the weight -- so the three come out here
// and reach a face through wkApplyTraitsToFace instead. And the UI design token names a font family
// rather than a face: kCTFontUIFontDesignMonospaced names Menlo, the one monospaced family 10.9 ships
// that carries the weight and the slant the same descriptor asks for beside the token (Regular, Bold,
// Italic and BoldItalic, in /System/Library/Fonts/Menlo.ttc), while serif and rounded have no 10.9
// system design and name nothing, leaving the descriptor to realize the system UI font it already
// does. A descriptor that names a font of its own keeps it; the token answers only the ui-serif /
// ui-monospace / ui-rounded shape SystemFontDatabaseCoreText::createSystemDesignFont writes, which
// names none.
static CTFontDescriptorRef wk_realizableDescriptor(CTFontDescriptorRef descriptor)
{
    if (!descriptor || !WK_ORIGINAL(CTFontDescriptorCopyAttributes))
        return NULL;
    CFDictionaryRef attributes = WK_ORIGINAL(CTFontDescriptorCopyAttributes)(descriptor);
    if (!attributes)
        return NULL;

    CFDictionaryRef traits = (CFDictionaryRef)CFDictionaryGetValue(attributes, kCTFontTraitsAttribute);
    if (traits && CFGetTypeID(traits) != CFDictionaryGetTypeID())
        traits = NULL;
    bool namesAFont = CFDictionaryContainsKey(attributes, kCTFontNameAttribute)
        || CFDictionaryContainsKey(attributes, kCTFontFamilyNameAttribute);
    CFTypeRef design = traits ? CFDictionaryGetValue(traits, kCTFontUIFontDesignTrait) : NULL;
    bool wantsMonospaced = !namesAFont && design && CFGetTypeID(design) == CFStringGetTypeID()
        && CFEqual(design, kCTFontUIFontDesignMonospaced);
    bool hasMatchingTraits = traits && (CFDictionaryContainsKey(traits, kCTFontWeightTrait)
        || CFDictionaryContainsKey(traits, kCTFontWidthTrait)
        || CFDictionaryContainsKey(traits, kCTFontSlantTrait));
    if (!wantsMonospaced && !hasMatchingTraits) {
        CFRelease(attributes);
        return NULL;
    }

    CFMutableDictionaryRef realizable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
    CFMutableDictionaryRef reducedTraits = traits
        ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, traits) : NULL;
    CFRelease(attributes);
    CTFontDescriptorRef realized = NULL;
    if (realizable && (reducedTraits || !traits)) {
        if (reducedTraits) {
            CFDictionaryRemoveValue(reducedTraits, kCTFontWeightTrait);
            CFDictionaryRemoveValue(reducedTraits, kCTFontWidthTrait);
            CFDictionaryRemoveValue(reducedTraits, kCTFontSlantTrait);
            if (CFDictionaryGetCount(reducedTraits))
                CFDictionarySetValue(realizable, kCTFontTraitsAttribute, reducedTraits);
            else
                CFDictionaryRemoveValue(realizable, kCTFontTraitsAttribute);
        }
        if (wantsMonospaced)
            CFDictionarySetValue(realizable, kCTFontFamilyNameAttribute, CFSTR("Menlo"));
        realized = CTFontDescriptorCreateWithAttributesAndOptions(realizable,
            wk_descriptorIsSystemUI(descriptor) ? WK_SYSTEM_UI_FONT_OPTION : 0);
    }
    if (reducedTraits)
        CFRelease(reducedTraits);
    if (realizable)
        CFRelease(realizable);
    return realized;
}

// kCTFontVariationAttribute on a font this OS instances itself. 10.9 discards the WHOLE dictionary when
// it names an axis the font has not got, or gives an axis a value outside its range; newer CoreText
// applies the axes it recognizes and clamps each value into range. Measured on Skia, whose 'a' is
// 31.0938 wide at 80pt on the fvar defaults: {wght 1.5454} widens it to 34.2969, while {wght 1.5454,
// slnt 0} and {wght 700} both leave it at 31.0938. Every WebCore realization asks for all of wght, wdth
// and a slope axis (UnrealizedCoreTextFont::modifyFromContext), and almost no variable font carries all
// three, so on this OS the request is thrown away and every variable font renders at its default
// instance. Rewriting the request to the axes the font has, each value clamped, realizes the instance
// newer CoreText realizes from the same dictionary.
//
// Answers NULL when the request is already one 10.9 realizes as it stands, and when nothing in it
// survives the rewrite -- the default instance, which is the font in hand either way.
static bool wk_axisTagValue(CFNumberRef number, uint32_t *tag)
{
    long long raw = 0;
    if (CFGetTypeID(number) != CFNumberGetTypeID() || !CFNumberGetValue(number, kCFNumberLongLongType, &raw))
        return false;
    *tag = (uint32_t)raw;
    return true;
}

typedef struct {
    uint32_t tag;
    double value;
    bool found;
} wk_axis_lookup;

// kCTFontVariationAttribute keys an axis by a CFNumber holding its four-character code.
static void wk_matchRequestedAxis(const void *key, const void *value, void *context)
{
    wk_axis_lookup *lookup = (wk_axis_lookup *)context;
    uint32_t tag = 0;
    double number = 0;
    if (!wk_axisTagValue((CFNumberRef)key, &tag) || tag != lookup->tag || CFGetTypeID(value) != CFNumberGetTypeID()
        || !CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number))
        return;
    lookup->value = number;
    lookup->found = true;
}

static bool wk_requestedAxisValue(CFDictionaryRef requested, uint32_t tag, double *value)
{
    wk_axis_lookup lookup = { tag, 0, false };
    CFDictionaryApplyFunction(requested, wk_matchRequestedAxis, &lookup);
    if (lookup.found)
        *value = lookup.value;
    return lookup.found;
}

static CFDictionaryRef wk_realizableVariations(CFArrayRef axes, CFDictionaryRef requested)
{
    CFIndex requestedCount = CFDictionaryGetCount(requested);
    CFIndex axisCount = CFArrayGetCount(axes);
    CFMutableDictionaryRef realizable = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    bool rewritten = false;
    for (CFIndex i = 0; realizable && i < axisCount; i++) {
        CFDictionaryRef axis = (CFDictionaryRef)CFArrayGetValueAtIndex(axes, i);
        if (CFGetTypeID(axis) != CFDictionaryGetTypeID())
            continue;
        CFNumberRef identifier = (CFNumberRef)CFDictionaryGetValue(axis, kCTFontVariationAxisIdentifierKey);
        CFNumberRef minimum = (CFNumberRef)CFDictionaryGetValue(axis, kCTFontVariationAxisMinimumValueKey);
        CFNumberRef maximum = (CFNumberRef)CFDictionaryGetValue(axis, kCTFontVariationAxisMaximumValueKey);
        double lowest = 0, highest = 0;
        uint32_t tag = 0;
        if (!identifier || !minimum || !maximum
            || !wk_axisTagValue(identifier, &tag)
            || !CFNumberGetValue(minimum, kCFNumberDoubleType, &lowest)
            || !CFNumberGetValue(maximum, kCFNumberDoubleType, &highest))
            continue;
        double value = 0;
        if (!wk_requestedAxisValue(requested, tag, &value))
            continue;
        double clamped = value < lowest ? lowest : (value > highest ? highest : value);
        if (clamped != value)
            rewritten = true;
        CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &tag);
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &clamped);
        if (key && number)
            CFDictionarySetValue(realizable, key, number);
        if (key)
            CFRelease(key);
        if (number)
            CFRelease(number);
    }
    if (realizable && !rewritten && CFDictionaryGetCount(realizable) == requestedCount) {
        CFRelease(realizable);
        return NULL;
    }
    return realizable;
}

// Variable fonts built from bytes. Such a font draws from a static cut of its sfnt, which carries none of
// what makes the font variable, so 10.9 reports no axes, no variation and no variation tables for it.
// The font keeps the descriptor it was realized from -- the source bytes and the variation request ride on
// it -- and the replacements below answer from that the way newer CoreText answers from the variable font:
// the axes and the variation in the form 10.9 reports an installed variable font's, the tables the cut
// lacks from the source, and a descriptor that realizes the same font. A copy of the font realizes that
// descriptor with the copy's attributes laid over it.
static const void *wk_variableFontSourceKey(void)
{
    // Cached: sel_registerName hashes under the runtime lock, and this runs per table and attribute read.
    // The SEL is the one address every image's copy of this archive agrees on.
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_variableFontSource");
    return key;
}

static CTFontRef wk_recordVariableFontSource(CTFontRef font, CTFontDescriptorRef descriptor)
{
    if (font)
        objc_setAssociatedObject((id)(void *)font, wk_variableFontSourceKey(), (id)(void *)descriptor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return font;
}

static CTFontDescriptorRef wk_variableFontSource(CTFontRef font)
{
    return font ? (CTFontDescriptorRef)(void *)objc_getAssociatedObject((id)(void *)font, wk_variableFontSourceKey()) : NULL;
}

static CFDataRef wk_variableFontSourceData(CTFontRef font)
{
    CTFontDescriptorRef descriptor = wk_variableFontSource(font);
    return descriptor ? (CFDataRef)wk_carriedAttribute(descriptor, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY) : NULL;
}

// 10.9 reports an axis value, 16.16 in the font, truncated to four decimal places: an fvar minimum of
// -12.34567 reads -12.3456.
static double wk_reportedAxisValue(int32_t fixed)
{
    return (double)((int64_t)fixed * 625 / 4096) / 10000.0;
}

static wk_legacy_variable_font_axis *wk_copySourceAxes(CFDataRef source, CFIndex *count)
{
    CFIndex available = source ? wk_legacy_variable_font_copy_axes(source, NULL, 0) : 0;
    wk_legacy_variable_font_axis *axes = available > 0
        ? (wk_legacy_variable_font_axis *)calloc((size_t)available, sizeof(*axes)) : NULL;
    if (axes)
        *count = wk_legacy_variable_font_copy_axes(source, axes, available);
    return axes;
}

static void wk_releaseSourceAxes(wk_legacy_variable_font_axis *axes, CFIndex count)
{
    for (CFIndex i = 0; i < count; i++) {
        if (axes[i].name)
            CFRelease(axes[i].name);
    }
    free(axes);
}

static CFArrayRef wk_copyVariationAxesOfSource(CFDataRef source)
{
    CFIndex count = 0;
    wk_legacy_variable_font_axis *axes = wk_copySourceAxes(source, &count);
    if (!axes)
        return NULL;
    CFMutableArrayRef result = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; result && i < count; i++) {
        int32_t tag = (int32_t)axes[i].tag;
        double minimum = wk_reportedAxisValue(axes[i].minimumValue);
        double maximum = wk_reportedAxisValue(axes[i].maximumValue);
        double defaultValue = wk_reportedAxisValue(axes[i].defaultValue);
        CFNumberRef identifier = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &tag);
        CFNumberRef minimumNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &minimum);
        CFNumberRef maximumNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &maximum);
        CFNumberRef defaultNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &defaultValue);
        const void *keys[] = { kCTFontVariationAxisIdentifierKey, kCTFontVariationAxisMinimumValueKey,
            kCTFontVariationAxisMaximumValueKey, kCTFontVariationAxisDefaultValueKey, kCTFontVariationAxisNameKey };
        const void *values[] = { identifier, minimumNumber, maximumNumber, defaultNumber, axes[i].name };
        CFDictionaryRef axis = CFDictionaryCreate(kCFAllocatorDefault, keys, values, axes[i].name ? 5 : 4,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (axis) {
            CFArrayAppendValue(result, axis);
            CFRelease(axis);
        }
        CFRelease(identifier);
        CFRelease(minimumNumber);
        CFRelease(maximumNumber);
        CFRelease(defaultNumber);
    }
    wk_releaseSourceAxes(axes, count);
    return result;
}

// The value every axis of a descriptor's source realizes at under its request: the requested value
// clamped into the axis's range, or the axis's default.
static CFDictionaryRef wk_copyRealizedVariation(CTFontDescriptorRef descriptor)
{
    CFDataRef source = (CFDataRef)wk_carriedAttribute(descriptor, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY);
    CFDictionaryRef request = (CFDictionaryRef)wk_carriedAttribute(descriptor, kCTFontVariationAttribute);
    bool haveRequest = request && CFGetTypeID(request) == CFDictionaryGetTypeID();
    CFIndex count = 0;
    wk_legacy_variable_font_axis *axes = wk_copySourceAxes(source, &count);
    CFMutableDictionaryRef result = axes ? CFDictionaryCreateMutable(kCFAllocatorDefault, count,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
    for (CFIndex i = 0; result && i < count; i++) {
        int32_t tag = (int32_t)axes[i].tag;
        double minimum = wk_reportedAxisValue(axes[i].minimumValue);
        double maximum = wk_reportedAxisValue(axes[i].maximumValue);
        double value = wk_reportedAxisValue(axes[i].defaultValue);
        double requested = 0;
        if (haveRequest && wk_requestedAxisValue(request, axes[i].tag, &requested))
            value = requested < minimum ? minimum : (requested > maximum ? maximum : requested);
        CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &tag);
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &value);
        CFDictionarySetValue(result, key, number);
        CFRelease(key);
        CFRelease(number);
    }
    if (axes)
        wk_releaseSourceAxes(axes, count);
    if (request)
        CFRelease(request);
    if (source)
        CFRelease(source);
    return result;
}

WK_POLYFILL_REPLACES("CoreText", CFArrayRef, CTFontCopyVariationAxes, (CTFontRef font))
{
    CFDataRef source = wk_variableFontSourceData(font);
    if (!source)
        return WK_ORIGINAL(CTFontCopyVariationAxes) ? WK_ORIGINAL(CTFontCopyVariationAxes)(font) : NULL;
    CFArrayRef axes = wk_copyVariationAxesOfSource(source);
    CFRelease(source);
    return axes;
}

WK_POLYFILL_REPLACES("CoreText", CFDictionaryRef, CTFontCopyVariation, (CTFontRef font))
{
    CTFontDescriptorRef descriptor = wk_variableFontSource(font);
    if (!descriptor)
        return WK_ORIGINAL(CTFontCopyVariation) ? WK_ORIGINAL(CTFontCopyVariation)(font) : NULL;
    return wk_copyRealizedVariation(descriptor);
}

static CTFontDescriptorRef wk_descriptorWithGraphicsFont(CTFontRef font, CTFontDescriptorRef descriptor)
{
    if (!descriptor)
        return NULL;
    CGFontRef graphics = (CGFontRef)objc_getAssociatedObject((id)(void *)font, sel_registerName("wk_fontGraphicsFont"));
    if (graphics) {
        const void *key = CFSTR("WKFontGraphicsFont");
        const void *value = graphics;
        CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, &key, &value, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef copy = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes);
        CFRelease(attributes);
        CFRelease(descriptor);
        descriptor = copy;
    }
    return descriptor;
}

WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontCopyFontDescriptor, (CTFontRef font))
{
    CTFontDescriptorRef descriptor = wk_variableFontSource(font);
    if (!descriptor)
        return wk_descriptorWithGraphicsFont(font, wk_descriptorWithCarriedOptions(font,
            WK_ORIGINAL(CTFontCopyFontDescriptor) ? WK_ORIGINAL(CTFontCopyFontDescriptor)(font) : NULL));
    CGFloat size = CTFontGetSize(font);
    CFNumberRef sizeNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &size);
    const void *keys[] = { kCTFontSizeAttribute };
    const void *values[] = { sizeNumber };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(sizeNumber);
    CTFontDescriptorRef result = attributes ? CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes) : NULL;
    if (attributes)
        CFRelease(attributes);
    return wk_descriptorWithCarriedOptions(font, result);
}

static CFComparisonResult wk_compareTableTags(const void *left, const void *right, void *context)
{
    (void)context;
    return (uintptr_t)left < (uintptr_t)right ? kCFCompareLessThan
        : ((uintptr_t)left > (uintptr_t)right ? kCFCompareGreaterThan : kCFCompareEqualTo);
}

WK_POLYFILL_REPLACES("CoreText", CFArrayRef, CTFontCopyAvailableTables, (CTFontRef font, CTFontTableOptions options))
{
    CFArrayRef own = WK_ORIGINAL(CTFontCopyAvailableTables) ? WK_ORIGINAL(CTFontCopyAvailableTables)(font, options) : NULL;
    CFDataRef source = wk_variableFontSourceData(font);
    if (!source)
        return own;
    CFIndex count = wk_legacy_variable_font_table_tags(source, NULL, 0);
    uint32_t *tags = count > 0 ? (uint32_t *)calloc((size_t)count, sizeof(*tags)) : NULL;
    CFMutableArrayRef tables = own ? CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, own)
        : CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    if (tags && tables) {
        count = wk_legacy_variable_font_table_tags(source, tags, count);
        for (CFIndex i = 0; i < count; i++) {
            const void *tag = (const void *)(uintptr_t)tags[i];
            if (!CFArrayContainsValue(tables, CFRangeMake(0, CFArrayGetCount(tables)), tag))
                CFArrayAppendValue(tables, tag);
        }
        CFArraySortValues(tables, CFRangeMake(0, CFArrayGetCount(tables)), wk_compareTableTags, NULL);
    }
    free(tags);
    CFRelease(source);
    if (own)
        CFRelease(own);
    return tables;
}

WK_POLYFILL_REPLACES("CoreText", CFDataRef, CTFontCopyTable, (CTFontRef font, CTFontTableTag table, CTFontTableOptions options))
{
    CFDataRef own = WK_ORIGINAL(CTFontCopyTable) ? WK_ORIGINAL(CTFontCopyTable)(font, table, options) : NULL;
    CFDataRef source = own ? NULL : wk_variableFontSourceData(font);
    if (!source)
        return own;
    CFDataRef copied = wk_legacy_variable_font_copy_table(source, table);
    CFRelease(source);
    return copied;
}

// FontParser's averaged glyph heights include overshoot. OS/2 supplies the font's
// typographic cap and x heights, including MVAR deltas in a realized static instance.
static bool wk_os2Height(CTFontRef font, CFIndex offset, CGFloat *height)
{
    if (!font)
        return false;
    CFDataRef nativeVariations = WK_ORIGINAL(CTFontCopyTable)(font, 'MVAR', kCTFontTableOptionNoOptions);
    if (nativeVariations) {
        CFRelease(nativeVariations);
        return false;
    }
    CFDataRef os2 = wk_fontTable(font, sel_registerName("wk_os2Style"), kCTFontTableOS2);
    if (!os2 || CFDataGetLength(os2) < offset + 2)
        return false;
    const UInt8 *bytes = CFDataGetBytePtr(os2);
    uint16_t version = ((uint16_t)bytes[0] << 8) | bytes[1];
    int16_t units = (int16_t)(((uint16_t)bytes[offset] << 8) | bytes[offset + 1]);
    unsigned unitsPerEm = CTFontGetUnitsPerEm(font);
    if (version < 2 || !units || !unitsPerEm)
        return false;
    CGFloat scale = CTFontGetSize(font) / unitsPerEm;
    CGAffineTransform matrix = CGAffineTransformScale(CTFontGetMatrix(font), scale, scale);
    *height = CGPointApplyAffineTransform(CGPointMake(0, units), matrix).y;
    return true;
}

WK_POLYFILL_REPLACES("CoreText", CGFloat, CTFontGetCapHeight, (CTFontRef font))
{
    CGFloat height;
    return wk_os2Height(font, 88, &height) ? height : WK_ORIGINAL(CTFontGetCapHeight)(font);
}

WK_POLYFILL_REPLACES("CoreText", CGFloat, CTFontGetXHeight, (CTFontRef font))
{
    CGFloat height;
    return wk_os2Height(font, 86, &height) ? height : WK_ORIGINAL(CTFontGetXHeight)(font);
}

// A copy's attributes with their variation request rewritten against the axes of the font being copied,
// or NULL when the request realizes as it stands. 10.9 lays a request it realizes over the copied font's
// own variation, and copies under one it drops at the default instance: Skia varied to {wght 1.5454}
// measures 40.625 copied under {wdth 1.2} and 31.0938 under {wdth 1.2, slnt 0}, while an empty request
// leaves it at 34.2969.
static CTFontDescriptorRef wk_attributesWithRealizableVariations(CTFontRef font, CTFontDescriptorRef attributes)
{
    if (!font || !attributes || !WK_ORIGINAL(CTFontCopyVariationAxes))
        return NULL;
    CFArrayRef axes = WK_ORIGINAL(CTFontCopyVariationAxes)(font);
    if (!axes)
        return NULL;
    CFDictionaryRef requested = (CFDictionaryRef)wk_carriedAttribute(attributes, kCTFontVariationAttribute);
    CFDictionaryRef realizable = requested && CFGetTypeID(requested) == CFDictionaryGetTypeID()
        ? wk_realizableVariations(axes, requested) : NULL;
    CFRelease(axes);
    if (requested)
        CFRelease(requested);
    if (!realizable)
        return NULL;
    // Built afresh: a descriptor copy merges the two variation dictionaries, keeping the axis 10.9 drops
    // the request over.
    CFDictionaryRef carried = CTFontDescriptorCopyAttributes(attributes);
    CFMutableDictionaryRef replaced = carried ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, carried) : NULL;
    if (carried)
        CFRelease(carried);
    CTFontDescriptorRef result = NULL;
    if (replaced) {
        CFDictionarySetValue(replaced, kCTFontVariationAttribute, realizable);
        result = CTFontDescriptorCreateWithAttributesAndOptions(replaced,
            wk_descriptorIsSystemUI(attributes) ? WK_SYSTEM_UI_FONT_OPTION : 0);
        CFRelease(replaced);
    }
    CFRelease(realizable);
    return result;
}

// The font `descriptor` asks for, with its variation request rewritten to one this OS realizes; defined
// below, beside the copy entry point it reaches CoreText's own implementation through.
static CTFontRef wk_fontWithRealizableVariations(CTFontRef font, CTFontDescriptorRef descriptor,
                                                 CGFloat size, const CGAffineTransform *matrix);

// The font with its optical size inside the range its 'trak' table covers; defined beside the above.
static CTFontRef wk_fontWithTrackingSizeInRange(CTFontRef font);


// CTFontCreateWithFontDescriptor / ...AndOptions — DELIBERATE REPLACEMENTS of present-but-broken
// 10.9 functions: they are where a descriptor's kCTFontVariationAttribute is meant to take effect
// and where 10.9 instead drops it (see the block comment above), where its weight and width traits
// are meant to select a face and 10.9 hands back the default one -- the route ui-serif, ui-monospace
// and ui-rounded reach their weight through, since SystemFontDatabaseCoreText::createSystemDesignFont
// names no font to copy from -- and where a size names the scale of the realized font. Every other
// request realizes through 10.9's own implementation, unchanged.
WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithFontDescriptor,
                     (CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix))
{
    const CGAffineTransform *requested = matrix;
    CTFontDescriptorRef requestedDescriptor = descriptor;
    CGAffineTransform composed;
    wk_optical_size_request opticalSize = wk_opticalSizeRequest(descriptor);
    CTFontDescriptorRef resolved = opticalSize == WK_OPTICAL_SIZE_POINT_SIZE
        ? wk_descriptorWithOpticalSize(descriptor, wk_resolvedPointSize(descriptor, size, 12.0)) : NULL;
    if (resolved)
        descriptor = resolved;
    matrix = wk_fontMatrixForRequest(wk_descriptorScalesToNothing(descriptor), descriptor, size, matrix, NULL, &composed);
    bool carriesSource = false;
    CTFontRef instance = wk_realizeVariableFontInstance(descriptor, size, matrix, &carriesSource);
    if (!instance) {
        CTFontDescriptorRef realizable = wk_realizableDescriptor(descriptor);
        CTFontDescriptorRef nativeDescriptor = realizable ? realizable : descriptor;
        CGFontRef graphics = nativeDescriptor ? (CGFontRef)wk_carriedAttribute(nativeDescriptor, CFSTR("WKFontGraphicsFont")) : NULL;
        instance = graphics ? CTFontCreateWithGraphicsFont(graphics, size, matrix, nativeDescriptor)
            : WK_ORIGINAL(CTFontCreateWithFontDescriptor)(nativeDescriptor, size, matrix);
        if (graphics)
            CGFontRelease(graphics);
        if (realizable)
            CFRelease(realizable);
        instance = wkApplyTraitsToFace(instance, descriptor);
        instance = wk_fontWithRealizableVariations(instance, descriptor, size, matrix);
    }
    instance = wk_fontWithTrackingSizeInRange(instance);
    if (resolved)
        CFRelease(resolved);
    if (opticalSize == WK_OPTICAL_SIZE_POINT_SIZE)
        wk_markOpticalSizeFollowsPointSize(instance);
    if (carriesSource)
        wk_recordVariableFontSource(instance, requestedDescriptor);
    return wk_recordFontRequest(wk_recordDescriptorOptions(instance, requestedDescriptor), size, requested);
}

WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithFontDescriptorAndOptions,
                     (CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CFOptionFlags options))
{
    const CGAffineTransform *requested = matrix;
    CTFontDescriptorRef requestedDescriptor = descriptor;
    CGAffineTransform composed;
    wk_optical_size_request opticalSize = wk_opticalSizeRequest(descriptor);
    CTFontDescriptorRef resolved = opticalSize == WK_OPTICAL_SIZE_POINT_SIZE
        ? wk_descriptorWithOpticalSize(descriptor, wk_resolvedPointSize(descriptor, size, 12.0)) : NULL;
    if (resolved)
        descriptor = resolved;
    matrix = wk_fontMatrixForRequest(wk_descriptorScalesToNothing(descriptor), descriptor, size, matrix, NULL, &composed);
    bool carriesSource = false;
    CTFontRef instance = wk_realizeVariableFontInstance(descriptor, size, matrix, &carriesSource);
    if (!instance) {
        CTFontDescriptorRef realizable = wk_realizableDescriptor(descriptor);
        CTFontDescriptorRef nativeDescriptor = realizable ? realizable : descriptor;
        CGFontRef graphics = nativeDescriptor ? (CGFontRef)wk_carriedAttribute(nativeDescriptor, CFSTR("WKFontGraphicsFont")) : NULL;
        instance = graphics ? CTFontCreateWithGraphicsFont(graphics, size, matrix, nativeDescriptor)
            : WK_ORIGINAL(CTFontCreateWithFontDescriptorAndOptions)(nativeDescriptor, size, matrix, options);
        if (graphics)
            CGFontRelease(graphics);
        if (realizable)
            CFRelease(realizable);
        instance = wkApplyTraitsToFace(instance, descriptor);
        instance = wk_fontWithRealizableVariations(instance, descriptor, size, matrix);
    }
    instance = wk_fontWithTrackingSizeInRange(instance);
    if (resolved)
        CFRelease(resolved);
    if (opticalSize == WK_OPTICAL_SIZE_POINT_SIZE)
        wk_markOpticalSizeFollowsPointSize(instance);
    if (carriesSource)
        wk_recordVariableFontSource(instance, requestedDescriptor);
    return wk_recordFontRequest(wk_recordDescriptorOptions(instance, requestedDescriptor), size, requested);
}

// An attributes descriptor naming nothing but a kCTFontWeightTrait.
static CTFontDescriptorRef wkWeightRequestDescriptor(CGFloat weight)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &weight);
    if (!number)
        return NULL;
    const void *traitKeys[] = { kCTFontWeightTrait };
    const void *traitValues[] = { number };
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, traitKeys, traitValues, 1,
                                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    if (!traits)
        return NULL;
    const void *keys[] = { kCTFontTraitsAttribute };
    const void *values[] = { traits };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(traits);
    if (!attributes)
        return NULL;
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    return descriptor;
}

// The URL reader preserves the CFF FontMatrix; the graphics font retains the open file.
static CGFontRef wk_createGraphicsFontFromSfnt(CFDataRef data)
{
    if (CFDataGetLength(data) < 4 || wk_be32(CFDataGetBytePtr(data)) != 'OTTO') {
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGFontRef font = provider ? CGFontCreateWithDataProvider(provider) : NULL;
        if (provider)
            CGDataProviderRelease(provider);
        return font;
    }
    char directory[PATH_MAX];
    size_t length = confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory));
    if (!length || length > sizeof(directory))
        return NULL;
    char *path = malloc(strlen(directory) + sizeof("wk-font-XXXXXX"));
    if (!path)
        return NULL;
    strcpy(path, directory);
    strcat(path, "wk-font-XXXXXX");
    int fd = mkstemp(path);
    if (fd < 0) {
        free(path);
        return NULL;
    }
    const UInt8 *bytes = CFDataGetBytePtr(data);
    CFIndex remaining = CFDataGetLength(data);
    while (remaining) {
        ssize_t written = write(fd, bytes, (size_t)remaining);
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0)
            break;
        bytes += written;
        remaining -= written;
    }
    close(fd);
    CGFontRef result = NULL;
    CFURLRef url = NULL;
    if (!remaining) {
        url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, strlen(path), false);
        CFArrayRef descriptors = url ? CTFontManagerCreateFontDescriptorsFromURL(url) : NULL;
        if (descriptors && CFArrayGetCount(descriptors) == 1) {
            const void *keys[] = { kCTFontURLAttribute };
            const void *values[] = { url };
            CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes((CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0), attributes);
            CTFontRef font = WK_ORIGINAL(CTFontCreateWithFontDescriptor)(descriptor, 12, NULL);
            CFRelease(descriptor);
            CFRelease(attributes);
            if (font) {
                result = CTFontCopyGraphicsFont(font, NULL);
                CFRelease(font);
            }
        }
        if (descriptors)
            CFRelease(descriptors);
    }
    if (!result) {
        unlink(path);
        free(path);
        if (url)
            CFRelease(url);
        return NULL;
    }
    unlink(path);
    free(path);
    CFRelease(url);
    objc_setAssociatedObject((id)(void *)result, sel_registerName("wk_cffURLFont"), (id)(void *)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

// The trait values a descriptor carries in its kCTFontTraitsAttribute.
typedef struct {
    bool haveWeight;
    CGFloat weight;
    bool haveWidth;
    CGFloat width;
    bool haveSlant;
    CGFloat slant;
    uint32_t symbolic;
} wk_font_traits;

static bool wkNumberValue(CFDictionaryRef traits, CFStringRef key, CGFloat *out)
{
    CFNumberRef number = (CFNumberRef)CFDictionaryGetValue(traits, key);
    return number && CFGetTypeID(number) == CFNumberGetTypeID()
        && CFNumberGetValue(number, kCFNumberCGFloatType, out);
}

static bool wkTraitsFromDictionary(CFTypeRef traits, wk_font_traits *out)
{
    memset(out, 0, sizeof(*out));
    if (!traits)
        return false;
    bool haveTraits = CFGetTypeID(traits) == CFDictionaryGetTypeID();
    if (haveTraits) {
        CFDictionaryRef dictionary = (CFDictionaryRef)traits;
        out->haveWeight = wkNumberValue(dictionary, kCTFontWeightTrait, &out->weight);
        out->haveWidth = wkNumberValue(dictionary, kCTFontWidthTrait, &out->width);
        out->haveSlant = wkNumberValue(dictionary, kCTFontSlantTrait, &out->slant);
        int32_t bits = 0;
        CFNumberRef symbolicNumber = (CFNumberRef)CFDictionaryGetValue(dictionary, kCTFontSymbolicTrait);
        if (symbolicNumber && CFGetTypeID(symbolicNumber) == CFNumberGetTypeID()
            && CFNumberGetValue(symbolicNumber, kCFNumberSInt32Type, &bits))
            out->symbolic = (uint32_t)bits;
    }
    CFRelease(traits);
    return haveTraits;
}

// The traits a face HAS. A concrete face's descriptor carries no traits dictionary of its own -- a
// CTFontCopyFontDescriptor result carries a name and a size and nothing else -- so its weight and
// width come from the match, which is what CTFontDescriptorCopyAttribute performs.
static bool wkDescriptorTraits(CTFontDescriptorRef descriptor, wk_font_traits *out)
{
    return wkTraitsFromDictionary(CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute), out);
}

// The traits a request ASKS FOR. Matching answers a traits dictionary for every descriptor, weight
// and width included, so the request has to be read from the attributes it carries.
static bool wkRequestedTraits(CTFontDescriptorRef descriptor, wk_font_traits *out)
{
    return wkTraitsFromDictionary(wk_carriedAttribute(descriptor, kCTFontTraitsAttribute), out);
}

// The CSS weight a kCTFontWeightTrait value stands for. The axis is the nine weights CoreText names
// and the interpolation between them, so the CSS weight each landmark carries is the scale a
// difference of two weights is a distance on: kCTFontWeightMedium is one step from regular and two
// from bold, which |0.23 - 0.0| > |0.23 - 0.4| does not say.
static CGFloat wkCSSWeight(CGFloat weight)
{
    // A traits dictionary carries its weight as a single-precision number, so the landmarks are
    // compared at that precision: a face sitting on one has to land on its CSS weight exactly, not
    // a rounding step past it and onto the wrong side of the request.
    const struct { float ct; CGFloat css; } ladder[] = {
        { (float)kCTFontWeightUltraLight, 100 }, { (float)kCTFontWeightThin, 200 }, { (float)kCTFontWeightLight, 300 },
        { (float)kCTFontWeightRegular, 400 }, { (float)kCTFontWeightMedium, 500 }, { (float)kCTFontWeightSemibold, 600 },
        { (float)kCTFontWeightBold, 700 }, { (float)kCTFontWeightHeavy, 800 }, { (float)kCTFontWeightBlack, 900 },
    };
    size_t count = sizeof(ladder) / sizeof(ladder[0]);
    float value = (float)weight;
    if (value <= ladder[0].ct)
        return ladder[0].css;
    for (size_t i = 0; i + 1 < count; ++i) {
        if (value <= ladder[i + 1].ct) {
            CGFloat ratio = (CGFloat)(value - ladder[i].ct) / (CGFloat)(ladder[i + 1].ct - ladder[i].ct);
            return ladder[i].css + ratio * (ladder[i + 1].css - ladder[i].css);
        }
    }
    return ladder[count - 1].css;
}

// The CSS stretch percentage a kCTFontWidthTrait value stands for: -1..1 onto 50%..200%, in the two
// segments that meet at standard width.
static CGFloat wkCSSWidth(CGFloat width)
{
    float value = (float)width;
    return value < 0 ? 100.0 + value * 50.0 : 100.0 + value * 100.0;
}

// How a candidate ranks against a request on one axis. Matching searches one side of the request
// first -- the narrower widths at or below standard and the wider above it, the lighter weights at or
// below 500 and the heavier above -- so a candidate on the searched side beats every candidate off
// it, however far off, and distance orders only the candidates that share a side.
typedef struct {
    bool offSide;
    CGFloat distance;
} wk_axis_rank;

static wk_axis_rank wkAxisRank(CGFloat candidate, CGFloat target, CGFloat pivot)
{
    wk_axis_rank rank;
    rank.offSide = target <= pivot ? candidate > target : candidate < target;
    rank.distance = candidate > target ? candidate - target : target - candidate;
    return rank;
}

// How near a family member sits to the requested traits. Font matching resolves width before weight,
// so the two axes are ranked in that order rather than combined; kCTFontNameAttribute breaks a tie in
// favour of the face the request started from.
typedef struct {
    wk_axis_rank width;
    wk_axis_rank weight;
    bool isSourceFace;
} wk_face_rank;

static wk_face_rank wkRankFace(CGFloat width, CGFloat weight, CGFloat targetWidth, CGFloat targetWeight,
                               bool isSourceFace)
{
    wk_face_rank rank;
    rank.width = wkAxisRank(wkCSSWidth(width), wkCSSWidth(targetWidth), 100.0);
    rank.weight = wkAxisRank(wkCSSWeight(weight), wkCSSWeight(targetWeight), 500.0);
    rank.isSourceFace = isSourceFace;
    return rank;
}

static bool wkRankIsNearer(const wk_face_rank *candidate, const wk_face_rank *best)
{
    if (candidate->width.offSide != best->width.offSide)
        return !candidate->width.offSide;
    if (candidate->width.distance != best->width.distance)
        return candidate->width.distance < best->width.distance;
    if (candidate->weight.offSide != best->weight.offSide)
        return !candidate->weight.offSide;
    if (candidate->weight.distance != best->weight.distance)
        return candidate->weight.distance < best->weight.distance;
    return candidate->isSourceFace && !best->isSourceFace;
}

static CTFontDescriptorRef wk_bestShippedMatch(CTFontDescriptorRef request, CFArrayRef matches)
{
    wk_font_traits wanted;
    wkRequestedTraits(request, &wanted);
    if (!wanted.haveWeight && (wanted.symbolic & kCTFontTraitBold))
        wanted.weight = kCTFontWeightBold;
    if (!wanted.haveWidth && (wanted.symbolic & kCTFontTraitCondensed))
        wanted.width = kCTFontWidthCondensed;
    else if (!wanted.haveWidth && (wanted.symbolic & kCTFontTraitExpanded))
        wanted.width = kCTFontWidthExpanded;
    CTFontDescriptorRef best = NULL;
    wk_face_rank bestRank;
    bool bestSlant = false;
    for (CFIndex i = 0; i < CFArrayGetCount(matches); ++i) {
        CTFontDescriptorRef candidate = (CTFontDescriptorRef)CFArrayGetValueAtIndex(matches, i);
        wk_font_traits traits;
        wkDescriptorTraits(candidate, &traits);
        bool slant = (traits.symbolic & kCTFontTraitItalic) == (wanted.symbolic & kCTFontTraitItalic);
        wk_face_rank rank = wkRankFace(traits.width, traits.weight, wanted.width, wanted.weight, false);
        if (!best || (slant && !bestSlant) || (slant == bestSlant && wkRankIsNearer(&rank, &bestRank))) {
            best = candidate;
            bestRank = rank;
            bestSlant = slant;
        }
    }
    return best ? (CTFontDescriptorRef)CFRetain(best) : NULL;
}

// Realize a family member by name onto the copy's OWN descriptor, so every other attribute the copy
// carries -- kCTFontFallbackOptionAttribute and the user-installed-fonts restriction among them --
// stays on the result.
static CTFontRef wkFontWithFaceName(CTFontRef copy, CFStringRef name)
{
    CTFontDescriptorRef own = CTFontCopyFontDescriptor(copy);
    if (!own)
        return NULL;
    const void *keys[] = { kCTFontNameAttribute };
    const void *values[] = { name };
    CFDictionaryRef nameAttribute = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
                                                       &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontRef font = NULL;
    if (nameAttribute) {
        CTFontDescriptorRef chosen = CTFontDescriptorCreateCopyWithAttributes(own, nameAttribute);
        if (chosen) {
            CGAffineTransform sourceMatrix = CTFontGetMatrix(copy);
            font = CTFontCreateWithFontDescriptor(chosen, CTFontGetSize(copy), &sourceMatrix);
            CFRelease(chosen);
        }
        CFRelease(nameAttribute);
    }
    CFRelease(own);
    return font;
}

// The member of the copy's family nearest the requested width and weight, out of the family's
// enumeration. Slant filters rather than ranks -- an upright face and an italic one are different
// styles, not two distances along an axis -- so the candidates are the members carrying the slant
// asked for, and the members carrying the source's when the family holds no face with it: an upright
// family answers an italic request with its upright face, which WebCore obliques itself
// (FontFamilySpecificationCoreText::fontRanges passes the synthetic oblique it computes). Width and
// weight are ranked, because every family member is a legitimate answer to them.
// The enumeration-and-ranking half of wkNearestEnumeratedFamilyMember: the chosen member's name, or
// NULL when the family gives no answer. The caller owns the returned name.
static CFStringRef wkSelectFamilyMemberName(CFStringRef family, CFStringRef sourceName, const uint32_t slants[2],
                                            CGFloat targetWidth, CGFloat targetWeight)
{
    const void *familyKeys[] = { kCTFontFamilyNameAttribute };
    const void *familyValues[] = { family };
    CFDictionaryRef familyAttributes = CFDictionaryCreate(kCFAllocatorDefault, familyKeys, familyValues, 1,
                                                          &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!familyAttributes)
        return NULL;
    CTFontDescriptorRef familyDescriptor = CTFontDescriptorCreateWithAttributes(familyAttributes);
    CFSetRef mandatory = CFSetCreate(kCFAllocatorDefault, familyKeys, 1, &kCFTypeSetCallBacks);
    CFRelease(familyAttributes);
    CFArrayRef members = (familyDescriptor && mandatory)
        ? CTFontDescriptorCreateMatchingFontDescriptors(familyDescriptor, mandatory) : NULL;
    if (familyDescriptor)
        CFRelease(familyDescriptor);
    if (mandatory)
        CFRelease(mandatory);
    if (!members)
        return NULL;

    // A font whose family name is one an installed family also carries, without its own face being in
    // that family -- a CGFont-backed face, a @font-face whose internal family reads "Helvetica Neue"
    // -- is not a member and has no member to be moved to.
    bool sourceIsMember = false;
    for (CFIndex i = 0, count = CFArrayGetCount(members); !sourceIsMember && i < count; ++i) {
        CFStringRef memberName = (CFStringRef)CTFontDescriptorCopyAttribute(
            (CTFontDescriptorRef)CFArrayGetValueAtIndex(members, i), kCTFontNameAttribute);
        sourceIsMember = memberName && CFEqual(memberName, sourceName);
        if (memberName)
            CFRelease(memberName);
    }
    if (!sourceIsMember) {
        CFRelease(members);
        return NULL;
    }

    CTFontDescriptorRef best = NULL;
    wk_face_rank bestRank;
    CFIndex candidates = 0;
    for (unsigned pass = 0; pass < 2 && !candidates; ++pass) {
        if (pass && slants[1] == slants[0])
            break;
        for (CFIndex i = 0, count = CFArrayGetCount(members); i < count; ++i) {
            CTFontDescriptorRef member = (CTFontDescriptorRef)CFArrayGetValueAtIndex(members, i);
            wk_font_traits traits;
            if (!wkDescriptorTraits(member, &traits) || !traits.haveWeight)
                continue;
            if ((traits.symbolic & kCTFontTraitItalic) != slants[pass])
                continue;
            ++candidates;

            CFStringRef memberName = (CFStringRef)CTFontDescriptorCopyAttribute(member, kCTFontNameAttribute);
            wk_face_rank rank = wkRankFace(traits.haveWidth ? traits.width : 0.0, traits.weight,
                                           targetWidth, targetWeight,
                                           memberName && CFEqual(memberName, sourceName));
            if (memberName)
                CFRelease(memberName);

            if (!best || wkRankIsNearer(&rank, &bestRank)) {
                best = member;
                bestRank = rank;
            }
        }
    }

    // One candidate is the family's only face for this style: an answer when it is not the face the
    // request started from, and nothing to say when it is.
    CFStringRef name = NULL;
    if (best && (candidates > 1 || !bestRank.isSourceFace))
        name = (CFStringRef)CTFontDescriptorCopyAttribute(best, kCTFontNameAttribute);
    CFRelease(members);
    return name;
}

// Memo over wkSelectFamilyMemberName. The choice is a pure function of its arguments and the set of
// installed faces, and the enumeration behind it is a full font-database match paid per font
// realization -- every system-UI request carries the traits that lead here. The installed set can
// change (CTFontManagerRegisterFonts*), and CoreText announces that; the observer flushes the memo.
enum { WK_FACE_MEMO_SLOTS = 32 };
struct wk_face_memo {
    CFStringRef family;      // NULL = empty slot
    CFStringRef source;
    CGFloat targetWidth;
    CGFloat targetWeight;
    uint32_t slants[2];
    CFStringRef face;        // NULL = the family gives no answer (cached too)
};
static struct wk_face_memo wk_faceMemo[WK_FACE_MEMO_SLOTS];
static unsigned wk_faceMemoNext;
// Bumped by every flush, captured before a compute, checked before its insert: a selection computed
// against the pre-flush installed set must not be planted after the flush, where it would outlive
// the very notification meant to clear it.
static unsigned wk_faceMemoFlushGeneration;
static pthread_mutex_t wk_faceMemoLock = PTHREAD_MUTEX_INITIALIZER;

static void wk_faceMemoFlush(CFNotificationCenterRef center, void *observer, CFStringRef name,
                             const void *object, CFDictionaryRef userInfo)
{
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    pthread_mutex_lock(&wk_faceMemoLock);
    ++wk_faceMemoFlushGeneration;
    for (unsigned i = 0; i < WK_FACE_MEMO_SLOTS; ++i) {
        if (!wk_faceMemo[i].family)
            continue;
        CFRelease(wk_faceMemo[i].family);
        CFRelease(wk_faceMemo[i].source);
        if (wk_faceMemo[i].face)
            CFRelease(wk_faceMemo[i].face);
        memset(&wk_faceMemo[i], 0, sizeof(wk_faceMemo[i]));
    }
    pthread_mutex_unlock(&wk_faceMemoLock);
}

static void wk_faceMemoInstallFlushObserver(void)
{
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), wk_faceMemo, wk_faceMemoFlush,
                                    kCTFontManagerRegisteredFontsChangedNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), wk_faceMemo, wk_faceMemoFlush,
                                    kCTFontManagerRegisteredFontsChangedNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static CTFontRef wkNearestEnumeratedFamilyMember(CTFontRef copy, CGFloat targetWidth, CGFloat targetWeight,
                                                 uint32_t wantedSlant)
{
    CFStringRef family = CTFontCopyFamilyName(copy);
    if (!family)
        return NULL;
    CFStringRef sourceName = CTFontCopyPostScriptName(copy);
    if (!sourceName) {
        // No PostScript name means the source cannot be a family member, which is the enumeration's
        // own no-member answer.
        CFRelease(family);
        return NULL;
    }
    uint32_t slants[2] = { wantedSlant, CTFontGetSymbolicTraits(copy) & kCTFontTraitItalic };

    static pthread_once_t observerOnce = PTHREAD_ONCE_INIT;
    pthread_once(&observerOnce, wk_faceMemoInstallFlushObserver);

    CFStringRef face = NULL;
    bool cached = false;
    pthread_mutex_lock(&wk_faceMemoLock);
    unsigned flushGeneration = wk_faceMemoFlushGeneration;
    for (unsigned i = 0; i < WK_FACE_MEMO_SLOTS && !cached; ++i) {
        struct wk_face_memo *memo = &wk_faceMemo[i];
        if (memo->family && memo->targetWidth == targetWidth && memo->targetWeight == targetWeight
            && memo->slants[0] == slants[0] && memo->slants[1] == slants[1]
            && CFEqual(memo->family, family) && CFEqual(memo->source, sourceName)) {
            face = memo->face ? (CFStringRef)CFRetain(memo->face) : NULL;
            cached = true;
        }
    }
    pthread_mutex_unlock(&wk_faceMemoLock);

    if (!cached) {
        face = wkSelectFamilyMemberName(family, sourceName, slants, targetWidth, targetWeight);
        pthread_mutex_lock(&wk_faceMemoLock);
        if (wk_faceMemoFlushGeneration != flushGeneration) {
            pthread_mutex_unlock(&wk_faceMemoLock);
            goto selected;
        }
        struct wk_face_memo *memo = &wk_faceMemo[wk_faceMemoNext++ % WK_FACE_MEMO_SLOTS];
        if (memo->family) {
            CFRelease(memo->family);
            CFRelease(memo->source);
            if (memo->face)
                CFRelease(memo->face);
        }
        memo->family = (CFStringRef)CFRetain(family);
        memo->source = (CFStringRef)CFRetain(sourceName);
        memo->targetWidth = targetWidth;
        memo->targetWeight = targetWeight;
        memo->slants[0] = slants[0];
        memo->slants[1] = slants[1];
        memo->face = face ? (CFStringRef)CFRetain(face) : NULL;
        pthread_mutex_unlock(&wk_faceMemoLock);
    }

selected:
    CFRelease(family);
    CFRelease(sourceName);
    if (!face)
        return NULL;
    CTFontRef selected = wkFontWithFaceName(copy, face);
    CFRelease(face);
    return selected;
}

// The same nearest choice over a family CoreText will not enumerate -- the hidden system UI family
// among them, whose kCTFontFamilyNameAttribute match returns NULL on this host. Its members are still
// reachable one at a time through the bold symbolic trait, so the candidate set is the two faces that
// trait resolves to, each judged by its own kCTFontWeightTrait. The trait carries no width, so this
// route answers a weight request only. NULL when the two faces are the same one.
static CTFontRef wkNearestSymbolicTraitFace(CTFontRef copy, CGFloat targetWeight)
{
    CGFloat size = CTFontGetSize(copy);
    CGAffineTransform matrix = CTFontGetMatrix(copy);
    CTFontRef faces[2];
    faces[0] = CTFontCreateCopyWithSymbolicTraits(copy, size, &matrix, 0, kCTFontTraitBold);
    faces[1] = CTFontCreateCopyWithSymbolicTraits(copy, size, &matrix, kCTFontTraitBold, kCTFontTraitBold);
    CTFontRef chosen = NULL;
    if (faces[0] && faces[1]) {
        CFStringRef lighter = CTFontCopyPostScriptName(faces[0]);
        CFStringRef heavier = CTFontCopyPostScriptName(faces[1]);
        bool distinct = lighter && heavier && !CFEqual(lighter, heavier);
        if (lighter)
            CFRelease(lighter);
        if (heavier)
            CFRelease(heavier);
        if (distinct) {
            CGFloat weights[2] = { 0.0, 0.0 };
            bool haveWeights = true;
            for (int i = 0; i < 2; ++i) {
                CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(faces[i]);
                wk_font_traits traits;
                if (!descriptor || !wkDescriptorTraits(descriptor, &traits) || !traits.haveWeight)
                    haveWeights = false;
                else
                    weights[i] = traits.weight;
                if (descriptor)
                    CFRelease(descriptor);
            }
            if (haveWeights) {
                wk_face_rank lighter = wkRankFace(0.0, weights[0], 0.0, targetWeight, false);
                wk_face_rank heavier = wkRankFace(0.0, weights[1], 0.0, targetWeight, false);
                // The symbolic-trait fonts name the candidates but are not the answer:
                // CTFontCreateCopyWithSymbolicTraits drops the descriptor's options, so the chosen
                // face is minted again by name off the source's own descriptor, which carries them.
                CTFontRef nearest = faces[wkRankIsNearer(&heavier, &lighter) ? 1 : 0];
                CFStringRef nearestName = CTFontCopyPostScriptName(nearest);
                if (nearestName) {
                    chosen = wkFontWithFaceName(copy, nearestName);
                    CFRelease(nearestName);
                }
            }
        }
    }
    for (int i = 0; i < 2; ++i) {
        if (faces[i])
            CFRelease(faces[i]);
    }
    return chosen;
}

// A kCTFontWidthTrait or kCTFontWeightTrait in the attributes selects the family member carrying it.
// 10.9's matcher reads both as filters it cannot satisfy and leaves the face alone -- measured on this
// host for Helvetica, Helvetica Neue, Avenir, Lucida Grande, Menlo and the system UI family alike, at
// every weight from -0.8 to 0.62, by all four routes (copy-with-attributes, descriptor copy, explicit
// matching, family-plus-trait descriptor). So make the selection here, over the copy's family. An axis
// the attributes leave out keeps the copy's own value, which is what a copy inherits.
static CTFontRef wkApplyTraitsToFace(CTFontRef copy, CTFontDescriptorRef attributes)
{
    if (!copy || !attributes)
        return copy;

    // A face the attributes name outright is the caller's own choice of member. The name has to be one
    // the attributes CARRY: matching answers kCTFontNameAttribute for every descriptor, weight-only
    // requests included.
    CFTypeRef namedFace = wk_carriedAttribute(attributes, kCTFontNameAttribute);
    if (namedFace) {
        CFRelease(namedFace);
        return copy;
    }

    wk_font_traits requested;
    if (!wkRequestedTraits(attributes, &requested)
        || (!requested.haveWeight && !requested.haveWidth && !requested.haveSlant))
        return copy;

    wk_font_traits own;
    memset(&own, 0, sizeof(own));
    CTFontDescriptorRef ownDescriptor = CTFontCopyFontDescriptor(copy);
    if (ownDescriptor) {
        wkDescriptorTraits(ownDescriptor, &own);
        CFRelease(ownDescriptor);
    }
    CGFloat targetWidth = requested.haveWidth ? requested.width : (own.haveWidth ? own.width : 0.0);
    CGFloat targetWeight = requested.haveWeight ? requested.weight : (own.haveWeight ? own.weight : 0.0);

    uint32_t wantedSlant = requested.haveSlant ? (requested.slant > 0 ? (uint32_t)kCTFontTraitItalic : 0u)
                                              : (CTFontGetSymbolicTraits(copy) & kCTFontTraitItalic);

    CTFontRef selected = wkNearestEnumeratedFamilyMember(copy, targetWidth, targetWeight, wantedSlant);
    if (!selected && requested.haveWeight)
        selected = wkNearestSymbolicTraitFace(copy, targetWeight);
    if (!selected)
        return copy;
    CFRelease(copy);
    return selected;
}

// The copy entry point, where the source's scale is the font's own and the size that can name a
// new one is the attributes descriptor's. This is how WebCore realizes a font whose base is a
// CTFont rather than a descriptor (UnrealizedCoreTextFont::realize). A NULL matrix here means the
// copy inherits the source font's, so the matrix recorded on the result is the source's recorded one.
WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateCopyWithAttributes,
                     (CTFontRef font, CGFloat size, const CGAffineTransform *matrix, CTFontDescriptorRef attributes))
{
    CTFontDescriptorRef requestedAttributes = attributes;
    wk_font_request source;
    bool haveSource = wk_recordedFontRequest(font, &source);
    const CGAffineTransform *requested = matrix ? matrix : (haveSource ? &source.matrix : NULL);
    // A variable font built from bytes realizes from the descriptor it keeps, the copy's attributes laid over it.
    if (wk_variableFontSource(font)) {
        CTFontDescriptorRef own = CTFontCopyFontDescriptor(font);
        CFDictionaryRef laid = attributes ? CTFontDescriptorCopyAttributes(attributes) : NULL;
        CTFontDescriptorRef merged = own && laid ? CTFontDescriptorCreateCopyWithAttributes(own, laid) : NULL;
        CTFontDescriptorRef realized = merged ? merged : own;
        CTFontRef copy = realized ? CTFontCreateWithFontDescriptor(realized, size, requested) : NULL;
        if (merged)
            CFRelease(merged);
        if (laid)
            CFRelease(laid);
        if (own)
            CFRelease(own);
        return copy;
    }
    CGAffineTransform composed;
    matrix = wk_fontMatrixForRequest(wk_fontScalesToNothing(font), attributes, size, matrix,
                                     haveSource ? &source.matrix : NULL, &composed);
    // Attributes that name no optical size leave the source's request standing, and "auto" resolves
    // against the size the COPY is taken at.
    wk_optical_size_request opticalSize = wk_opticalSizeRequest(attributes);
    if (opticalSize == WK_OPTICAL_SIZE_UNNAMED && wk_opticalSizeFollowsPointSize(font))
        opticalSize = WK_OPTICAL_SIZE_POINT_SIZE;
    CTFontDescriptorRef resolved = opticalSize == WK_OPTICAL_SIZE_POINT_SIZE
        ? wk_descriptorWithOpticalSize(attributes, wk_resolvedPointSize(attributes, size, CTFontGetSize(font))) : NULL;
    if (resolved)
        attributes = resolved;
    CTFontDescriptorRef realizable = wk_attributesWithRealizableVariations(font, attributes);
    if (realizable)
        attributes = realizable;
    CTFontRef copy = WK_ORIGINAL(CTFontCreateCopyWithAttributes)
        ? WK_ORIGINAL(CTFontCreateCopyWithAttributes)(font, size, matrix, attributes) : NULL;
    copy = wkApplyTraitsToFace(copy, attributes);
    copy = wk_fontWithRealizableVariations(copy, attributes, size, matrix);
    copy = wk_fontWithTrackingSizeInRange(copy);
    if (realizable)
        CFRelease(realizable);
    if (resolved)
        CFRelease(resolved);
    if (opticalSize == WK_OPTICAL_SIZE_POINT_SIZE)
        wk_markOpticalSizeFollowsPointSize(copy);
    wk_inheritDescriptorOptions(copy, font, requestedAttributes);
    return wk_recordFontRequest(copy, size, requested);
}

// The font `descriptor` asks for, with its variation request rewritten to one this OS realizes. A
// request that needed rewriting was dropped whole, and a font realized without its request is the
// default instance, which the rewritten request is laid over. The copy entry point rewrites against the
// font it copies before copying, so a copy reaches this only when it realizes a face with other axes.
// The request is read off what the descriptor CARRIES: a matched read answers every descriptor with the
// realized font's own axis values.
static CTFontRef wk_fontWithRealizableVariations(CTFontRef font, CTFontDescriptorRef descriptor,
                                                 CGFloat size, const CGAffineTransform *matrix)
{
    if (!font || !descriptor || !WK_ORIGINAL(CTFontCreateCopyWithAttributes) || !WK_ORIGINAL(CTFontCopyVariationAxes))
        return font;
    // The axis read comes first: it is the cheap one, and it is NULL for every font that has no axes,
    // which every realization that is not of a variable font goes through. It is 10.9's own read, which
    // is NULL for the static cut a variable font built from bytes draws with.
    CFArrayRef axes = WK_ORIGINAL(CTFontCopyVariationAxes)(font);
    if (!axes)
        return font;
    CFDictionaryRef requested = (CFDictionaryRef)wk_carriedAttribute(descriptor, kCTFontVariationAttribute);
    CFDictionaryRef realizable = requested && CFGetTypeID(requested) == CFDictionaryGetTypeID()
        ? wk_realizableVariations(axes, requested) : NULL;
    CFRelease(axes);
    if (requested)
        CFRelease(requested);
    if (realizable && !CFDictionaryGetCount(realizable)) {
        CFRelease(realizable);
        realizable = NULL;
    }
    if (!realizable)
        return font;
    const void *keys[] = { kCTFontVariationAttribute };
    const void *values[] = { realizable };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(realizable);
    CTFontDescriptorRef modification = attributes ? CTFontDescriptorCreateWithAttributes(attributes) : NULL;
    if (attributes)
        CFRelease(attributes);
    if (!modification)
        return font;
    CTFontRef varied = WK_ORIGINAL(CTFontCreateCopyWithAttributes)(font, size, matrix, modification);
    CFRelease(modification);
    if (!varied)
        return font;
    CFRelease(font);
    return varied;
}

// This OS looks a font's 'trak' value up at its optical size (TFont::SetExtras ->
// TAATTrakTable::UnscaledTrackAmountForSize) and carries the table's end segments on past its first
// and last sizes, which takes Apple Color Emoji's tracking to -150 units at 64pt. Newer CoreText holds
// the value of the nearest end size. At an end size this OS's lookup gives that end value exactly, so a
// font whose optical size lies past an end is copied at that end size; a copy with size 0 and no matrix
// keeps the font's own. The horizontal table is the one this OS reads for both orientations.
static CTFontRef wk_fontWithTrackingSizeInRange(CTFontRef font)
{
    if (!font || !WK_ORIGINAL(CTFontCopyAttribute) || !WK_ORIGINAL(CTFontCreateCopyWithAttributes))
        return font;
    CFTypeRef named = WK_ORIGINAL(CTFontCopyAttribute)(font, kCTFontOpticalSizeAttribute);
    double points = 0;
    bool numbered = named && CFGetTypeID(named) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)named, kCFNumberDoubleType, &points);
    if (named)
        CFRelease(named);
    if (!numbered || !(points > 0))
        return font;

    // trak: horizOffset at 6; its track data holds nSizes at 2 and the size table's offset at 4, and
    // the size table is nSizes 16.16 sizes.
    CFDataRef table = CTFontCopyTable(font, kCTFontTableTrak, kCTFontTableOptionNoOptions);
    const uint8_t *bytes = table ? CFDataGetBytePtr(table) : NULL;
    CFIndex length = table ? CFDataGetLength(table) : 0;
    double first = 0, last = 0;
    bool ranged = false;
    if (bytes && length >= 12) {
        uint16_t trackData = wk_be16(bytes + 6);
        if (trackData && (CFIndex)trackData + 8 <= length) {
            uint16_t sizes = wk_be16(bytes + trackData + 2);
            uint32_t sizeTable = wk_be32(bytes + trackData + 4);
            if (sizes >= 2 && sizeTable <= (uint64_t)length && ((uint64_t)length - sizeTable) / 4 >= sizes) {
                first = (int32_t)wk_be32(bytes + sizeTable) / 65536.0;
                last = (int32_t)wk_be32(bytes + sizeTable + 4 * (sizes - 1)) / 65536.0;
                ranged = true;
            }
        }
    }
    if (table)
        CFRelease(table);
    if (!ranged)
        return font;
    double low = first < last ? first : last;
    double high = first < last ? last : first;
    double held = points < low ? low : (points > high ? high : points);
    if (held == points || !(held > 0))
        return font;

    CTFontDescriptorRef modification = wk_descriptorWithOpticalSize(NULL, (CGFloat)held);
    CTFontRef tracked = modification ? WK_ORIGINAL(CTFontCreateCopyWithAttributes)(font, 0, NULL, modification) : NULL;
    if (modification)
        CFRelease(modification);
    if (!tracked)
        return font;
    CFRelease(font);
    return tracked;
}

// The remaining boundaries a caller names a size and a matrix at. 10.9 realizes each of these exactly
// as newer CoreText documents — a size of 0 takes the 12.0 default unconditionally, with no descriptor
// to say otherwise — so the request only has to be recorded on the result, which is what makes a font
// asked for with a scaled-to-nothing matrix report the pair its caller named.
WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithName,
                     (CFStringRef name, CGFloat size, const CGAffineTransform *matrix))
{
    return wk_recordFontRequest(WK_ORIGINAL(CTFontCreateWithName)
        ? WK_ORIGINAL(CTFontCreateWithName)(name, size, matrix) : NULL, size, matrix);
}

WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithNameAndOptions,
                     (CFStringRef name, CGFloat size, const CGAffineTransform *matrix, CFOptionFlags options))
{
    return wk_recordFontRequest(WK_ORIGINAL(CTFontCreateWithNameAndOptions)
        ? WK_ORIGINAL(CTFontCreateWithNameAndOptions)(name, size, matrix, options) : NULL, size, matrix);
}

WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithGraphicsFont,
                     (CGFontRef font, CGFloat size, const CGAffineTransform *matrix, CTFontDescriptorRef attributes))
{
    CTFontRef result = WK_ORIGINAL(CTFontCreateWithGraphicsFont)(font, size, matrix, attributes);
    wk_recordDescriptorOptions(result, attributes);
    if (result && font && objc_getAssociatedObject((id)(void *)font, sel_registerName("wk_cffURLFont")))
        objc_setAssociatedObject((id)(void *)result, sel_registerName("wk_fontGraphicsFont"), (id)(void *)font, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return wk_recordFontRequest(result, size, matrix);
}

// CTFontDescriptorCopyAttribute answers the kCTFontCSSWeightAttribute / kCTFontCSSWidthAttribute
// queries that 10.15+ CoreText bakes into every descriptor. 10.9 descriptors carry no such keys,
// so its own implementation answers NULL and WebCore's per-face capability read degrades to
// normal weight/width for every installed face: findClosestFont() then cannot prefer Verdana-Bold
// for a bold request and the engine synthesizes bold over the regular face (it also hides the
// real trait from NSFontManager — the Mail formatting-toolbar state). The answers here derive
// from the descriptor's own kCTFontTraitsAttribute dictionary: kCTFontWeightTrait through the
// same keyframe curve as WebCore's normalizeCTWeight (FontMetricsNormalization.h),
// kCTFontWidthTrait onto the CSS stretch scale (-1..1 maps to 50%..200%, 0 to 100%), with
// symbolic bold/expanded/condensed fallbacks. Every other attribute, and every descriptor the
// system can answer for, takes the system implementation's answer unchanged.
static const struct { float ct; float css; } wk_ct_weight_keyframes[] = {
    { -0.8f, 30 }, { -0.4f, 274 }, { 0.0f, 400 }, { 0.23f, 510 },
    { 0.3f, 590 }, { 0.4f, 700 }, { 0.56f, 860 }, { 0.62f, 1000 },
};

static float wk_normalize_ct_weight(float value)
{
    size_t count = sizeof(wk_ct_weight_keyframes) / sizeof(wk_ct_weight_keyframes[0]);
    if (value < wk_ct_weight_keyframes[0].ct)
        return wk_ct_weight_keyframes[0].css;
    for (size_t i = 0; i + 1 < count; i++) {
        float beforeCT = wk_ct_weight_keyframes[i].ct, afterCT = wk_ct_weight_keyframes[i + 1].ct;
        if (value >= beforeCT && value <= afterCT) {
            float ratio = (value - beforeCT) / (afterCT - beforeCT);
            return ratio * (wk_ct_weight_keyframes[i + 1].css - wk_ct_weight_keyframes[i].css) + wk_ct_weight_keyframes[i].css;
        }
    }
    return wk_ct_weight_keyframes[count - 1].css;
}

WK_POLYFILL_REPLACES("CoreText", CFTypeRef, CTFontDescriptorCopyAttribute,
                     (CTFontDescriptorRef descriptor, CFStringRef attribute))
{
    if (descriptor && attribute && CFEqual(attribute, kCTFontOpticalSizeAttribute)
        && wk_opticalSizeIsDefault(descriptor))
        return CFRetain(CFSTR("none"));
    CFTypeRef value = WK_ORIGINAL(CTFontDescriptorCopyAttribute)
        ? WK_ORIGINAL(CTFontDescriptorCopyAttribute)(descriptor, attribute) : NULL;
    if (value && descriptor && attribute && CFEqual(attribute, kCTFontTraitsAttribute)
        && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        CFTypeRef requestedTraits = wk_carriedAttribute(descriptor, kCTFontTraitsAttribute);
        if (!requestedTraits) {
            CTFontRef font = WK_ORIGINAL(CTFontCreateWithFontDescriptor)(descriptor, 12, NULL);
            if (font) {
                CFDictionaryRef corrected = wk_copyTraitsWithSymbolic((CFDictionaryRef)value, CTFontGetSymbolicTraits(font));
                CFRelease(value);
                value = corrected;
                CFRelease(font);
            }
        } else
            CFRelease(requestedTraits);
    }
    if (value || !descriptor || !attribute)
        return value;
    // A variable font built from bytes draws from a static cut, so 10.9 answers no variation for its
    // descriptor; the variation is the one its source realizes at.
    if (CFEqual(attribute, kCTFontVariationAttribute)) {
        CFTypeRef source = wk_carriedAttribute(descriptor, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY);
        if (!source)
            return NULL;
        CFRelease(source);
        return wk_copyRealizedVariation(descriptor);
    }
    // A descriptor's variation axes. 10.9 answers NULL for kCTFontVariationAxesAttribute -- measured on
    // this host for that key and for two other spellings of it -- while CTFontCopyVariationAxes answers
    // the same array from the realized font, carrying the identifier, minimum, maximum, default and name
    // keys the caller reads. Everything WebKit learns about a variable font enters through this one call
    // (FontCacheCoreText.cpp's variationAxesWithNonLocalizedAxesNames), so without it an @font-face that
    // names a weight range renders at the face's default weight: measured on Skia, "font-weight: 700 800"
    // and no range at all produce byte-identical ink. The names 10.9 returns are localized, which for
    // these axes ("Weight", "Width") is the text the non-localized query answers.
// kCTFontVariationAxesAttribute is 10.13+ in the SDK and absent on the 10.9 runtime; this file supplies
// it (WK_POLYFILL_CONST above), so this reads the layer's own definition.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    bool wantVariationAxes = CFEqual(attribute, kCTFontVariationAxesAttribute);
#pragma clang diagnostic pop
    if (wantVariationAxes) {
        CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 0, NULL);
        if (!font)
            return NULL;
        CFArrayRef axes = CTFontCopyVariationAxes(font);
        CFRelease(font);
        return axes;
    }

    bool wantWeight = CFEqual(attribute, kCTFontCSSWeightAttribute);
    bool wantWidth = !wantWeight && CFEqual(attribute, kCTFontCSSWidthAttribute);
    if (!wantWeight && !wantWidth)
        return NULL;
    CFDictionaryRef traits = WK_ORIGINAL(CTFontDescriptorCopyAttribute)
        ? (CFDictionaryRef)WK_ORIGINAL(CTFontDescriptorCopyAttribute)(descriptor, kCTFontTraitsAttribute) : NULL;
    if (!traits)
        return NULL;
    int32_t symbolic = 0;
    CFNumberRef symbolicNumber = (CFNumberRef)CFDictionaryGetValue(traits, kCTFontSymbolicTrait);
    if (symbolicNumber)
        CFNumberGetValue(symbolicNumber, kCFNumberSInt32Type, &symbolic);
    float trait = 0;
    float css = 0;
    bool have = false;
    CFNumberRef traitNumber = (CFNumberRef)CFDictionaryGetValue(traits, wantWeight ? kCTFontWeightTrait : kCTFontWidthTrait);
    if (traitNumber && CFNumberGetValue(traitNumber, kCFNumberFloatType, &trait)) {
        css = wantWeight ? wk_normalize_ct_weight(trait) : (float)wkCSSWidth(trait);
        have = true;
    } else if (wantWeight && (symbolic & kCTFontTraitBold)) {
        css = 700;
        have = true;
    } else if (wantWidth && (symbolic & kCTFontTraitExpanded)) {
        css = 125;
        have = true;
    } else if (wantWidth && (symbolic & kCTFontTraitCondensed)) {
        css = 75;
        have = true;
    }
    CFRelease(traits);
    if (!have)
        return NULL;
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &css);
}

// ---------------------------------------------------------------------------------------------------
// CSS font-feature-settings.
//
// 10.9's feature processor (TFontFeatures::CopyNonDefaultFeatureSettings, reached from
// CTFontCreateWithFontDescriptor) reads exactly one element form: the pre-10.10 AAT dictionary, keyed by
// kCTFontFeatureTypeIdentifierKey / kCTFontFeatureSelectorIdentifierKey, both CFNumbers. It sends every
// element -objectForKey: and reads both numbers out of the answer, so any other form takes the process
// down — an unrecognized selector on a non-dictionary, a NULL dereference on a dictionary holding half a
// pair. 10.10 and later accept four more forms, which WebCore uses: the OpenType-tag dictionary keyed by
// kCTFontOpenTypeFeatureTag / kCTFontOpenTypeFeatureValue, an array pair of an OpenType tag string and a
// value number, an array pair of an AAT type and selector number, and a bare OpenType tag string. Every
// one of them is reduced here to the AAT dictionary before 10.9 sees it.
//
// Each OpenType tag maps to the AAT (feature type, on-selector, off-selector) triple Apple's Font Feature
// Registry assigns it, so 10.9 applies the feature for real: a value of 0 selects the off selector,
// anything else the on selector. The two OpenType keys are this layer's own tokens (defined above), absent
// from 10.9's CoreText, so matching on them cannot collide with a key the system defines. A tag with no
// entry in the AAT registry — character variants cvNN, and the OpenType-only features outside the AAT
// model — has no 10.9 representation and is dropped.
// ---------------------------------------------------------------------------------------------------

// Apple's Font Feature Registry, read in both directions: an OpenType tag names an AAT (feature type,
// on-selector, off-selector) triple, and an AAT (type, selector) pair names the tag and the value that
// select it. A few off-selectors are the registry's documented numeric defaults, which SFNTLayoutTypes.h
// gives no named constant for (kCharacterShapeType 16, kTextSpacingType 7, kNumberCaseType 2,
// kNumberSpacingType 4, kLetterCaseType 15). The table is in tag order, which is the order the reverse
// reading resolves a pair several tags share.
static const struct { char tag[5]; int type; int on; int off; } wk_aatFeatureMappings[] = {
        { "afrc", kFractionsType, kVerticalFractionsSelector, kNoFractionsSelector },
        { "c2pc", kUpperCaseType, kUpperCasePetiteCapsSelector, kDefaultUpperCaseSelector },
        { "c2sc", kUpperCaseType, kUpperCaseSmallCapsSelector, kDefaultUpperCaseSelector },
        { "calt", kContextualAlternatesType, kContextualAlternatesOnSelector, kContextualAlternatesOffSelector },
        { "case", kCaseSensitiveLayoutType, kCaseSensitiveLayoutOnSelector, kCaseSensitiveLayoutOffSelector },
        { "clig", kLigaturesType, kContextualLigaturesOnSelector, kContextualLigaturesOffSelector },
        { "cpsp", kCaseSensitiveLayoutType, kCaseSensitiveSpacingOnSelector, kCaseSensitiveSpacingOffSelector },
        { "cswh", kContextualAlternatesType, kContextualSwashAlternatesOnSelector, kContextualSwashAlternatesOffSelector },
        { "dlig", kLigaturesType, kRareLigaturesOnSelector, kRareLigaturesOffSelector },
        { "expt", kCharacterShapeType, kExpertCharactersSelector, 16 },
        { "frac", kFractionsType, kDiagonalFractionsSelector, kNoFractionsSelector },
        { "fwid", kTextSpacingType, kMonospacedTextSelector, 7 },
        { "halt", kTextSpacingType, kAltHalfWidthTextSelector, 7 },
        { "hist", kLigaturesType, kHistoricalLigaturesOnSelector, kHistoricalLigaturesOffSelector },
        { "hkna", kAlternateKanaType, kAlternateHorizKanaOnSelector, kAlternateHorizKanaOffSelector },
        { "hlig", kLigaturesType, kHistoricalLigaturesOnSelector, kHistoricalLigaturesOffSelector },
        { "hngl", kTransliterationType, kHanjaToHangulSelector, kNoTransliterationSelector },
        { "hojo", kCharacterShapeType, kHojoCharactersSelector, 16 },
        { "hwid", kTextSpacingType, kHalfWidthTextSelector, 7 },
        { "ital", kItalicCJKRomanType, kCJKItalicRomanOnSelector, kCJKItalicRomanOffSelector },
        { "jp04", kCharacterShapeType, kJIS2004CharactersSelector, 16 },
        { "jp78", kCharacterShapeType, kJIS1978CharactersSelector, 16 },
        { "jp83", kCharacterShapeType, kJIS1983CharactersSelector, 16 },
        { "jp90", kCharacterShapeType, kJIS1990CharactersSelector, 16 },
        { "liga", kLigaturesType, kCommonLigaturesOnSelector, kCommonLigaturesOffSelector },
        { "lnum", kNumberCaseType, kUpperCaseNumbersSelector, 2 },
        { "mgrk", kMathematicalExtrasType, kMathematicalGreekOnSelector, kMathematicalGreekOffSelector },
        { "nlck", kCharacterShapeType, kNLCCharactersSelector, 16 },
        { "onum", kNumberCaseType, kLowerCaseNumbersSelector, 2 },
        { "ordn", kVerticalPositionType, kOrdinalsSelector, kNormalPositionSelector },
        { "palt", kTextSpacingType, kAltProportionalTextSelector, 7 },
        { "pcap", kLowerCaseType, kLowerCasePetiteCapsSelector, kDefaultLowerCaseSelector },
        { "pkna", kTextSpacingType, kProportionalTextSelector, 7 },
        { "pnum", kNumberSpacingType, kProportionalNumbersSelector, 4 },
        { "pwid", kTextSpacingType, kProportionalTextSelector, 7 },
        { "qwid", kTextSpacingType, kQuarterWidthTextSelector, 7 },
        { "ruby", kRubyKanaType, kRubyKanaOnSelector, kRubyKanaOffSelector },
        { "sinf", kVerticalPositionType, kScientificInferiorsSelector, kNormalPositionSelector },
        { "smcp", kLowerCaseType, kLowerCaseSmallCapsSelector, kDefaultLowerCaseSelector },
        { "smpl", kCharacterShapeType, kSimplifiedCharactersSelector, 16 },
        { "subs", kVerticalPositionType, kInferiorsSelector, kNormalPositionSelector },
        { "sups", kVerticalPositionType, kSuperiorsSelector, kNormalPositionSelector },
        { "swsh", kContextualAlternatesType, kSwashAlternatesOnSelector, kSwashAlternatesOffSelector },
        { "titl", kStyleOptionsType, kTitlingCapsSelector, kNoStyleOptionsSelector },
        { "tnam", kCharacterShapeType, kTraditionalNamesCharactersSelector, 16 },
        { "tnum", kNumberSpacingType, kMonospacedNumbersSelector, 4 },
        { "trad", kCharacterShapeType, kTraditionalCharactersSelector, 16 },
        { "twid", kTextSpacingType, kThirdWidthTextSelector, 7 },
        { "unic", kLetterCaseType, 14, 15 },
        { "valt", kTextSpacingType, kAltProportionalTextSelector, 7 },
        { "vhal", kTextSpacingType, kAltHalfWidthTextSelector, 7 },
        { "vkna", kAlternateKanaType, kAlternateVertKanaOnSelector, kAlternateVertKanaOffSelector },
        { "vpal", kTextSpacingType, kAltProportionalTextSelector, 7 },
        { "vrt2", kVerticalSubstitutionType, kSubstituteVerticalFormsOnSelector, kSubstituteVerticalFormsOffSelector },
        { "vrtr", kVerticalSubstitutionType, kSubstituteVerticalFormsOnSelector, kSubstituteVerticalFormsOffSelector },
        { "zero", kTypographicExtrasType, kSlashedZeroOnSelector, kSlashedZeroOffSelector },
};

// The AAT triple for an OpenType tag. Stylistic sets ss01..ss20 are computed: kStylisticAlternativesType
// with on/off selectors running base + 2*(n-1).
static bool wk_aatFeatureForOpenTypeTag(const char *tag, int *type, int *onSelector, int *offSelector)
{
    if (tag[0] == 's' && tag[1] == 's' && tag[2] >= '0' && tag[2] <= '9' && tag[3] >= '0' && tag[3] <= '9') {
        int n = (tag[2] - '0') * 10 + (tag[3] - '0');
        if (n >= 1 && n <= 20) {
            *type = kStylisticAlternativesType;
            *onSelector = kStylisticAltOneOnSelector + 2 * (n - 1);
            *offSelector = kStylisticAltOneOffSelector + 2 * (n - 1);
            return true;
        }
    }

    for (size_t i = 0; i < sizeof(wk_aatFeatureMappings) / sizeof(wk_aatFeatureMappings[0]); i++) {
        if (!memcmp(tag, wk_aatFeatureMappings[i].tag, 4)) {
            *type = wk_aatFeatureMappings[i].type;
            *onSelector = wk_aatFeatureMappings[i].on;
            *offSelector = wk_aatFeatureMappings[i].off;
            return true;
        }
    }
    return false;
}

// The OpenType tag an AAT (feature type, selector) pair belongs to, and the feature value that pair
// selects: a selector names the first tag, in tag order, that turns its feature on, and failing that
// the one tag it turns off. An exclusive type's numeric default is the off-selector of every tag in the
// type — kTextSpacingType's 7 turns off fwid, halt, hwid, palt and six more — and so names none of them.
static bool wk_openTypeTagForAATFeature(int type, int selector, char tag[5], int *value)
{
    if (type == kStylisticAlternativesType) {
        int on = (selector - kStylisticAltOneOnSelector) / 2;
        int off = (selector - kStylisticAltOneOffSelector) / 2;
        int n = 0;
        if (on >= 0 && on < 20 && selector == kStylisticAltOneOnSelector + 2 * on) {
            n = on + 1;
            *value = 1;
        } else if (off >= 0 && off < 20 && selector == kStylisticAltOneOffSelector + 2 * off) {
            n = off + 1;
            *value = 0;
        } else
            return false;
        tag[0] = 's'; tag[1] = 's'; tag[2] = (char)('0' + n / 10); tag[3] = (char)('0' + n % 10); tag[4] = 0;
        return true;
    }

    const char *turnsOn = NULL;
    const char *turnsOff = NULL;
    int turnsOffCount = 0;
    for (size_t i = 0; i < sizeof(wk_aatFeatureMappings) / sizeof(wk_aatFeatureMappings[0]); i++) {
        if (wk_aatFeatureMappings[i].type != type)
            continue;
        if (wk_aatFeatureMappings[i].on == selector && !turnsOn)
            turnsOn = wk_aatFeatureMappings[i].tag;
        if (wk_aatFeatureMappings[i].off == selector) {
            turnsOff = wk_aatFeatureMappings[i].tag;
            turnsOffCount++;
        }
    }
    if (turnsOn) {
        memcpy(tag, turnsOn, 5);
        *value = 1;
        return true;
    }
    if (turnsOffCount == 1) {
        memcpy(tag, turnsOff, 5);
        *value = 0;
        return true;
    }
    return false;
}

typedef enum {
    WK_FEATURE_AAT,               // the AAT dictionary 10.9's parser reads, carried through as it stands
    WK_FEATURE_NORMALIZED,        // *normalized holds the AAT dictionary this element names
    WK_FEATURE_CLEAR,             // *clearedType holds the AAT feature type this element clears
    WK_FEATURE_NO_AAT_EQUIVALENT  // nothing 10.9 can be told, so the element is dropped
} wk_feature_normalization;

static bool wk_intFromNumber(CFTypeRef value, int *result)
{
    return value && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, result);
}

static bool wk_isNull(CFTypeRef value)
{
    return value && CFGetTypeID(value) == CFNullGetTypeID();
}

static CFDictionaryRef wk_aatFeatureDictionary(int type, int selector)
{
    CFNumberRef typeNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &type);
    CFNumberRef selectorNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &selector);
    const void *keys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
    const void *values[] = { typeNumber, selectorNumber };
    CFDictionaryRef result = (typeNumber && selectorNumber)
        ? CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
    if (typeNumber)
        CFRelease(typeNumber);
    if (selectorNumber)
        CFRelease(selectorNumber);
    return result;
}

// The AAT (feature type, on-selector, off-selector) triple an OpenType tag names.
static bool wk_aatFeatureForTagValue(CFTypeRef tagValue, int *type, int *onSelector, int *offSelector)
{
    char tag[8] = { 0 };
    if (!tagValue || CFGetTypeID(tagValue) != CFStringGetTypeID()
        || !CFStringGetCString((CFStringRef)tagValue, tag, sizeof(tag), kCFStringEncodingASCII)
        || strlen(tag) != 4)
        return false;
    return wk_aatFeatureForOpenTypeTag(tag, type, onSelector, offSelector);
}

// The AAT dictionary an OpenType tag and value name, NULL for a tag the registry has no entry for.
static CFDictionaryRef wk_aatDictionaryForOpenTypeTag(CFTypeRef tagValue, int value)
{
    int type = 0, onSelector = 0, offSelector = 0;
    if (!wk_aatFeatureForTagValue(tagValue, &type, &onSelector, &offSelector))
        return NULL;
    return wk_aatFeatureDictionary(type, value ? onSelector : offSelector);
}

// ---------------------------------------------------------------------------------------------------
// Reporting a font's features. From 10.10 each selector dictionary CTFontCopyFeatures returns carries
// kCTFontOpenTypeFeatureTag and kCTFontOpenTypeFeatureValue alongside its AAT identifier, and that tag
// is what WebCore reads: supportsOpenTypeFeature (FontCoreText.cpp) walks these selectors looking for
// the tag it was asked about, which is how Font::supportsOpenTypeAlternateHalfWidths decides whether a
// font has `halt` and so whether TextSpacing's half-width font exists. 10.9's selectors carry only
// CTFeatureSelectorIdentifier, Name, NameID and Default — measured on this host, Hiragino Sans GB W3
// reports feature type 22 selector 6 "Alternate Half Width" with no tag anywhere — so the registry
// above supplies each pair's tag here.
// ---------------------------------------------------------------------------------------------------

// One selector dictionary with its OpenType tag and value, or NULL when the pair names no tag.
static CFDictionaryRef wk_selectorWithOpenTypeTag(CFTypeRef selector, int featureType)
{
    int identifier = 0, value = 0;
    char tag[5] = { 0 };
    if (!selector || CFGetTypeID(selector) != CFDictionaryGetTypeID())
        return NULL;
// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK and absent on the 10.9 runtime; this file
// supplies both (WK_POLYFILL_CONST above), so these read the layer's own definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    if (CFDictionaryGetValue((CFDictionaryRef)selector, kCTFontOpenTypeFeatureTag))
        return NULL;
#pragma clang diagnostic pop
    if (!wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)selector, kCTFontFeatureSelectorIdentifierKey), &identifier)
        || !wk_openTypeTagForAATFeature(featureType, identifier, tag, &value))
        return NULL;

    CFMutableDictionaryRef result = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, (CFDictionaryRef)selector);
    CFStringRef tagString = CFStringCreateWithCString(kCFAllocatorDefault, tag, kCFStringEncodingASCII);
    CFNumberRef valueNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    if (result && tagString && valueNumber) {
// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK and absent on the 10.9 runtime; this file
// supplies both (WK_POLYFILL_CONST above), so these read the layer's own definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
        CFDictionarySetValue(result, kCTFontOpenTypeFeatureTag, tagString);
        CFDictionarySetValue(result, kCTFontOpenTypeFeatureValue, valueNumber);
#pragma clang diagnostic pop
    } else if (result) {
        CFRelease(result);
        result = NULL;
    }
    if (tagString)
        CFRelease(tagString);
    if (valueNumber)
        CFRelease(valueNumber);
    return result;
}

// One feature type's dictionary with every selector of it tagged.
static CFDictionaryRef wk_featureWithOpenTypeTags(CFTypeRef feature)
{
    int featureType = 0;
    if (!feature || CFGetTypeID(feature) != CFDictionaryGetTypeID())
        return NULL;
    if (!wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)feature, kCTFontFeatureTypeIdentifierKey), &featureType))
        return NULL;
    CFTypeRef selectors = CFDictionaryGetValue((CFDictionaryRef)feature, kCTFontFeatureTypeSelectorsKey);
    if (!selectors || CFGetTypeID(selectors) != CFArrayGetTypeID())
        return NULL;

    CFIndex count = CFArrayGetCount((CFArrayRef)selectors);
    CFMutableArrayRef tagged = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    if (!tagged)
        return NULL;
    bool anyTagged = false;
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef selector = CFArrayGetValueAtIndex((CFArrayRef)selectors, i);
        CFDictionaryRef withTag = wk_selectorWithOpenTypeTag(selector, featureType);
        CFArrayAppendValue(tagged, withTag ? (CFTypeRef)withTag : selector);
        if (withTag) {
            CFRelease(withTag);
            anyTagged = true;
        }
    }
    CFMutableDictionaryRef result = anyTagged
        ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, (CFDictionaryRef)feature) : NULL;
    if (result)
        CFDictionarySetValue(result, kCTFontFeatureTypeSelectorsKey, tagged);
    CFRelease(tagged);
    return result;
}

WK_POLYFILL_REPLACES("CoreText", CFArrayRef, CTFontCopyFeatures, (CTFontRef font))
{
    CFArrayRef features = WK_ORIGINAL(CTFontCopyFeatures) ? WK_ORIGINAL(CTFontCopyFeatures)(font) : NULL;
    if (!features)
        return NULL;
    CFIndex count = CFArrayGetCount(features);
    CFMutableArrayRef tagged = CFArrayCreateMutable(kCFAllocatorDefault, count, &kCFTypeArrayCallBacks);
    if (!tagged)
        return features;
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef feature = CFArrayGetValueAtIndex(features, i);
        CFDictionaryRef withTags = wk_featureWithOpenTypeTags(feature);
        CFArrayAppendValue(tagged, withTags ? (CFTypeRef)withTags : feature);
        if (withTags)
            CFRelease(withTags);
    }
    CFRelease(features);
    return tagged;
}

// One feature-settings element, reduced to the AAT dictionary 10.9's parser reads. The forms newer
// CoreText accepts are that dictionary, the OpenType dictionary, an array pair of an OpenType tag
// string and a value number, an array pair of an AAT type and selector number, and a bare OpenType tag
// string, which enables the feature. A kCFNull in place of the selector or the value is the 10.12 form
// that clears the element's feature type from the descriptor being copied, and is reported as such.
// What is left — a tag outside the AAT registry, a dictionary naming only half a pair — names no 10.9
// feature and is dropped. Dropping is what keeps the process alive: 10.9 sends every element
// -objectForKey: and reads both AAT numbers out of the answer, so a non-dictionary element raises an
// unrecognized selector and a half-populated one dereferences NULL.
static wk_feature_normalization wk_normalizeFeatureElement(CFTypeRef element, CFDictionaryRef *normalized,
                                                           int *clearedType)
{
    *normalized = NULL;
    *clearedType = 0;
    if (!element)
        return WK_FEATURE_NO_AAT_EQUIVALENT;
    CFTypeID elementType = CFGetTypeID(element);
    int onSelector = 0, offSelector = 0;

    if (elementType == CFDictionaryGetTypeID()) {
        CFDictionaryRef dictionary = (CFDictionaryRef)element;
        int aatType = 0, aatSelector = 0;
        bool namesType = wk_intFromNumber(CFDictionaryGetValue(dictionary, kCTFontFeatureTypeIdentifierKey), &aatType);
        if (namesType && wk_isNull(CFDictionaryGetValue(dictionary, kCTFontFeatureSelectorIdentifierKey))) {
            *clearedType = aatType;
            return WK_FEATURE_CLEAR;
        }
        if (namesType
            && wk_intFromNumber(CFDictionaryGetValue(dictionary, kCTFontFeatureSelectorIdentifierKey), &aatSelector))
            return WK_FEATURE_AAT;
// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK and absent on the 10.9 runtime; this file
// supplies both (WK_POLYFILL_CONST above), so these read the layer's own definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
        CFTypeRef tagValue = CFDictionaryGetValue(dictionary, kCTFontOpenTypeFeatureTag);
        if (wk_isNull(CFDictionaryGetValue(dictionary, kCTFontOpenTypeFeatureValue))) {
            if (!wk_aatFeatureForTagValue(tagValue, clearedType, &onSelector, &offSelector))
                return WK_FEATURE_NO_AAT_EQUIVALENT;
            return WK_FEATURE_CLEAR;
        }
        int value = 1;
        if (!wk_intFromNumber(CFDictionaryGetValue(dictionary, kCTFontOpenTypeFeatureValue), &value))
            value = 1;
#pragma clang diagnostic pop
        *normalized = wk_aatDictionaryForOpenTypeTag(tagValue, value);
        return *normalized ? WK_FEATURE_NORMALIZED : WK_FEATURE_NO_AAT_EQUIVALENT;
    }

    if (elementType == CFStringGetTypeID()) {
        *normalized = wk_aatDictionaryForOpenTypeTag(element, 1);
        return *normalized ? WK_FEATURE_NORMALIZED : WK_FEATURE_NO_AAT_EQUIVALENT;
    }

    if (elementType == CFArrayGetTypeID()) {
        CFArrayRef pair = (CFArrayRef)element;
        CFIndex count = CFArrayGetCount(pair);
        if (count < 1)
            return WK_FEATURE_NO_AAT_EQUIVALENT;
        CFTypeRef first = CFArrayGetValueAtIndex(pair, 0);
        CFTypeRef second = count > 1 ? CFArrayGetValueAtIndex(pair, 1) : NULL;
        int aatType = 0, aatSelector = 0;
        if (wk_intFromNumber(first, &aatType)) {
            if (wk_isNull(second)) {
                *clearedType = aatType;
                return WK_FEATURE_CLEAR;
            }
            if (wk_intFromNumber(second, &aatSelector))
                *normalized = wk_aatFeatureDictionary(aatType, aatSelector);
        } else if (wk_isNull(second)) {
            if (!wk_aatFeatureForTagValue(first, clearedType, &onSelector, &offSelector))
                return WK_FEATURE_NO_AAT_EQUIVALENT;
            return WK_FEATURE_CLEAR;
        } else {
            int value = 1;
            if (second && !wk_intFromNumber(second, &value))
                return WK_FEATURE_NO_AAT_EQUIVALENT;
            *normalized = wk_aatDictionaryForOpenTypeTag(first, value);
        }
        return *normalized ? WK_FEATURE_NORMALIZED : WK_FEATURE_NO_AAT_EQUIVALENT;
    }

    return WK_FEATURE_NO_AAT_EQUIVALENT;
}

// The OpenType tag and value an OpenType-form element names: a tag/value dictionary, a [tag, value] pair,
// or a bare tag, which turns its feature on.
static bool wk_openTypeElementTagValue(CFTypeRef element, CFStringRef *tag, int *value)
{
    CFTypeRef tagValue = NULL, number = NULL;
    CFTypeID type = CFGetTypeID(element);
// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK and absent on the 10.9 runtime; this file
// supplies both (WK_POLYFILL_CONST above), so these read the layer's own definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    if (type == CFDictionaryGetTypeID()) {
        tagValue = CFDictionaryGetValue((CFDictionaryRef)element, kCTFontOpenTypeFeatureTag);
        number = CFDictionaryGetValue((CFDictionaryRef)element, kCTFontOpenTypeFeatureValue);
    } else if (type == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)element) >= 1) {
        tagValue = CFArrayGetValueAtIndex((CFArrayRef)element, 0);
        number = CFArrayGetCount((CFArrayRef)element) > 1 ? CFArrayGetValueAtIndex((CFArrayRef)element, 1) : NULL;
    } else if (type == CFStringGetTypeID())
        tagValue = element;
#pragma clang diagnostic pop
    if (!tagValue || CFGetTypeID(tagValue) != CFStringGetTypeID())
        return false;
    *tag = (CFStringRef)tagValue;
    if (!number || !wk_intFromNumber(number, value))
        *value = 1;
    return true;
}

// The OpenType tag of the feature an element sets: the tag an OpenType-form element names, or the one tag an
// AAT pair's selector belongs to. NULL for a selector naming no single tag -- the numeric default an
// exclusive type's tags share. `pair` is the AAT dictionary the element reduces to.
static CFStringRef wk_copyFeatureElementTag(CFTypeRef element, CFDictionaryRef pair)
{
    CFStringRef tag = NULL;
    int value = 1, type = 0, selector = 0;
    char name[5] = { 0 };
    if (wk_openTypeElementTagValue(element, &tag, &value))
        return (CFStringRef)CFRetain(tag);
    if (!pair || !wk_intFromNumber(CFDictionaryGetValue(pair, kCTFontFeatureTypeIdentifierKey), &type)
        || !wk_intFromNumber(CFDictionaryGetValue(pair, kCTFontFeatureSelectorIdentifierKey), &selector)
        || !wk_openTypeTagForAATFeature(type, selector, name, &value))
        return NULL;
    return CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
}

// The settings a feature-settings value names, as the AAT dictionaries 10.9's parser reads. A value that
// is not an array names none of them; clear directives are not settings and are collected separately.
//
// A feature keeps only its last setting, whichever form names it: -apple-system-monospaced-numbers states
// tnum as the AAT pair {kNumberSpacingType, kMonospacedNumbersSelector}, and WebCore appends the page's
// font-feature-settings after it, so a later "tnum" 0 turns it off. Several OpenType tags also turn their
// feature off through one selector their AAT type shares, and 10.9 applies the last entry of an exclusive
// type: jp83 on followed by jp78, jp90, jp04, smpl and trad off -- all kCharacterShapeType selector 16 --
// shapes the jp83 glyph back to its default, as smcp does under pcap off, lnum under onum off and sups
// under subs off. So the OpenType-form settings that turn a feature off come before every other setting,
// where they cannot undo one a later tag turns on.
static CFArrayRef wk_featureSettingsAsAAT(CFTypeRef settings)
{
    CFMutableArrayRef result = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!result || !settings || CFGetTypeID(settings) != CFArrayGetTypeID())
        return result;
    CFArrayRef array = (CFArrayRef)settings;
    CFIndex count = CFArrayGetCount(array);
    if (!count)
        return result;
    CFDictionaryRef *pairs = (CFDictionaryRef *)calloc((size_t)count, sizeof(CFDictionaryRef));
    CFStringRef *tags = (CFStringRef *)calloc((size_t)count, sizeof(CFStringRef));
    bool *first = (bool *)calloc((size_t)count, sizeof(bool));
    CFMutableArrayRef rest = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (pairs && tags && first && rest) {
        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef element = CFArrayGetValueAtIndex(array, i);
            int clearedType = 0;
            switch (wk_normalizeFeatureElement(element, &pairs[i], &clearedType)) {
            case WK_FEATURE_AAT:
                pairs[i] = (CFDictionaryRef)CFRetain(element);
                break;
            case WK_FEATURE_NORMALIZED: {
                CFStringRef tag = NULL;
                int value = 1;
                first[i] = wk_openTypeElementTagValue(element, &tag, &value) && !value;
                break;
            }
            case WK_FEATURE_CLEAR:
            case WK_FEATURE_NO_AAT_EQUIVALENT:
                continue;
            }
            tags[i] = wk_copyFeatureElementTag(element, pairs[i]);
        }
        for (CFIndex i = 0; i < count; i++) {
            if (!pairs[i])
                continue;
            bool superseded = false;
            for (CFIndex later = i + 1; tags[i] && later < count && !superseded; later++)
                superseded = tags[later] && CFEqual(tags[i], tags[later]);
            if (!superseded)
                CFArrayAppendValue(first[i] ? result : rest, pairs[i]);
        }
        CFArrayAppendArray(result, rest, CFRangeMake(0, CFArrayGetCount(rest)));
    }
    for (CFIndex i = 0; i < count; i++) {
        if (pairs && pairs[i])
            CFRelease(pairs[i]);
        if (tags && tags[i])
            CFRelease(tags[i]);
    }
    free(pairs);
    free(tags);
    free(first);
    if (rest)
        CFRelease(rest);
    return result;
}

// The same value, or NULL when every element already is an AAT dictionary and 10.9 can read it as it
// stands. The one shape besides an all-AAT array that 10.9's parser reads is the empty array.
static CFArrayRef wk_featureSettingsNormalized(CFTypeRef settings)
{
    if (!settings)
        return NULL;
    if (CFGetTypeID(settings) == CFArrayGetTypeID()) {
        CFArrayRef array = (CFArrayRef)settings;
        CFIndex count = CFArrayGetCount(array);
        bool needsNormalizing = false;
        for (CFIndex i = 0; i < count && !needsNormalizing; i++) {
            CFDictionaryRef probe = NULL;
            int clearedType = 0;
            if (wk_normalizeFeatureElement(CFArrayGetValueAtIndex(array, i), &probe, &clearedType) != WK_FEATURE_AAT)
                needsNormalizing = true;
            if (probe)
                CFRelease(probe);
        }
        if (!needsNormalizing)
            return NULL;
    }
    return wk_featureSettingsAsAAT(settings);
}

// The attributes dictionary as 10.9 takes it -- feature settings in the AAT dictionary form and no
// optical size naming the axis default -- or NULL when nothing needed rewriting.
static CFDictionaryRef wk_attributesAsTaken(CFDictionaryRef attributes)
{
    if (!attributes || CFGetTypeID(attributes) != CFDictionaryGetTypeID())
        return NULL;
    CFArrayRef normalized = wk_featureSettingsNormalized(CFDictionaryGetValue(attributes, kCTFontFeatureSettingsAttribute));
    bool namesOpticalSizeDefault = wk_attributesNameOpticalSizeDefault(attributes);
    if (!normalized && !namesOpticalSizeDefault)
        return NULL;
    CFMutableDictionaryRef result = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes);
    if (result) {
        if (normalized)
            CFDictionarySetValue(result, kCTFontFeatureSettingsAttribute, normalized);
        if (namesOpticalSizeDefault)
            CFDictionaryRemoveValue(result, kCTFontOpticalSizeAttribute);
    }
    if (normalized)
        CFRelease(normalized);
    return result;
}

// The axis-default request as it stands on the descriptor a caller gets back: named by the
// attributes, else the source descriptor's own when the attributes name no optical size.
static CTFontDescriptorRef wk_carryOpticalSizeDefault(CTFontDescriptorRef result, CTFontDescriptorRef source,
                                                      CFDictionaryRef attributes)
{
    bool named = attributes && CFGetTypeID(attributes) == CFDictionaryGetTypeID()
        && CFDictionaryGetValue(attributes, kCTFontOpticalSizeAttribute);
    if (named ? wk_attributesNameOpticalSizeDefault(attributes) : wk_opticalSizeIsDefault(source))
        wk_markOpticalSizeDefault(result);
    return result;
}

// ---------------------------------------------------------------------------------------------------
// Clearing a descriptor's feature settings. CTFontDescriptorCreateCopyWithAttributes MERGES the feature
// settings it is given onto the original's — 10.9 and newer CoreText alike — and from 10.12 a caller
// subtracts instead: kCFNull for the whole kCTFontFeatureSettingsAttribute value clears every setting
// the original holds, and a kCFNull selector or value in one element clears that element's feature type
// alone. 10.9 has no subtracting form, and a merge states a feature type's LAST entry: measured on this
// host, Hoefler Text carrying {type 1, selector 3} shapes "fi" as two glyphs, and a copy restating
// {type 1, selector 2} over it shapes one. So a clear is expressed as what it means — the cleared types
// restated at the selector they sit at when nothing has set them — and the copy carries the original's
// identity, its CGFont binding included, the way every other copy here does.
// ---------------------------------------------------------------------------------------------------

static bool wk_arrayHoldsInt(CFArrayRef array, int wanted)
{
    CFIndex count = array ? CFArrayGetCount(array) : 0;
    for (CFIndex i = 0; i < count; i++) {
        int held = 0;
        if (wk_intFromNumber(CFArrayGetValueAtIndex(array, i), &held) && held == wanted)
            return true;
    }
    return false;
}

// The AAT feature types an attributes dictionary's clear directives name, and whether it clears them all.
static CFArrayRef wk_featureSettingClears(CFDictionaryRef attributes, bool *clearsAll)
{
    *clearsAll = false;
    if (!attributes || CFGetTypeID(attributes) != CFDictionaryGetTypeID())
        return NULL;
    CFTypeRef settings = CFDictionaryGetValue(attributes, kCTFontFeatureSettingsAttribute);
    if (!settings)
        return NULL;
    if (wk_isNull(settings)) {
        *clearsAll = true;
        return NULL;
    }
    if (CFGetTypeID(settings) != CFArrayGetTypeID())
        return NULL;

    CFMutableArrayRef types = NULL;
    CFIndex count = CFArrayGetCount((CFArrayRef)settings);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef normalized = NULL;
        int clearedType = 0;
        if (wk_normalizeFeatureElement(CFArrayGetValueAtIndex((CFArrayRef)settings, i), &normalized, &clearedType)
            == WK_FEATURE_CLEAR) {
            CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &clearedType);
            if (!types)
                types = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
            if (types && number)
                CFArrayAppendValue(types, number);
            if (number)
                CFRelease(number);
        }
        if (normalized)
            CFRelease(normalized);
    }
    return types;
}

// The selector a feature type sits at when nothing has set it: the one its entry in the font's own
// feature list marks kCTFontFeatureSelectorDefaultKey. A type whose feature list marks none has no
// default to state -- 249 of the 1433 feature types the 502 faces installed here offer are in that
// position, 49 of them offering more than one selector -- and a type with no default to state is left
// alone rather than set to one of the selectors it happens to list.
static bool wk_defaultFeatureSelector(CTFontRef font, int type, int *selector)
{
    CFArrayRef features = font ? CTFontCopyFeatures(font) : NULL;
    if (!features)
        return false;
    bool found = false;
    for (CFIndex i = 0, count = CFArrayGetCount(features); i < count && !found; i++) {
        CFTypeRef entry = CFArrayGetValueAtIndex(features, i);
        int entryType = 0;
        if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()
            || !wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)entry, kCTFontFeatureTypeIdentifierKey), &entryType)
            || entryType != type)
            continue;
        CFTypeRef selectors = CFDictionaryGetValue((CFDictionaryRef)entry, kCTFontFeatureTypeSelectorsKey);
        if (!selectors || CFGetTypeID(selectors) != CFArrayGetTypeID())
            continue;
        for (CFIndex j = 0, selectorCount = CFArrayGetCount((CFArrayRef)selectors); j < selectorCount && !found; j++) {
            CFTypeRef offered = CFArrayGetValueAtIndex((CFArrayRef)selectors, j);
            int identifier = 0;
            if (!offered || CFGetTypeID(offered) != CFDictionaryGetTypeID()
                || CFDictionaryGetValue((CFDictionaryRef)offered, kCTFontFeatureSelectorDefaultKey) != kCFBooleanTrue
                || !wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)offered, kCTFontFeatureSelectorIdentifierKey), &identifier))
                continue;
            *selector = identifier;
            found = true;
        }
    }
    CFRelease(features);
    return found;
}

// The feature types a settings array names.
static CFArrayRef wk_featureSettingTypes(CFTypeRef settings)
{
    CFMutableArrayRef types = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!types || !settings || CFGetTypeID(settings) != CFArrayGetTypeID())
        return types;
    for (CFIndex i = 0, count = CFArrayGetCount((CFArrayRef)settings); i < count; i++) {
        CFTypeRef element = CFArrayGetValueAtIndex((CFArrayRef)settings, i);
        int type = 0;
        if (!element || CFGetTypeID(element) != CFDictionaryGetTypeID()
            || !wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)element, kCTFontFeatureTypeIdentifierKey), &type)
            || wk_arrayHoldsInt(types, type))
            continue;
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &type);
        if (number) {
            CFArrayAppendValue(types, number);
            CFRelease(number);
        }
    }
    return types;
}

// One AAT setting: this feature type at this selector.
static CFDictionaryRef wk_featureSetting(int type, int selector)
{
    CFNumberRef typeNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &type);
    CFNumberRef selectorNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &selector);
    CFDictionaryRef setting = NULL;
    if (typeNumber && selectorNumber) {
        const void *keys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
        const void *values[] = { typeNumber, selectorNumber };
        setting = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    if (typeNumber)
        CFRelease(typeNumber);
    if (selectorNumber)
        CFRelease(selectorNumber);
    return setting;
}

// Every cleared feature type restated at its default selector, for the types that have one. `clearsAll`
// names the types the original itself carries; anything the original does not set is already at its
// default and needs no entry. The selectors come from the original realized, which is the only thing
// that knows them.
static CFArrayRef wk_featureSettingsAtTheirDefaults(CTFontDescriptorRef original, bool clearsAll, CFArrayRef clearedTypes)
{
    CFTypeRef carried = wk_carriedAttribute(original, kCTFontFeatureSettingsAttribute);
    CFArrayRef carriedTypes = wk_featureSettingTypes(carried);
    if (carried)
        CFRelease(carried);
    CFArrayRef types = clearsAll ? (CFArrayRef)CFRetain(carriedTypes) : (CFArrayRef)CFRetain(clearedTypes);
    CFMutableArrayRef settings = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CTFontRef realized = (settings && CFArrayGetCount(types)) ? CTFontCreateWithFontDescriptor(original, 12.0, NULL) : NULL;
    for (CFIndex i = 0; realized && i < CFArrayGetCount(types); i++) {
        int type = 0;
        int selector = 0;
        if (!wk_intFromNumber(CFArrayGetValueAtIndex(types, i), &type)
            || (!clearsAll && !wk_arrayHoldsInt(carriedTypes, type))
            || !wk_defaultFeatureSelector(realized, type, &selector))
            continue;
        CFDictionaryRef setting = wk_featureSetting(type, selector);
        if (setting) {
            CFArrayAppendValue(settings, setting);
            CFRelease(setting);
        }
    }
    if (realized)
        CFRelease(realized);
    CFRelease(types);
    CFRelease(carriedTypes);
    return settings;
}

// The three entry points a caller-supplied attributes dictionary reaches CoreText through. Attributes
// whose feature settings are already the AAT dictionary form are passed to 10.9's own implementation
// exactly as given.
WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateWithAttributes, (CFDictionaryRef attributes))
{
    CFDictionaryRef rewritten = wk_attributesAsTaken(attributes);
    CTFontDescriptorRef result = WK_ORIGINAL(CTFontDescriptorCreateWithAttributes)
        ? WK_ORIGINAL(CTFontDescriptorCreateWithAttributes)(rewritten ? rewritten : attributes) : NULL;
    if (rewritten)
        CFRelease(rewritten);
    return wk_carryOpticalSizeDefault(result, NULL, attributes);
}

// CTFontDescriptorOptions is CoreText SPI (PAL/pal/spi/cf/CoreTextSPI.h), a uint32_t option set.
WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateWithAttributesAndOptions,
                     (CFDictionaryRef attributes, uint32_t options))
{
    CFDictionaryRef rewritten = wk_attributesAsTaken(attributes);
    CTFontDescriptorRef result = WK_ORIGINAL(CTFontDescriptorCreateWithAttributesAndOptions)
        ? WK_ORIGINAL(CTFontDescriptorCreateWithAttributesAndOptions)(rewritten ? rewritten : attributes, options) : NULL;
    if (rewritten)
        CFRelease(rewritten);
    return wk_carryOpticalSizeDefault(result, NULL, attributes);
}

// The copy entry point is the one that merges, so it is the one a clear directive subtracts from: with
// one present the merged attributes are assembled here and realized as a whole descriptor. The two
// entry points above have no original to subtract from, so a directive there leaves nothing behind.
WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateCopyWithAttributes,
                     (CTFontDescriptorRef original, CFDictionaryRef attributes))
{
    bool clearsAll = false;
    CFArrayRef clearedTypes = wk_featureSettingClears(attributes, &clearsAll);
    CFDictionaryRef rewritten = NULL;
    if (original && (clearsAll || clearedTypes)) {
        // The cleared types first, so the caller's own settings win where they name one too.
        CFArrayRef defaults = wk_featureSettingsAtTheirDefaults(original, clearsAll, clearedTypes);
        CFArrayRef stated = wk_featureSettingsAsAAT(CFDictionaryGetValue(attributes, kCTFontFeatureSettingsAttribute));
        CFMutableArrayRef settings = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        if (settings && defaults)
            CFArrayAppendArray(settings, defaults, CFRangeMake(0, CFArrayGetCount(defaults)));
        if (settings && stated)
            CFArrayAppendArray(settings, stated, CFRangeMake(0, CFArrayGetCount(stated)));
        CFMutableDictionaryRef named = settings
            ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, attributes) : NULL;
        if (named) {
            CFDictionarySetValue(named, kCTFontFeatureSettingsAttribute, settings);
            if (wk_attributesNameOpticalSizeDefault(attributes))
                CFDictionaryRemoveValue(named, kCTFontOpticalSizeAttribute);
        }
        rewritten = named;
        if (settings)
            CFRelease(settings);
        if (stated)
            CFRelease(stated);
        if (defaults)
            CFRelease(defaults);
    }
    if (clearedTypes)
        CFRelease(clearedTypes);
    if (!rewritten)
        rewritten = wk_attributesAsTaken(attributes);
    CTFontDescriptorRef result = WK_ORIGINAL(CTFontDescriptorCreateCopyWithAttributes)
        ? WK_ORIGINAL(CTFontDescriptorCreateCopyWithAttributes)(original, rewritten ? rewritten : attributes) : NULL;
    if (rewritten)
        CFRelease(rewritten);
    return wk_carryOpticalSizeDefault(result, original, attributes);
}

// libFontParser's FPFont* system font parser, which WebCore uses to split a downloaded font file
// into its constituent fonts and take the chosen one's canonical sfnt bytes. Asked of the running
// 10.9 through dlsym: FPFontCopyPostScriptName is there, FPFontCreateFontsFromData and
// FPFontCopySFNTData are not.
//
// 10.9 has no font-collection parser to stand in for the missing pair, so the polyfill's answer is
// the honest one for a machine without one: the data is a single font, and its sfnt bytes are the
// bytes themselves. An FPFontRef here is therefore the CFData, and the two functions that consume
// one recognise that. Since 10.9 does export FPFontCopyPostScriptName, that one is a replacement
// and hands anything it does not recognise back to the system implementation.
typedef const struct __FPFont* FPFontRef;

WK_POLYFILL_ABSENT("CoreText", CFArrayRef, FPFontCreateFontsFromData, (CFDataRef data))
{
    // The system parser's splitter; on this port every downloadable font is sanitized here (OTS,
    // unwrapping a WOFF or WOFF2 container as it reads), so the sfnt the rest of the path opens is one
    // OTS wrote, never the bytes off the network. A font OTS refuses has no sanitized form: the empty
    // result upstream reads as "something is wrong with the font" and rejects the @font-face. An
    // FPFontRef is that sanitized CFData, as it is for FPFontCreateMemorySafeFontsFromData below.
    CFDataRef sanitized = wk_font_is_ots_sanitized(data) ? (CFDataRef)CFRetain(data) : wk_ots_sanitize_font(data);
    if (!sanitized)
        return NULL;
    CFArrayRef fonts = wk_ots_copy_font_faces(sanitized);
    CFRelease(sanitized);
    return fonts;
}

WK_POLYFILL_ABSENT("CoreText", CFDataRef, FPFontCopySFNTData, (FPFontRef font))
{
    if (font && CFGetTypeID((CFTypeRef)font) == CFDataGetTypeID())
        return (CFDataRef)CFRetain((CFTypeRef)font);
    return NULL;
}

// The memory-safe font parser pair. macOS 15 parses a downloadable font with a parser written not to
// be exploitable by the font it is reading and hands CoreText the result; 10.9 has neither entry
// point, and its own parser is the one that replacement exists to keep away from page bytes. OTS
// (ots_font_parser.cpp) stands in: it re-serialises the font from its own bounds-checked table
// structures, so what the parser below opens is a sfnt OTS wrote, not the one that came off the
// network. A font OTS will not accept has no sanitized form, and NULL is the contract's answer.

WK_POLYFILL_ABSENT("CoreText", CFArrayRef, FPFontCreateMemorySafeFontsFromData, (CFDataRef data))
{
    CFDataRef sanitized = wk_ots_sanitize_font(data);
    if (!sanitized)
        return NULL;
    // An FPFontRef is the CFData, as it is for FPFontCreateFontsFromData above.
    CFArrayRef fonts = wk_ots_copy_font_faces(sanitized);
    CFRelease(sanitized);
    return fonts;
}

WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontManagerCreateMemorySafeFontDescriptorFromData, (CFDataRef data))
{
    // Reached only with bytes FPFontCreateMemorySafeFontsFromData already sanitized, so it realizes
    // them without sanitizing again.
    return wk_realizeDescriptorFromSfnt(data);
}

WK_POLYFILL_REPLACES("CoreText", CFStringRef, FPFontCopyPostScriptName, (FPFontRef font))
{
    if (font && CFGetTypeID((CFTypeRef)font) == CFDataGetTypeID()) {
        CFStringRef name = NULL;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)font);
        if (provider) {
            CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
            CGDataProviderRelease(provider);
            if (cgFont) {
                name = CGFontCopyPostScriptName(cgFont);
                CGFontRelease(cgFont);
            }
        }
        return name;
    }
    return WK_ORIGINAL(FPFontCopyPostScriptName) ? WK_ORIGINAL(FPFontCopyPostScriptName)(font) : NULL;
}
#pragma clang diagnostic pop

// ---------------------------------------------------------------------------------------------------
// CoreText — text rendering hits these live; where 10.9 ships an equivalent, the body calls through to it.
// ---------------------------------------------------------------------------------------------------

// CTFontManagerRegisterFontURLs (10.15) is the block-callback replacement for
// CTFontManagerRegisterFontsForURLs, which 10.9 HAS (nm-verified, alongside the singular
// _CTFontManagerRegisterFontsForURL). The modern spelling is a strict superset: same URLs, same
// scope, plus an `enabled` flag and a handler that may be called several times with `done` marking
// the last. The old call is synchronous and reports every failure in one out-parameter array, so a
// faithful emulation registers, then invokes the handler EXACTLY once with those errors and
// done=true. The handler's bool result asks whether to continue; nothing remains to continue after a
// synchronous call, so it is read and discarded.
//
// `enabled` is NOT dropped. It means "should the font participate in descriptor matching", and 10.9
// spells that with CTFontManagerEnableFontDescriptors (10.6+, nm-verified), fed by
// CTFontManagerCreateFontDescriptorsFromURL (10.6+, nm-verified) per URL. So enabled=false is
// registered and then disabled, which is the modern behaviour rather than an approximation of it.
// Verified on this host with a font the process does not otherwise have (LayoutTests Ahem.ttf):
// process-scope registration makes the family visible, CTFontManagerEnableFontDescriptors(descs,
// false) makes it invisible again, and Enable(true) restores it -- so it genuinely suppresses the
// PROCESS-scope registration. Measured again with a system-installed family (Al Bayan): the same
// sequence leaves it visible throughout, and a FRESH process still sees it, so it writes no
// persistent user-visible font-activation state. Refusing enabled=false with a synthesized CFError
// would invent a failure for something the OS can do.
WK_POLYFILL_ABSENT("CoreText", void, CTFontManagerRegisterFontURLs,
    (CFArrayRef fontURLs, CTFontManagerScope scope, bool enabled,
     bool (^registrationHandler)(CFArrayRef errors, bool done)))
{
    CFArrayRef errors = NULL;

    // WK_SYSTEM() is NULL when the provider cannot be dlopened or the symbol is missing; calling
    // through it unchecked would be a branch to address 0, the very fault this layer exists to stop.
    if (!WK_SYSTEM(CTFontManagerRegisterFontsForURLs)) {
        CFStringRef descKeys[] = { kCFErrorLocalizedDescriptionKey, kCTFontManagerErrorFontURLsKey };
        const void *descValues[] = { CFSTR("CoreText's font registration entry point is unavailable"), fontURLs };
        CFDictionaryRef userInfo = CFDictionaryCreate(kCFAllocatorDefault, (const void **)descKeys,
            descValues, fontURLs ? 2 : 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFErrorRef error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainPOSIX, ENOTSUP, userInfo);
        if (userInfo)
            CFRelease(userInfo);
        if (error) {
            const void *one[] = { error };
            errors = CFArrayCreate(kCFAllocatorDefault, one, 1, &kCFTypeArrayCallBacks);
            CFRelease(error);
        }
    } else {
        WK_SYSTEM(CTFontManagerRegisterFontsForURLs)(fontURLs, scope, &errors);

        // Registration on 10.9 always enables; take the fonts back out of descriptor matching when
        // the caller asked for enabled=false, which is what the modern flag means.
        if (!enabled && fontURLs && WK_SYSTEM(CTFontManagerCreateFontDescriptorsFromURL) && WK_SYSTEM(CTFontManagerEnableFontDescriptors)) {
            CFIndex count = CFArrayGetCount(fontURLs);
            for (CFIndex i = 0; i < count; i++) {
                CFArrayRef descriptors = WK_SYSTEM(CTFontManagerCreateFontDescriptorsFromURL)((CFURLRef)CFArrayGetValueAtIndex(fontURLs, i));
                if (!descriptors)
                    continue;
                WK_SYSTEM(CTFontManagerEnableFontDescriptors)(descriptors, false);
                CFRelease(descriptors);
            }
        }
    }

    if (registrationHandler) {
        CFArrayRef reported = errors;
        CFArrayRef empty = NULL;
        if (!reported) {
            empty = CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks);
            reported = empty;   // the modern handler documents an EMPTY array as "no errors", never NULL
        }
        (void)registrationHandler(reported, true);
        if (empty)
            CFRelease(empty);
    }
    if (errors)
        CFRelease(errors);
}

// ---------------------------------------------------------------------------------------------------
// Which of a font's glyphs a colour format or a font feature covers, one bit per glyph index. Both
// answers live in the font's own tables, which 10.9 hands out through CTFontCopyTable.
//
// CTFontCopyGlyphCoverageForFeature (10.13+) answers the feature question. The OpenType feature
// dictionary is answered from GSUB, and the AAT type/selector dictionary from the metamorphosis tables,
// morx or its pre-extended form mort. The two are separate answers to separate questions, which is why
// WebCore asks both and unions the results (Font::supportsSmallCaps and its three siblings,
// FontCoreText.cpp).
//
// A glyph is covered when a lookup the feature names can act on it: for GSUB, when it is in the input
// coverage of one of the feature's lookups; for a noncontextual metamorphosis subtable, when the
// subtable substitutes something else for it; for the state-machine subtables, when the subtable's
// class table gives it a class of its own rather than one of the four reserved ones.
// ---------------------------------------------------------------------------------------------------

// A font table read through bounds-checked accessors: a length-of-record or offset the font gets wrong
// reads as zero rather than off the end of the mapping.
typedef struct {
    const uint8_t *bytes;
    uint32_t length;
} wk_font_table;

static bool wk_tableHas(wk_font_table table, uint64_t offset, uint64_t size)
{
    return offset <= table.length && size <= table.length - offset;
}

static uint16_t wk_tableU16(wk_font_table table, uint64_t offset)
{
    return wk_tableHas(table, offset, 2) ? wk_be16(table.bytes + offset) : 0;
}

static uint32_t wk_tableU32(wk_font_table table, uint64_t offset)
{
    return wk_tableHas(table, offset, 4) ? wk_be32(table.bytes + offset) : 0;
}

static void wk_markGlyph(CFMutableBitVectorRef coverage, uint32_t glyph)
{
    if (glyph < (uint32_t)CFBitVectorGetCount(coverage))
        CFBitVectorSetBitAtIndex(coverage, (CFIndex)glyph, 1);
}

// An OpenType Coverage table: format 1 lists the glyphs, format 2 lists first/last ranges.
static void wk_markCoverageTable(wk_font_table gsub, uint64_t offset, CFMutableBitVectorRef coverage)
{
    uint16_t format = wk_tableU16(gsub, offset);
    uint64_t count = wk_tableU16(gsub, offset + 2);
    if (format == 1) {
        if (!wk_tableHas(gsub, offset + 4, count * 2))
            return;
        for (uint64_t i = 0; i < count; i++)
            wk_markGlyph(coverage, wk_be16(gsub.bytes + offset + 4 + i * 2));
    } else if (format == 2) {
        if (!wk_tableHas(gsub, offset + 4, count * 6))
            return;
        // The range ends the font states are unclamped, and wk_markGlyph discards anything past the
        // last glyph, so the walk stops there rather than running the stated range out.
        uint32_t glyphs = (uint32_t)CFBitVectorGetCount(coverage);
        for (uint64_t i = 0; i < count; i++) {
            const uint8_t *record = gsub.bytes + offset + 4 + i * 6;
            uint32_t last = wk_be16(record + 2);
            for (uint32_t glyph = wk_be16(record); glyph < glyphs && glyph <= last; glyph++)
                wk_markGlyph(coverage, glyph);
        }
    }
}

static void wk_markCoverageAt(wk_font_table gsub, uint64_t base, uint64_t offset, CFMutableBitVectorRef coverage)
{
    if (offset)
        wk_markCoverageTable(gsub, base + offset, coverage);
}

// One GSUB lookup subtable's input coverage. The single, multiple, alternate, ligature and reverse
// chaining substitution formats all name theirs at offset 2, as do formats 1 and 2 of the context and
// chaining-context types, which cover the first glyph of every rule they hold. Format 3 of those two
// names one coverage per input position instead, and an extension subtable names the real subtable and
// its type at a 32-bit offset.
static void wk_markGSUBSubtable(wk_font_table gsub, uint16_t lookupType, uint64_t subtable,
                                CFMutableBitVectorRef coverage, int extensionsLeft)
{
    uint16_t format = wk_tableU16(gsub, subtable);
    if (lookupType == 7) {
        if (extensionsLeft > 0 && format == 1)
            wk_markGSUBSubtable(gsub, wk_tableU16(gsub, subtable + 2), subtable + wk_tableU32(gsub, subtable + 4),
                                coverage, extensionsLeft - 1);
        return;
    }
    if (lookupType == 5 && format == 3) {
        uint64_t inputCount = wk_tableU16(gsub, subtable + 2);
        for (uint64_t i = 0; i < inputCount; i++)
            wk_markCoverageAt(gsub, subtable, wk_tableU16(gsub, subtable + 6 + i * 2), coverage);
        return;
    }
    if (lookupType == 6 && format == 3) {
        uint64_t cursor = subtable + 2 + 2 * (uint64_t)wk_tableU16(gsub, subtable + 2);
        uint64_t inputCount = wk_tableU16(gsub, cursor + 2);
        for (uint64_t i = 0; i < inputCount; i++)
            wk_markCoverageAt(gsub, subtable, wk_tableU16(gsub, cursor + 4 + i * 2), coverage);
        return;
    }
    wk_markCoverageAt(gsub, subtable, wk_tableU16(gsub, subtable + 2), coverage);
}

static void wk_markGSUBLookups(wk_font_table gsub, uint64_t feature, uint64_t lookupList,
                               CFMutableBitVectorRef coverage)
{
    uint64_t lookupCount = wk_tableU16(gsub, feature + 2);
    uint32_t listCount = wk_tableU16(gsub, lookupList);
    for (uint64_t i = 0; i < lookupCount; i++) {
        uint32_t index = wk_tableU16(gsub, feature + 4 + i * 2);
        if (index >= listCount)
            continue;
        uint64_t lookup = lookupList + wk_tableU16(gsub, lookupList + 2 + (uint64_t)index * 2);
        uint16_t lookupType = wk_tableU16(gsub, lookup);
        uint64_t subtableCount = wk_tableU16(gsub, lookup + 4);
        for (uint64_t s = 0; s < subtableCount; s++)
            wk_markGSUBSubtable(gsub, lookupType, lookup + wk_tableU16(gsub, lookup + 6 + s * 2), coverage, 1);
    }
}

// GSUB names each feature once in its FeatureList; the scripts and language systems only index into
// that list, so every record carrying the tag is the feature, whatever writing system reaches it.
static void wk_markOpenTypeFeatureCoverage(CTFontRef font, const char *tag, CFMutableBitVectorRef coverage)
{
    CFDataRef data = CTFontCopyTable(font, kCTFontTableGSUB, kCTFontTableOptionNoOptions);
    if (!data)
        return;
    wk_font_table gsub = { CFDataGetBytePtr(data), CFDataGetBytePtr(data) ? (uint32_t)CFDataGetLength(data) : 0 };
    if (gsub.bytes) {
        uint32_t wanted = ((uint32_t)(uint8_t)tag[0] << 24) | ((uint32_t)(uint8_t)tag[1] << 16)
                        | ((uint32_t)(uint8_t)tag[2] << 8) | (uint8_t)tag[3];
        uint64_t featureList = wk_tableU16(gsub, 6);
        uint64_t lookupList = wk_tableU16(gsub, 8);
        uint64_t featureCount = wk_tableU16(gsub, featureList);
        for (uint64_t i = 0; i < featureCount; i++) {
            uint64_t record = featureList + 2 + i * 6;
            if (wk_tableU32(gsub, record) == wanted)
                wk_markGSUBLookups(gsub, featureList + wk_tableU16(gsub, record + 4), lookupList, coverage);
        }
    }
    CFRelease(data);
}

static uint64_t wk_beN(const uint8_t *bytes, uint32_t size)
{
    uint64_t value = 0;
    for (uint32_t i = 0; i < size; i++)
        value = (value << 8) | bytes[i];
    return value;
}

// An AAT lookup table, in each of the six formats Apple's Lookup Tables document defines, visited entry
// by entry. The value an entry carries is the substitute glyph in a noncontextual subtable and the
// glyph class in a state table's class table.
typedef void (*wk_aat_lookup_visitor)(uint32_t glyph, uint64_t value, CFMutableBitVectorRef coverage);

static void wk_walkAATLookup(wk_font_table table, uint64_t offset, uint32_t glyphCount,
                             wk_aat_lookup_visitor visit, CFMutableBitVectorRef coverage)
{
    // The binary-search header formats 2, 4 and 6 share: unit size, unit count, and three search hints.
    uint64_t unitCount = wk_tableU16(table, offset + 4);
    uint64_t units = offset + 12;

    switch (wk_tableU16(table, offset)) {
    case 0:
        for (uint64_t glyph = 0; glyph < glyphCount && wk_tableHas(table, offset + 2 + glyph * 2, 2); glyph++)
            visit((uint32_t)glyph, wk_be16(table.bytes + offset + 2 + glyph * 2), coverage);
        break;
    case 2:
        for (uint64_t i = 0; i < unitCount && wk_tableHas(table, units + i * 6, 6); i++) {
            const uint8_t *unit = table.bytes + units + i * 6;
            uint32_t last = wk_be16(unit), value = wk_be16(unit + 4);
            for (uint32_t glyph = wk_be16(unit + 2); glyph < glyphCount && glyph <= last; glyph++)
                visit(glyph, value, coverage);
        }
        break;
    case 4:
        for (uint64_t i = 0; i < unitCount && wk_tableHas(table, units + i * 6, 6); i++) {
            const uint8_t *unit = table.bytes + units + i * 6;
            uint32_t last = wk_be16(unit), first = wk_be16(unit + 2);
            uint64_t values = offset + wk_be16(unit + 4);
            for (uint32_t glyph = first; glyph <= last; glyph++) {
                uint64_t at = values + (uint64_t)(glyph - first) * 2;
                if (!wk_tableHas(table, at, 2))
                    break;
                visit(glyph, wk_be16(table.bytes + at), coverage);
            }
        }
        break;
    case 6:
        for (uint64_t i = 0; i < unitCount && wk_tableHas(table, units + i * 4, 4); i++) {
            const uint8_t *unit = table.bytes + units + i * 4;
            visit(wk_be16(unit), wk_be16(unit + 2), coverage);
        }
        break;
    case 8: {
        uint32_t first = wk_tableU16(table, offset + 2);
        uint64_t count = wk_tableU16(table, offset + 4);
        for (uint64_t i = 0; i < count && wk_tableHas(table, offset + 6 + i * 2, 2); i++)
            visit(first + (uint32_t)i, wk_be16(table.bytes + offset + 6 + i * 2), coverage);
        break;
    }
    case 10: {
        // A trimmed array whose entries are one, two, four or eight bytes wide.
        uint64_t unitSize = wk_tableU16(table, offset + 2);
        uint32_t first = wk_tableU16(table, offset + 4);
        uint64_t count = wk_tableU16(table, offset + 6);
        if (unitSize != 1 && unitSize != 2 && unitSize != 4 && unitSize != 8)
            break;
        for (uint64_t i = 0; i < count && wk_tableHas(table, offset + 8 + i * unitSize, unitSize); i++)
            visit(first + (uint32_t)i, wk_beN(table.bytes + offset + 8 + i * unitSize, (uint32_t)unitSize), coverage);
        break;
    }
    default:
        break;
    }
}

static void wk_markSubstitutedGlyph(uint32_t glyph, uint64_t value, CFMutableBitVectorRef coverage)
{
    if (value && value != glyph)
        wk_markGlyph(coverage, glyph);
}

// Classes 0 through 3 are the reserved end-of-text, out-of-bounds, deleted-glyph and end-of-line ones,
// which every glyph the state machine does not name falls into.
static void wk_markClassifiedGlyph(uint32_t glyph, uint64_t value, CFMutableBitVectorRef coverage)
{
    if (value >= 4)
        wk_markGlyph(coverage, glyph);
}

// The glyphs one metamorphosis subtable acts on. Type 4 is the noncontextual substitution, whose whole
// body is an AAT lookup from glyph to substitute; types 0, 1, 2 and 5 — rearrangement, contextual,
// ligature and insertion — are state machines whose header names the class table that decides which
// glyphs the machine can see. morx carries the extended state header, with 32-bit offsets and an AAT
// lookup for the class table; mort carries the original, with 16-bit offsets and a trimmed byte array.
static void wk_markMetamorphosisSubtable(wk_font_table table, uint64_t body, uint32_t type, bool extended,
                                         uint32_t glyphCount, CFMutableBitVectorRef coverage)
{
    if (type == 4) {
        wk_walkAATLookup(table, body, glyphCount, wk_markSubstitutedGlyph, coverage);
        return;
    }
    if (type != 0 && type != 1 && type != 2 && type != 5)
        return;
    if (extended) {
        wk_walkAATLookup(table, body + wk_tableU32(table, body + 4), glyphCount, wk_markClassifiedGlyph, coverage);
        return;
    }
    uint64_t classTable = body + wk_tableU16(table, body + 2);
    uint32_t first = wk_tableU16(table, classTable);
    uint64_t count = wk_tableU16(table, classTable + 2);
    for (uint64_t i = 0; i < count && wk_tableHas(table, classTable + 4 + i, 1); i++)
        wk_markClassifiedGlyph(first + (uint32_t)i, table.bytes[classTable + 4 + i], coverage);
}

// One metamorphosis chain. A chain applies a feature entry as `flags = (flags & disableFlags) |
// enableFlags`, so an AAT type/selector pair selects every subtable whose flag it sets, and in addition
// turns off every subtable whose flag it clears and the chain's default flags had set. A selector can
// set nothing at all: Didot's lining-figures setting only clears the old-style flag its chain defaults
// carry, so the glyphs it acts on are that subtable's. Clearing a flag the defaults do not carry changes
// nothing, and names no glyph.
static void wk_markMetamorphosisChain(wk_font_table table, uint64_t chain, uint32_t featureCount,
                                      uint32_t subtableCount, uint32_t chainHeader, uint32_t subtableHeader,
                                      bool extended, int featureType, int featureSelector,
                                      uint32_t glyphCount, CFMutableBitVectorRef coverage)
{
    uint32_t enableFlags = 0, clearedFlags = 0;
    bool names = false;
    uint64_t entries = chain + chainHeader;
    for (uint64_t i = 0; i < featureCount && wk_tableHas(table, entries + i * 12, 12); i++) {
        const uint8_t *entry = table.bytes + entries + i * 12;
        if (wk_be16(entry) == (uint16_t)featureType && wk_be16(entry + 2) == (uint16_t)featureSelector) {
            enableFlags |= wk_be32(entry + 4);
            clearedFlags |= ~wk_be32(entry + 8);
            names = true;
        }
    }
    if (!names)
        return;
    uint32_t affectedFlags = enableFlags | (clearedFlags & wk_tableU32(table, chain));

    uint64_t subtable = entries + (uint64_t)featureCount * 12;
    for (uint32_t i = 0; i < subtableCount && wk_tableHas(table, subtable, subtableHeader); i++) {
        uint32_t length = extended ? wk_tableU32(table, subtable) : wk_tableU16(table, subtable);
        uint32_t flags = extended ? wk_tableU32(table, subtable + 8) : wk_tableU32(table, subtable + 4);
        uint32_t type = extended ? (wk_tableU32(table, subtable + 4) & 0xFF) : (wk_tableU16(table, subtable + 2) & 0x7);
        if (length < subtableHeader)
            return;
        if (affectedFlags & flags)
            wk_markMetamorphosisSubtable(table, subtable + subtableHeader, type, extended, glyphCount, coverage);
        subtable += length;
    }
}

// A metamorphosis chain can hold feature entries for type/selector pairs the font does not offer. The
// font's own feature list — its feat table, which CTFontCopyFeatures reads — is the declaration of
// which pairs it has, and CoreText applies no setting outside it. Didot's morx names both
// kLetterCaseType and kLowerCaseType small capitals and its feat table declares only the latter; that
// is the pair whose 57 glyphs CoreText substitutes.
static bool wk_fontOffersAATFeature(CTFontRef font, int featureType, int featureSelector)
{
    CFArrayRef features = CTFontCopyFeatures(font);
    if (!features)
        return false;
    bool offered = false;
    CFIndex count = CFArrayGetCount(features);
    for (CFIndex i = 0; i < count && !offered; i++) {
        CFTypeRef entry = CFArrayGetValueAtIndex(features, i);
        int type = 0;
        if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()
            || !wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)entry, kCTFontFeatureTypeIdentifierKey), &type)
            || type != featureType)
            continue;
        CFTypeRef selectors = CFDictionaryGetValue((CFDictionaryRef)entry, kCTFontFeatureTypeSelectorsKey);
        if (!selectors || CFGetTypeID(selectors) != CFArrayGetTypeID())
            continue;
        CFIndex selectorCount = CFArrayGetCount((CFArrayRef)selectors);
        for (CFIndex s = 0; s < selectorCount && !offered; s++) {
            CFTypeRef selector = CFArrayGetValueAtIndex((CFArrayRef)selectors, s);
            int identifier = 0;
            offered = selector && CFGetTypeID(selector) == CFDictionaryGetTypeID()
                && wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)selector, kCTFontFeatureSelectorIdentifierKey), &identifier)
                && identifier == featureSelector;
        }
    }
    CFRelease(features);
    return offered;
}

// morx and mort say the same thing in two layouts: morx counts its chains, feature entries and
// subtables in 32-bit fields and mort in a mix of 32- and 16-bit ones, and their chain and subtable
// headers are sized accordingly. morx is the extended form and supersedes mort, so a font carrying
// both is laid out by morx alone.
static void wk_markAATFeatureCoverage(CTFontRef font, int featureType, int featureSelector,
                                      uint32_t glyphCount, CFMutableBitVectorRef coverage)
{
    if (!wk_fontOffersAATFeature(font, featureType, featureSelector))
        return;
    CFDataRef data = CTFontCopyTable(font, kCTFontTableMorx, kCTFontTableOptionNoOptions);
    bool extended = data != NULL;
    if (!data)
        data = CTFontCopyTable(font, kCTFontTableMort, kCTFontTableOptionNoOptions);
    if (!data)
        return;

    wk_font_table table = { CFDataGetBytePtr(data), CFDataGetBytePtr(data) ? (uint32_t)CFDataGetLength(data) : 0 };
    uint32_t chainCount = wk_tableU32(table, 4);
    uint32_t chainHeader = extended ? 16u : 12u;
    uint64_t chain = 8;
    for (uint32_t c = 0; c < chainCount && wk_tableHas(table, chain, chainHeader); c++) {
        uint32_t length = wk_tableU32(table, chain + 4);
        uint32_t featureCount = extended ? wk_tableU32(table, chain + 8) : wk_tableU16(table, chain + 8);
        uint32_t subtableCount = extended ? wk_tableU32(table, chain + 12) : wk_tableU16(table, chain + 10);
        if (length < chainHeader || featureCount > table.length / 12)
            break;
        wk_markMetamorphosisChain(table, chain, featureCount, subtableCount, chainHeader,
                                  extended ? 12u : 8u, extended, featureType, featureSelector,
                                  glyphCount, coverage);
        chain += length;
    }
    CFRelease(data);
}

// Color coverage is glyph-indexed across sbix strikes and COLR base records.
WK_POLYFILL_ABSENT("CoreText", CFBitVectorRef, CTFontCopyColorGlyphCoverage, (CTFontRef font))
{
    CFIndex glyphCount = font ? CTFontGetGlyphCount(font) : 0;
    if (glyphCount <= 0)
        return NULL;
    CFDataRef data = CTFontCopyTable(font, kCTFontTableSbix, kCTFontTableOptionNoOptions);
    wk_font_table sbix = { data ? CFDataGetBytePtr(data) : NULL, data ? (uint32_t)CFDataGetLength(data) : 0 };
    CFMutableBitVectorRef coverage = CFBitVectorCreateMutable(kCFAllocatorDefault, 0);
    if (coverage) {
        CFBitVectorSetCount(coverage, glyphCount);
        // Each strike names one offset per glyph plus the terminating one; a glyph's bitmap is the
        // bytes between its offset and the next.
        CFIndex offsets = (glyphCount + 1) * 4;
        uint32_t strikeCount = wk_tableU32(sbix, 4);
        for (uint32_t i = 0; i < strikeCount; i++) {
            uint32_t strike = wk_tableU32(sbix, 8 + i * 4);
            if (strike > sbix.length || offsets > (CFIndex)sbix.length
                || !wk_tableHas(sbix, strike + 4, (uint32_t)offsets))
                continue;
            const uint8_t *glyphOffsets = sbix.bytes + strike + 4;
            for (uint32_t glyph = 0; glyph < (uint32_t)glyphCount; glyph++) {
                if (wk_be32(glyphOffsets + (glyph + 1) * 4) > wk_be32(glyphOffsets + glyph * 4))
                    wk_markGlyph(coverage, glyph);
            }
        }
        CFDataRef colr = wk_fontTable(font, wk_colrTableKey(), kCTFontTableCOLR);
        wk_colr_tables colorTables = { colr ? CFDataGetBytePtr(colr) : NULL,
            colr ? (size_t)CFDataGetLength(colr) : 0, NULL, 0 };
        for (unsigned glyph = 0; glyph < (unsigned)glyphCount; ++glyph) {
            if (wk_colrHasBaseGlyph(&colorTables, (uint16_t)glyph))
                wk_markGlyph(coverage, glyph);
        }
        if (!CFBitVectorGetCountOfBit(coverage, CFRangeMake(0, glyphCount), 1)) {
            CFRelease(coverage);
            coverage = NULL;
        }
    }
    if (data)
        CFRelease(data);
    return coverage;
}

// The feature coverage is glyph-indexed too, and is a real CFBitVector even when nothing is covered.
WK_POLYFILL_ABSENT("CoreText", CFBitVectorRef, CTFontCopyGlyphCoverageForFeature, (CTFontRef font, CFDictionaryRef feature))
{
    CFIndex glyphCount = font ? CTFontGetGlyphCount(font) : 0;
    CFMutableBitVectorRef coverage = CFBitVectorCreateMutable(kCFAllocatorDefault, 0);
    if (!coverage)
        return NULL;
    CFBitVectorSetCount(coverage, glyphCount > 0 ? glyphCount : 0);
    if (glyphCount <= 0 || !feature || CFGetTypeID(feature) != CFDictionaryGetTypeID())
        return coverage;

    int featureType = 0, featureSelector = 0;
    if (wk_intFromNumber(CFDictionaryGetValue(feature, kCTFontFeatureTypeIdentifierKey), &featureType)
        && wk_intFromNumber(CFDictionaryGetValue(feature, kCTFontFeatureSelectorIdentifierKey), &featureSelector)) {
        wk_markAATFeatureCoverage(font, featureType, featureSelector, (uint32_t)glyphCount, coverage);
        return coverage;
    }

// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK and absent on the 10.9 runtime; this file
// supplies both (WK_POLYFILL_CONST above), so these read the layer's own definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    CFTypeRef tagValue = CFDictionaryGetValue(feature, kCTFontOpenTypeFeatureTag);
#pragma clang diagnostic pop
    char tag[8] = { 0 };
    if (tagValue && CFGetTypeID(tagValue) == CFStringGetTypeID()
        && CFStringGetCString((CFStringRef)tagValue, tag, sizeof(tag), kCFStringEncodingASCII)
        && strlen(tag) == 4)
        wk_markOpenTypeFeatureCoverage(font, tag, coverage);
    return coverage;
}

// CSS generic family -> font descriptor. A generic family names one font, and CoreText's fallback table
// (DefaultFontFallbacks.plist in the CoreText bundle) names the font each of ja, zh-Hans, zh-Hant and ko
// uses in its place: the nested array of language/font pairs inside that family's cascade.
static CFDictionaryRef wkCSSFamilyFallbacks;

static void wk_loadCSSFamilyFallbacks(void)
{
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.CoreText"));
    CFURLRef url = bundle ? CFBundleCopyResourceURL(bundle, CFSTR("DefaultFontFallbacks"), CFSTR("plist"), NULL) : NULL;
    CFReadStreamRef stream = url ? CFReadStreamCreateWithFile(kCFAllocatorDefault, url) : NULL;
    if (stream && CFReadStreamOpen(stream)) {
        CFPropertyListRef plist = CFPropertyListCreateWithStream(kCFAllocatorDefault, stream, 0, kCFPropertyListImmutable, NULL, NULL);
        if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID())
            wkCSSFamilyFallbacks = (CFDictionaryRef)plist;
        else if (plist)
            CFRelease(plist);
        CFReadStreamClose(stream);
    }
    if (stream)
        CFRelease(stream);
    if (url)
        CFRelease(url);
}

// Chinese resolves to the table's zh-Hans or zh-Hant by script subtag, then by region (TW, HK and MO
// write Traditional); every other language matches on its primary subtag.
static bool wk_languageMatchesFallbackLanguage(CFStringRef language, CFStringRef fallbackLanguage)
{
    char requested[64], entry[16];
    if (!CFStringGetCString(language, requested, sizeof(requested), kCFStringEncodingASCII)
        || !CFStringGetCString(fallbackLanguage, entry, sizeof(entry), kCFStringEncodingASCII))
        return false;
    char *subtags[8];
    size_t subtagCount = 0;
    for (char *cursor = requested; *cursor && subtagCount < 8; ) {
        subtags[subtagCount++] = cursor;
        while (*cursor && *cursor != '-' && *cursor != '_')
            ++cursor;
        if (*cursor)
            *cursor++ = '\0';
    }
    size_t entryPrimaryLength = strcspn(entry, "-");
    if (!subtagCount || strlen(subtags[0]) != entryPrimaryLength || strncasecmp(subtags[0], entry, entryPrimaryLength))
        return false;
    if (strcasecmp(subtags[0], "zh"))
        return true;
    bool traditional = false;
    for (size_t i = 1; i < subtagCount; ++i) {
        if (!strcasecmp(subtags[i], "Hant") || !strcasecmp(subtags[i], "Hans")) {
            traditional = !strcasecmp(subtags[i], "Hant");
            break;
        }
        if (!strcasecmp(subtags[i], "TW") || !strcasecmp(subtags[i], "HK") || !strcasecmp(subtags[i], "MO"))
            traditional = true;
    }
    return !strcasecmp(entry, traditional ? "zh-Hant" : "zh-Hans");
}

static CFStringRef wk_languageFallbackFont(CFStringRef tableKey, CFStringRef language)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_loadCSSFamilyFallbacks);
    CFTypeRef cascade = wkCSSFamilyFallbacks ? CFDictionaryGetValue(wkCSSFamilyFallbacks, tableKey) : NULL;
    if (!cascade || CFGetTypeID(cascade) != CFArrayGetTypeID())
        return NULL;
    CFIndex count = CFArrayGetCount((CFArrayRef)cascade);
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef group = CFArrayGetValueAtIndex((CFArrayRef)cascade, i);
        if (CFGetTypeID(group) != CFArrayGetTypeID())
            continue;
        CFIndex pairCount = CFArrayGetCount((CFArrayRef)group);
        for (CFIndex j = 0; j < pairCount; ++j) {
            CFTypeRef pair = CFArrayGetValueAtIndex((CFArrayRef)group, j);
            if (CFGetTypeID(pair) != CFArrayGetTypeID() || CFArrayGetCount((CFArrayRef)pair) != 2)
                continue;
            CFTypeRef pairLanguage = CFArrayGetValueAtIndex((CFArrayRef)pair, 0);
            CFTypeRef pairFont = CFArrayGetValueAtIndex((CFArrayRef)pair, 1);
            if (CFGetTypeID(pairLanguage) == CFStringGetTypeID() && CFGetTypeID(pairFont) == CFStringGetTypeID()
                && wk_languageMatchesFallbackLanguage(language, (CFStringRef)pairLanguage))
                return (CFStringRef)pairFont;
        }
    }
    return NULL;
}

WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateForCSSFamily, (CFStringRef cssFamily, CFStringRef language))
{
    if (!cssFamily)
        return NULL;
    CFStringRef tableKey = NULL;
    CFStringRef name = NULL;
    if (CFEqual(cssFamily, kCTFontCSSFamilySerif)) {
        tableKey = CFSTR("serif");
        name = CFSTR("Times");
    } else if (CFEqual(cssFamily, kCTFontCSSFamilySansSerif)) {
        tableKey = CFSTR("sans-serif");
        name = CFSTR("Helvetica");
    } else if (CFEqual(cssFamily, kCTFontCSSFamilyMonospace)) {
        tableKey = CFSTR("monospace");
        name = CFSTR("Courier");
    } else if (CFEqual(cssFamily, kCTFontCSSFamilyCursive)) {
        tableKey = CFSTR("cursive");
        name = CFSTR("Apple Chancery");
    } else if (CFEqual(cssFamily, kCTFontCSSFamilyFantasy)) {
        tableKey = CFSTR("fantasy");
        name = CFSTR("Papyrus");
    }
    if (!name)
        return NULL;
    CFStringRef languageFont = language ? wk_languageFallbackFont(tableKey, language) : NULL;
    if (language && CFEqual(cssFamily, kCTFontCSSFamilyCursive)
        && wk_languageMatchesFallbackLanguage(language, CFSTR("zh-Hant")))
        languageFont = CFSTR("STKaiTi-TC-Regular");
    return CTFontDescriptorCreateWithNameAndSize(languageFont ? languageFont : name, 0.0);
}

// "Last Resort" tofu fallback font descriptor. The LastResort font ships on 10.9.
WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateLastResort, (void))
{
    return CTFontDescriptorCreateWithNameAndSize(CFSTR("LastResort"), 0.0);
}

// The text-style metrics CoreText publishes per platform, keyed by the style identifier. The Mac table
// is this host's; the Phone table is the one kCTFontTextStylePlatformPhone names. Both are the default
// content-size category: the Mac scale has only that one class. Headline is the sole style heavier than
// regular on Phone (semibold 0.3); the Mac scale makes it bold (0.4) and Caption2 medium (0.23). The
// short and tall variants carry their base style's point size.
typedef struct { const char* token; CGFloat size; CGFloat weight; } wk_text_style_metrics;

static const wk_text_style_metrics wkMacTextStyles[] = {
    { "UICTFontTextStyleTitle0",        26, 0.0 },
    { "UICTFontTextStyleTitle1",        22, 0.0 },
    { "UICTFontTextStyleTitle2",        17, 0.0 },
    { "UICTFontTextStyleTitle3",        15, 0.0 },
    { "UICTFontTextStyleTitle4",        13, 0.0 },
    { "UICTFontTextStyleHeadline",      13, 0.4 },
    { "UICTFontTextStyleBody",          13, 0.0 },
    { "UICTFontTextStyleCallout",       12, 0.0 },
    { "UICTFontTextStyleSubhead",       11, 0.0 },
    { "UICTFontTextStyleFootnote",      10, 0.0 },
    { "UICTFontTextStyleCaption1",      10, 0.0 },
    { "UICTFontTextStyleCaption2",      10, 0.23 },
    { "UICTFontTextStyleShortHeadline", 13, 0.4 },
    { "UICTFontTextStyleShortBody",     13, 0.0 },
    { "UICTFontTextStyleShortSubhead",  11, 0.0 },
    { "UICTFontTextStyleShortFootnote", 10, 0.0 },
    { "UICTFontTextStyleShortCaption1", 10, 0.0 },
    { "UICTFontTextStyleTallBody",      13, 0.0 },
};

static const wk_text_style_metrics wkPhoneTextStyles[] = {
    { "UICTFontTextStyleTitle0",        34, 0.0 },
    { "UICTFontTextStyleTitle1",        28, 0.0 },
    { "UICTFontTextStyleTitle2",        22, 0.0 },
    { "UICTFontTextStyleTitle3",        20, 0.0 },
    { "UICTFontTextStyleTitle4",        17, 0.0 },
    { "UICTFontTextStyleHeadline",      17, 0.3 },
    { "UICTFontTextStyleBody",          17, 0.0 },
    { "UICTFontTextStyleCallout",       16, 0.0 },
    { "UICTFontTextStyleSubhead",       15, 0.0 },
    { "UICTFontTextStyleFootnote",      13, 0.0 },
    { "UICTFontTextStyleCaption1",      12, 0.0 },
    { "UICTFontTextStyleCaption2",      11, 0.0 },
    { "UICTFontTextStyleShortHeadline", 17, 0.3 },
    { "UICTFontTextStyleShortBody",     17, 0.0 },
    { "UICTFontTextStyleShortSubhead",  15, 0.0 },
    { "UICTFontTextStyleShortFootnote", 13, 0.0 },
    { "UICTFontTextStyleShortCaption1", 12, 0.0 },
    { "UICTFontTextStyleTallBody",      17, 0.0 },
};

// CTFontTextStylePlatform, from PAL/pal/spi/cf/CoreTextSPI.h: Default -1, Phone 0, Watch 1, TV 2,
// Mac 3, MacTouchBar 4, Vision 5, VisionLegacy 6. Default names the running platform, a Mac here.
#define WK_CTFONT_TEXT_STYLE_PLATFORM_PHONE 0

// Style identifier -> point size and CTFontWeight for a platform. An identifier no table names takes
// Body's metrics, the scale's baseline.
static void wkTextStyleMetrics(CFStringRef style, int platform, CGFloat *size, CGFloat *weight)
{
    bool phone = platform == WK_CTFONT_TEXT_STYLE_PLATFORM_PHONE;
    const wk_text_style_metrics *table = phone ? wkPhoneTextStyles : wkMacTextStyles;
    size_t count = phone ? sizeof(wkPhoneTextStyles) / sizeof(wkPhoneTextStyles[0])
                         : sizeof(wkMacTextStyles) / sizeof(wkMacTextStyles[0]);
    char buf[64];
    if (!style || !CFStringGetCString(style, buf, sizeof(buf), kCFStringEncodingUTF8))
        strcpy(buf, "UICTFontTextStyleBody");
    for (size_t i = 0; i < count; ++i) {
        if (!strcmp(buf, table[i].token)) {
            *size = table[i].size;
            *weight = table[i].weight;
            return;
        }
    }
    for (size_t i = 0; i < count; ++i) {
        if (!strcmp("UICTFontTextStyleBody", table[i].token)) {
            *size = table[i].size;
            *weight = table[i].weight;
            return;
        }
    }
}

// The font a text style resolves to: the system UI font for the language at the style's point size,
// carrying the style's weight -- which reaches the family member holding it through the same nearest
// weight selection any other kCTFontWeightTrait request takes.
static CTFontRef wkTextStyleFont(CFStringRef style, int platform, CFStringRef language, CGFloat *outSize, CGFloat *outWeight)
{
    CGFloat size = 0.0, weight = 0.0;
    wkTextStyleMetrics(style, platform, &size, &weight);
    if (outSize)
        *outSize = size;
    if (outWeight)
        *outWeight = weight;
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, language);
    if (!font)
        return NULL;
    CTFontDescriptorRef request = wkWeightRequestDescriptor(weight);
    if (request) {
        font = wkApplyTraitsToFace(font, request);
        CFRelease(request);
    }
    return font;
}

// Text-style font descriptor (style / content-size category / language).
WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateWithTextStyle, (CFStringRef style, CFStringRef size, CFStringRef language))
{
    (void)size;
    CTFontRef font = wkTextStyleFont(style, -1 /* kCTFontTextStylePlatformDefault */, language, NULL, NULL);
    if (!font)
        return NULL;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
    CFRelease(font);
    return descriptor;
}

// CTFontDescriptorGetTextStyleSize (10.10+): the point size (return value), the weight (out-param, on
// the CTFontWeight -1..1 scale) and the line spacing (out-param, in points) of a text style at a
// content-size category, for the platform the third argument names. The style keys arrive as the
// polyfilled kCTUIFontTextStyle* CFStrings (defined above), so match on their text.
// kCTFontTextStylePlatformPhone answers the Phone table; every other value, Default included, answers
// this host's Mac table. Line spacing is the metric of the font the style resolves to: ascent + descent
// + leading at the answered size.
// (platform is the CTFontTextStylePlatform enum, absent from this system's CoreText headers, typed here
// as its underlying int so this TU needs no extra header; C linkage is by name.)
WK_POLYFILL_ABSENT("CoreText", CGFloat, CTFontDescriptorGetTextStyleSize, (CFStringRef style, CFTypeRef sizeCategory, int platform, CGFloat* weight, CGFloat* lineSpacing))
{
    (void)sizeCategory;
    CGFloat size = 0.0, w = 0.0;
    if (!lineSpacing) {
        wkTextStyleMetrics(style, platform, &size, &w);
        if (weight)
            *weight = w;
        return size;
    }

    *lineSpacing = 0.0;
    CTFontRef font = wkTextStyleFont(style, platform, NULL, &size, &w);
    if (weight)
        *weight = w;
    if (font) {
        *lineSpacing = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font);
        CFRelease(font);
    }
    return size;
}

// CTFontGetAccessibilityBoldWeightOfWeight (10.13+): the weight a system font should use when the
// "Bold Text" accessibility setting is on, given its normal weight (CTFontWeight, -1..1). 10.9 has no
// Bold Text accessibility feature — the whole AccessibilitySupport legibility subsystem is absent (see
// _AXSEnhanceTextLegibilityEnabled -> 0) — so there is no enhancement to apply: return the weight
// unchanged. WebKit only calls this under `shouldEnhanceTextLegibility`, which is driven by that same
// absent setting and is therefore false on 10.9, so this identity result is never actually consumed; it
// exists so the byte-upstream caller links and behaves correctly if the gate ever opens.
WK_POLYFILL_ABSENT("CoreText", CGFloat, CTFontGetAccessibilityBoldWeightOfWeight, (CGFloat weight))
{
    return weight;
}

// Glyphs for a run of consecutive BMP characters. The modern convenience over CTFontGetGlyphsFor
// Characters (which 10.9 has): the caller passes a CFRange of UniChar code points and a glyph buffer
// sized to the range length.
WK_POLYFILL_ABSENT("CoreText", bool, CTFontGetGlyphsForCharacterRange, (CTFontRef font, CGGlyph glyphs[], CFRange range))
{
    if (!font || range.length <= 0)
        return false;
    UniChar *characters = (UniChar *)malloc(sizeof(UniChar) * (size_t)range.length);
    if (!characters)
        return false;
    for (CFIndex i = 0; i < range.length; ++i)
        characters[i] = (UniChar)(range.location + i);
    bool result = CTFontGetGlyphsForCharacters(font, characters, glyphs, range.length);
    free(characters);
    return result;
}

// "Physical" (non-synthesized) symbolic traits. 10.9 exposes only CTFontGetSymbolicTraits; the
// physical traits are the same set for a real (non-synthesized) font.
WK_POLYFILL_ABSENT("CoreText", CTFontSymbolicTraits, CTFontGetPhysicalSymbolicTraits, (CTFontRef font))
{
    return CTFontGetSymbolicTraits(font);
}

// UI-font-type classification (newer): the type the font was created for, recorded above by
// CTFontCreateUIFontForLanguage. A font created any other way has no type.
WK_POLYFILL_ABSENT("CoreText", uint32_t, CTFontGetUIFontType, (CTFontRef font))
{
    uint32_t type = 0;
    return wk_recordedUIFontType(font, &type) ? type : (uint32_t)-1 /* kCTFontNoFontType */;
}

// Is this the Apple Color Emoji font? Compare the PostScript name (the emoji font ships on 10.9).
WK_POLYFILL_ABSENT("CoreText", bool, CTFontIsAppleColorEmoji, (CTFontRef font))
{
    if (!font)
        return false;
    CFStringRef postScriptName = CTFontCopyPostScriptName(font);
    bool result = postScriptName && CFStringCompare(postScriptName, CFSTR("AppleColorEmoji"), 0) == kCFCompareEqualTo;
    if (postScriptName)
        CFRelease(postScriptName);
    return result;
}

// The system UI font, and the option set a descriptor carries. 10.9 stores descriptor options and
// exposes the one that matters through CTFontDescriptorIsSystemUIFont, which reads the same
// kCTFontDescriptorOptionSystemUIFont bit CTFontDescriptorGetOptions reports. The bit is what the
// descriptor was created with, not a property of the names it carries: the same attributes with the
// option and without it are two different answers, which is the distinction the serialization round
// trip in FontPlatformDataCoreText.cpp turns on.
extern bool CTFontDescriptorIsSystemUIFont(CTFontDescriptorRef);

WK_POLYFILL_ABSENT("CoreText", uint32_t, CTFontDescriptorGetOptions, (CTFontDescriptorRef descriptor))
{
    return CTFontDescriptorIsSystemUIFont(descriptor) ? 1u << 1 /* kCTFontDescriptorOptionSystemUIFont */ : 0;
}

WK_POLYFILL_ABSENT("CoreText", bool, CTFontIsSystemUIFont, (CTFontRef font))
{
    if (!font)
        return false;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
    bool result = CTFontDescriptorIsSystemUIFont(descriptor);
    if (descriptor)
        CFRelease(descriptor);
    return result;
}

// Enable user-installed fonts process-wide (newer). User fonts are already enabled on 10.9.
WK_POLYFILL_ABSENT("CoreText", bool, CTFontManagerEnableAllUserFonts, (bool postFontChangeNotification))
{
    (void)postFontChangeNotification;
    return true;
}

// Composition language hint on a paragraph style (newer). No effect on 10.9 line layout.
WK_POLYFILL_ABSENT("CoreText", void, CTParagraphStyleSetCompositionLanguage, (CTParagraphStyleRef style, int language))
{
    (void)style; (void)language;
}

// Does the font contain a given sfnt table? 10.9 lacks the predicate but has the underlying copy.
WK_POLYFILL_ABSENT("CoreText", bool, CTFontHasTable, (CTFontRef font, CTFontTableTag tag))
{
    CFDataRef table = CTFontCopyTable(font, tag, 0);
    bool present = table != NULL;
    if (table)
        CFRelease(table);
    return present;
}

// CTFontShapeGlyphs (10.13+) shapes a run: it applies the font's substitutions and positioning to the
// caller's glyph array, growing or shrinking it through `handler` when substitution changes the glyph
// count, and returns the run's initial advance. `indexes` is the shaped run's map back into `chars` —
// one entry per glyph, naming the UTF-16 offset that glyph came from — and the handler resizes it
// alongside the glyphs, so the map stays one entry per glyph across a change in count.
//
// CTFontTransformGlyphs is 10.9's entry point for the same transformation, over the same glyph array:
// it rewrites the caller's glyphs and advances in place and marks each glyph a substitution consumed
// with kCGFontIndexInvalid and a zero advance. Measured on this host at 40pt, Hoefler Text "fi" goes
// from glyphs 73, 76 with advances 13.40, 11.20 to glyph 191 at 23.36 followed by 65535 at 0, and
// Helvetica "AVAV" kerns 26.68 26.68 26.68 26.68 to 23.73 23.73 23.73 26.68. Those emptied slots are
// removed through the handler below, so the caller sees the shorter run the newer API returns.
//
// Which slots the shaped run has room for follows from what the two arrays hold:
//
//   kCGFontIndexInvalid is not a glyph. CGFont.h caps a CGGlyph at kCGGlyphMax, 65534, and names
//   65535 the invalid index, so a slot holding it holds no glyph on either side of the call. A slot
//   that ARRIVED holding it is the caller's, neither produced nor consumed by shaping; only a slot
//   the transform itself emptied is one this run no longer has.
//
//   A surrogate pair is one glyph, indexed at its lead unit. Measured on this host through CoreText's
//   own mapping: CTFontGetGlyphsForCharacters over U+1F44B's two code units returns true and answers
//   glyph 1100 at the lead with the trail slot left empty, either surrogate alone maps to nothing,
//   and a CTLine over the same two units carries one glyph at string index 0. So no glyph a shaper
//   produces is indexed at a trailing surrogate, and a slot that holds glyph 0 — the pad the caller
//   leaves for the trail unit — while its `indexes` entry names one is a pair the caller split across
//   two slots, which kCTFontShapeWithClusterComposition, and only that option, asks to be composed
//   back into the one glyph the pair maps to. A slot at a trailing surrogate holding any other glyph
//   is a glyph this run still has.
//
// Measured on the same host, 10.9 reads an EMPTY option set as "apply everything" rather than "apply
// nothing" — at 0 both the ligature and the kerning above happen — so each transformation is always
// named explicitly: shaping on every call, since CTFontShapeOptions has no bit that turns shaping
// off, and positioning only when the caller asks for kerning through kCTFontShapeWithKerning.
//
// CTFontShapeOptions, mirrored from PAL/pal/spi/cf/CoreTextSPI.h so the bit tested here can be checked
// against the enum that defines it rather than against a bare literal:
//     kCTFontShapeWithKerning            = (1 << 0)
//     kCTFontShapeWithClusterComposition = (1 << 1)
//     kCTFontShapeRightToLeft            = (1 << 2)
#define WK_CTFONT_SHAPE_WITH_KERNING             (1u << 0)
#define WK_CTFONT_SHAPE_WITH_CLUSTER_COMPOSITION (1u << 1)
#define WK_CTFONT_SHAPE_RIGHT_TO_LEFT            (1u << 2)

// CTFontTransformOptions, from the same header.
WK_SYSTEM_FN("CoreText", bool, CTFontTransformGlyphs, (CTFontRef, CGGlyph[], CGSize[], CFIndex, uint32_t));
#define WK_CTFONT_TRANSFORM_APPLY_SHAPING     (1u << 0)
#define WK_CTFONT_TRANSFORM_APPLY_POSITIONING (1u << 1)
#define WK_CGFONT_INDEX_INVALID               0xFFFF
#define WK_SHAPE_INLINE_GLYPHS                256

static bool wkShapeRemovesSlot(const CGGlyph *glyphs, const CGGlyph *arrivedGlyphs, const CFIndex *indexes,
    const UniChar *chars, bool composeClusters, CFIndex slot)
{
    if (glyphs[slot] == WK_CGFONT_INDEX_INVALID && arrivedGlyphs[slot] != WK_CGFONT_INDEX_INVALID)
        return true;
    if (!composeClusters || !chars || !indexes || indexes[slot] < 0)
        return false;
    UniChar character = chars[indexes[slot]];
    return glyphs[slot] == 0 && character >= 0xDC00 && character <= 0xDFFF;
}

// CTFontTransformGlyphs builds its run from glyphs alone and defaults to the Latin script. A character
// stream supplies the script and other context it cannot recover from glyphs. TOpenTypeMorph and TOpenTypePositioningEngine take the language system from the
// stream's kCTLanguageAttributeName; a default-ignorable character is dropped from the stream before
// shaping rather than left between the glyphs it joins; and a positioning feature the font's settings
// request is applied only to a stream. Measured on this host, a CTLine sets Lato "fi" without its ligature
// under "tr", forms Times f U+200D i into one glyph and applies Hiragino Kaku Gothic ProN's palt (384.00 to
// 330.05 at 48pt), and CTFontTransformGlyphs over the same glyphs does none of the three. A run that carries
// one of them, or a non-Latin script with layout tables, is set by a typesetter over its characters.
//
// The language system 10.9 selects for a language: ScriptAndLangSysTagsFromLanguage reduces the canonical
// locale identifier to a Mac language code with CFLocaleGetLanguageRegionEncodingForLocaleIdentifier and
// indexes this table, read out of that function's jump table. An empty entry selects the default one.
static const char wk_langSysTagForMacLanguage[152][5] = {
    "ENG ", "FRA ", "DEU ", "ITA ", "NLD ", "SVE ", "ESP ", "DAN ", "PTG ", "NOR ", "IWR ", "JAN ", "ARA ", "FIN ",
    "ELL ", "ISL ", "MTS ", "TRK ", "HRV ", "ZHT ", "URD ", "HIN ", "THA ", "KOR ", "LTH ", "PLK ", "HUN ", "ETI ",
    "LVI ", "NSM ", "FOS ", "FAR ", "RUS ", "ZHS ", "FLE ", "IRI ", "SQI ", "ROM ", "CSY ", "SKY ", "SLV ", "JII ",
    "SRB ", "MKD ", "BGR ", "UKR ", "BEL ", "UZB ", "KAZ ", "AZE ", "AZE ", "HYE ", "KAT ", "MOL ", "KIR ", "TAJ ",
    "TKM ", "MNG ", "MNG ", "PAS ", "KUR ", "KSH ", "SND ", "TIB ", "NEP ", "SAN ", "MAR ", "BEN ", "ASM ", "GUJ ",
    "PAN ", "ORI ", "MAL ", "KAN ", "TAM ", "TEL ", "SNH ", "BRM ", "KHM ", "LAO ", "VIT ", "IND ", "",     "MLY ",
    "MLY ", "AMH ", "TGY ", "ORO ", "SML ", "SWK ", "RUA ", "",     "CHI ", "MLG ", "NTO ", "",     "",     "",
    "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",
    "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",     "",
    "",     "",     "WEL ", "EUQ ", "CAT ", "LAT ", "",     "GUA ", "AYM ", "TAT ", "UYG ", "DZN ", "JAV ", "",
    "GAL ", "AFK ", "BRE ", "INU ", "GAE ", "MNX ", "IRT ", "TGN ", "PGR ", "GRN ", "AZE ", "NYN ",
};

// What of a font's shaping depends on a run's characters: the language system tags its GSUB and GPOS
// script lists name, and whether its feature settings turn on a feature its GPOS carries. Kept on the CTFont.
typedef struct {
    bool requestsPositioningFeature;
    CFIndex languageSystemCount;
    CFIndex scriptCount;
    uint32_t languageSystems[];
} wk_shaping_context;

static void wk_collectLanguageSystems(CTFontRef font, CTFontTableTag tableTag, uint32_t **tags, CFIndex *count, CFIndex *capacity)
{
    CFDataRef data = CTFontCopyTable(font, tableTag, kCTFontTableOptionNoOptions);
    if (!data)
        return;
    wk_font_table table = { CFDataGetBytePtr(data), CFDataGetBytePtr(data) ? (uint32_t)CFDataGetLength(data) : 0 };
    uint64_t scriptList = wk_tableU16(table, 4);
    uint64_t scriptCount = scriptList ? wk_tableU16(table, scriptList) : 0;
    for (uint64_t s = 0; s < scriptCount; s++) {
        uint64_t script = scriptList + wk_tableU16(table, scriptList + 2 + s * 6 + 4);
        uint64_t languageSystemCount = wk_tableU16(table, script + 2);
        for (uint64_t l = 0; l < languageSystemCount; l++) {
            if (*count == *capacity) {
                CFIndex grown = *capacity ? *capacity * 2 : 8;
                uint32_t *resized = (uint32_t *)realloc(*tags, (size_t)grown * sizeof(uint32_t));
                if (!resized)
                    abort();
                *tags = resized;
                *capacity = grown;
            }
            (*tags)[(*count)++] = wk_tableU32(table, script + 4 + l * 6);
        }
    }
    CFRelease(data);
}

static void wk_collectScripts(CTFontRef font, CTFontTableTag tag, uint32_t **tags, CFIndex *count)
{
    CFDataRef data = CTFontCopyTable(font, tag, kCTFontTableOptionNoOptions);
    if (!data)
        return;
    wk_font_table table = { CFDataGetBytePtr(data), (uint32_t)CFDataGetLength(data) };
    uint64_t list = wk_tableU16(table, 4);
    uint16_t scripts = list ? wk_tableU16(table, list) : 0;
    if (list + 2 + (uint64_t)scripts * 6 <= table.length) {
        uint32_t *grown = realloc(*tags, (size_t)(*count + scripts) * sizeof(uint32_t));
        if (scripts && !grown)
            abort();
        *tags = grown;
        for (uint16_t i = 0; i < scripts; ++i)
            (*tags)[(*count)++] = wk_tableU32(table, list + 2 + (uint64_t)i * 6);
    }
    CFRelease(data);
}

static bool wk_gposCarriesFeature(wk_font_table gpos, const char tag[4])
{
    uint32_t wanted = ((uint32_t)(uint8_t)tag[0] << 24) | ((uint32_t)(uint8_t)tag[1] << 16)
                    | ((uint32_t)(uint8_t)tag[2] << 8) | (uint8_t)tag[3];
    uint64_t featureList = wk_tableU16(gpos, 6);
    uint64_t featureCount = featureList ? wk_tableU16(gpos, featureList) : 0;
    for (uint64_t i = 0; i < featureCount; i++) {
        if (wk_tableU32(gpos, featureList + 2 + i * 6) == wanted)
            return true;
    }
    return false;
}

// A setting names its feature by OpenType tag and value or by AAT type and selector, and requests the
// feature only when it turns it on.
static bool wk_settingsRequestPositioningFeature(CTFontRef font)
{
    CFArrayRef settings = CTFontCopyFeatureSettings(font);
    if (!settings)
        return false;
    CFDataRef data = CTFontCopyTable(font, kCTFontTableGPOS, kCTFontTableOptionNoOptions);
    wk_font_table gpos = { data ? CFDataGetBytePtr(data) : NULL, data && CFDataGetBytePtr(data) ? (uint32_t)CFDataGetLength(data) : 0 };
    bool requested = false;
    for (CFIndex i = 0; gpos.bytes && !requested && i < CFArrayGetCount(settings); i++) {
        CFTypeRef setting = CFArrayGetValueAtIndex(settings, i);
        if (!setting || CFGetTypeID(setting) != CFDictionaryGetTypeID())
            continue;
        char tag[5] = { 0 };
        int value = 1;
// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK and absent on the 10.9 runtime; this file
// supplies both (WK_POLYFILL_CONST above), so these read the layer's own definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
        CFTypeRef openTypeTag = CFDictionaryGetValue((CFDictionaryRef)setting, kCTFontOpenTypeFeatureTag);
        CFTypeRef openTypeValue = CFDictionaryGetValue((CFDictionaryRef)setting, kCTFontOpenTypeFeatureValue);
#pragma clang diagnostic pop
        if (openTypeTag && CFGetTypeID(openTypeTag) == CFStringGetTypeID()) {
            if (!CFStringGetCString((CFStringRef)openTypeTag, tag, sizeof(tag), kCFStringEncodingASCII) || strlen(tag) != 4
                || (openTypeValue && !wk_intFromNumber(openTypeValue, &value)))
                continue;
        } else {
            int type = 0, selector = 0;
            if (!wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)setting, kCTFontFeatureTypeIdentifierKey), &type)
                || !wk_intFromNumber(CFDictionaryGetValue((CFDictionaryRef)setting, kCTFontFeatureSelectorIdentifierKey), &selector)
                || !wk_openTypeTagForAATFeature(type, selector, tag, &value))
                continue;
        }
        requested = value && wk_gposCarriesFeature(gpos, tag);
    }
    if (data)
        CFRelease(data);
    CFRelease(settings);
    return requested;
}

static const void *wk_shapingContextKey(void) { return sel_registerName("wk_shapingContext"); }

// The association is set once and never replaced, so a present value is read without a lock.
static const wk_shaping_context *wk_shapingContext(CTFontRef font)
{
    CFDataRef cached = (CFDataRef)objc_getAssociatedObject((id)(void *)font, wk_shapingContextKey());
    if (!cached) {
        objc_sync_enter((id)(void *)font);
        cached = (CFDataRef)objc_getAssociatedObject((id)(void *)font, wk_shapingContextKey());
        if (!cached) {
            uint32_t *tags = NULL;
            CFIndex count = 0, capacity = 0;
            wk_collectLanguageSystems(font, kCTFontTableGSUB, &tags, &count, &capacity);
            wk_collectLanguageSystems(font, kCTFontTableGPOS, &tags, &count, &capacity);
            CFIndex languageCount = count;
            wk_collectScripts(font, kCTFontTableGSUB, &tags, &count);
            wk_collectScripts(font, kCTFontTableGPOS, &tags, &count);
            CFMutableDataRef context = CFDataCreateMutable(kCFAllocatorDefault, 0);
            if (!context)
                abort();
            CFDataSetLength(context, (CFIndex)(sizeof(wk_shaping_context) + (size_t)count * sizeof(uint32_t)));
            wk_shaping_context *fields = (wk_shaping_context *)(void *)CFDataGetMutableBytePtr(context);
            if (!fields)
                abort();
            fields->requestsPositioningFeature = wk_settingsRequestPositioningFeature(font);
            fields->languageSystemCount = languageCount;
            fields->scriptCount = count - languageCount;
            if (count)
                memcpy(fields->languageSystems, tags, (size_t)count * sizeof(uint32_t));
            free(tags);
            objc_setAssociatedObject((id)(void *)font, wk_shapingContextKey(), (id)context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CFRelease(context);
            cached = (CFDataRef)objc_getAssociatedObject((id)(void *)font, wk_shapingContextKey());
        }
        objc_sync_exit((id)(void *)font);
    }
    return (const wk_shaping_context *)(void *)CFDataGetBytePtr(cached);
}

// CFLocale.h declares this on 10.9; the SDK's header no longer does.
extern Boolean CFLocaleGetLanguageRegionEncodingForLocaleIdentifier(CFStringRef localeIdentifier, LangCode *languageCode,
    RegionCode *regionCode, ScriptCode *scriptCode, CFStringEncoding *stringEncoding);

// The last language this thread resolved: a page's runs share one, so its canonical form is found once.
typedef struct {
    CFStringRef language;
    uint32_t languageSystem;
} wk_language_system_memo;

static pthread_key_t wkLanguageSystemMemoKey;

static void wk_releaseLanguageSystemMemo(void *value)
{
    wk_language_system_memo *memo = (wk_language_system_memo *)value;
    if (memo->language)
        CFRelease(memo->language);
    free(memo);
}

static void wk_makeLanguageSystemMemoKey(void)
{
    if (pthread_key_create(&wkLanguageSystemMemoKey, wk_releaseLanguageSystemMemo))
        abort();
}

static uint32_t wk_languageSystemForLanguage(CFStringRef language)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_makeLanguageSystemMemoKey);
    wk_language_system_memo *memo = (wk_language_system_memo *)pthread_getspecific(wkLanguageSystemMemoKey);
    if (!memo) {
        memo = (wk_language_system_memo *)calloc(1, sizeof(*memo));
        if (!memo || pthread_setspecific(wkLanguageSystemMemoKey, memo))
            abort();
    }
    if (memo->language && (memo->language == language || CFEqual(memo->language, language)))
        return memo->languageSystem;

    uint32_t languageSystem = 0;
    CFStringRef canonical = CFLocaleCreateCanonicalLocaleIdentifierFromString(kCFAllocatorDefault, language);
    LangCode code = 0x7FFF;
    if (canonical) {
        CFLocaleGetLanguageRegionEncodingForLocaleIdentifier(canonical, &code, NULL, NULL, NULL);
        CFRelease(canonical);
    }
    if (code >= 0 && code < (LangCode)(sizeof(wk_langSysTagForMacLanguage) / sizeof(wk_langSysTagForMacLanguage[0]))) {
        const char *tag = wk_langSysTagForMacLanguage[code];
        if (tag[0])
            languageSystem = ((uint32_t)(uint8_t)tag[0] << 24) | ((uint32_t)(uint8_t)tag[1] << 16)
                           | ((uint32_t)(uint8_t)tag[2] << 8) | (uint8_t)tag[3];
    }
    CFStringRef copy = CFStringCreateCopy(kCFAllocatorDefault, language);
    if (!copy)
        abort();
    if (memo->language)
        CFRelease(memo->language);
    memo->language = copy;
    memo->languageSystem = languageSystem;
    return languageSystem;
}

static bool wk_shapingDependsOnCharacters(CTFontRef font, const UniChar chars[], CFIndex count, CFStringRef language)
{
    if (!font || !chars)
        return false;
    bool nonLatin = false;
    for (CFIndex i = 0; i < count;) {
        UChar32 character;
        U16_NEXT(chars, i, count, character);
        if (u_hasBinaryProperty(character, UCHAR_DEFAULT_IGNORABLE_CODE_POINT))
            return true;
        UErrorCode status = U_ZERO_ERROR;
        UScriptCode script = uscript_getScript(character, &status);
        nonLatin |= U_SUCCESS(status) && script != USCRIPT_COMMON && script != USCRIPT_INHERITED && script != USCRIPT_LATIN;
    }
    const wk_shaping_context *context = wk_shapingContext(font);
    if (context->requestsPositioningFeature)
        return true;
    // TOpenTypeMorph derives a script from characters; a glyph-only transform selects latn.
    // A non-Latin run can select its own Script table or DFLT, including when only latn is present.
    if (nonLatin && context->scriptCount)
        return true;
    if (!language || !context->languageSystemCount || CFGetTypeID(language) != CFStringGetTypeID())
        return false;
    uint32_t languageSystem = wk_languageSystemForLanguage(language);
    for (CFIndex i = 0; languageSystem && i < context->languageSystemCount; i++) {
        if (context->languageSystems[i] == languageSystem)
            return true;
    }
    return false;
}

static CFNumberRef wkTypesetterShapingZeroKern;
static CFDictionaryRef wkTypesetterShapingOptions[2];

static void wk_makeTypesetterShapingConstants(void)
{
    float zero = 0;
    wkTypesetterShapingZeroKern = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &zero);
    for (int level = 0; level < 2; ++level) {
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &level);
        const void *keys[] = { kCTTypesetterOptionForcedEmbeddingLevel };
        const void *values[] = { number };
        wkTypesetterShapingOptions[level] = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(number);
    }
}

// Set the caller's own nominal glyphs from characters, language and kerning at the forced direction.
static bool wk_shapeThroughTypesetter(CTFontRef font, CGGlyph glyphs[], CGSize advances[], CGPoint origins[], CFIndex indexes[],
    const UniChar chars[], CFIndex count, CFOptionFlags options, CFStringRef language,
    void (^handler)(CFRange, CGGlyph**, CGSize**, CGPoint**, CFIndex**), CGSize *initialAdvance)
{
    if (!chars || !indexes || !origins)
        return false;
    for (CFIndex i = 0; i < count; i++) {
        if (indexes[i] != i || (chars[i] >= 0xD800 && chars[i] <= 0xDFFF))
            return false;
    }

    CGGlyph inlineNominal[WK_SHAPE_INLINE_GLYPHS];
    CGSize inlineNominalAdvances[WK_SHAPE_INLINE_GLYPHS];
    bool inlineBuffers = count <= WK_SHAPE_INLINE_GLYPHS;
    CGGlyph *nominal = inlineBuffers ? inlineNominal : (CGGlyph *)malloc((size_t)count * sizeof(CGGlyph));
    CGSize *nominalAdvances = inlineBuffers ? inlineNominalAdvances : (CGSize *)malloc((size_t)count * sizeof(CGSize));
    if (!nominal || !nominalAdvances)
        abort();
    CTFontGetGlyphsForCharacters(font, chars, nominal, count);
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, nominal, nominalAdvances, count);
    // WebCore measures a glyph through a float, so the advances are compared at that precision.
    bool ownGlyphs = true;
    for (CFIndex i = 0; i < count && ownGlyphs; i++)
        ownGlyphs = nominal[i] && nominal[i] == glyphs[i] && (float)nominalAdvances[i].width == (float)advances[i].width;
    if (!inlineBuffers) {
        free(nominal);
        free(nominalAdvances);
    }
    if (!ownGlyphs)
        return false;

    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_makeTypesetterShapingConstants);
    CFNumberRef zeroKern = wkTypesetterShapingZeroKern;
    CFDictionaryRef typesetterOptions = wkTypesetterShapingOptions[!!(options & WK_CTFONT_SHAPE_RIGHT_TO_LEFT)];
    CFStringRef string = CFStringCreateWithCharactersNoCopy(kCFAllocatorDefault, chars, count, kCFAllocatorNull);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!string || !attributes || !zeroKern || !typesetterOptions)
        abort();
    CFDictionarySetValue(attributes, kCTFontAttributeName, font);
    if (language && CFGetTypeID(language) == CFStringGetTypeID())
        CFDictionarySetValue(attributes, kCTLanguageAttributeName, language);
    if (!(options & WK_CTFONT_SHAPE_WITH_KERNING))
        CFDictionarySetValue(attributes, kCTKernAttributeName, zeroKern);
    CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, string, attributes);
    CTTypesetterRef typesetter = attributed ? CTTypesetterCreateWithAttributedStringAndOptions(attributed, typesetterOptions) : NULL;
    CTLineRef line = typesetter ? CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0)) : NULL;
    CFArrayRef runs = line ? CTLineGetGlyphRuns(line) : NULL;
    CTRunRef run = runs && CFArrayGetCount(runs) == 1 ? (CTRunRef)CFArrayGetValueAtIndex(runs, 0) : NULL;
    CFDictionaryRef runAttributes = run ? CTRunGetAttributes(run) : NULL;
    CTFontRef runFont = runAttributes ? (CTFontRef)CFDictionaryGetValue(runAttributes, kCTFontAttributeName) : NULL;

    bool shaped = runFont && (runFont == font || CFEqual(runFont, font));
    if (shaped) {
        CFIndex runCount = CTRunGetGlyphCount(run);
        size_t slots = (size_t)(runCount ? runCount : 1);
        CGGlyph *runGlyphs = (CGGlyph *)malloc(slots * sizeof(CGGlyph));
        CGSize *runAdvances = (CGSize *)malloc(slots * sizeof(CGSize));
        CGPoint *runPositions = (CGPoint *)malloc(slots * sizeof(CGPoint));
        CFIndex *runIndices = (CFIndex *)malloc(slots * sizeof(CFIndex));
        if (!runGlyphs || !runAdvances || !runPositions || !runIndices)
            abort();
        CTRunGetGlyphs(run, CFRangeMake(0, 0), runGlyphs);
        CTRunGetAdvances(run, CFRangeMake(0, 0), runAdvances);
        CTRunGetPositions(run, CFRangeMake(0, 0), runPositions);
        CTRunGetStringIndices(run, CFRangeMake(0, 0), runIndices);

        // CTLine compacts substitutions itself. Its retained invisible glyphs carry string indices
        // and zero advances, including the sole glyph of a default-ignorable run.
        CGGlyph *outGlyphs = glyphs; CGSize *outAdvances = advances;
        CGPoint *outOrigins = origins; CFIndex *outIndexes = indexes;
        if (runCount != count)
            handler(CFRangeMake(count, runCount - count), &outGlyphs, &outAdvances, &outOrigins, &outIndexes);

        // Each origin is its glyph's offset from where the advances before it leave the pen; the first
        // glyph's own position is the run's initial advance.
        CGFloat pen = 0;
        CFIndex slot = 0;
        for (CFIndex r = 0; r < runCount; r++) {
            if (!slot) {
                initialAdvance->width = runPositions[r].x;
                pen = runPositions[r].x;
            }
            outGlyphs[slot] = runGlyphs[r];
            outAdvances[slot] = CGSizeMake(runAdvances[r].width, 0);
            outOrigins[slot] = CGPointMake(runPositions[r].x - pen, runPositions[r].y);
            outIndexes[slot] = runIndices[r];
            pen += runAdvances[r].width;
            slot++;
        }
        free(runGlyphs);
        free(runAdvances);
        free(runPositions);
        free(runIndices);
    }

    if (line)
        CFRelease(line);
    if (typesetter)
        CFRelease(typesetter);
    if (attributed)
        CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
    return shaped;
}

// CTFontShapeGlyphs takes a right-to-left run in logical order and returns it in visual order, which WebCore
// reverses back (Font::applyTransforms). CTFontTransformGlyphs reads a run in visual order.
static void wk_shapeReverse(CGGlyph *glyphs, CGSize *advances, CGPoint *origins, CFIndex *indexes, CFIndex count)
{
    for (CFIndex i = 0, j = count - 1; i < j; ++i, --j) {
        CGGlyph glyph = glyphs[i]; glyphs[i] = glyphs[j]; glyphs[j] = glyph;
        CGSize advance = advances[i]; advances[i] = advances[j]; advances[j] = advance;
        if (origins) {
            CGPoint origin = origins[i]; origins[i] = origins[j]; origins[j] = origin;
        }
        if (indexes) {
            CFIndex index = indexes[i]; indexes[i] = indexes[j]; indexes[j] = index;
        }
    }
}

WK_POLYFILL_ABSENT("CoreText", CGSize, CTFontShapeGlyphs,
    (CTFontRef font, CGGlyph glyphs[], CGSize advances[], CGPoint origins[], CFIndex indexes[], const UniChar chars[], CFIndex count, CFOptionFlags options, CFStringRef language, void (^handler)(CFRange, CGGlyph**, CGSize**, CGPoint**, CFIndex**)))
{
    CGSize zero = { 0, 0 };
    if (count <= 0 || !glyphs || !advances || !WK_SYSTEM(CTFontTransformGlyphs))
        return zero;

    uint32_t transform = WK_CTFONT_TRANSFORM_APPLY_SHAPING
        | ((options & WK_CTFONT_SHAPE_WITH_KERNING) ? WK_CTFONT_TRANSFORM_APPLY_POSITIONING : 0);

    CGSize initialAdvance = zero;
    if (handler && wk_shapingDependsOnCharacters(font, chars, count, language)
        && wk_shapeThroughTypesetter(font, glyphs, advances, origins, indexes, chars, count, options, language, handler, &initialAdvance))
        return initialAdvance;

    CTFontRef shapingFont = wk_shapingFont(font, !!(options & WK_CTFONT_SHAPE_RIGHT_TO_LEFT));
    if (shapingFont)
        font = shapingFont;

    if (options & WK_CTFONT_SHAPE_RIGHT_TO_LEFT)
        wk_shapeReverse(glyphs, advances, origins, indexes, count);

    // The advances are in/out, and CTFontTransformGlyphs keeps that contract itself: it writes an
    // advance only where it substitutes a glyph (measured, zero-seeded Hoefler "fi" comes back as
    // glyph 191 at the ligature's nominal 23.36) and applies kerning as a delta on the caller's
    // values (zero-seeded Helvetica "AVAV" comes back -2.95 per kerned pair, 23.73 - 26.68). Every
    // unchanged glyph keeps the caller's measurement — the only record of its run's orientation,
    // since the CTFont it was measured through carries no kCTFontOrientationAttribute.
    //
    // A caller with no handler cannot be told the glyph count changed, so it gets exactly what 10.9's
    // own CTFontTransformGlyphs hands its callers: the shaped run, with each slot substitution
    // consumed left at kCGFontIndexInvalid and a zero advance.
    if (!handler) {
        WK_SYSTEM(CTFontTransformGlyphs)(font, glyphs, advances, count, transform);
        return zero;
    }

    // Which slots the transform empties is the difference between the arrived glyphs and the returned
    // ones, so keep the arrived ones.
    CGGlyph inlineGlyphs[WK_SHAPE_INLINE_GLYPHS];
    CGGlyph *arrivedGlyphs = count <= WK_SHAPE_INLINE_GLYPHS
        ? inlineGlyphs : (CGGlyph *)malloc((size_t)count * sizeof(CGGlyph));
    // A run's worth of CGGlyphs either allocates or the process is past saving; abort rather than
    // compact against a snapshot that is not there.
    if (!arrivedGlyphs)
        abort();
    memcpy(arrivedGlyphs, glyphs, (size_t)count * sizeof(CGGlyph));

    WK_SYSTEM(CTFontTransformGlyphs)(font, glyphs, advances, count, transform);

    bool composeClusters = (options & WK_CTFONT_SHAPE_WITH_CLUSTER_COMPOSITION) != 0;

    // Compact the removed slots, last run of them first, so the indices of the ones still to visit hold
    // across each removal. A negative length removes that many entries ending at `location`; the handler
    // hands back the buffers' fresh bases, which the caller may have moved.
    CGGlyph *outGlyphs = glyphs; CGSize *outAdvances = advances;
    CGPoint *outOrigins = origins; CFIndex *outIndexes = indexes;
    CFIndex i = count;
    while (i > 0) {
        if (!wkShapeRemovesSlot(outGlyphs, arrivedGlyphs, outIndexes, chars, composeClusters, i - 1)) {
            i--;
            continue;
        }
        CFIndex removedEnd = i;
        while (i > 0 && wkShapeRemovesSlot(outGlyphs, arrivedGlyphs, outIndexes, chars, composeClusters, i - 1))
            i--;
        handler(CFRangeMake(removedEnd, i - removedEnd), &outGlyphs, &outAdvances, &outOrigins, &outIndexes);
    }
    if (arrivedGlyphs != inlineGlyphs)
        free(arrivedGlyphs);
    return zero;   // a transformed glyph array starts at the origin; there is no initial advance to report
}

// 10.9 stores a line's shaping advance in TLine, separately from each TRun's advance.
// A retained CTRun keeps this first-visual-run contribution after its CTLine is released.
static const void *wk_lineInitialAdvanceKey(void)
{
    return sel_registerName("wk_lineInitialAdvance");
}

WK_POLYFILL_REPLACES("CoreText", CFArrayRef, CTLineGetGlyphRuns, (CTLineRef line))
{
    CFArrayRef runs = WK_ORIGINAL(CTLineGetGlyphRuns)(line);
    if (!line || !runs || !CFArrayGetCount(runs))
        return runs;

    // CTLineGetTypographicBounds reads CTLine's TLine at +0x28; TLine::CachePositions
    // reads its shaping advance at +0xa8/+0xb0 before positioning the first run.
    const char *nativeLine;
    memcpy(&nativeLine, (const char *)line + 0x28, sizeof(nativeLine));
    CGSize initial;
    memcpy(&initial, nativeLine + 0xa8, sizeof(initial));
    if (!initial.width && !initial.height)
        return runs;

    id run = (id)(void *)CFArrayGetValueAtIndex(runs, 0);
    objc_sync_enter(run);
    if (!objc_getAssociatedObject(run, wk_lineInitialAdvanceKey())) {
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&initial, sizeof(initial));
        if (!data)
            abort();
        objc_setAssociatedObject(run, wk_lineInitialAdvanceKey(), (id)(void *)data, OBJC_ASSOCIATION_RETAIN);
        CFRelease(data);
    }
    objc_sync_exit(run);
    return runs;
}

WK_POLYFILL_REPLACES("CoreText", CGSize, CTRunGetInitialAdvance, (CTRunRef run))
{
    CGSize initial = WK_ORIGINAL(CTRunGetInitialAdvance)(run);
    CFDataRef data = run ? (CFDataRef)objc_getAssociatedObject((id)(void *)run, wk_lineInitialAdvanceKey()) : NULL;
    if (data) {
        CGSize lineInitial;
        memcpy(&lineInitial, CFDataGetBytePtr(data), sizeof(lineInitial));
        initial.width += lineInitial.width;
        initial.height += lineInitial.height;
    }
    return initial;
}

// 10.9 encodes mark placement in paint advances. Base advances keep mark glyphs at zero,
// and origins retain their displacement from the advancing pen, so normalizing a space's width
// does not erase the following mark's placement.
typedef struct {
    bool hasOrigins;
    CFIndex count;
    // count CGSize advances, followed by count CGPoint origins.
    CGSize advances[];
} wk_run_geometry;

// GDEF class 3 identifies marks, including marks with a nonzero hmtx advance.
static bool wk_runGlyphIsMark(CFDataRef gdef, CGGlyph glyph, CGFloat nominalAdvance)
{
    if (!gdef)
        return !nominalAdvance;
    CFIndex length = CFDataGetLength(gdef);
    const uint8_t *bytes = CFDataGetBytePtr(gdef);
    if (length < 6)
        return false;
    unsigned offset = wk_be16(bytes + 4);
    if (!offset || offset + 4 > length)
        return false;
    const uint8_t *classes = bytes + offset;
    unsigned format = wk_be16(classes);
    if (format == 1) {
        if (offset + 6 > length)
            return false;
        unsigned start = wk_be16(classes + 2);
        unsigned count = wk_be16(classes + 4);
        return glyph >= start && glyph - start < count && offset + 6 + 2 * count <= length
            && wk_be16(classes + 6 + 2 * (glyph - start)) == 3;
    }
    if (format == 2) {
        unsigned count = wk_be16(classes + 2);
        if (offset + 4 + 6 * count > length)
            return false;
        for (unsigned i = 0; i < count; ++i) {
            const uint8_t *range = classes + 4 + 6 * i;
            if (glyph >= wk_be16(range) && glyph <= wk_be16(range + 2))
                return wk_be16(range + 4) == 3;
        }
    }
    return false;
}

static const wk_run_geometry *wk_runGeometry(CTRunRef run)
{
    const void *key = sel_registerName("wk_runGeometry");
    CFDataRef cached = (CFDataRef)objc_getAssociatedObject((id)(void *)run, key);
    if (!cached) {
        objc_sync_enter((id)(void *)run);
        cached = (CFDataRef)objc_getAssociatedObject((id)(void *)run, key);
        if (!cached) {
            CFIndex count = CTRunGetGlyphCount(run);
            CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
            if (!data)
                abort();
            CFDataSetLength(data, sizeof(wk_run_geometry) + count * (sizeof(CGSize) + sizeof(CGPoint)));
            wk_run_geometry *geometry = (wk_run_geometry *)(void *)CFDataGetMutableBytePtr(data);
            geometry->count = count;
            geometry->hasOrigins = false;
            CGPoint *origins = (CGPoint *)(geometry->advances + count);
            if (count) {
                CTRunGetAdvances(run, CFRangeMake(0, 0), geometry->advances);
                CFDictionaryRef attributes = CTRunGetAttributes(run);
                CTFontRef font = attributes ? (CTFontRef)CFDictionaryGetValue(attributes, kCTFontAttributeName) : NULL;
                bool horizontal = !attributes || CFDictionaryGetValue(attributes, kCTVerticalFormsAttributeName) != kCFBooleanTrue;
                if (font && horizontal) {
                    CGGlyph *glyphs = malloc(count * sizeof(CGGlyph));
                    CGSize *nominal = malloc(count * sizeof(CGSize));
                    CGPoint *positions = malloc(count * sizeof(CGPoint));
                    if (!glyphs || !nominal || !positions)
                        abort();
                    CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
                    CTRunGetPositions(run, CFRangeMake(0, 0), positions);
                    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, nominal, count);
                    CGPoint end = CGPointMake(positions[count - 1].x + geometry->advances[count - 1].width,
                        positions[count - 1].y + geometry->advances[count - 1].height);
                    CFDataRef gdef = wk_fontTable(font, sel_registerName("wk_runGDEF"), kCTFontTableGDEF);
                    CFIndex firstBase = 0;
                    while (firstBase < count && wk_runGlyphIsMark(gdef, glyphs[firstBase], nominal[firstBase].width))
                        ++firstBase;
                    CGFloat pen = firstBase < count ? positions[firstBase].x : end.x;
                    for (CFIndex i = 0; i < count; ++i) {
                        origins[i] = CGPointMake(positions[i].x - pen, positions[i].y - end.y);
                        geometry->hasOrigins |= origins[i].x != 0 || origins[i].y != 0;
                        CGFloat nextPen = pen;
                        if (!wk_runGlyphIsMark(gdef, glyphs[i], nominal[i].width)) {
                            CFIndex nextBase = i + 1;
                            while (nextBase < count && wk_runGlyphIsMark(gdef, glyphs[nextBase], nominal[nextBase].width))
                                ++nextBase;
                            nextPen = nextBase < count ? positions[nextBase].x : end.x;
                        }
                        geometry->advances[i] = CGSizeMake(nextPen - pen, 0);
                        pen = nextPen;
                    }
                    free(positions);
                    free(nominal);
                    free(glyphs);
                }
            }
            objc_setAssociatedObject((id)(void *)run, key, (id)(void *)data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            CFRelease(data);
            cached = (CFDataRef)objc_getAssociatedObject((id)(void *)run, key);
        }
        objc_sync_exit((id)(void *)run);
    }
    return (const wk_run_geometry *)(const void *)CFDataGetBytePtr(cached);
}

WK_POLYFILL_REPLACES("CoreText", CTRunStatus, CTRunGetStatus, (CTRunRef run))
{
    CTRunStatus status = WK_ORIGINAL(CTRunGetStatus)(run);
    if (run && wk_runGeometry(run)->hasOrigins)
        status |= 1u << 4; // kCTRunStatusHasOrigins, from CoreTextSPI.h.
    return status;
}

WK_POLYFILL_ABSENT("CoreText", void, CTRunGetBaseAdvancesAndOrigins,
    (CTRunRef run, CFRange range, CGSize *advances, CGPoint *origins))
{
    if (!run)
        return;
    const wk_run_geometry *geometry = wk_runGeometry(run);
    CFIndex count = range.length ? range.length : geometry->count - range.location;
    if (range.location < 0 || count < 0 || range.location > geometry->count || count > geometry->count - range.location)
        return;
    if (advances)
        memcpy(advances, geometry->advances + range.location, count * sizeof(CGSize));
    if (origins)
        memcpy(origins, (const CGPoint *)(geometry->advances + geometry->count) + range.location, count * sizeof(CGPoint));
}

// ============================================================================
// Text drawn into a CGPDFContext while a transparency layer is open
// ============================================================================
// 10.9's CGPDFContext records nothing for a glyph run PAINTED while a transparency
// layer is open: the emitted page carries no text-showing operators and the font is
// never embedded. The characters are absent from the document itself rather than only
// from its rasterization, so a printed or saved PDF loses every painted glyph that
// falls under an opacity, mask, blend or clip layer.
//
// Measured on this OS by rasterizing the emitted page and counting ink:
//
//   outlined text, fill / stroke / fill+stroke   plain 1516 / 724 / 2016   layer 0 / 0 / 0
//   color glyphs (Apple Color Emoji)             plain 1408                layer 1408
//   a plain CGImage                              plain 2304                layer 2304
//   text clip, then fill the whole page          plain  758                layer  758
//
// So the defect is confined to PAINTING outlined glyphs. Core Text emits color glyphs
// as images, and images -- like paths -- are recorded correctly, so a color run is
// handed to the system implementation untouched; converting it to outlines would erase
// emoji that print correctly today, because CTFontCreatePathForGlyph returns NULL for
// them. Text clipping also works inside a layer, so clip modes keep the system
// implementation for the clip itself.
//
// Splitting one run across several CTFontDrawGlyphs calls is safe ONLY for the pure
// painting modes. CG intersects the text clip once per CALL, not per glyph: two
// clip-mode calls leave an EMPTY clip where a single call clipping the same two glyphs
// yields their union (measured). Clip-mode runs are therefore never split.
//
// 10.9 offers no way to ask a context whether a layer is open
// (CGContextGetTransparencyLayerDepth and CGContextIsInTransparencyLayer are both
// absent from CoreGraphics here), so the CGContext{Begin,End}TransparencyLayer
// replacements in CoreGraphics.c carry the count (wk_helpers.h).

WK_SYSTEM_FN("CoreGraphics", int, CGContextGetType, (CGContextRef));
WK_SYSTEM_FN("CoreGraphics", CGTextDrawingMode, CGContextGetTextDrawingMode, (CGContextRef));

// Defined after the CTFontDrawGlyphs replacement below, because it re-issues color
// runs through that entry point's original implementation.
static void wk_drawGlyphsInPDFTransparencyLayer(CGContextRef context, CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count);
static void wk_drawGlyphRun(CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count, CGContextRef context);

WK_SYSTEM_FN("CoreGraphics", CGColorRef, CGContextGetFillColorAsColor, (CGContextRef));

typedef enum { WK_GLYPH_OUTLINE, WK_GLYPH_SBIX, WK_GLYPH_COLR } wk_glyph_kind;

// What one draw or measure needs of a colour font: its tables, the palette it was realized with, and
// the glyph count every layer glyph is bounded by.
typedef struct {
    CTFontRef font;
    bool sbix;
    bool colr;
    wk_colr_tables tables;
    uint32_t glyphCount;
    uint16_t palette;
    CFDictionaryRef overrides;
    CGFloat pointSize;
} wk_color_font;

static bool wk_colorFontOpen(CTFontRef font, wk_color_font *out)
{
    if (!font)
        return false;
    memset(out, 0, sizeof(*out));
    out->font = font;
    out->sbix = wk_sbixFont(font);
    CFDataRef colr = wk_fontTable(font, wk_colrTableKey(), kCTFontTableCOLR);
    if (colr) {
        CFDataRef cpal = wk_fontTable(font, wk_cpalTableKey(), kCTFontTableCPAL);
        out->colr = colr != NULL;
        out->tables.colr = colr ? CFDataGetBytePtr(colr) : NULL;
        out->tables.colrLength = colr ? (size_t)CFDataGetLength(colr) : 0;
        out->tables.cpal = cpal ? CFDataGetBytePtr(cpal) : NULL;
        out->tables.cpalLength = cpal ? (size_t)CFDataGetLength(cpal) : 0;
        out->glyphCount = (uint32_t)CTFontGetGlyphCount(font);
        int64_t requested = 0;
        CFNumberRef palette = (CFNumberRef)objc_getAssociatedObject((id)(void *)font, wk_paletteKey());
        if (palette)
            CFNumberGetValue(palette, kCFNumberSInt64Type, &requested);
        out->palette = wk_cpalResolvePalette(&out->tables, requested);
        out->overrides = (CFDictionaryRef)objc_getAssociatedObject((id)(void *)font, wk_paletteColorsKey());
    }
    if (!out->sbix && !out->colr)
        return false;
    out->pointSize = CTFontGetSize(font);
    return true;
}

static bool wk_sbixGlyph(const wk_color_font *f, CGGlyph glyph)
{
    if (!f->sbix)
        return false;
    pthread_mutex_lock(&wkSbixLock);
    bool bitmap = wk_sbixBitmap(f->font, glyph, f->pointSize, NULL, NULL);
    pthread_mutex_unlock(&wkSbixLock);
    return bitmap;
}

// A COLR layer never names a glyph this OS would draw from its sbix strike, which decodes in ImageIO.
static bool wk_colrLayerExcluded(void *context, uint16_t glyph)
{
    return wk_sbixGlyph((const wk_color_font *)context, glyph);
}

static size_t wk_colrGlyphLayers(const wk_color_font *f, CGGlyph glyph, wk_colr_layer *layers)
{
    if (!f->colr || !wk_colrHasBaseGlyph(&f->tables, glyph))
        return 0;
    return wk_colrLayers(&f->tables, glyph, f->glyphCount, f->palette, wk_colrLayerExcluded, (void *)f, layers, WK_COLR_MAX_LAYERS);
}

static wk_glyph_kind wk_glyphKind(const wk_color_font *f, CGGlyph glyph)
{
    if (wk_sbixGlyph(f, glyph))
        return WK_GLYPH_SBIX;
    wk_colr_layer layers[WK_COLR_MAX_LAYERS];
    return wk_colrGlyphLayers(f, glyph, layers) ? WK_GLYPH_COLR : WK_GLYPH_OUTLINE;
}

static size_t wk_colorRunGroup(const wk_color_font *f, const CGGlyph *glyphs, size_t count, size_t from, wk_glyph_kind *outKind)
{
    wk_glyph_kind kind = wk_glyphKind(f, glyphs[from]);
    size_t next = from + 1;
    while (next < count && wk_glyphKind(f, glyphs[next]) == kind)
        ++next;
    *outKind = kind;
    return next;
}

static CGColorRef wk_copyLayerColor(const wk_color_font *f, const wk_colr_layer *layer, CGColorRef foreground, CGColorSpaceRef sRGB)
{
    if (layer->paletteEntry == WK_COLR_FOREGROUND)
        return foreground ? CGColorRetain(foreground) : NULL;
    if (f->overrides) {
        int64_t entry = layer->paletteEntry;
        CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &entry);
        CFTypeRef override = key ? CFDictionaryGetValue(f->overrides, key) : NULL;
        if (key)
            CFRelease(key);
        if (override && CFGetTypeID(override) == CGColorGetTypeID())
            return CGColorRetain((CGColorRef)override);
    }
    CGFloat components[4] = { layer->red / 255.0, layer->green / 255.0, layer->blue / 255.0, layer->alpha / 255.0 };
    return sRGB ? CGColorCreate(sRGB, components) : NULL;
}

// COLR layers composite as one group, applying context alpha, blend mode and shadow once.
// CTFontCreatePathForGlyph applies the font matrix to the outline; its pen needs the same transform.
static CGAffineTransform wk_glyphPathMatrix(CTFontRef font, CGPoint position, CGAffineTransform textMatrix)
{
    position = CGPointApplyAffineTransform(position, CTFontGetMatrix(font));
    return CGAffineTransformConcat(CGAffineTransformMakeTranslation(position.x, position.y), textMatrix);
}

static void wk_drawColrRun(const wk_color_font *f, const CGGlyph *glyphs, const CGPoint *positions, size_t count, CGContextRef context)
{
    wk_colr_layer *layers = (wk_colr_layer *)malloc(WK_COLR_MAX_LAYERS * sizeof(*layers));
    if (!layers)
        return;
    CGColorRef foreground = WK_SYSTEM(CGContextGetFillColorAsColor) ? WK_SYSTEM(CGContextGetFillColorAsColor)(context) : NULL;
    if (foreground)
        CGColorRetain(foreground);
    CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

    CGContextSaveGState(context);
    CGContextBeginTransparencyLayer(context, NULL);
    CGAffineTransform textMatrix = CGContextGetTextMatrix(context);
    for (size_t i = 0; i < count; ++i) {
        size_t layerCount = wk_colrGlyphLayers(f, glyphs[i], layers);
        for (size_t j = 0; j < layerCount; ++j) {
            CGColorRef color = wk_copyLayerColor(f, &layers[j], foreground, sRGB);
            if (color) {
                CGContextSetFillColorWithColor(context, color);
                CGColorRelease(color);
            }
            CGAffineTransform matrix = wk_glyphPathMatrix(f->font, positions[i], textMatrix);
            CGPathRef path = CTFontCreatePathForGlyph(f->font, layers[j].glyph, &matrix);
            if (path) {
                CGContextBeginPath(context);
                CGContextAddPath(context, path);
                CGContextFillPath(context);
                CGPathRelease(path);
            }
        }
    }
    CGContextEndTransparencyLayer(context);
    CGContextRestoreGState(context);

    if (sRGB)
        CGColorSpaceRelease(sRGB);
    if (foreground)
        CGColorRelease(foreground);
    free(layers);
}

static CGRect wk_glyphPathBounds(CTFontRef font, CGGlyph glyph)
{
    CGPathRef path = CTFontCreatePathForGlyph(font, glyph, NULL);
    CGRect rect = path ? CGPathGetPathBoundingBox(path) : CGRectZero;
    if (path)
        CFRelease(path);
    return rect;
}

// A COLR glyph occupies the union of its layer glyphs.
static CGRect wk_colrGlyphBounds(const wk_color_font *f, CGGlyph glyph)
{
    wk_colr_layer layers[WK_COLR_MAX_LAYERS];
    size_t layerCount = wk_colrGlyphLayers(f, glyph, layers);
    CGRect united = CGRectNull;
    for (size_t j = 0; j < layerCount; ++j) {
        CGRect rect = wk_glyphPathBounds(f->font, layers[j].glyph);
        if (!CGRectIsNull(rect) && !CGRectIsInfinite(rect) && !CGRectIsEmpty(rect))
            united = CGRectIsNull(united) ? rect : CGRectUnion(united, rect);
    }
    return CGRectIsNull(united) ? CGRectZero : united;
}

WK_POLYFILL_REPLACES("CoreText", void, CTFontDrawGlyphs, (CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count, CGContextRef context))
{
    // A font with neither an sbix nor a COLR table has no glyph this layer draws, so the whole run goes to
    // CoreText. Past this point it may. A glyph carrying an sbix record is never handed to the original:
    // this OS decodes an sbix strike in ImageIO, and a strike's bytes are a downloadable font's bytes. A
    // COLR glyph is painted from its layers, which this OS's CoreText does not read.
    wk_color_font f;
    if (!glyphs || !positions || !context || !count || !wk_colorFontOpen(font, &f)) {
        wk_drawGlyphRun(font, glyphs, positions, count, context);
        return;
    }

    // A colour glyph contributes nothing to a text clip on this OS, and CG intersects the clip once per
    // CALL rather than once per glyph, so a clipping run reaches CoreText as ONE call carrying the
    // outlined glyphs alone. Measured on this OS with kCGTextClip and a full-page fill afterwards: an
    // outlined glyph clips to its own shape, a run of colour glyphs alone leaves an EMPTY clip, and a
    // call carrying no glyphs at all leaves the clip untouched -- so a run with nothing to outline
    // intersects the clip with an empty rectangle, which is the same outcome. The colour glyphs are
    // painted before that call installs the clip.
    CGTextDrawingMode mode = WK_SYSTEM(CGContextGetTextDrawingMode) ? WK_SYSTEM(CGContextGetTextDrawingMode)(context) : kCGTextFill;

    // kCGTextInvisible paints nothing at all. The outlined glyphs still reach CoreText, which paints
    // nothing for them either, so whatever a call carries with it is unchanged; splitting the run is
    // free here because no clip is being intersected.
    if (mode == kCGTextInvisible) {
        size_t i = 0;
        while (i < count) {
            wk_glyph_kind kind = WK_GLYPH_OUTLINE;
            size_t next = wk_colorRunGroup(&f, glyphs, count, i, &kind);
            if (kind == WK_GLYPH_OUTLINE)
                wk_drawGlyphRun(font, &glyphs[i], &positions[i], next - i, context);
            i = next;
        }
        return;
    }

    if (mode >= kCGTextFillClip) {
        // A run this layer draws none of goes to CoreText whole, which is also the only shape that
        // needs no gathering.
        bool anyColor = false;
        for (size_t i = 0; i < count && !anyColor; ) {
            wk_glyph_kind kind = WK_GLYPH_OUTLINE;
            i = wk_colorRunGroup(&f, glyphs, count, i, &kind);
            anyColor = kind != WK_GLYPH_OUTLINE;
        }
        if (!anyColor) {
            wk_drawGlyphRun(font, glyphs, positions, count, context);
            return;
        }

        // One block for both arrays, positions first so the glyphs after them stay aligned. Without
        // it the outlined glyphs cannot be gathered into the single call the clip needs, and the run
        // clips to nothing -- which is what a run of colour glyphs alone already does.
        CGPoint *outlinedPositions = (CGPoint *)malloc(count * (sizeof(CGPoint) + sizeof(CGGlyph)));
        CGGlyph *outlined = outlinedPositions ? (CGGlyph *)(void *)(outlinedPositions + count) : NULL;
        size_t outlinedCount = 0;
        size_t i = 0;
        while (i < count) {
            wk_glyph_kind kind = WK_GLYPH_OUTLINE;
            size_t next = wk_colorRunGroup(&f, glyphs, count, i, &kind);
            if (kind == WK_GLYPH_OUTLINE) {
                for (size_t j = i; outlined && j < next; ++j) {
                    outlinedPositions[outlinedCount] = positions[j];
                    outlined[outlinedCount] = glyphs[j];
                    ++outlinedCount;
                }
            } else if (mode != kCGTextClip) {
                // kCGTextClip establishes a clip and paints no ink; the other clip modes fill or stroke
                // as well, and a colour glyph's own colours are what their paint looks like.
                if (kind == WK_GLYPH_COLR)
                    wk_drawColrRun(&f, &glyphs[i], &positions[i], next - i, context);
                else {
                    for (size_t j = i; j < next; ++j)
                        wk_drawSbixGlyph(font, glyphs[j], positions[j], context);
                }
            }
            i = next;
        }
        if (outlinedCount)
            wk_drawGlyphRun(font, outlined, outlinedPositions, outlinedCount, context);
        else
            CGContextClipToRect(context, CGRectZero);
        free(outlinedPositions);
        return;
    }

    // A painting run keeps its order, so glyphs composite as one CoreText call would paint them.
    size_t i = 0;
    while (i < count) {
        wk_glyph_kind kind = WK_GLYPH_OUTLINE;
        size_t next = wk_colorRunGroup(&f, glyphs, count, i, &kind);
        if (kind == WK_GLYPH_SBIX) {
            for (size_t j = i; j < next; ++j)
                wk_drawSbixGlyph(font, glyphs[j], positions[j], context);
        } else if (kind == WK_GLYPH_COLR)
            wk_drawColrRun(&f, &glyphs[i], &positions[i], next - i, context);
        else
            wk_drawGlyphRun(font, &glyphs[i], &positions[i], next - i, context);
        i = next;
    }
}

// A glyph ID at or past the font's glyph count has no outline, and CTFontCreatePathForGlyph answers
// NULL for it -- modern CoreText's answer, and this OS's own for an outline font. This OS's colour-bitmap
// lookup indexes a font's sbix strike offsets with the ID unbounded by that count, so the answer is
// given here before the lookup runs. WebCore measures and draws deletedGlyph (0xFFFF) through it.
WK_POLYFILL_REPLACES("CoreText", CGPathRef, CTFontCreatePathForGlyph,
                     (CTFontRef font, CGGlyph glyph, const CGAffineTransform *matrix))
{
    if (!WK_ORIGINAL(CTFontCreatePathForGlyph))
        return NULL;
    if (font && glyph >= CTFontGetGlyphCount(font))
        return NULL;
    return WK_ORIGINAL(CTFontCreatePathForGlyph)(font, glyph, matrix);
}

// This OS reports every glyph of a font that carries an sbix table 0.075 em below where it draws it,
// which is what layout and ink overflow measure, so the rectangles are built here instead. A colour
// bitmap is measured by the rectangle it is painted in, above; every other glyph by the bounds of the
// path CTFontCreatePathForGlyph returns, which this OS places exactly where CTFontDrawGlyphs paints it
// (CoreText hands out no path for a glyph that has a strike, which is why the strike answers first).
// A vertical rectangle is the horizontal one moved to the vertical origin and rotated left, the
// construction this OS's own answer follows for a font with no sbix table -- measured to the hundredth
// of a point on Ahem, Arial Unicode and an sbix-stripped copy of Ahem-sbix.
static CGRect wk_rotateRectLeft(CGRect rect)
{
    return CGRectMake(-CGRectGetMaxY(rect), CGRectGetMinX(rect), rect.size.height, rect.size.width);
}

// Control characters. CoreText maps U+0000, and every other control character WebKit leaves to it, to one
// glyph -- the font's zero-width .null -- and WebKit reads that glyph from glyph page 0 as the font's zero
// width space glyph (Font::platformGlyphInit), whose advance widthForGlyph zeroes. 10.9 answers U+0000 with
// .null only when asked for it alone or in a short run: at the head of the 256-character page WebKit asks
// for, it answers glyph 0 (measured: Times, Helvetica and Lucida Grande give .null, glyph 1, alone and
// glyph 0 as the first of 256). And it maps U+000D to the font's nonmarkingreturn or space glyph, which
// carries a space's advance (Times 4.00 at 16pt), so a carriage return WebKit sets as text is a space wide.
// Tab and line feed keep 10.9's space-wide glyph: WebKit gives both the space or tab advance itself.
static bool wk_isControlCharacterMappedToNull(UniChar character)
{
    return (character < 0x20 && character != 0x09 && character != 0x0A) || (character >= 0x7F && character < 0xA0);
}

// The glyph `font` answers for U+0000 asked for alone.
static CGGlyph wk_nullGlyph(CTFontRef font, bool (*getGlyphs)(CTFontRef, const UniChar[], CGGlyph[], CFIndex))
{
    const UniChar null = 0;
    CGGlyph glyph = 0;
    getGlyphs(font, &null, &glyph, 1);
    return glyph;
}

// Maps each control character in `characters` to the U+0000 glyph, and answers whether every character
// has a glyph, a trailing surrogate counting as mapped with its lead.
static bool wk_mapControlCharactersToNull(CTFontRef font, const UniChar characters[], CGGlyph glyphs[], CFIndex count, bool mapped,
    bool (*getGlyphs)(CTFontRef, const UniChar[], CGGlyph[], CFIndex))
{
    if (!font || !characters || !glyphs || count <= 0)
        return mapped;
    bool hasControl = false;
    for (CFIndex i = 0; i < count && !hasControl; ++i)
        hasControl = wk_isControlCharacterMappedToNull(characters[i]);
    if (!hasControl)
        return mapped;
    const CGGlyph null = wk_nullGlyph(font, getGlyphs);
    bool allMapped = true;
    for (CFIndex i = 0; i < count; ++i) {
        if (wk_isControlCharacterMappedToNull(characters[i]))
            glyphs[i] = null;
        bool trailing = i && characters[i] >= 0xDC00 && characters[i] <= 0xDFFF && characters[i - 1] >= 0xD800 && characters[i - 1] <= 0xDBFF;
        allMapped = allMapped && (glyphs[i] || (trailing && glyphs[i - 1]));
    }
    return allMapped;
}

WK_POLYFILL_REPLACES("CoreText", bool, CTFontGetGlyphsForCharacters,
                     (CTFontRef font, const UniChar characters[], CGGlyph glyphs[], CFIndex count))
{
    if (!WK_ORIGINAL(CTFontGetGlyphsForCharacters))
        return false;
    bool mapped = WK_ORIGINAL(CTFontGetGlyphsForCharacters)(font, characters, glyphs, count);
    return wk_mapControlCharactersToNull(font, characters, glyphs, count, mapped, WK_ORIGINAL(CTFontGetGlyphsForCharacters));
}

WK_POLYFILL_REPLACES("CoreText", bool, CTFontGetVerticalGlyphsForCharacters,
                     (CTFontRef font, const UniChar characters[], CGGlyph glyphs[], CFIndex count))
{
    if (!WK_ORIGINAL(CTFontGetVerticalGlyphsForCharacters))
        return false;
    bool mapped = WK_ORIGINAL(CTFontGetVerticalGlyphsForCharacters)(font, characters, glyphs, count);
    return wk_mapControlCharactersToNull(font, characters, glyphs, count, mapped, WK_ORIGINAL(CTFontGetVerticalGlyphsForCharacters));
}

// A font with neither vmtx nor VORG has no vertical origin of its own, and hangs every glyph set upright
// from its ascent, as the fonts that do carry vertical metrics here report theirs: Hiragino Kaku Gothic
// ProN answers -88 at 100pt for every glyph, its ascent. 10.9 instead derives the height of such a font's
// origin from each glyph's bounding box -- Ahem at 100pt answers -84.9 for a full-height glyph and -64.9
// for a shorter one, Times -49.85 for 'x' and -71.14 for 'T' -- so an upright glyph moves off the line its
// horizontal setting sits on. The width, half the advance, is left as 10.9 computes it.
static const void *wk_verticalOriginTablesKey(void) { return sel_registerName("wk_verticalOriginTables"); }

// Whether the font carries vmtx or VORG, kept on the CTFont as kCFBooleanTrue or kCFBooleanFalse. The
// association is set once and never replaced, so a present value is read without a lock.
static bool wk_fontHasVerticalOrigins(CTFontRef font)
{
    CFBooleanRef cached = (CFBooleanRef)objc_getAssociatedObject((id)(void *)font, wk_verticalOriginTablesKey());
    if (!cached) {
        objc_sync_enter((id)(void *)font);
        cached = (CFBooleanRef)objc_getAssociatedObject((id)(void *)font, wk_verticalOriginTablesKey());
        if (!cached) {
            CFDataRef vmtx = CTFontCopyTable(font, kCTFontTableVmtx, kCTFontTableOptionNoOptions);
            CFDataRef vorg = vmtx ? NULL : CTFontCopyTable(font, kCTFontTableVORG, kCTFontTableOptionNoOptions);
            cached = (vmtx || vorg) ? kCFBooleanTrue : kCFBooleanFalse;
            if (vmtx)
                CFRelease(vmtx);
            if (vorg)
                CFRelease(vorg);
            objc_setAssociatedObject((id)(void *)font, wk_verticalOriginTablesKey(), (id)(void *)cached, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_sync_exit((id)(void *)font);
    }
    return cached == kCFBooleanTrue;
}

WK_POLYFILL_REPLACES("CoreText", void, CTFontGetVerticalTranslationsForGlyphs,
                     (CTFontRef font, const CGGlyph glyphs[], CGSize translations[], CFIndex count))
{
    if (!WK_ORIGINAL(CTFontGetVerticalTranslationsForGlyphs))
        return;
    WK_ORIGINAL(CTFontGetVerticalTranslationsForGlyphs)(font, glyphs, translations, count);
    if (!font || !translations || count <= 0 || wk_fontHasVerticalOrigins(font))
        return;
    CGFloat height = -CTFontGetAscent(font);
    for (CFIndex i = 0; i < count; ++i)
        translations[i].height = height;
}

WK_POLYFILL_REPLACES("CoreText", CGRect, CTFontGetBoundingRectsForGlyphs,
                     (CTFontRef font, CTFontOrientation orientation, const CGGlyph *glyphs, CGRect *boundingRects, CFIndex count))
{
    if (!WK_ORIGINAL(CTFontGetBoundingRectsForGlyphs))
        return CGRectNull;
    wk_color_font f;
    if (!font || !glyphs || count <= 0 || !wk_colorFontOpen(font, &f))
        return WK_ORIGINAL(CTFontGetBoundingRectsForGlyphs)(font, orientation, glyphs, boundingRects, count);

    bool vertical = orientation == kCTFontOrientationVertical
        || (orientation == kCTFontOrientationDefault && (CTFontGetSymbolicTraits(font) & kCTFontTraitVertical));
    const CFIndex glyphCount = CTFontGetGlyphCount(font);

    CGRect united = CGRectNull;
    for (CFIndex i = 0; i < count; ++i) {
        CGRect rect = CGRectZero;
        // A glyph ID at or past the glyph count occupies nothing, and never reaches this OS's colour-bitmap
        // lookup, which reads it unbounded by that count.
        if ((CFIndex)glyphs[i] >= glyphCount) {
            if (boundingRects)
                boundingRects[i] = CGRectZero;
            continue;
        }
        // Rectangles built here are horizontal glyph space, moved for a vertical run below; CoreText's
        // own answer for an outline glyph of a font with no sbix table is already placed.
        bool built = true;
        wk_glyph_kind kind = wk_glyphKind(&f, glyphs[i]);
        if (kind == WK_GLYPH_SBIX) {
            pthread_mutex_lock(&wkSbixLock);
            wk_sbixBitmap(font, glyphs[i], CTFontGetSize(font), NULL, &rect);
            pthread_mutex_unlock(&wkSbixLock);
            rect = CGRectApplyAffineTransform(rect, CTFontGetMatrix(font));
        } else if (kind == WK_GLYPH_COLR)
            rect = wk_colrGlyphBounds(&f, glyphs[i]);
        else if (f.sbix)
            rect = wk_glyphPathBounds(font, glyphs[i]);
        else {
            WK_ORIGINAL(CTFontGetBoundingRectsForGlyphs)(font, orientation, &glyphs[i], &rect, 1);
            built = false;
        }
        // A glyph that occupies nothing has no rectangle to move, and leaves the union alone.
        if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect))
            rect = CGRectZero;
        else if (vertical && built) {
            CGSize translation = CGSizeZero;
            CTFontGetVerticalTranslationsForGlyphs(font, &glyphs[i], &translation, 1);
            rect = wk_rotateRectLeft(CGRectOffset(rect, translation.width, translation.height));
        }
        if (boundingRects)
            boundingRects[i] = rect;
        if (!CGRectIsEmpty(rect))
            united = CGRectIsNull(united) ? rect : CGRectUnion(united, rect);
    }
    return CGRectIsNull(united) ? CGRectZero : united;
}

// A glyph ID at or past the glyph count of a font carrying an sbix table advances nothing, as it does in
// modern CoreText; this OS's colour-bitmap lookup reads such an ID unbounded by that count, so it is never
// asked for one.
WK_POLYFILL_REPLACES("CoreText", double, CTFontGetAdvancesForGlyphs,
                     (CTFontRef font, CTFontOrientation orientation, const CGGlyph *glyphs, CGSize *advances, CFIndex count))
{
    if (!WK_ORIGINAL(CTFontGetAdvancesForGlyphs))
        return 0;
    const CFIndex glyphCount = font && glyphs && count > 0 ? CTFontGetGlyphCount(font) : 0;
    CFIndex outOfRange = 0;
    for (CFIndex i = 0; glyphCount && i < count; ++i)
        outOfRange += (CFIndex)glyphs[i] >= glyphCount;
    if (!outOfRange || !wk_sbixFont(font))
        return WK_ORIGINAL(CTFontGetAdvancesForGlyphs)(font, orientation, glyphs, advances, count);

    double total = 0;
    CFIndex i = 0;
    while (i < count) {
        if ((CFIndex)glyphs[i] >= glyphCount) {
            if (advances)
                advances[i] = CGSizeZero;
            ++i;
            continue;
        }
        CFIndex next = i + 1;
        while (next < count && (CFIndex)glyphs[next] < glyphCount)
            ++next;
        total += WK_ORIGINAL(CTFontGetAdvancesForGlyphs)(font, orientation, &glyphs[i], advances ? &advances[i] : NULL, next - i);
        i = next;
    }
    return total;
}

// One run, through whichever implementation the context calls for. A glyph ID at or past the font's glyph
// count draws nothing, as it does in modern CoreText; this OS's colour-bitmap lookup reads a font's sbix
// strike with the ID unbounded by that count, so such a glyph is left out of the run before it is drawn.
static void wk_drawGlyphRun(CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count, CGContextRef context)
{
    if (font && glyphs && positions && count) {
        const CFIndex glyphCount = CTFontGetGlyphCount(font);
        size_t kept = 0;
        for (size_t i = 0; i < count; ++i)
            kept += (CFIndex)glyphs[i] < glyphCount;
        if (kept < count) {
            if (!kept)
                return;
            CGGlyph inlineGlyphs[128];
            CGPoint inlinePositions[128];
            CGGlyph *keptGlyphs = kept <= 128 ? inlineGlyphs : (CGGlyph *)malloc(kept * sizeof(CGGlyph));
            CGPoint *keptPositions = kept <= 128 ? inlinePositions : (CGPoint *)malloc(kept * sizeof(CGPoint));
            if (keptGlyphs && keptPositions) {
                size_t k = 0;
                for (size_t i = 0; i < count; ++i) {
                    if ((CFIndex)glyphs[i] >= glyphCount)
                        continue;
                    keptGlyphs[k] = glyphs[i];
                    keptPositions[k] = positions[i];
                    ++k;
                }
                wk_drawGlyphRun(font, keptGlyphs, keptPositions, kept, context);
            }
            if (keptGlyphs != inlineGlyphs)
                free(keptGlyphs);
            if (keptPositions != inlinePositions)
                free(keptPositions);
            return;
        }
    }
    if (font && glyphs && positions && count && context && wk_isInsideTransparencyLayer(context)
        && WK_SYSTEM(CGContextGetType) && WK_SYSTEM(CGContextGetType)(context) == WK_CG_CONTEXT_TYPE_PDF)
        wk_drawGlyphsInPDFTransparencyLayer(context, font, glyphs, positions, count);
    else if (WK_ORIGINAL(CTFontDrawGlyphs))
        WK_ORIGINAL(CTFontDrawGlyphs)(font, glyphs, positions, count, context);
}

static void wk_paintOutlines(CGContextRef context, CGPathRef path, bool fills, bool strokes)
{
    if (!fills && !strokes)
        return;
    CGContextBeginPath(context);
    CGContextAddPath(context, path);
    CGContextDrawPath(context, fills && strokes ? kCGPathFillStroke : (fills ? kCGPathFill : kCGPathStroke));
}

static void wk_drawGlyphsInPDFTransparencyLayer(CGContextRef context, CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count)
{
    CGTextDrawingMode mode = kCGTextFill;
    if (WK_SYSTEM(CGContextGetTextDrawingMode))
        mode = WK_SYSTEM(CGContextGetTextDrawingMode)(context);

    // Invisible paints nothing, and clip-only establishes a clip the layer already
    // records correctly. Neither needs anything from this code.
    if (mode == kCGTextInvisible || mode == kCGTextClip) {
        if (WK_ORIGINAL(CTFontDrawGlyphs))
            WK_ORIGINAL(CTFontDrawGlyphs)(font, glyphs, positions, count, context);
        return;
    }

    bool fills = mode == kCGTextFill || mode == kCGTextFillStroke || mode == kCGTextFillClip || mode == kCGTextFillStrokeClip;
    bool strokes = mode == kCGTextStroke || mode == kCGTextFillStroke || mode == kCGTextStrokeClip || mode == kCGTextFillStrokeClip;
    CGAffineTransform textMatrix = CGContextGetTextMatrix(context);

    if (mode >= kCGTextFillClip) {
        // CG paints the run and THEN unions the whole call into the clip. Paint every
        // outlined glyph as one path first, then hand the UNSPLIT run to the system
        // implementation: its painting is what the layer drops, but its clip -- and
        // its handling of color glyphs -- is correct.
        CGMutablePathRef path = CGPathCreateMutable();
        for (size_t i = 0; i < count; ++i) {
            CGAffineTransform matrix = wk_glyphPathMatrix(font, positions[i], textMatrix);
            CGPathRef glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], &matrix);
            if (!glyphPath)
                continue;
            CGPathAddPath(path, NULL, glyphPath);
            CFRelease(glyphPath);
        }
        wk_paintOutlines(context, path, fills, strokes);
        CGPathRelease(path);
        if (WK_ORIGINAL(CTFontDrawGlyphs))
            WK_ORIGINAL(CTFontDrawGlyphs)(font, glyphs, positions, count, context);
        return;
    }

    // A pure painting mode. Walk the run in index order and process maximal spans of
    // one kind, so glyphs composite in the order CTFontDrawGlyphs would paint them and
    // nothing is allocated per run -- an allocation that could fail is an opportunity
    // to silently drop glyphs.
    size_t i = 0;
    while (i < count) {
        CGAffineTransform matrix = wk_glyphPathMatrix(font, positions[i], textMatrix);
        CGPathRef glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], &matrix);
        size_t next = i + 1;
        if (glyphPath) {
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddPath(path, NULL, glyphPath);
            CFRelease(glyphPath);
            for (; next < count; ++next) {
                CGAffineTransform nextMatrix = wk_glyphPathMatrix(font, positions[next], textMatrix);
                CGPathRef nextPath = CTFontCreatePathForGlyph(font, glyphs[next], &nextMatrix);
                if (!nextPath)
                    break;
                CGPathAddPath(path, NULL, nextPath);
                CFRelease(nextPath);
            }
            wk_paintOutlines(context, path, fills, strokes);
            CGPathRelease(path);
        } else {
            for (; next < count; ++next) {
                CGAffineTransform nextMatrix = wk_glyphPathMatrix(font, positions[next], textMatrix);
                CGPathRef nextPath = CTFontCreatePathForGlyph(font, glyphs[next], &nextMatrix);
                if (nextPath) {
                    CFRelease(nextPath);
                    break;
                }
            }
            if (WK_ORIGINAL(CTFontDrawGlyphs))
                WK_ORIGINAL(CTFontDrawGlyphs)(font, &glyphs[i], &positions[i], next - i, context);
        }
        i = next;
    }
}

// ---------------------------------------------------------------------------------------------------
// Font fallback by grapheme cluster. 10.9's typesetter looks for a fallback font one composed-character
// cluster at a time, and those clusters leave emoji ZWJ, modifier and tag sequences in pieces; a piece the
// current font covers stays in it. Times covers ZERO WIDTH JOINER, so a family emoji set in Times comes out
// as three emoji with the joiners in Times, and the font's ligature never forms. The provider CoreText reads
// is wrapped so that a UAX #29 cluster 10.9 would split, and the current font does not cover, arrives in one
// font: the first of the font's cascade list that covers the whole cluster, which is also how 10.9 picks a
// font for a cluster it keeps whole. CoreText shapes each provided block separately, so the block carrying
// that font also takes the neighbouring uncovered clusters the same font is picked for, and everything
// else reaches CoreText in the blocks the caller provided.
// ---------------------------------------------------------------------------------------------------

typedef const UniChar *(*CTUniCharProviderCallback)(CFIndex stringIndex, CFIndex *charCount, CFDictionaryRef *attributes, void *refCon);
typedef void (*CTUniCharDisposeCallback)(const UniChar *chars, void *refCon);

// The cascade list of the last font a thread looked a cluster font up for, its fonts created on first use.
typedef struct {
    CTFontRef font;
    CFStringRef language;
    CFArrayRef descriptors;
    CFIndex count;
    CFTypeRef *fonts; // NULL until created; kCFNull for LastResort or a descriptor that yields no font
} wk_cascadeFonts;

static pthread_key_t wk_cascadeFontsKey;
static pthread_once_t wk_cascadeFontsKeyOnce = PTHREAD_ONCE_INIT;

static void wk_cascadeFontsClear(wk_cascadeFonts *cascade)
{
    for (CFIndex i = 0; i < cascade->count; ++i) {
        if (cascade->fonts[i])
            CFRelease(cascade->fonts[i]);
    }
    free(cascade->fonts);
    if (cascade->descriptors)
        CFRelease(cascade->descriptors);
    if (cascade->language)
        CFRelease(cascade->language);
    if (cascade->font)
        CFRelease(cascade->font);
    memset(cascade, 0, sizeof(*cascade));
}

static void wk_cascadeFontsDestroy(void *cascade)
{
    wk_cascadeFontsClear((wk_cascadeFonts *)cascade);
    free(cascade);
}

static void wk_cascadeFontsKeyCreate(void)
{
    if (pthread_key_create(&wk_cascadeFontsKey, wk_cascadeFontsDestroy))
        abort();
}

static wk_cascadeFonts *wk_cascadeFontsFor(CTFontRef font, CFStringRef language)
{
    pthread_once(&wk_cascadeFontsKeyOnce, wk_cascadeFontsKeyCreate);
    wk_cascadeFonts *cascade = (wk_cascadeFonts *)pthread_getspecific(wk_cascadeFontsKey);
    if (!cascade) {
        cascade = (wk_cascadeFonts *)calloc(1, sizeof(*cascade));
        if (!cascade)
            abort();
        pthread_setspecific(wk_cascadeFontsKey, cascade);
    }
    if (cascade->font && CFEqual(cascade->font, font)
        && (cascade->language == language || (cascade->language && language && CFEqual(cascade->language, language))))
        return cascade;

    wk_cascadeFontsClear(cascade);
    cascade->font = (CTFontRef)CFRetain(font);
    cascade->language = language ? (CFStringRef)CFRetain(language) : NULL;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
    CFTypeRef cascadeList = descriptor ? CTFontDescriptorCopyAttribute(descriptor, kCTFontCascadeListAttribute) : NULL;
    if (descriptor)
        CFRelease(descriptor);
    if (cascadeList && CFGetTypeID(cascadeList) == CFArrayGetTypeID())
        cascade->descriptors = (CFArrayRef)cascadeList;
    else {
        if (cascadeList)
            CFRelease(cascadeList);
        CFArrayRef languages = language ? CFArrayCreate(kCFAllocatorDefault, (const void **)&language, 1, &kCFTypeArrayCallBacks) : NULL;
        cascade->descriptors = CTFontCopyDefaultCascadeListForLanguages(font, languages);
        if (languages)
            CFRelease(languages);
    }
    cascade->count = cascade->descriptors ? CFArrayGetCount(cascade->descriptors) : 0;
    if (cascade->count) {
        cascade->fonts = (CFTypeRef *)calloc((size_t)cascade->count, sizeof(CFTypeRef));
        if (!cascade->fonts)
            abort();
    }
    return cascade;
}

static CTFontRef wk_cascadeFontAt(wk_cascadeFonts *cascade, CFIndex index)
{
    if (!cascade->fonts[index]) {
        CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(cascade->descriptors, index);
        CTFontRef candidate = CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(cascade->font), NULL);
        CFStringRef name = candidate ? CTFontCopyPostScriptName(candidate) : NULL;
        if (!candidate || (name && CFEqual(name, CFSTR("LastResort")))) {
            cascade->fonts[index] = kCFNull;
            if (candidate)
                CFRelease(candidate);
        } else
            cascade->fonts[index] = wk_inheritFontRequest(candidate, cascade->font);
        if (name)
            CFRelease(name);
    }
    return cascade->fonts[index] == kCFNull ? NULL : (CTFontRef)cascade->fonts[index];
}

enum { WKGlyphLookupLength = 128 };

// Which code points of a block a font has glyphs for, looked up a window at a time.
typedef struct {
    CTFontRef font;
    const UniChar *characters;
    CFIndex length;
    CFIndex windowStart;
    CFIndex windowLength;
    bool windowCovered;
    CGGlyph glyphs[WKGlyphLookupLength];
} wk_coverageCursor;

static void wk_coverageCursorInit(wk_coverageCursor *cursor, CTFontRef font, const UniChar *characters, CFIndex length)
{
    cursor->font = font;
    cursor->characters = characters;
    cursor->length = length;
    cursor->windowStart = 0;
    cursor->windowLength = 0;
    cursor->windowCovered = false;
}

static CFIndex wk_codePointLength(const UniChar *characters, CFIndex length, CFIndex position)
{
    return U16_IS_LEAD(characters[position]) && position + 1 < length && U16_IS_TRAIL(characters[position + 1]) ? 2 : 1;
}

// The first code point in [from, limit) the font has no glyph for, or limit.
static CFIndex wk_nextUncoveredCharacter(wk_coverageCursor *cursor, CFIndex from, CFIndex limit)
{
    for (CFIndex position = from; position < limit; ) {
        if (position < cursor->windowStart || position >= cursor->windowStart + cursor->windowLength) {
            CFIndex count = cursor->length - position;
            if (count > WKGlyphLookupLength) {
                count = WKGlyphLookupLength;
                if (U16_IS_LEAD(cursor->characters[position + count - 1]))
                    --count;
            }
            cursor->windowCovered = CTFontGetGlyphsForCharacters(cursor->font, cursor->characters + position, cursor->glyphs, count);
            cursor->windowStart = position;
            cursor->windowLength = count;
        }
        if (cursor->windowCovered) {
            position = cursor->windowStart + cursor->windowLength;
            continue;
        }
        if (!cursor->glyphs[position - cursor->windowStart])
            return position;
        position += wk_codePointLength(cursor->characters, cursor->length, position);
    }
    return limit;
}

static bool wk_fontCoversCluster(CTFontRef font, const UniChar *cluster, CFIndex length)
{
    wk_coverageCursor cursor;
    wk_coverageCursorInit(&cursor, font, cluster, length);
    return wk_nextUncoveredCharacter(&cursor, 0, length) == length;
}

// The first font of the cascade list with a glyph for every code point of the cluster, or NULL.
static CTFontRef wk_cascadeFontCovering(wk_cascadeFonts *cascade, const UniChar *cluster, CFIndex length)
{
    for (CFIndex i = 0; i < cascade->count; ++i) {
        CTFontRef candidate = wk_cascadeFontAt(cascade, i);
        if (candidate && wk_fontCoversCluster(candidate, cluster, length))
            return candidate;
    }
    return NULL;
}

// Whether 10.9's composed-character clusters divide the cluster. scratch is a mutable string over external
// characters, created on first use and repointed at each cluster.
static bool wk_systemSplitsCluster(CFMutableStringRef *scratch, const UniChar *cluster, CFIndex length)
{
    if (wk_codePointLength(cluster, length, 0) == length)
        return false;
    if (!*scratch) {
        *scratch = CFStringCreateMutableWithExternalCharactersNoCopy(kCFAllocatorDefault, NULL, 0, 0, kCFAllocatorNull);
        if (!*scratch)
            abort();
    }
    CFStringSetExternalCharactersNoCopy(*scratch, (UniChar *)cluster, length, length);
    return wk_systemComposedCharacterClusterAtIndex(*scratch, 0).length < length;
}

// ---------------------------------------------------------------------------------------------------
// Logical-order morx subtables. A subtable whose coverage carries the logical-order flag runs over its
// glyphs in logical order in either direction, or reverse logical order with the descending flag. 10.9's
// CoreText predates the flag and runs every subtable in layout order, which right to left is reversed, so
// a subtable written for logical order misses its sequences there: Apple Color Emoji's ligature subtables
// carry the flag, and a skin-tone, keycap or ZWJ sequence set right to left comes out in pieces. 10.9
// applies the descending flag against layout order, so right-to-left text is shaped in an instance of the
// font whose logical-order subtables have the descending flag inverted, which runs them in logical order.
// The instance carries the font's tables with each sbix strike's glyph images left out, which 10.9 shapes
// identically, and only shapes: CTRunGetAttributes answers the attributes the text was provided in.
// ---------------------------------------------------------------------------------------------------

enum {
    WKMorxCoverageDescending = 0x40000000,
    WKMorxCoverageLogicalOrder = 0x10000000,
};

static uint32_t wk_readBigEndian32(const uint8_t *bytes)
{
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

static void wk_writeBigEndian32(uint8_t *bytes, uint32_t value)
{
    bytes[0] = (uint8_t)(value >> 24);
    bytes[1] = (uint8_t)(value >> 16);
    bytes[2] = (uint8_t)(value >> 8);
    bytes[3] = (uint8_t)value;
}

// Whether a morx table has a logical-order subtable. With invert, each such subtable's descending flag is
// inverted in place.
static bool wk_morxLogicalOrderSubtables(uint8_t *morx, CFIndex length, bool invert)
{
    bool found = false;
    if (length < 8)
        return false;
    uint32_t chainCount = wk_readBigEndian32(morx + 4);
    CFIndex chain = 8;
    for (uint32_t c = 0; c < chainCount && chain <= length - 16; ++c) {
        CFIndex chainLength = wk_readBigEndian32(morx + chain + 4);
        if (chainLength < 16 || chainLength > length - chain)
            break;
        CFIndex chainEnd = chain + chainLength;
        CFIndex subtable = chain + 16 + 12 * (CFIndex)wk_readBigEndian32(morx + chain + 8);
        uint32_t subtableCount = wk_readBigEndian32(morx + chain + 12);
        for (uint32_t s = 0; s < subtableCount && subtable <= chainEnd - 12; ++s) {
            CFIndex subtableLength = wk_readBigEndian32(morx + subtable);
            if (subtableLength < 12 || subtableLength > chainEnd - subtable)
                break;
            uint32_t coverage = wk_readBigEndian32(morx + subtable + 4);
            if (coverage & WKMorxCoverageLogicalOrder) {
                found = true;
                if (invert)
                    wk_writeBigEndian32(morx + subtable + 4, coverage ^ WKMorxCoverageDescending);
            }
            subtable += subtableLength;
        }
        chain = chainEnd;
    }
    return found;
}

// sbix with its strikes and no glyph images: every glyph's data range is empty.
static CFDataRef wk_createSbixWithoutImages(CFDataRef sbix, CFIndex glyphCount)
{
    const uint8_t *table = CFDataGetBytePtr(sbix);
    CFIndex length = CFDataGetLength(sbix);
    if (length < 8)
        return (CFDataRef)CFRetain(sbix);
    CFIndex strikeCount = wk_readBigEndian32(table + 4);
    if (strikeCount > (length - 8) / 4)
        return (CFDataRef)CFRetain(sbix);
    CFIndex headerLength = 8 + 4 * strikeCount;
    CFIndex strikeLength = 4 + 4 * (glyphCount + 1);
    CFMutableDataRef result = CFDataCreateMutable(kCFAllocatorDefault, 0);
    if (!result)
        abort();
    CFDataSetLength(result, headerLength + strikeCount * strikeLength);
    uint8_t *bytes = CFDataGetMutableBytePtr(result);
    memcpy(bytes, table, 8);
    for (CFIndex strike = 0; strike < strikeCount; ++strike) {
        CFIndex source = wk_readBigEndian32(table + 8 + 4 * strike);
        CFIndex destination = headerLength + strike * strikeLength;
        wk_writeBigEndian32(bytes + 8 + 4 * strike, (uint32_t)destination);
        if (source <= length - 4)
            memcpy(bytes + destination, table + source, 4);
        for (CFIndex glyph = 0; glyph <= glyphCount; ++glyph)
            wk_writeBigEndian32(bytes + destination + 4 + 4 * glyph, (uint32_t)strikeLength);
    }
    return result;
}

static int wk_compareSfntTableTags(const void *a, const void *b)
{
    uint32_t first = *(const uint32_t *)a;
    uint32_t second = *(const uint32_t *)b;
    return first < second ? -1 : first > second;
}

static void wk_unmapShapingSfnt(void *bytes, void *length)
{
    munmap(bytes, (size_t)length);
}

// A shaping instance carries the installed font's GPOS repair and the RTL morx flags.
static CGFontRef wk_createShapingInstance(CTFontRef font, bool rightToLeft)
{
    CFDataRef morx = rightToLeft ? CTFontCopyTable(font, 'morx', kCTFontTableOptionNoOptions) : NULL;
    bool logicalOrder = morx && wk_morxLogicalOrderSubtables((uint8_t *)CFDataGetBytePtr(morx), CFDataGetLength(morx), false);
    if (morx)
        CFRelease(morx);
    CFTypeRef url = WK_ORIGINAL(CTFontCopyAttribute)(font, kCTFontURLAttribute);
    CFDataRef gpos = url ? CTFontCopyTable(font, kCTFontTableGPOS, kCTFontTableOptionNoOptions) : NULL;
    CFDataRef repairedGPOS = wk_copy_gpos_with_reachable_last_pair_sets(gpos);
    if (gpos)
        CFRelease(gpos);
    if (url)
        CFRelease(url);
    if (!logicalOrder && !repairedGPOS)
        return NULL;

    CFArrayRef tagArray = CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions);
    CFIndex tagCount = tagArray ? CFArrayGetCount(tagArray) : 0;
    uint32_t *tags = (uint32_t *)malloc((size_t)(tagCount + 1) * sizeof(uint32_t));
    CFDataRef *tables = (CFDataRef *)malloc((size_t)(tagCount + 1) * sizeof(CFDataRef));
    if (!tags || !tables)
        abort();
    for (CFIndex i = 0; i < tagCount; ++i)
        tags[i] = (uint32_t)(uintptr_t)CFArrayGetValueAtIndex(tagArray, i);
    if (tagArray)
        CFRelease(tagArray);
    qsort(tags, (size_t)tagCount, sizeof(uint32_t), wk_compareSfntTableTags);

    CFIndex count = 0;
    CFIndex tablesLength = 0;
    bool compactFontFormat = false;
    for (CFIndex i = 0; i < tagCount; ++i) {
        CFDataRef table = tags[i] == 'GPOS' && repairedGPOS ? (CFDataRef)CFRetain(repairedGPOS)
            : CTFontCopyTable(font, tags[i], kCTFontTableOptionNoOptions);
        if (!table)
            continue;
        if (tags[i] == 'sbix') {
            CFDataRef withoutImages = wk_createSbixWithoutImages(table, CTFontGetGlyphCount(font));
            CFRelease(table);
            table = withoutImages;
        }
        if (tags[i] == 'CFF ' || tags[i] == 'CFF2')
            compactFontFormat = true;
        tags[count] = tags[i];
        tables[count] = table;
        tablesLength += (CFDataGetLength(table) + 3) & ~(CFIndex)3;
        ++count;
    }

    CFIndex directoryLength = 12 + 16 * count;
    size_t length = directoryLength + tablesLength;
    // VM storage returns the sfnt pages directly when the reader releases them.
    uint8_t *bytes = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (bytes == MAP_FAILED)
        abort();
    wk_writeBigEndian32(bytes, compactFontFormat ? 'OTTO' : 0x00010000);
    bytes[4] = (uint8_t)(count >> 8);
    bytes[5] = (uint8_t)count;
    CFIndex offset = directoryLength;
    for (CFIndex i = 0; i < count; ++i) {
        CFIndex tableLength = CFDataGetLength(tables[i]);
        memcpy(bytes + offset, CFDataGetBytePtr(tables[i]), (size_t)tableLength);
        if (tags[i] == 'morx' && logicalOrder)
            wk_morxLogicalOrderSubtables(bytes + offset, tableLength, true);
        uint8_t *entry = bytes + 12 + 16 * i;
        wk_writeBigEndian32(entry, tags[i]);
        wk_writeBigEndian32(entry + 8, (uint32_t)offset);
        wk_writeBigEndian32(entry + 12, (uint32_t)tableLength);
        offset += (tableLength + 3) & ~(CFIndex)3;
        CFRelease(tables[i]);
    }
    free(tags);
    free(tables);
    if (repairedGPOS)
        CFRelease(repairedGPOS);

    CFAllocatorContext context = { .info = (void *)length, .deallocate = wk_unmapShapingSfnt };
    CFAllocatorRef allocator = CFAllocatorCreate(kCFAllocatorDefault, &context);
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, bytes, length, allocator);
    CFRelease(allocator);
    if (!data)
        abort();
    CGFontRef instance = wk_createGraphicsFontFromSfnt(data);
    CFRelease(data);
    return instance;
}

static const void *wk_shapingInstanceKey(bool rightToLeft)
{
    return sel_registerName(rightToLeft ? "wk_shapingInstanceRTL" : "wk_shapingInstanceLTR");
}

static const void *wk_isShapingInstanceKey(void) { return sel_registerName("wk_isShapingInstance"); }

static CGFontRef wk_copyShapingInstanceForFont(CTFontRef font, bool rightToLeft)
{
    if (rightToLeft) {
        CFDataRef morx = CTFontCopyTable(font, 'morx', kCTFontTableOptionNoOptions);
        bool logicalOrder = morx && wk_morxLogicalOrderSubtables((uint8_t *)CFDataGetBytePtr(morx), CFDataGetLength(morx), false);
        if (morx)
            CFRelease(morx);
        if (!logicalOrder)
            return wk_copyShapingInstanceForFont(font, false);
    }
    CGFontRef graphicsFont = CTFontCopyGraphicsFont(font, NULL);
    if (!graphicsFont)
        return NULL;
    const void *key = wk_shapingInstanceKey(rightToLeft);
    objc_sync_enter((id)(void *)graphicsFont);
    CFTypeRef instance = (CFTypeRef)objc_getAssociatedObject((id)(void *)graphicsFont, key);
    if (!instance) {
        CGFontRef created = wk_createShapingInstance(font, rightToLeft);
        instance = created ? (CFTypeRef)created : kCFNull;
        if (created)
            objc_setAssociatedObject((id)(void *)created, wk_isShapingInstanceKey(), (id)(void *)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject((id)(void *)graphicsFont, key, (id)(void *)instance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (created)
            CGFontRelease(created);
    }
    CGFontRef result = instance == kCFNull ? NULL : CGFontRetain((CGFontRef)instance);
    objc_sync_exit((id)(void *)graphicsFont);
    CGFontRelease(graphicsFont);
    return result;
}

static bool wk_isShapingInstance(CTFontRef font)
{
    CGFontRef graphicsFont = CTFontCopyGraphicsFont(font, NULL);
    if (!graphicsFont)
        return false;
    bool instance = objc_getAssociatedObject((id)(void *)graphicsFont, wk_isShapingInstanceKey()) != NULL;
    CGFontRelease(graphicsFont);
    return instance;
}

// The source font owns its realized shaping fonts.
static CTFontRef wk_shapingFont(CTFontRef font, bool rightToLeft)
{
    const void *key = sel_registerName(rightToLeft ? "wk_shapingFontRTL" : "wk_shapingFontLTR");
    objc_sync_enter((id)(void *)font);
    CFTypeRef cached = (CFTypeRef)objc_getAssociatedObject((id)(void *)font, key);
    if (cached) {
        objc_sync_exit((id)(void *)font);
        return cached == kCFNull ? NULL : (CTFontRef)cached;
    }
    CFTypeRef shapingFont = kCFNull;
    CGFontRef instance = wk_isShapingInstance(font) ? NULL : wk_copyShapingInstanceForFont(font, rightToLeft);
    if (instance) {
        CGAffineTransform matrix = CTFontGetMatrix(font);
        CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(font);
        shapingFont = CTFontCreateWithGraphicsFont(instance, CTFontGetSize(font), &matrix, descriptor);
        CGFontRelease(instance);
        if (descriptor)
            CFRelease(descriptor);
        if (!shapingFont)
            abort();
        CGFontRef realizedGraphics = CTFontCopyGraphicsFont((CTFontRef)shapingFont, NULL);
        objc_setAssociatedObject((id)(void *)realizedGraphics, wk_isShapingInstanceKey(), (id)(void *)kCFBooleanTrue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGFontRelease(realizedGraphics);
    } else
        CFRetain(shapingFont);

    objc_setAssociatedObject((id)(void *)font, key, (id)(void *)shapingFont, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFRelease(shapingFont);
    objc_sync_exit((id)(void *)font);
    return shapingFont == kCFNull ? NULL : (CTFontRef)shapingFont;
}

// ---------------------------------------------------------------------------------------------------
// The providers CoreText reads through.
// ---------------------------------------------------------------------------------------------------

typedef struct {
    CFIndex start;
    CFIndex count;
    const UniChar *characters;
    CFDictionaryRef attributes;
    bool disposeForwarded;
} wk_servedBlock;

enum { WKServedBlockInlineCapacity = 4 };

typedef struct {
    CTUniCharProviderCallback provide;
    CTUniCharDisposeCallback dispose;
    void *refCon;
    bool rightToLeft;
    bool recordsServedBlocks;
    bool forwardsDispose;
    CFMutableArrayRef createdAttributes; // every dictionary made for CoreText, released with the provider
    CFDictionaryRef lastSourceAttributes;
    CTFontRef lastClusterFont;
    CFDictionaryRef lastClusterAttributes;
    CFDictionaryRef lastShapingSource;
    CTFontRef lastShapingFont;
    CFDictionaryRef lastShapingAttributes;
    wk_servedBlock *servedBlocks; // NULL while the inline blocks hold them
    CFIndex servedCount;
    CFIndex servedCapacity;
    wk_servedBlock inlineServedBlocks[WKServedBlockInlineCapacity];
    CFIndex outstandingBlocks;
    bool creationFinished;
    bool fallsBack; // right to left, CoreText sets some served text in a fallback font
} wk_clusterFontProvider;

static void wk_keepAttributes(wk_clusterFontProvider *provider, CFMutableDictionaryRef attributes)
{
    if (!provider->createdAttributes) {
        provider->createdAttributes = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        if (!provider->createdAttributes)
            abort();
    }
    CFArrayAppendValue(provider->createdAttributes, attributes);
    CFRelease(attributes);
}

static CFDictionaryRef wk_clusterFontAttributes(wk_clusterFontProvider *provider, CFDictionaryRef source, CTFontRef font)
{
    if (provider->lastClusterAttributes && provider->lastSourceAttributes == source && CFEqual(provider->lastClusterFont, font))
        return provider->lastClusterAttributes;
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, source);
    if (!attributes)
        abort();
    CFDictionarySetValue(attributes, kCTFontAttributeName, font);
    wk_keepAttributes(provider, attributes);
    provider->lastSourceAttributes = source;
    provider->lastClusterFont = font;
    provider->lastClusterAttributes = attributes;
    return attributes;
}

// The attributes a dictionary made for CoreText stands in for, which CTRunGetAttributes answers. CoreText
// keeps the key on the dictionaries it makes from an attributed string's.
static CFStringRef wk_sourceAttributesKey(void)
{
    return CFSTR("WKSourceAttributes");
}

// Source attributes with the shaping font.
static CFDictionaryRef wk_shapingAttributes(wk_clusterFontProvider *provider, CFDictionaryRef source, CTFontRef shapingFont)
{
    if (provider->lastShapingAttributes && provider->lastShapingSource == source && provider->lastShapingFont == shapingFont)
        return provider->lastShapingAttributes;
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, source);
    if (!attributes)
        abort();
    CFDictionarySetValue(attributes, kCTFontAttributeName, shapingFont);
    CFDictionaryRef original = (CFDictionaryRef)CFDictionaryGetValue(source, wk_sourceAttributesKey());
    CFDictionarySetValue(attributes, wk_sourceAttributesKey(), original ? original : source);
    wk_keepAttributes(provider, attributes);
    provider->lastShapingSource = source;
    provider->lastShapingFont = shapingFont;
    provider->lastShapingAttributes = attributes;
    return attributes;
}

// A block's grapheme clusters, segmented on first use.
typedef struct {
    const UniChar *characters;
    CFIndex length;
    UText text;
    UBreakIterator *iterator;
} wk_blockClusters;

static UBreakIterator *wk_blockClusterIterator(wk_blockClusters *clusters)
{
    if (!clusters->iterator) {
        UErrorCode status = U_ZERO_ERROR;
        clusters->text = (UText)UTEXT_INITIALIZER;
        utext_openUChars(&clusters->text, (const UChar *)clusters->characters, clusters->length, &status);
        clusters->iterator = wk_characterClusterIterator();
        ubrk_setUText(clusters->iterator, &clusters->text, &status);
        if (U_FAILURE(status))
            abort();
    }
    return clusters->iterator;
}

// The first run of clusters in a block set in a font other than the block's own: clusters the block's font
// does not cover that 10.9 splits. Answers that font, or NULL.
static CTFontRef wk_findClusterFontRun(CTFontRef font, CFStringRef language, wk_blockClusters *clusters,
    wk_coverageCursor *coverage, CFIndex *runStartResult, CFIndex *runEndResult)
{
    const UniChar *characters = clusters->characters;
    CFIndex length = clusters->length;

    // Below U+0300 no character but CR and LF joins another, so a cluster of more than one code point holds a
    // code point at or above it, and a code point of that cluster without a glyph is that code point or one
    // next to it.
    CFIndex position = 0;
    while (position < length && characters[position] < 0x0300)
        ++position;
    if (position == length)
        return NULL;

    wk_cascadeFonts *cascade = NULL;
    CFMutableStringRef scratch = NULL;
    CTFontRef clusterFont = NULL;
    CFIndex runStart = 0;
    CFIndex runEnd = 0;
    while (position < length) {
        CFIndex next = position + wk_codePointLength(characters, length, position);
        CFIndex neighbourhoodStart = position;
        if (position >= 2 && U16_IS_TRAIL(characters[position - 1]) && U16_IS_LEAD(characters[position - 2]))
            neighbourhoodStart -= 2;
        else if (position)
            --neighbourhoodStart;
        CFIndex neighbourhoodEnd = next < length ? next + wk_codePointLength(characters, length, next) : length;
        if (wk_nextUncoveredCharacter(coverage, neighbourhoodStart, neighbourhoodEnd) < neighbourhoodEnd) {
            UBreakIterator *iterator = wk_blockClusterIterator(clusters);
            CFIndex clusterEnd = ubrk_following(iterator, (int32_t)position);
            CFIndex clusterStart = ubrk_previous(iterator);
            CFIndex clusterLength = clusterEnd - clusterStart;
            if (wk_nextUncoveredCharacter(coverage, clusterStart, clusterEnd) < clusterEnd) {
                if (wk_systemSplitsCluster(&scratch, characters + clusterStart, clusterLength)) {
                    if (!cascade)
                        cascade = wk_cascadeFontsFor(font, language);
                    CTFontRef candidate = wk_cascadeFontCovering(cascade, characters + clusterStart, clusterLength);
                    if (candidate) {
                        clusterFont = candidate;
                        runStart = clusterStart;
                        runEnd = clusterEnd;
                        break;
                    }
                }
            }
            next = clusterEnd;
        }
        position = next;
        while (position < length && characters[position] < 0x0300)
            ++position;
    }
    if (scratch)
        CFRelease(scratch);
    if (!clusterFont)
        return NULL;

    UBreakIterator *iterator = clusters->iterator;
    while (runStart > 0) {
        CFIndex previous = ubrk_preceding(iterator, (int32_t)runStart);
        if (wk_nextUncoveredCharacter(coverage, previous, runStart) == runStart
            || wk_cascadeFontCovering(cascade, characters + previous, runStart - previous) != clusterFont)
            break;
        runStart = previous;
    }
    while (runEnd < length) {
        CFIndex next = ubrk_following(iterator, (int32_t)runEnd);
        if (wk_nextUncoveredCharacter(coverage, runEnd, next) == next
            || wk_cascadeFontCovering(cascade, characters + runEnd, next - runEnd) != clusterFont)
            break;
        runEnd = next;
    }
    *runStartResult = runStart;
    *runEndResult = runEnd;
    return clusterFont;
}

static bool wk_fontUsesSystemFallbackOnly(CTFontRef font)
{
    CFTypeRef attribute = CTFontCopyAttribute(font, kCTFontFallbackOptionAttribute);
    long option = 0;
    bool restricted = attribute && CFGetTypeID(attribute) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)attribute, kCFNumberLongType, &option) && option == 1;
    if (attribute)
        CFRelease(attribute);
    return restricted;
}

// Narrows a block CoreText is handed to its first part that is set one way, and sets it that way.
static void wk_serveBlock(wk_clusterFontProvider *provider, const UniChar *characters, CFIndex *charCount, CFDictionaryRef *attributes)
{
    CFDictionaryRef source = *attributes;
    CTFontRef font = source ? (CTFontRef)CFDictionaryGetValue(source, kCTFontAttributeName) : NULL;
    if (!font || CFGetTypeID(font) != CTFontGetTypeID())
        return;
    CFIndex length = *charCount;
    CFStringRef language = (CFStringRef)CFDictionaryGetValue(source, kCTLanguageAttributeName);
    if (language && CFGetTypeID(language) != CFStringGetTypeID())
        language = NULL;

    wk_blockClusters clusters = { .characters = characters, .length = length };
    wk_coverageCursor coverage;
    wk_coverageCursorInit(&coverage, font, characters, length);
    // System-only requests select their fallback font before native shaping.
    if (wk_fontUsesSystemFallbackOnly(font)) {
        CFIndex uncovered = wk_nextUncoveredCharacter(&coverage, 0, length);
        if (uncovered < length) {
            UBreakIterator *iterator = wk_blockClusterIterator(&clusters);
            CFIndex start = ubrk_preceding(iterator, (int32_t)(uncovered + 1));
            CFIndex end = ubrk_following(iterator, (int32_t)uncovered);
            if (!start) {
                CTFontRef fallback = wk_copySystemFallback(font, characters, end, language, NULL);
                if (!fallback) {
                    CTFontDescriptorRef lastResort = CTFontDescriptorCreateLastResort();
                    fallback = CTFontCreateWithFontDescriptor(lastResort, CTFontGetSize(font), NULL);
                    CFRelease(lastResort);
                }
                fallback = wk_inheritFontRequest(fallback, font);
                CFDictionaryRef selected = wk_clusterFontAttributes(provider, source, fallback);
                CTFontRef shaping = wk_shapingFont(fallback, provider->rightToLeft);
                *attributes = shaping ? wk_shapingAttributes(provider, selected, shaping) : selected;
                *charCount = end;
                CFRelease(fallback);
                return;
            }
            length = *charCount = start;
            clusters.length = start;
            coverage.length = start;
        }
    }
    CFIndex runStart = 0;
    CFIndex runEnd = 0;
    CTFontRef clusterFont = wk_findClusterFontRun(font, language, &clusters, &coverage, &runStart, &runEnd);
    if (clusterFont && !runStart) {
        CFDictionaryRef clusterAttributes = wk_clusterFontAttributes(provider, source, clusterFont);
        CTFontRef shapingFont = wk_shapingFont(clusterFont, provider->rightToLeft);
        *charCount = runEnd;
        *attributes = shapingFont ? wk_shapingAttributes(provider, clusterAttributes, shapingFont) : clusterAttributes;
        return;
    }

    CFIndex served = clusterFont ? runStart : length;
    CFIndex uncovered = wk_nextUncoveredCharacter(&coverage, 0, served);
    if (uncovered < served)
        provider->fallsBack = true;
    CTFontRef shapingFont = wk_shapingFont(font, provider->rightToLeft);
    if (shapingFont) {
        if (uncovered < served) {
            UBreakIterator *iterator = wk_blockClusterIterator(&clusters);
            CFIndex clusterStart = ubrk_preceding(iterator, (int32_t)(uncovered + 1));
            if (!clusterStart) {
                // Clusters the font does not cover are set in the fallback font CoreText finds for them.
                CFIndex end = ubrk_following(iterator, 0);
                while (end < served) {
                    CFIndex next = ubrk_following(iterator, (int32_t)end);
                    if (wk_nextUncoveredCharacter(&coverage, end, next) == next)
                        break;
                    end = next;
                }
                *charCount = end;
                return;
            }
            served = clusterStart;
        }
        *attributes = wk_shapingAttributes(provider, source, shapingFont);
    }
    *charCount = served;
}

static wk_servedBlock *wk_servedBlocks(wk_clusterFontProvider *provider)
{
    return provider->servedBlocks ? provider->servedBlocks : provider->inlineServedBlocks;
}

static void wk_recordServedBlock(wk_clusterFontProvider *provider, CFIndex start, CFIndex count, const UniChar *characters, CFDictionaryRef attributes)
{
    CFIndex capacity = provider->servedBlocks ? provider->servedCapacity : WKServedBlockInlineCapacity;
    if (provider->servedCount == capacity) {
        wk_servedBlock *blocks = (wk_servedBlock *)malloc((size_t)(2 * capacity) * sizeof(wk_servedBlock));
        if (!blocks)
            abort();
        memcpy(blocks, wk_servedBlocks(provider), (size_t)provider->servedCount * sizeof(wk_servedBlock));
        free(provider->servedBlocks);
        provider->servedBlocks = blocks;
        provider->servedCapacity = 2 * capacity;
    }
    wk_servedBlocks(provider)[provider->servedCount++] = (wk_servedBlock) { start, count, characters, attributes, false };
}

static const UniChar *wk_clusterFontProvide(CFIndex stringIndex, CFIndex *charCount, CFDictionaryRef *attributes, void *refCon)
{
    wk_clusterFontProvider *provider = (wk_clusterFontProvider *)refCon;
    const UniChar *characters = provider->provide(stringIndex, charCount, attributes, provider->refCon);
    if (!characters || *charCount <= 0)
        return characters;
    if (provider->dispose)
        ++provider->outstandingBlocks;
    wk_serveBlock(provider, characters, charCount, attributes);
    if (provider->recordsServedBlocks)
        wk_recordServedBlock(provider, stringIndex, *charCount, characters, *attributes);
    return characters;
}

static void wk_clusterFontProviderRelease(wk_clusterFontProvider *provider)
{
    if (provider->createdAttributes)
        CFRelease(provider->createdAttributes);
    free(provider->servedBlocks);
}

static void wk_clusterFontDispose(const UniChar *characters, void *refCon)
{
    wk_clusterFontProvider *provider = (wk_clusterFontProvider *)refCon;
    if (provider->forwardsDispose)
        provider->dispose(characters, provider->refCon);
    if (!--provider->outstandingBlocks && provider->creationFinished) {
        wk_clusterFontProviderRelease(provider);
        free(provider);
    }
}

// A provider with a dispose callback is read again when CoreText releases what it made, so it lives on the
// heap until the last block is disposed of.
static wk_clusterFontProvider *wk_clusterFontProviderBegin(wk_clusterFontProvider *local)
{
    if (!local->dispose)
        return local;
    wk_clusterFontProvider *provider = (wk_clusterFontProvider *)malloc(sizeof(*provider));
    if (!provider)
        abort();
    *provider = *local;
    return provider;
}

static void wk_clusterFontProviderEnd(wk_clusterFontProvider *provider)
{
    if (!provider->dispose) {
        wk_clusterFontProviderRelease(provider);
        return;
    }
    provider->creationFinished = true;
    if (!provider->outstandingBlocks) {
        wk_clusterFontProviderRelease(provider);
        free(provider);
    }
}

// Whether options force an embedding level, and which.
static bool wk_forcedEmbeddingLevel(CFDictionaryRef options, int *level)
{
    CFNumberRef value = options ? (CFNumberRef)CFDictionaryGetValue(options, kCTTypesetterOptionForcedEmbeddingLevel) : NULL;
    return value && CFGetTypeID(value) == CFNumberGetTypeID() && CFNumberGetValue(value, kCFNumberIntType, level);
}

typedef enum { WKNaturalLine, WKNaturalTypesetter } wk_naturalKind;

static CFTypeRef wk_createNaturalDirection(wk_naturalKind, CTUniCharProviderCallback, CTUniCharDisposeCallback, void *refCon, CFDictionaryRef options);
static CTTypesetterRef wk_createForcedLevelTypesetter(CTUniCharProviderCallback, CTUniCharDisposeCallback, void *refCon, CFDictionaryRef options, int level);

WK_POLYFILL_REPLACES("CoreText", CTTypesetterRef, CTTypesetterCreateWithUniCharProviderAndOptions,
    (CTUniCharProviderCallback provide, CTUniCharDisposeCallback dispose, void *refCon, CFDictionaryRef options))
{
    if (!provide)
        return WK_ORIGINAL(CTTypesetterCreateWithUniCharProviderAndOptions)(provide, dispose, refCon, options);
    int level = 0;
    if (!wk_forcedEmbeddingLevel(options, &level))
        return (CTTypesetterRef)wk_createNaturalDirection(WKNaturalTypesetter, provide, dispose, refCon, options);
    return wk_createForcedLevelTypesetter(provide, dispose, refCon, options, level);
}

WK_POLYFILL_REPLACES("CoreText", CTLineRef, CTLineCreateWithUniCharProvider,
    (CTUniCharProviderCallback provide, CTUniCharDisposeCallback dispose, void *refCon))
{
    if (!provide)
        return WK_ORIGINAL(CTLineCreateWithUniCharProvider)(provide, dispose, refCon);
    return (CTLineRef)wk_createNaturalDirection(WKNaturalLine, provide, dispose, refCon, NULL);
}

static bool wk_isShapingInstance(CTFontRef);

static const void *wk_reportedAttributesKey(void)
{
    // Cached, and a SEL so every image's copy of this archive agrees on it.
    static const void *key;
    if (!key)
        key = (const void *)sel_registerName("wk_reportedAttributes");
    return key;
}

WK_POLYFILL_REPLACES("CoreText", CFDictionaryRef, CTRunGetAttributes, (CTRunRef run))
{
    CFDictionaryRef attributes = WK_ORIGINAL(CTRunGetAttributes)(run);
    CFDictionaryRef source = attributes ? (CFDictionaryRef)CFDictionaryGetValue(attributes, wk_sourceAttributesKey()) : NULL;
    if (!source || CFGetTypeID(source) != CFDictionaryGetTypeID())
        return attributes;
    CTFontRef runFont = (CTFontRef)CFDictionaryGetValue(attributes, kCTFontAttributeName);
    CTFontRef sourceFont = (CTFontRef)CFDictionaryGetValue(source, kCTFontAttributeName);
    if (!runFont || !sourceFont || runFont == sourceFont || CFEqual(runFont, sourceFont) || wk_isShapingInstance(runFont))
        return source;
    // CoreText set the run in a fallback font: the provided attributes with that font, kept with the run.
    CFDictionaryRef reported = (CFDictionaryRef)objc_getAssociatedObject((id)(void *)run, wk_reportedAttributesKey());
    if (!reported) {
        CFMutableDictionaryRef fallback = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, source);
        if (!fallback)
            abort();
        CFDictionarySetValue(fallback, kCTFontAttributeName, runFont);
        objc_setAssociatedObject((id)(void *)run, wk_reportedAttributesKey(), (id)(void *)fallback, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFRelease(fallback);
        reported = fallback;
    }
    return reported;
}

// ---------------------------------------------------------------------------------------------------
// Natural direction. Text without a forced embedding level is read from its provider first, and then set
// by one of two routes.
//
// 10.9's CoreText resolves its levels with libicucore's ICU 51, which predates the Unicode 6.3 bracket-pair
// and isolate rules and classes a code point assigned since by its block's default: an emoji modifier is left
// to right there, so a skin-tone sequence between Hebrew letters splits into two runs. Modern CoreText
// resolves levels from current Unicode data. When the levels ICU 51 resolves are the levels this port's ICU
// 74 resolves, the provided blocks go to CoreText as they were provided. When they differ, the text is laid
// out from an attributed string that overrides each character to its ICU 74 level. An override can only
// raise a level, so each is raised by two, which leaves the visual order and every run's direction as they
// are.
//
// A right-to-left run set in a font with logical-order subtables is then set again in its shaping font. The
// fonts do not enter level resolution, so the second layout resolves the same runs.
// ---------------------------------------------------------------------------------------------------

WK_SYSTEM_FN("/usr/lib/libicucore.A.dylib", UCharDirection, u_charDirection, (UChar32));
WK_SYSTEM_FN("/usr/lib/libicucore.A.dylib", UBiDi *, ubidi_open, (void));
WK_SYSTEM_FN("/usr/lib/libicucore.A.dylib", void, ubidi_setPara, (UBiDi *, const UChar *, int32_t, UBiDiLevel, UBiDiLevel *, UErrorCode *));
WK_SYSTEM_FN("/usr/lib/libicucore.A.dylib", const UBiDiLevel *, ubidi_getLevels, (UBiDi *, UErrorCode *));
WK_SYSTEM_FN("/usr/lib/libicucore.A.dylib", void, ubidi_close, (UBiDi *));

// A thread's ICU 74 and ICU 51 resolvers.
typedef struct {
    UBiDi *current;
    UBiDi *system;
} wk_bidiResolvers;

static pthread_key_t wk_bidiResolversKey;
static pthread_once_t wk_bidiResolversKeyOnce = PTHREAD_ONCE_INIT;

static void wk_bidiResolversDestroy(void *value)
{
    wk_bidiResolvers *resolvers = (wk_bidiResolvers *)value;
    ubidi_close(resolvers->current);
    WK_SYSTEM(ubidi_close)(resolvers->system);
    free(resolvers);
}

static void wk_bidiResolversKeyCreate(void)
{
    if (pthread_key_create(&wk_bidiResolversKey, wk_bidiResolversDestroy))
        abort();
}

static wk_bidiResolvers *wk_bidiResolversForThread(void)
{
    pthread_once(&wk_bidiResolversKeyOnce, wk_bidiResolversKeyCreate);
    wk_bidiResolvers *resolvers = (wk_bidiResolvers *)pthread_getspecific(wk_bidiResolversKey);
    if (resolvers)
        return resolvers;
    resolvers = (wk_bidiResolvers *)calloc(1, sizeof(*resolvers));
    if (!resolvers || !WK_SYSTEM(ubidi_open) || !WK_SYSTEM(ubidi_setPara) || !WK_SYSTEM(ubidi_getLevels) || !WK_SYSTEM(ubidi_close) || !WK_SYSTEM(u_charDirection))
        abort();
    resolvers->current = ubidi_open();
    resolvers->system = WK_SYSTEM(ubidi_open)();
    if (!resolvers->current || !resolvers->system)
        abort();
    pthread_setspecific(wk_bidiResolversKey, resolvers);
    return resolvers;
}

// The classes that can give a character a level other than a left-to-right paragraph's.
static bool wk_directionRaisesLevels(UCharDirection direction)
{
    switch (direction) {
    case U_RIGHT_TO_LEFT:
    case U_RIGHT_TO_LEFT_ARABIC:
    case U_ARABIC_NUMBER:
    case U_LEFT_TO_RIGHT_EMBEDDING:
    case U_LEFT_TO_RIGHT_OVERRIDE:
    case U_RIGHT_TO_LEFT_EMBEDDING:
    case U_RIGHT_TO_LEFT_OVERRIDE:
    case U_POP_DIRECTIONAL_FORMAT:
    case U_LEFT_TO_RIGHT_ISOLATE:
    case U_RIGHT_TO_LEFT_ISOLATE:
    case U_FIRST_STRONG_ISOLATE:
    case U_POP_DIRECTIONAL_ISOLATE:
        return true;
    default:
        return false;
    }
}

static CTWritingDirection wk_baseWritingDirection(CFDictionaryRef attributes)
{
    CTParagraphStyleRef style = attributes ? (CTParagraphStyleRef)CFDictionaryGetValue(attributes, kCTParagraphStyleAttributeName) : NULL;
    CTWritingDirection direction = kCTWritingDirectionNatural;
    if (style && CFGetTypeID(style) == CTParagraphStyleGetTypeID())
        CTParagraphStyleGetValueForSpecifier(style, kCTParagraphStyleSpecifierBaseWritingDirection, sizeof(direction), &direction);
    return direction;
}

// The provided text as one run of UTF-16, copied only when its blocks are not already one buffer.
typedef struct {
    const UniChar *characters;
    CFIndex length;
    UniChar *copy;
} wk_providedText;

static void wk_providedTextInit(wk_providedText *text, wk_clusterFontProvider *reader)
{
    memset(text, 0, sizeof(*text));
    wk_servedBlock *blocks = wk_servedBlocks(reader);
    CFIndex count = reader->servedCount;
    if (!count)
        return;
    text->length = blocks[count - 1].start + blocks[count - 1].count;
    bool contiguous = true;
    for (CFIndex i = 1; i < count && contiguous; ++i)
        contiguous = blocks[i - 1].characters + blocks[i - 1].count == blocks[i].characters;
    if (contiguous) {
        text->characters = blocks[0].characters;
        return;
    }
    text->copy = (UniChar *)malloc((size_t)text->length * sizeof(UniChar));
    if (!text->copy)
        abort();
    for (CFIndex i = 0; i < count; ++i)
        memcpy(text->copy + blocks[i].start, blocks[i].characters, (size_t)blocks[i].count * sizeof(UniChar));
    text->characters = text->copy;
}

typedef enum {
    WKLevelsLeftToRight, // every character is at the paragraph's left-to-right level
    WKLevelsCurrent, // CoreText resolves the levels current Unicode does
    WKLevelsExplicit, // CoreText resolves other levels; the current ones are handed back
} wk_levelResolution;

static bool wk_isParagraphSeparator(UChar32 codePoint)
{
    // Below U+058D the paragraph separators are LF, CR, U+001C-001E and U+0085.
    return codePoint < 0x058D
        ? codePoint == '\n' || codePoint == '\r' || (codePoint >= 0x1C && codePoint <= 0x1E) || codePoint == 0x85
        : u_charDirection(codePoint) == U_BLOCK_SEPARATOR;
}

// Where the paragraph holding the character at index ends: after a paragraph separator, taking CR LF as one.
static CFIndex wk_paragraphEnd(const wk_providedText *text, CFIndex index)
{
    for (CFIndex i = index; i < text->length; ) {
        UChar32 codePoint;
        U16_NEXT(text->characters, i, text->length, codePoint);
        if (wk_isParagraphSeparator(codePoint)) {
            if (codePoint == '\r' && i < text->length && text->characters[i] == '\n')
                ++i;
            return i;
        }
    }
    return text->length;
}

// The served block holding the character at index.
static const wk_servedBlock *wk_servedBlockAt(wk_clusterFontProvider *provider, CFIndex index)
{
    wk_servedBlock *blocks = wk_servedBlocks(provider);
    for (CFIndex i = 0; i < provider->servedCount; ++i) {
        if (index < blocks[i].start + blocks[i].count)
            return &blocks[i];
    }
    return NULL;
}

// Each paragraph takes its level from the paragraph style of the block it starts in, as CoreText gives it.
static UBiDiLevel wk_paragraphLevel(CTWritingDirection direction)
{
    return direction == kCTWritingDirectionRightToLeft ? 1 : direction == kCTWritingDirectionLeftToRight ? 0 : UBIDI_DEFAULT_LTR;
}

static wk_levelResolution wk_resolveLevels(wk_clusterFontProvider *reader, const wk_providedText *text, UBiDiLevel **levelsResult)
{
    if (!text->length)
        return WKLevelsLeftToRight;

    // ICU 51 implements the Unicode 6.2 bidirectional algorithm. What has changed levels since is classes,
    // the paired-bracket rule and the depth of explicit embedding, which went from 61 to 125, so text holding
    // no code point classed differently, no paired bracket and no more explicit controls than 61 resolves
    // alike in both. Below U+058D the two class every code point alike and the paired brackets are ASCII's,
    // and below U+0590 no class raises a level. A paragraph whose style changes after it starts is not
    // resolved by CoreText the way it is by the algorithm, so it is always set at explicit levels.
    enum { WKSystemMaxExplicitLevel = 61 };
    bool raises = false;
    bool mayDiffer = false;
    bool explicitLevels = false;
    CFIndex explicitControls = 0;
    wk_servedBlock *blocks = wk_servedBlocks(reader);
    CFIndex block = 0;
    CFIndex blockEnd = blocks[0].start + blocks[0].count;
    bool paragraphStarts = true;
    CTWritingDirection paragraphDirection = kCTWritingDirectionNatural;
    for (CFIndex i = 0; i < text->length && !(raises && (mayDiffer || explicitLevels)); ) {
        if (i >= blockEnd) {
            while (blocks[block].start + blocks[block].count <= i)
                ++block;
            blockEnd = blocks[block].start + blocks[block].count;
            if (!paragraphStarts && wk_baseWritingDirection(blocks[block].attributes) != paragraphDirection)
                explicitLevels = true;
        }
        if (paragraphStarts) {
            paragraphDirection = wk_baseWritingDirection(blocks[block].attributes);
            raises = raises || paragraphDirection == kCTWritingDirectionRightToLeft;
            paragraphStarts = false;
        }
        UniChar unit = text->characters[i];
        if (unit < 0x058D) {
            ++i;
            // Of these, only the ASCII brackets and the paragraph separators can matter. The next paragraph starts
            // after a separator, taking CR LF as one.
            if (unit <= '}' || unit == 0x85) {
                if (unit == '(' || unit == ')' || unit == '[' || unit == ']' || unit == '{' || unit == '}')
                    mayDiffer = true;
                else if (wk_isParagraphSeparator(unit) && !(unit == '\r' && i < text->length && text->characters[i] == '\n'))
                    paragraphStarts = true;
            }
            continue;
        }
        UChar32 codePoint;
        U16_NEXT(text->characters, i, text->length, codePoint);
        if (wk_isParagraphSeparator(codePoint))
            paragraphStarts = true;
        UCharDirection current = u_charDirection(codePoint);
        UCharDirection system = WK_SYSTEM(u_charDirection)(codePoint);
        raises = raises || wk_directionRaisesLevels(current) || wk_directionRaisesLevels(system);
        if (wk_directionRaisesLevels(current) && current != U_RIGHT_TO_LEFT && current != U_RIGHT_TO_LEFT_ARABIC && current != U_ARABIC_NUMBER)
            ++explicitControls;
        mayDiffer = mayDiffer || current != system || explicitControls > WKSystemMaxExplicitLevel
            || u_getIntPropertyValue(codePoint, UCHAR_BIDI_PAIRED_BRACKET_TYPE) != U_BPT_NONE;
    }
    if (!raises)
        return WKLevelsLeftToRight;
    if (!mayDiffer && !explicitLevels)
        return WKLevelsCurrent;

    UBiDiLevel *levels = (UBiDiLevel *)malloc((size_t)text->length);
    if (!levels)
        abort();
    wk_bidiResolvers *resolvers = wk_bidiResolversForThread();
    bool same = true;
    for (CFIndex start = 0; start < text->length; ) {
        CFIndex end = wk_paragraphEnd(text, start);
        UBiDiLevel paragraphLevel = wk_paragraphLevel(wk_baseWritingDirection(wk_servedBlockAt(reader, start)->attributes));
        UErrorCode status = U_ZERO_ERROR;
        ubidi_setPara(resolvers->current, (const UChar *)text->characters + start, (int32_t)(end - start), paragraphLevel, NULL, &status);
        const UBiDiLevel *current = ubidi_getLevels(resolvers->current, &status);
        UErrorCode systemStatus = U_ZERO_ERROR;
        WK_SYSTEM(ubidi_setPara)(resolvers->system, (const UChar *)text->characters + start, (int32_t)(end - start), paragraphLevel, NULL, &systemStatus);
        const UBiDiLevel *system = WK_SYSTEM(ubidi_getLevels)(resolvers->system, &systemStatus);
        if (U_FAILURE(status) || U_FAILURE(systemStatus) || !current || !system)
            abort();
        memcpy(levels + start, current, (size_t)(end - start));
        same = same && !memcmp(current, system, (size_t)(end - start));
        start = end;
    }
    if (same && !explicitLevels) {
        free(levels);
        return WKLevelsCurrent;
    }
    *levelsResult = levels;
    return WKLevelsExplicit;
}

// The nested overrides that take a character to level to, which is at least 2, from a paragraph at level 0 or 1:
// the first is left to right, which takes either to level 2.
static CFArrayRef wk_createOverrideChain(int to)
{
    CFMutableArrayRef chain = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!chain)
        abort();
    for (int level = 0; level < to; ) {
        int rightToLeft = to - level == 1 ? (to & 1) : (level & 1);
        int value = (rightToLeft ? kCTWritingDirectionRightToLeft : kCTWritingDirectionLeftToRight) | kCTWritingDirectionOverride;
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
        if (!number)
            abort();
        CFArrayAppendValue(chain, number);
        CFRelease(number);
        level += ((level + 1) & 1) == rightToLeft ? 1 : 2;
    }
    return chain;
}

// Whether a range of the text the provider served is a single code point.
static bool wk_servedRangeIsOneCodePoint(wk_clusterFontProvider *provider, CFRange range)
{
    if (range.length == 1)
        return true;
    if (range.length != 2)
        return false;
    wk_servedBlock *blocks = wk_servedBlocks(provider);
    for (CFIndex i = 0; i < provider->servedCount; ++i) {
        if (blocks[i].start <= range.location && range.location + 2 <= blocks[i].start + blocks[i].count) {
            const UniChar *characters = blocks[i].characters + (range.location - blocks[i].start);
            return U16_IS_LEAD(characters[0]) && U16_IS_TRAIL(characters[1]);
        }
    }
    return false;
}

typedef struct {
    CFIndex start;
    CFIndex end;
    CTFontRef font;
} wk_rightToLeftRange;

static int wk_compareRightToLeftRanges(const void *a, const void *b)
{
    CFIndex first = ((const wk_rightToLeftRange *)a)->start;
    CFIndex second = ((const wk_rightToLeftRange *)b)->start;
    return first < second ? -1 : first > second;
}

// The right-to-left runs of more than one code point set in a font with logical-order subtables, in string
// order and joined where they meet in one font. NULL when there are none.
static wk_rightToLeftRange *wk_copyLogicalOrderRightToLeftRanges(wk_clusterFontProvider *provider, CTLineRef line, CFIndex *rangeCount)
{
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex runCount = runs ? CFArrayGetCount(runs) : 0;
    wk_rightToLeftRange *ranges = NULL;
    CFIndex count = 0;
    for (CFIndex i = 0; i < runCount; ++i) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
        if (!(CTRunGetStatus(run) & kCTRunStatusRightToLeft))
            continue;
        CFRange range = CTRunGetStringRange(run);
        if (wk_servedRangeIsOneCodePoint(provider, range))
            continue;
        CFDictionaryRef runAttributes = WK_ORIGINAL(CTRunGetAttributes)(run);
        CTFontRef font = runAttributes ? (CTFontRef)CFDictionaryGetValue(runAttributes, kCTFontAttributeName) : NULL;
        if (!font || CFGetTypeID(font) != CTFontGetTypeID() || !wk_shapingFont(font, true))
            continue;
        if (!ranges) {
            ranges = (wk_rightToLeftRange *)malloc((size_t)runCount * sizeof(wk_rightToLeftRange));
            if (!ranges)
                abort();
        }
        ranges[count++] = (wk_rightToLeftRange) { range.location, range.location + range.length, font };
    }
    if (!count)
        return NULL;
    qsort(ranges, (size_t)count, sizeof(wk_rightToLeftRange), wk_compareRightToLeftRanges);
    CFIndex joined = 0;
    for (CFIndex i = 1; i < count; ++i) {
        if (ranges[i].start == ranges[joined].end && ranges[i].font == ranges[joined].font)
            ranges[joined].end = ranges[i].end;
        else
            ranges[++joined] = ranges[i];
    }
    *rangeCount = joined + 1;
    return ranges;
}

static CGFloat wk_zeroWidthMetric(void *refCon)
{
    (void)refCon;
    return 0;
}

static void wk_zeroWidthDeallocate(void *refCon)
{
    (void)refCon;
}

typedef enum {
    WKStandInNone,
    WKStandInZeroWidth,
    WKStandInSpace,
} wk_standIn;

// CoreText does not take an override on two kinds of character. 10.9 classes the isolate controls U+2066-2069 as
// boundary neutrals, which take the level of the character before them, and a paragraph separator takes its
// paragraph's level. Where those differ from the character's current level, CoreText lays out a space in its
// place: a space takes its override and is not a mark, so no cluster before it takes it in, and in a zero-width run
// delegate it has no advance. LF and CR are laid out as a plain space, which is the advance CoreText gives them.
// In a font without a space, U+FFFC in a zero-width run delegate stands in.
static wk_standIn wk_standInFor(const wk_providedText *text, const UBiDiLevel *levels, CFIndex index)
{
    UniChar character = text->characters[index];
    if (character >= 0x2066 && character <= 0x2069)
        return !index || levels[index] != levels[index - 1] ? WKStandInZeroWidth : WKStandInNone;
    if (character == '\n' || character == '\r')
        return WKStandInSpace;
    if (!U16_IS_SURROGATE(character) && wk_isParagraphSeparator(character))
        return WKStandInZeroWidth;
    return WKStandInNone;
}

typedef struct {
    CFIndex start;
    CFIndex end;
    CFMutableDictionaryRef attributes;
} wk_levelSegment;

// The attributed string the provided text is laid out from at explicit levels: each block's attributes, each
// character overridden to its level raised by two, and the ranges given set in their shaping fonts.
static CFAttributedStringRef wk_createExplicitLevelString(wk_clusterFontProvider *reader, const wk_providedText *text,
    const UBiDiLevel *levels, const wk_rightToLeftRange *ranges, CFIndex rangeCount)
{
    wk_levelSegment *segments = NULL;
    CFIndex segmentCount = 0;
    CFIndex segmentCapacity = 0;
    UniChar *laidOut = NULL;
    CTRunDelegateRef zeroWidth = NULL;
    CFArrayRef chains[UBIDI_MAX_EXPLICIT_LEVEL + 4] = { 0 };
    wk_servedBlock *blocks = wk_servedBlocks(reader);
    CFIndex rangeIndex = 0;
    for (CFIndex b = 0; b < reader->servedCount; ++b) {
        const wk_servedBlock *block = &blocks[b];
        CFIndex blockEnd = block->start + block->count;
        for (CFIndex position = block->start; position < blockEnd; ) {
            wk_standIn standIn = wk_standInFor(text, levels, position);
            CFIndex end = position + 1;
            if (standIn == WKStandInNone) {
                while (end < blockEnd && levels[end] == levels[position] && wk_standInFor(text, levels, end) == WKStandInNone)
                    ++end;
            }
            while (rangeIndex < rangeCount && ranges[rangeIndex].end <= position)
                ++rangeIndex;
            const wk_rightToLeftRange *shaping = NULL;
            if (rangeIndex < rangeCount) {
                if (ranges[rangeIndex].start <= position) {
                    shaping = &ranges[rangeIndex];
                    if (shaping->end < end)
                        end = shaping->end;
                } else if (ranges[rangeIndex].start < end)
                    end = ranges[rangeIndex].start;
            }

            CFDictionaryRef source = block->attributes;
            CFMutableDictionaryRef attributes = source ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, source)
                : CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            if (!attributes)
                abort();
            if (shaping && source) {
                if (CFDictionaryGetValue(source, kCTFontAttributeName) != shaping->font)
                    source = wk_clusterFontAttributes(reader, source, shaping->font);
                CFDictionarySetValue(attributes, kCTFontAttributeName, wk_shapingFont(shaping->font, true));
            }
            UBiDiLevel level = levels[position];
            if (!chains[level + 2])
                chains[level + 2] = wk_createOverrideChain(level + 2);
            CFDictionarySetValue(attributes, kCTWritingDirectionAttributeName, chains[level + 2]);
            if (source)
                CFDictionarySetValue(attributes, wk_sourceAttributesKey(), source);

            if (standIn != WKStandInNone) {
                CTFontRef font = (CTFontRef)CFDictionaryGetValue(attributes, kCTFontAttributeName);
                UniChar space = ' ';
                CGGlyph spaceGlyph;
                bool hasSpace = font && CFGetTypeID(font) == CTFontGetTypeID() && CTFontGetGlyphsForCharacters(font, &space, &spaceGlyph, 1);
                if (!laidOut) {
                    laidOut = (UniChar *)malloc((size_t)text->length * sizeof(UniChar));
                    if (!laidOut)
                        abort();
                    memcpy(laidOut, text->characters, (size_t)text->length * sizeof(UniChar));
                }
                laidOut[position] = hasSpace ? ' ' : 0xFFFC;
                if (standIn == WKStandInZeroWidth || !hasSpace) {
                    if (!zeroWidth) {
                        CTRunDelegateCallbacks callbacks = { kCTRunDelegateVersion1, wk_zeroWidthDeallocate, wk_zeroWidthMetric, wk_zeroWidthMetric, wk_zeroWidthMetric };
                        zeroWidth = CTRunDelegateCreate(&callbacks, NULL);
                        if (!zeroWidth)
                            abort();
                    }
                    CFDictionarySetValue(attributes, kCTRunDelegateAttributeName, zeroWidth);
                }
            }

            if (segmentCount == segmentCapacity) {
                segmentCapacity = segmentCapacity ? 2 * segmentCapacity : 16;
                segments = (wk_levelSegment *)realloc(segments, (size_t)segmentCapacity * sizeof(wk_levelSegment));
                if (!segments)
                    abort();
            }
            segments[segmentCount++] = (wk_levelSegment) { position, end, attributes };
            position = end;
        }
    }

    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, laidOut ? laidOut : text->characters, text->length);
    CFMutableAttributedStringRef result = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0);
    if (!string || !result)
        abort();
    CFAttributedStringReplaceString(result, CFRangeMake(0, 0), string);
    CFRelease(string);
    CFAttributedStringBeginEditing(result);
    for (CFIndex i = 0; i < segmentCount; ++i) {
        CFAttributedStringSetAttributes(result, CFRangeMake(segments[i].start, segments[i].end - segments[i].start), segments[i].attributes, true);
        CFRelease(segments[i].attributes);
    }
    CFAttributedStringEndEditing(result);
    free(segments);
    free(laidOut);
    if (zeroWidth)
        CFRelease(zeroWidth);
    for (size_t i = 0; i < sizeof(chains) / sizeof(*chains); ++i) {
        if (chains[i])
            CFRelease(chains[i]);
    }
    return result;
}

// Serves the blocks a reader was handed, with the ranges given set in their shaping fonts. Each block is
// disposed of once, when CoreText lets go of its start.
typedef struct {
    wk_clusterFontProvider base; // the dispose callback, the dictionaries made, and the lifetime
    wk_servedBlock *blocks;
    CFIndex blockCount;
    CFIndex blockCursor;
    const wk_rightToLeftRange *ranges;
    CFIndex rangeCount;
    CFIndex rangeCursor;
} wk_replayProvider;

static const UniChar *wk_replayProvide(CFIndex stringIndex, CFIndex *charCount, CFDictionaryRef *attributes, void *refCon)
{
    wk_replayProvider *provider = (wk_replayProvider *)refCon;
    if (provider->blockCursor >= provider->blockCount || provider->blocks[provider->blockCursor].start > stringIndex)
        provider->blockCursor = 0;
    while (provider->blockCursor < provider->blockCount
        && provider->blocks[provider->blockCursor].start + provider->blocks[provider->blockCursor].count <= stringIndex)
        ++provider->blockCursor;
    if (stringIndex < 0 || provider->blockCursor == provider->blockCount || provider->blocks[provider->blockCursor].start > stringIndex) {
        *charCount = 0;
        return NULL;
    }
    const wk_servedBlock *block = &provider->blocks[provider->blockCursor];

    if (provider->rangeCursor >= provider->rangeCount || (provider->rangeCursor && provider->ranges[provider->rangeCursor - 1].end > stringIndex))
        provider->rangeCursor = 0;
    while (provider->rangeCursor < provider->rangeCount && provider->ranges[provider->rangeCursor].end <= stringIndex)
        ++provider->rangeCursor;

    CFIndex end = block->start + block->count;
    CFDictionaryRef served = block->attributes;
    if (provider->rangeCursor < provider->rangeCount) {
        const wk_rightToLeftRange *range = &provider->ranges[provider->rangeCursor];
        if (range->start <= stringIndex && served) {
            if (range->end < end)
                end = range->end;
            CFDictionaryRef source = CFDictionaryGetValue(served, kCTFontAttributeName) == range->font ? served : wk_clusterFontAttributes(&provider->base, served, range->font);
            served = wk_shapingAttributes(&provider->base, source, wk_shapingFont(range->font, true));
        } else if (range->start > stringIndex && range->start < end)
            end = range->start;
    }
    if (provider->base.dispose)
        ++provider->base.outstandingBlocks;
    *charCount = end - stringIndex;
    *attributes = served;
    return block->characters + (stringIndex - block->start);
}

static void wk_replayProviderRelease(wk_replayProvider *provider)
{
    wk_clusterFontProviderRelease(&provider->base);
    free(provider->blocks);
}

static void wk_replayDispose(const UniChar *characters, void *refCon)
{
    wk_replayProvider *provider = (wk_replayProvider *)refCon;
    for (CFIndex i = 0; i < provider->blockCount; ++i) {
        if (!provider->blocks[i].disposeForwarded && provider->blocks[i].characters == characters) {
            provider->blocks[i].disposeForwarded = true;
            if (provider->base.forwardsDispose)
                provider->base.dispose(characters, provider->base.refCon);
            break;
        }
    }
    if (!--provider->base.outstandingBlocks && provider->base.creationFinished) {
        wk_replayProviderRelease(provider);
        free(provider);
    }
}

static wk_replayProvider *wk_replayProviderBegin(wk_replayProvider *local, wk_clusterFontProvider *reader, const wk_rightToLeftRange *ranges, CFIndex rangeCount)
{
    *local = (wk_replayProvider) {
        .base = { .dispose = reader->dispose, .refCon = reader->refCon, .forwardsDispose = true },
        .blockCount = reader->servedCount,
        .ranges = ranges,
        .rangeCount = rangeCount,
    };
    local->blocks = (wk_servedBlock *)malloc((size_t)(reader->servedCount + 1) * sizeof(wk_servedBlock));
    if (!local->blocks)
        abort();
    memcpy(local->blocks, wk_servedBlocks(reader), (size_t)reader->servedCount * sizeof(wk_servedBlock));
    if (!local->base.dispose)
        return local;
    wk_replayProvider *provider = (wk_replayProvider *)malloc(sizeof(*provider));
    if (!provider)
        abort();
    *provider = *local;
    return provider;
}

// After CoreText has made what it makes from the provider. A provider with a dispose callback lives until
// its last block is disposed of, and the caller may still stop it forwarding until then.
static void wk_replayProviderEnd(wk_replayProvider *provider)
{
    provider->ranges = NULL;
    provider->rangeCount = 0;
    if (!provider->base.dispose) {
        wk_replayProviderRelease(provider);
        return;
    }
    provider->base.creationFinished = true;
    if (!provider->base.outstandingBlocks) {
        wk_replayProviderRelease(provider);
        free(provider);
    }
}

static CFTypeRef wk_createFromReplay(wk_naturalKind kind, wk_replayProvider *provider, CFDictionaryRef options)
{
    CTUniCharDisposeCallback dispose = provider->base.dispose ? wk_replayDispose : NULL;
    if (kind == WKNaturalLine)
        return WK_ORIGINAL(CTLineCreateWithUniCharProvider)(wk_replayProvide, dispose, provider);
    return WK_ORIGINAL(CTTypesetterCreateWithUniCharProviderAndOptions)(wk_replayProvide, dispose, provider, options);
}

// Attributed-string clients use the same installed-font GPOS instances as character providers.
static CFAttributedStringRef wk_copyWithShapingFonts(CFAttributedStringRef string)
{
    CFMutableAttributedStringRef copy = NULL;
    CFIndex length = CFAttributedStringGetLength(string);
    for (CFIndex i = 0; i < length;) {
        CFRange range;
        CFDictionaryRef attributes = CFAttributedStringGetAttributes(string, i, &range);
        CTFontRef font = (CTFontRef)CFDictionaryGetValue(attributes, kCTFontAttributeName);
        if (font && CFGetTypeID(font) == CTFontGetTypeID() && wk_fontUsesSystemFallbackOnly(font)) {
            UniChar *characters = malloc((size_t)range.length * sizeof(UniChar));
            if (!characters)
                abort();
            CFStringGetCharacters(CFAttributedStringGetString(string), range, characters);
            wk_clusterFontProvider provider = { 0 };
            for (CFIndex offset = 0; offset < range.length;) {
                CFIndex count = range.length - offset;
                CFDictionaryRef selected = attributes;
                wk_serveBlock(&provider, characters + offset, &count, &selected);
                if (selected != attributes) {
                    if (!copy)
                        copy = CFAttributedStringCreateMutableCopy(kCFAllocatorDefault, 0, string);
                    CFAttributedStringSetAttributes(copy, CFRangeMake(range.location + offset, count), selected, true);
                }
                offset += count;
            }
            wk_clusterFontProviderRelease(&provider);
            free(characters);
            i = range.location + range.length;
            continue;
        }
        CTFontRef shaping = font && CFGetTypeID(font) == CTFontGetTypeID() ? wk_shapingFont(font, false) : NULL;
        if (shaping) {
            if (!copy)
                copy = CFAttributedStringCreateMutableCopy(kCFAllocatorDefault, 0, string);
            CFAttributedStringSetAttribute(copy, range, kCTFontAttributeName, shaping);
            CFAttributedStringSetAttribute(copy, range, wk_sourceAttributesKey(), attributes);
        }
        i = range.location + range.length;
    }
    return copy;
}

WK_POLYFILL_REPLACES("CoreText", CTLineRef, CTLineCreateWithAttributedString, (CFAttributedStringRef string))
{
    CFAttributedStringRef copy = string ? wk_copyWithShapingFonts(string) : NULL;
    CTLineRef line = WK_ORIGINAL(CTLineCreateWithAttributedString)(copy ? copy : string);
    if (copy)
        CFRelease(copy);
    return line;
}

WK_POLYFILL_REPLACES("CoreText", CTTypesetterRef, CTTypesetterCreateWithAttributedStringAndOptions,
    (CFAttributedStringRef string, CFDictionaryRef options))
{
    CFAttributedStringRef copy = string ? wk_copyWithShapingFonts(string) : NULL;
    CTTypesetterRef typesetter = WK_ORIGINAL(CTTypesetterCreateWithAttributedStringAndOptions)(copy ? copy : string, options);
    if (copy)
        CFRelease(copy);
    return typesetter;
}

static CFTypeRef wk_createFromAttributedString(wk_naturalKind kind, CFAttributedStringRef string, CFDictionaryRef options)
{
    if (kind == WKNaturalLine)
        return CTLineCreateWithAttributedString(string);
    return CTTypesetterCreateWithAttributedStringAndOptions(string, options);
}

static wk_rightToLeftRange *wk_copyLogicalOrderRanges(wk_naturalKind kind, CFTypeRef made, wk_clusterFontProvider *reader, CFIndex *rangeCount)
{
    if (!made)
        return NULL;
    if (kind == WKNaturalLine)
        return wk_copyLogicalOrderRightToLeftRanges(reader, (CTLineRef)made, rangeCount);
    // A typesetter's levels are its paragraphs' and do not depend on where lines break.
    CTLineRef line = CTTypesetterCreateLine((CTTypesetterRef)made, CFRangeMake(0, 0));
    if (!line)
        return NULL;
    wk_rightToLeftRange *ranges = wk_copyLogicalOrderRightToLeftRanges(reader, line, rangeCount);
    CFRelease(line);
    return ranges;
}

static CFTypeRef wk_createNaturalDirection(wk_naturalKind kind, CTUniCharProviderCallback provide, CTUniCharDisposeCallback dispose, void *refCon, CFDictionaryRef options)
{
    wk_clusterFontProvider reader = { .provide = provide, .dispose = dispose, .refCon = refCon, .recordsServedBlocks = true };
    for (CFIndex index = 0;;) {
        CFIndex count = 0;
        CFDictionaryRef attributes = NULL;
        if (!wk_clusterFontProvide(index, &count, &attributes, &reader) || count <= 0)
            break;
        index += count;
    }
    wk_providedText text;
    wk_providedTextInit(&text, &reader);
    UBiDiLevel *levels = NULL;
    wk_levelResolution resolution = wk_resolveLevels(&reader, &text, &levels);

    CFTypeRef made;
    if (resolution != WKLevelsExplicit) {
        wk_replayProvider storage;
        wk_replayProvider *provider = wk_replayProviderBegin(&storage, &reader, NULL, 0);
        made = wk_createFromReplay(kind, provider, options);
        wk_replayProviderEnd(provider);
        CFIndex rangeCount = 0;
        wk_rightToLeftRange *ranges = resolution == WKLevelsCurrent ? wk_copyLogicalOrderRanges(kind, made, &reader, &rangeCount) : NULL;
        if (ranges) {
            wk_replayProvider shapingStorage;
            wk_replayProvider *shaping = wk_replayProviderBegin(&shapingStorage, &reader, ranges, rangeCount);
            CFTypeRef shaped = wk_createFromReplay(kind, shaping, options);
            wk_replayProviderEnd(shaping);
            free(ranges);
            if (dispose)
                provider->base.forwardsDispose = false;
            CFRelease(made);
            made = shaped;
        }
    } else {
        CFAttributedStringRef string = wk_createExplicitLevelString(&reader, &text, levels, NULL, 0);
        made = wk_createFromAttributedString(kind, string, options);
        CFRelease(string);
        CFIndex rangeCount = 0;
        wk_rightToLeftRange *ranges = wk_copyLogicalOrderRanges(kind, made, &reader, &rangeCount);
        if (ranges) {
            string = wk_createExplicitLevelString(&reader, &text, levels, ranges, rangeCount);
            CFTypeRef shaped = wk_createFromAttributedString(kind, string, options);
            CFRelease(string);
            free(ranges);
            if (made)
                CFRelease(made);
            made = shaped;
        }
        free(levels);
        // The attributed string holds its own copy of the text.
        if (dispose) {
            wk_servedBlock *blocks = wk_servedBlocks(&reader);
            for (CFIndex i = 0; i < reader.servedCount; ++i)
                dispose(blocks[i].characters, refCon);
        }
    }
    free(text.copy);
    wk_clusterFontProviderRelease(&reader);
    return made;
}

// A forced right-to-left level sets the blocks CoreText reads in a font with logical-order subtables in that
// font's shaping font as they are read. Where CoreText sets some of the text in a fallback font instead, the
// runs it set in a font with logical-order subtables are set again in their shaping font.
static CTTypesetterRef wk_createForcedLevelTypesetter(CTUniCharProviderCallback provide, CTUniCharDisposeCallback dispose, void *refCon, CFDictionaryRef options, int level)
{
    bool rightToLeft = level & 1;
    wk_clusterFontProvider local = { .provide = provide, .dispose = dispose, .refCon = refCon,
        .rightToLeft = rightToLeft, .recordsServedBlocks = rightToLeft, .forwardsDispose = true };
    wk_clusterFontProvider *provider = wk_clusterFontProviderBegin(&local);
    CTTypesetterRef typesetter = WK_ORIGINAL(CTTypesetterCreateWithUniCharProviderAndOptions)(wk_clusterFontProvide,
        dispose ? wk_clusterFontDispose : NULL, provider, options);
    CFIndex rangeCount = 0;
    wk_rightToLeftRange *ranges = typesetter && provider->fallsBack ? wk_copyLogicalOrderRanges(WKNaturalTypesetter, typesetter, provider, &rangeCount) : NULL;
    if (ranges) {
        wk_replayProvider storage;
        wk_replayProvider *shaping = wk_replayProviderBegin(&storage, provider, ranges, rangeCount);
        CTTypesetterRef shaped = (CTTypesetterRef)wk_createFromReplay(WKNaturalTypesetter, shaping, options);
        wk_replayProviderEnd(shaping);
        free(ranges);
        provider->forwardsDispose = false;
        CFRelease(typesetter);
        typesetter = shaped;
    }
    wk_clusterFontProviderEnd(provider);
    return typesetter;
}
