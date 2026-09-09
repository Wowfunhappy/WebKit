// CoreText: entry points and constants modern WebKit references that 10.9's CoreText does not
// export, or exports with behaviour that has to be replaced.
#include "wk_polyfill.h"
#include "wk_helpers.h"
#include "VariableFontInstancer.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <CoreText/SFNTLayoutTypes.h>
#include <jpeglib.h>
#include <math.h>
#include <png.h>
#include <setjmp.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <tiffio.h>

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
// carries an sbix table the same distance low, so the two replacements at the end of this file draw
// and measure colour-bitmap glyphs from the record and the outline instead.
// A strike's payload is font bytes, and a font is downloadable, so these are page-controlled bytes.
// They decode through the same libpng, libjpeg and libtiff WebCore decodes every other image with,
// never through CGImageSourceCreateWithData: nothing in this port hands page bytes to 10.9's ImageIO.
typedef struct {
    const uint8_t *bytes;
    size_t length;
    size_t offset;
} WKSbixSource;

static void wk_sbixPixelsRelease(void *info, const void *data, size_t size) { (void)data; (void)size; free(info); }

// Present on this OS, declared 10.12 in the SDK this builds against.
WK_SYSTEM_FN("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithICCData, (CFTypeRef));

// The strike's own colour space when it carries an ICC profile, sRGB otherwise. 10.10+ CoreText
// paints an sbix strike through the profile ImageIO attaches to the image, so a profiled strike
// tagged sRGB here would draw in the wrong colours. Only a three-component profile describes the
// RGBA the decoders below produce; a strike that carries any other kind is drawn as sRGB.
static CGColorSpaceRef wk_sbixColorSpace(const uint8_t *profile, size_t profileLength)
{
    if (profile && profileLength) {
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)profile, (CFIndex)profileLength);
        if (data) {
            CGColorSpaceRef space = WK_SYSTEM(CGColorSpaceCreateWithICCData)
                ? WK_SYSTEM(CGColorSpaceCreateWithICCData)(data) : NULL;
            CFRelease(data);
            if (space) {
                if (CGColorSpaceGetNumberOfComponents(space) == 3)
                    return space;
                CGColorSpaceRelease(space);
            }
        }
    }
    return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
}

// Takes ownership of pixels and space either way. Premultiplies unless the decoder already did,
// because CGImageCreate below is told the alpha is premultiplied, which is what a drawn glyph needs.
static CGImageRef wk_sbixImageFromRGBA(uint8_t *pixels, size_t width, size_t height,
                                       CGColorSpaceRef space, bool premultiplied)
{
    size_t stride = width * 4;
    CGDataProviderRef provider = pixels && space ? CGDataProviderCreateWithData(pixels, pixels, height * stride, wk_sbixPixelsRelease) : NULL;
    if (!provider) {
        free(pixels);
        if (space)
            CGColorSpaceRelease(space);
        return NULL;
    }
    if (!premultiplied) {
        for (size_t i = 0; i < height * stride; i += 4) {
            uint8_t alpha = pixels[i + 3];
            if (alpha == 255)
                continue;
            pixels[i] = (uint8_t)((pixels[i] * alpha + 127) / 255);
            pixels[i + 1] = (uint8_t)((pixels[i + 1] * alpha + 127) / 255);
            pixels[i + 2] = (uint8_t)((pixels[i + 2] * alpha + 127) / 255);
        }
    }
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, space,
                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault,
                                     provider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return image;
}

// Four bytes a pixel and a row pointer each, both of which have to be expressible. Bounded by what
// the buffer can address rather than by a chosen maximum.
static bool wk_sbixUsableDimensions(size_t width, size_t height)
{
    return width && height && height <= SIZE_MAX / sizeof(void *) && width <= (SIZE_MAX / 4) / height;
}

static void wk_sbixPNGRead(png_structp png, png_bytep out, png_size_t count)
{
    WKSbixSource *source = (WKSbixSource *)png_get_io_ptr(png);
    if (!source || count > source->length - source->offset) {
        png_error(png, "truncated");
        return;
    }
    memcpy(out, source->bytes + source->offset, count);
    source->offset += count;
}

static void wk_sbixPNGError(png_structp png, png_const_charp message)
{
    (void)message;
    longjmp(png_jmpbuf(png), 1);
}

static void wk_sbixPNGWarning(png_structp png, png_const_charp message) { (void)png; (void)message; }

static CGImageRef wk_sbixDecodePNG(const uint8_t *bytes, size_t length)
{
    if (!bytes || length < 8 || png_sig_cmp((png_const_bytep)bytes, 0, 8))
        return NULL;

    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, wk_sbixPNGError, wk_sbixPNGWarning);
    if (!png)
        return NULL;
    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, NULL, NULL);
        return NULL;
    }

    // The two locals the longjmp branch reads are volatile: C leaves an ordinary automatic that is
    // modified between setjmp and longjmp indeterminate there. The image is assembled after the last
    // call that can longjmp, so ownership of the pixels never moves inside this region.
    uint8_t * volatile pixels = NULL;
    png_bytep * volatile rows = NULL;
    if (setjmp(png_jmpbuf(png))) {
        free(pixels);
        free(rows);
        png_destroy_read_struct(&png, &info, NULL);
        return NULL;
    }

    WKSbixSource source = { bytes, length, 0 };
    png_set_read_fn(png, &source, wk_sbixPNGRead);
    png_read_info(png, info);

    png_uint_32 width = 0, height = 0;
    int depth = 0, colorType = 0;
    png_get_IHDR(png, info, &width, &height, &depth, &colorType, NULL, NULL, NULL);
    if (!wk_sbixUsableDimensions(width, height))
        png_error(png, "unusable dimensions");

    png_charp profileName = NULL;
    png_bytep profile = NULL;
    png_uint_32 profileLength = 0;
    int profileCompression = 0;
    if (!png_get_iCCP(png, info, &profileName, &profileCompression, &profile, &profileLength)) {
        profile = NULL;
        profileLength = 0;
    }

    // Whatever the file holds, in 8-bit RGBA.
    if (colorType == PNG_COLOR_TYPE_PALETTE)
        png_set_palette_to_rgb(png);
    if (colorType == PNG_COLOR_TYPE_GRAY && depth < 8)
        png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS))
        png_set_tRNS_to_alpha(png);
    if (depth == 16)
        png_set_strip_16(png);
    if (colorType == PNG_COLOR_TYPE_GRAY || colorType == PNG_COLOR_TYPE_GRAY_ALPHA)
        png_set_gray_to_rgb(png);
    png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    png_set_interlace_handling(png);
    png_read_update_info(png, info);
    if (png_get_rowbytes(png, info) != (png_size_t)width * 4)
        png_error(png, "not four channels");

    size_t stride = (size_t)width * 4;
    pixels = (uint8_t *)calloc(height, stride);
    rows = (png_bytep *)calloc(height, sizeof(png_bytep));
    if (!pixels || !rows)
        png_error(png, "no space");
    for (png_uint_32 y = 0; y < height; ++y)
        rows[y] = pixels + (size_t)y * stride;
    png_read_image(png, rows);
    png_read_end(png, NULL);

    // Built while the read struct that owns the profile bytes is still alive.
    CGColorSpaceRef space = wk_sbixColorSpace(profile, profileLength);
    uint8_t *owned = pixels;
    pixels = NULL;
    free(rows);
    rows = NULL;
    png_destroy_read_struct(&png, &info, NULL);
    return wk_sbixImageFromRGBA(owned, width, height, space, false);
}

typedef struct {
    struct jpeg_error_mgr base;
    jmp_buf escape;
} WKSbixJPEGError;

static void wk_sbixJPEGFail(j_common_ptr cinfo) { longjmp(((WKSbixJPEGError *)cinfo->err)->escape, 1); }
static void wk_sbixJPEGSilent(j_common_ptr cinfo) { (void)cinfo; }

static CGImageRef wk_sbixDecodeJPEG(const uint8_t *bytes, size_t length)
{
    if (!bytes || length < 4)
        return NULL;

    struct jpeg_decompress_struct cinfo;
    WKSbixJPEGError error;
    memset(&cinfo, 0, sizeof(cinfo));
    cinfo.err = jpeg_std_error(&error.base);
    error.base.error_exit = wk_sbixJPEGFail;
    error.base.output_message = wk_sbixJPEGSilent;

    uint8_t * volatile pixels = NULL;
    JSAMPROW * volatile rows = NULL;
    JOCTET * volatile profile = NULL;
    if (setjmp(error.escape)) {
        free(pixels);
        free(rows);
        free(profile);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_save_markers(&cinfo, JPEG_APP0 + 2, 0xFFFF);
    jpeg_mem_src(&cinfo, bytes, (unsigned long)length);
    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK)
        longjmp(error.escape, 1);

    // libjpeg converts grayscale and YCbCr to RGB itself, but neither CMYK nor YCCK, so those come
    // out as four-component CMYK and are converted below. Either way four bytes a pixel.
    bool cmyk = cinfo.jpeg_color_space == JCS_CMYK || cinfo.jpeg_color_space == JCS_YCCK;
    cinfo.out_color_space = cmyk ? JCS_CMYK : JCS_EXT_RGBX;
    jpeg_start_decompress(&cinfo);
    if (cinfo.output_components != 4 || !wk_sbixUsableDimensions(cinfo.output_width, cinfo.output_height))
        longjmp(error.escape, 1);

    size_t width = cinfo.output_width, height = cinfo.output_height, stride = width * 4;
    pixels = (uint8_t *)calloc(height, stride);
    rows = (JSAMPROW *)calloc(height, sizeof(JSAMPROW));
    if (!pixels || !rows)
        longjmp(error.escape, 1);
    for (size_t y = 0; y < height; ++y)
        rows[y] = (JSAMPROW)(pixels + y * stride);
    while (cinfo.output_scanline < cinfo.output_height)
        jpeg_read_scanlines(&cinfo, &rows[cinfo.output_scanline], cinfo.output_height - cinfo.output_scanline);
    // Inverted CMYK to RGB: R = iC*iK/255, and G and B likewise (Source/WebCore/platform/
    // image-decoders/jpeg/JPEGImageDecoder.cpp). Otherwise only the fourth byte needs filling, which
    // libjpeg-turbo leaves undefined for the RGBX spellings.
    for (size_t i = 0; i < height * stride; i += 4) {
        if (cmyk) {
            unsigned k = pixels[i + 3];
            pixels[i] = (uint8_t)(pixels[i] * k / 255);
            pixels[i + 1] = (uint8_t)(pixels[i + 1] * k / 255);
            pixels[i + 2] = (uint8_t)(pixels[i + 2] * k / 255);
        }
        pixels[i + 3] = 0xFF;
    }

    unsigned int profileLength = 0;
    JOCTET *readProfile = NULL;
    if (jpeg_read_icc_profile(&cinfo, &readProfile, &profileLength))
        profile = readProfile;
    jpeg_finish_decompress(&cinfo);

    CGColorSpaceRef space = wk_sbixColorSpace(profile, profileLength);
    uint8_t *owned = pixels;
    pixels = NULL;
    free(rows);
    rows = NULL;
    free(profile);
    profile = NULL;
    jpeg_destroy_decompress(&cinfo);
    return wk_sbixImageFromRGBA(owned, width, height, space, true);
}

static tmsize_t wk_sbixTIFFRead(thandle_t handle, void *buffer, tmsize_t count)
{
    WKSbixSource *source = (WKSbixSource *)handle;
    if (count < 0 || (size_t)count > source->length - source->offset)
        count = (tmsize_t)(source->length - source->offset);
    memcpy(buffer, source->bytes + source->offset, (size_t)count);
    source->offset += (size_t)count;
    return count;
}

static tmsize_t wk_sbixTIFFWrite(thandle_t handle, void *buffer, tmsize_t count)
{
    (void)handle; (void)buffer; (void)count;
    return 0;
}

static toff_t wk_sbixTIFFSeek(thandle_t handle, toff_t offset, int whence)
{
    WKSbixSource *source = (WKSbixSource *)handle;
    uint64_t base = whence == SEEK_CUR ? source->offset : (whence == SEEK_END ? source->length : 0);
    uint64_t wanted = base + offset;
    if (wanted > source->length)
        wanted = source->length;
    source->offset = (size_t)wanted;
    return (toff_t)source->offset;
}

static int wk_sbixTIFFClose(thandle_t handle) { (void)handle; return 0; }
static toff_t wk_sbixTIFFSize(thandle_t handle) { return (toff_t)((WKSbixSource *)handle)->length; }

// The strike is already a contiguous span of the font, so libtiff reads an uncompressed tile
// straight out of it rather than through a staging buffer of its own.
static int wk_sbixTIFFMap(thandle_t handle, void **base, toff_t *size)
{
    WKSbixSource *source = (WKSbixSource *)handle;
    *base = (void *)source->bytes;
    *size = (toff_t)source->length;
    return 1;
}

static void wk_sbixTIFFUnmap(thandle_t handle, void *base, toff_t size) { (void)handle; (void)base; (void)size; }

// Per handle rather than libtiff's process-global setters: WebCore's own TIFF decoder shares this
// vendored copy, and a strike that will not decode is this function's answer, not a line on the
// process's stderr. Returning 1 tells libtiff the diagnostic is handled.
static int wk_sbixTIFFSilent(TIFF *tiff, void *context, const char *module, const char *format, va_list arguments)
{
    (void)tiff; (void)context; (void)module; (void)format; (void)arguments;
    return 1;
}

static CGImageRef wk_sbixDecodeTIFF(const uint8_t *bytes, size_t length)
{
    if (!bytes || length < 8)
        return NULL;

    TIFFOpenOptions *options = TIFFOpenOptionsAlloc();
    if (!options)
        return NULL;
    TIFFOpenOptionsSetErrorHandlerExtR(options, wk_sbixTIFFSilent, NULL);
    TIFFOpenOptionsSetWarningHandlerExtR(options, wk_sbixTIFFSilent, NULL);

    WKSbixSource source = { bytes, length, 0 };
    TIFF *tiff = TIFFClientOpenExt("sbix", "r", (thandle_t)&source, wk_sbixTIFFRead, wk_sbixTIFFWrite,
                                   wk_sbixTIFFSeek, wk_sbixTIFFClose, wk_sbixTIFFSize,
                                   wk_sbixTIFFMap, wk_sbixTIFFUnmap, options);
    TIFFOpenOptionsFree(options);
    if (!tiff)
        return NULL;

    uint32_t width = 0, height = 0;
    TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
    TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);
    if (!wk_sbixUsableDimensions(width, height)) {
        TIFFClose(tiff);
        return NULL;
    }

    size_t stride = (size_t)width * 4;
    uint8_t *pixels = (uint8_t *)calloc(height, stride);
    // The raster is uint32 per pixel, which on this architecture lays the channels down as RGBA, and
    // TIFFReadRGBAImageOriented always returns alpha already associated with the colour.
    if (!pixels || !TIFFReadRGBAImageOriented(tiff, width, height, (uint32_t *)pixels, ORIENTATION_TOPLEFT, 0)) {
        free(pixels);
        TIFFClose(tiff);
        return NULL;
    }

    uint32_t profileLength = 0;
    void *profile = NULL;
    if (!TIFFGetField(tiff, TIFFTAG_ICCPROFILE, &profileLength, &profile))
        profile = NULL;
    CGColorSpaceRef space = wk_sbixColorSpace((const uint8_t *)profile, profile ? profileLength : 0);
    TIFFClose(tiff);
    return wk_sbixImageFromRGBA(pixels, width, height, space, true);
}

// The strike image for a record, in each of the graphic types the sbix format defines for one.
static CGImageRef wk_sbixDecodeStrike(uint32_t graphicType, const uint8_t *bytes, size_t length)
{
    switch (graphicType) {
    case 'png ':
        return wk_sbixDecodePNG(bytes, length);
    case 'jpg ':
        return wk_sbixDecodeJPEG(bytes, length);
    case 'tiff':
        return wk_sbixDecodeTIFF(bytes, length);
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
static size_t wk_sbixRunGroup(CTFontRef font, const CGGlyph *glyphs, size_t count, size_t from, bool *outBitmap)
{
    pthread_mutex_lock(&wkSbixLock);
    CGFloat pointSize = CTFontGetSize(font);
    bool bitmap = wk_sbixBitmap(font, glyphs[from], pointSize, NULL, NULL);
    size_t next = from + 1;
    while (next < count && wk_sbixBitmap(font, glyphs[next], pointSize, NULL, NULL) == bitmap)
        ++next;
    pthread_mutex_unlock(&wkSbixLock);
    *outBitmap = bitmap;
    return next;
}

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

// One colour-bitmap glyph, in the coordinate system CoreText draws glyphs in: the text matrix on top
// of the context's own transform, with the position as the pen. The image carries its own colour, so
// the fill and stroke the context holds do not reach it, and neither does the text drawing mode.
static void wk_drawSbixGlyph(CTFontRef font, CGGlyph glyph, CGPoint position, CGContextRef context)
{
    CGAffineTransform textMatrix = CGContextGetTextMatrix(context);
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

// CTFontCreateForCharactersWithLanguageAndOption (10.13+): the option only restricts fallback to
// system (non-user-installed) fonts. The classic CTFontCreateForCharactersWithLanguage returns the
// same fallback font on 10.9 and is present there. The face it returns is cut at the current font's
// scale, so it carries what that font's caller named for size and matrix — see the size-0 machinery
// below, whose record this is the one derivation point that can hand on.
static CTFontRef wk_inheritFontRequest(CTFontRef font, CTFontRef source);
WK_SYSTEM_FN("CoreText", bool, CTFontManagerRegisterFontsForURLs, (CFArrayRef, CTFontManagerScope, CFArrayRef *));
WK_SYSTEM_FN("CoreText", CFArrayRef, CTFontManagerCreateFontDescriptorsFromURL, (CFURLRef));
WK_SYSTEM_FN("CoreText", void, CTFontManagerEnableFontDescriptors, (CFArrayRef, bool));

WK_POLYFILL_ABSENT("CoreText", CTFontRef, CTFontCreateForCharactersWithLanguageAndOption,
    (CTFontRef currentFont, const UTF16Char *characters, CFIndex length, CFStringRef language, unsigned long option, CFIndex *coveredLength))
{
    (void)option;
    return wk_inheritFontRequest(CTFontCreateForCharactersWithLanguage(currentFont, characters, length,
                                                                      language, coveredLength), currentFont);
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

// CTFontManagerCreateFontDescriptorFromData — a DELIBERATE REPLACEMENT of a present-but-broken 10.9
// function. The 10.9 implementation returns
// descriptors that crash when realized: TFontFeatures loading (TBaseFont::CopyFeatures →
// CreateFontWithFontURL) message-sends a freed object for many downloaded fonts (DDG and
// others). Descriptors built from a CGFont avoid TFontFeatures setup entirely, so the
// replacement round-trips the data through CGFontCreateWithDataProvider →
// CTFontCreateWithGraphicsFont → CTFontCopyFontDescriptor. Costs on this path (accepted):
// CTFontCopyVariationAxes returns null and font-feature-settings are skipped.
// Data a CGFont cannot parse falls through to the real CoreText implementation so exotic
// inputs keep exact system behavior.
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

WK_POLYFILL_REPLACES("CoreText", CTFontDescriptorRef, CTFontManagerCreateFontDescriptorFromData, (CFDataRef data))
{
    if (data) {
        bool variable = wk_legacy_variable_font_is_instanceable(data);
        CFDataRef master = variable ? wk_legacy_variable_font_strip_variations(data) : (CFDataRef)CFRetain(data);
        CGDataProviderRef provider = master ? CGDataProviderCreateWithCFData(master) : NULL;
        if (master)
            CFRelease(master);
        if (provider) {
            CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
            CGDataProviderRelease(provider);
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
                        CFDictionarySetValue(source, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY, data);
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
    }
    return WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)
        ? WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)(data) : NULL;
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
static CFTypeRef wk_carriedAttribute(CTFontDescriptorRef descriptor, CFStringRef key);

static CTFontRef wk_realizeVariableFontInstance(CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix)
{
    if (!descriptor)
        return NULL;
    // The key is one only descriptors this layer minted carry, so it is read off the descriptor's own
    // attributes; CTFontDescriptorCopyAttribute would answer it by matching, per realization, for the
    // overwhelming majority of descriptors that lack it.
    CFDataRef sourceData = (CFDataRef)wk_carriedAttribute(descriptor, WK_LEGACY_VARIABLE_FONT_SOURCE_KEY);
    if (!sourceData)
        return NULL;

    CTFontRef font = NULL;
    CFDictionaryRef variations = (CFDictionaryRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontVariationAttribute);
    CFDataRef instance = wk_legacy_variable_font_instance(sourceData, variations);
    if (instance) {
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(instance);
        if (provider) {
            CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
            CGDataProviderRelease(provider);
            if (cgFont) {
                CTFontDescriptorRef carriedOver = wk_descriptorAttributesToCarryOver(descriptor);
                font = CTFontCreateWithGraphicsFont(cgFont, wk_sizeForRealizedFont(descriptor, size), matrix, carriedOver);
                if (carriedOver)
                    CFRelease(carriedOver);
                CGFontRelease(cgFont);
            }
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
//
// kCTFontUserInstalledAttribute answers whether a font was installed onto this system rather than
// shipped with it. 10.9's CoreText has no such attribute -- the key above is this layer's -- and the
// font's own URL is where its provenance is recorded. This OS ships its faces in two directories:
// /System/Library/Fonts holds the system and UI faces, /Library/Fonts the other 231 it installs
// (Andale Mono, PT Mono, Osaka-Mono, Courier New, Arial and the rest). A font installed afterwards
// lives elsewhere -- ~/Library/Fonts, /Network/Library/Fonts, a file registered at runtime -- and a
// font built from data carries no URL at all, having never been installed from a file. Defined after
// the replacement below, which is where the URL lookup reaches CoreText's own implementation.
static bool wk_fontIsUserInstalled(CTFontRef font);

WK_POLYFILL_REPLACES("CoreText", CFTypeRef, CTFontCopyAttribute, (CTFontRef font, CFStringRef attribute))
{
    if (font && attribute && CFEqual(attribute, kCTFontUserInstalledAttribute))
        return CFRetain(wk_fontIsUserInstalled(font) ? (CFTypeRef)kCFBooleanTrue : (CFTypeRef)kCFBooleanFalse);

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

static bool wk_fontIsUserInstalled(CTFontRef font)
{
    if (!WK_ORIGINAL(CTFontCopyAttribute))
        return false;
    CFTypeRef url = WK_ORIGINAL(CTFontCopyAttribute)(font, kCTFontURLAttribute);
    if (!url)
        return true;
    bool shippedWithTheSystem = false;
    if (CFGetTypeID(url) == CFURLGetTypeID()) {
        CFStringRef path = CFURLCopyFileSystemPath((CFURLRef)url, kCFURLPOSIXPathStyle);
        if (path) {
            shippedWithTheSystem = CFStringHasPrefix(path, CFSTR("/System/Library/Fonts/"))
                || CFStringHasPrefix(path, CFSTR("/Library/Fonts/"));
            CFRelease(path);
        }
    }
    CFRelease(url);
    return !shippedWithTheSystem;
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
    CGAffineTransform composed;
    wk_optical_size_request opticalSize = wk_opticalSizeRequest(descriptor);
    CTFontDescriptorRef resolved = opticalSize == WK_OPTICAL_SIZE_POINT_SIZE
        ? wk_descriptorWithOpticalSize(descriptor, wk_resolvedPointSize(descriptor, size, 12.0)) : NULL;
    if (resolved)
        descriptor = resolved;
    matrix = wk_fontMatrixForRequest(wk_descriptorScalesToNothing(descriptor), descriptor, size, matrix, NULL, &composed);
    CTFontRef instance = wk_realizeVariableFontInstance(descriptor, size, matrix);
    if (!instance) {
        CTFontDescriptorRef realizable = wk_realizableDescriptor(descriptor);
        instance = WK_ORIGINAL(CTFontCreateWithFontDescriptor)
            ? WK_ORIGINAL(CTFontCreateWithFontDescriptor)(realizable ? realizable : descriptor, size, matrix) : NULL;
        if (realizable)
            CFRelease(realizable);
        instance = wkApplyTraitsToFace(instance, descriptor);
    }
    if (resolved)
        CFRelease(resolved);
    if (opticalSize == WK_OPTICAL_SIZE_POINT_SIZE)
        wk_markOpticalSizeFollowsPointSize(instance);
    return wk_recordFontRequest(instance, size, requested);
}

WK_POLYFILL_REPLACES("CoreText", CTFontRef, CTFontCreateWithFontDescriptorAndOptions,
                     (CTFontDescriptorRef descriptor, CGFloat size, const CGAffineTransform *matrix, CFOptionFlags options))
{
    const CGAffineTransform *requested = matrix;
    CGAffineTransform composed;
    wk_optical_size_request opticalSize = wk_opticalSizeRequest(descriptor);
    CTFontDescriptorRef resolved = opticalSize == WK_OPTICAL_SIZE_POINT_SIZE
        ? wk_descriptorWithOpticalSize(descriptor, wk_resolvedPointSize(descriptor, size, 12.0)) : NULL;
    if (resolved)
        descriptor = resolved;
    matrix = wk_fontMatrixForRequest(wk_descriptorScalesToNothing(descriptor), descriptor, size, matrix, NULL, &composed);
    CTFontRef instance = wk_realizeVariableFontInstance(descriptor, size, matrix);
    if (!instance) {
        CTFontDescriptorRef realizable = wk_realizableDescriptor(descriptor);
        instance = WK_ORIGINAL(CTFontCreateWithFontDescriptorAndOptions)
            ? WK_ORIGINAL(CTFontCreateWithFontDescriptorAndOptions)(realizable ? realizable : descriptor, size, matrix, options) : NULL;
        if (realizable)
            CFRelease(realizable);
        instance = wkApplyTraitsToFace(instance, descriptor);
    }
    if (resolved)
        CFRelease(resolved);
    if (opticalSize == WK_OPTICAL_SIZE_POINT_SIZE)
        wk_markOpticalSizeFollowsPointSize(instance);
    return wk_recordFontRequest(instance, size, requested);
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
    wk_font_request source;
    bool haveSource = wk_recordedFontRequest(font, &source);
    const CGAffineTransform *requested = matrix ? matrix : (haveSource ? &source.matrix : NULL);
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
    CTFontRef copy = WK_ORIGINAL(CTFontCreateCopyWithAttributes)
        ? WK_ORIGINAL(CTFontCreateCopyWithAttributes)(font, size, matrix, attributes) : NULL;
    copy = wkApplyTraitsToFace(copy, attributes);
    if (resolved)
        CFRelease(resolved);
    if (opticalSize == WK_OPTICAL_SIZE_POINT_SIZE)
        wk_markOpticalSizeFollowsPointSize(copy);
    return wk_recordFontRequest(copy, size, requested);
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
    return wk_recordFontRequest(WK_ORIGINAL(CTFontCreateWithGraphicsFont)
        ? WK_ORIGINAL(CTFontCreateWithGraphicsFont)(font, size, matrix, attributes) : NULL, size, matrix);
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
    if (value || !descriptor || !attribute)
        return value;
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

// The settings a feature-settings value names, as the AAT dictionaries 10.9's parser reads. A value that
// is not an array names none of them; clear directives are not settings and are collected separately.
static CFArrayRef wk_featureSettingsAsAAT(CFTypeRef settings)
{
    CFMutableArrayRef result = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!result || !settings || CFGetTypeID(settings) != CFArrayGetTypeID())
        return result;
    CFArrayRef array = (CFArrayRef)settings;
    CFIndex count = CFArrayGetCount(array);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef element = CFArrayGetValueAtIndex(array, i);
        CFDictionaryRef aat = NULL;
        int clearedType = 0;
        switch (wk_normalizeFeatureElement(element, &aat, &clearedType)) {
        case WK_FEATURE_AAT:
            CFArrayAppendValue(result, element);
            break;
        case WK_FEATURE_NORMALIZED:
            CFArrayAppendValue(result, aat);
            CFRelease(aat);
            break;
        case WK_FEATURE_CLEAR:
        case WK_FEATURE_NO_AAT_EQUIVALENT:
            break;
        }
    }
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
    if (!data)
        return NULL;
    // Upstream reads an empty result as "something is wrong with the font" and rejects the
    // @font-face outright, so the parse has to be attempted here rather than deferred. Accept
    // exactly what CTFontManagerCreateFontDescriptorFromData above accepts: CoreGraphics' parser
    // first, then 10.9's own for the data it cannot read.
    bool usable = false;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    if (provider) {
        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (cgFont) {
            CGFontRelease(cgFont);
            usable = true;
        }
    }
    if (!usable && WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)) {
        CTFontDescriptorRef descriptor = WK_ORIGINAL(CTFontManagerCreateFontDescriptorFromData)(data);
        if (descriptor) {
            CFRelease(descriptor);
            usable = true;
        }
    }
    if (!usable)
        return NULL;
    const void *values[1] = { data };
    return CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
}

WK_POLYFILL_ABSENT("CoreText", CFDataRef, FPFontCopySFNTData, (FPFontRef font))
{
    if (font && CFGetTypeID((CFTypeRef)font) == CFDataGetTypeID())
        return (CFDataRef)CFRetain((CFTypeRef)font);
    return NULL;
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

// CTFontCopyColorGlyphCoverage (10.13+) answers the colour question. Upstream asks it only of a font
// CoreText has marked kCTFontTraitColorGlyphs, "colour bitmap glyphs are available", and on 10.9 that
// trait means an sbix table — the Apple colour-bitmap format Apple Color Emoji is built from, and the
// same table CTFontGetSbixImageSizeForGlyphAndContentsScale reads above. A glyph is a colour one when
// some strike holds a non-empty bitmap for it. NULL says the font has none, which is what upstream's
// call site reads as "no emoji glyphs" (Font::platformInit, FontCoreText.cpp); its three siblings below
// answer with a bit vector however empty, because unionBitVectors() hands theirs straight to
// CFBitVectorGetCount() with no null check.
WK_POLYFILL_ABSENT("CoreText", CFBitVectorRef, CTFontCopyColorGlyphCoverage, (CTFontRef font))
{
    CFIndex glyphCount = font ? CTFontGetGlyphCount(font) : 0;
    if (glyphCount <= 0)
        return NULL;
    CFDataRef data = CTFontCopyTable(font, kCTFontTableSbix, kCTFontTableOptionNoOptions);
    if (!data)
        return NULL;

    wk_font_table sbix = { CFDataGetBytePtr(data), CFDataGetBytePtr(data) ? (uint32_t)CFDataGetLength(data) : 0 };
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
        if (!CFBitVectorGetCountOfBit(coverage, CFRangeMake(0, glyphCount), 1)) {
            CFRelease(coverage);
            coverage = NULL;
        }
    }
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

// CSS generic family -> concrete 10.9 font descriptor. The cssFamily argument is one of the
// kCTFontCSSFamily* constants are defined above (each value is its own name). Map each to a
// font that ships on 10.9 so generic families (serif/sans-serif/monospace/cursive/fantasy) resolve.
WK_POLYFILL_ABSENT("CoreText", CTFontDescriptorRef, CTFontDescriptorCreateForCSSFamily, (CFStringRef cssFamily, CFStringRef language))
{
    (void)language;
    if (!cssFamily)
        return NULL;
    CFStringRef name = NULL;
    if (CFStringHasSuffix(cssFamily, CFSTR("Serif")) && !CFStringHasSuffix(cssFamily, CFSTR("SansSerif")))
        name = CFSTR("Times");
    else if (CFStringHasSuffix(cssFamily, CFSTR("SansSerif")))
        name = CFSTR("Helvetica");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Monospace")))
        name = CFSTR("Courier");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Cursive")))
        name = CFSTR("Apple Chancery");
    else if (CFStringHasSuffix(cssFamily, CFSTR("Fantasy")))
        name = CFSTR("Papyrus");
    if (!name)
        return NULL;
    return CTFontDescriptorCreateWithNameAndSize(name, 0.0);
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

WK_POLYFILL_ABSENT("CoreText", CGSize, CTFontShapeGlyphs,
    (CTFontRef font, CGGlyph glyphs[], CGSize advances[], CGPoint origins[], CFIndex indexes[], const UniChar chars[], CFIndex count, CFOptionFlags options, CFStringRef language, void (^handler)(CFRange, CGGlyph**, CGSize**, CGPoint**, CFIndex**)))
{
    (void)language;
    CGSize zero = { 0, 0 };
    if (count <= 0 || !glyphs || !advances || !WK_SYSTEM(CTFontTransformGlyphs))
        return zero;

    uint32_t transform = WK_CTFONT_TRANSFORM_APPLY_SHAPING
        | ((options & WK_CTFONT_SHAPE_WITH_KERNING) ? WK_CTFONT_TRANSFORM_APPLY_POSITIONING : 0);

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

// CTRunGetBaseAdvancesAndOrigins (10.11+): the base advances and per-glyph origins over a run range,
// where a zero length means "to the end of the run". The advances are the ones 10.9's CTRunGetAdvances
// reports. The origins are all zero: 10.9's CTRun.h declares CTRunStatus without a
// kCTRunStatusHasOrigins bit, so no run this CoreText produces carries per-glyph origin offsets.
WK_POLYFILL_ABSENT("CoreText", void, CTRunGetBaseAdvancesAndOrigins,
    (CTRunRef run, CFRange range, CGSize *advances, CGPoint *origins))
{
    if (!run)
        return;
    CFIndex glyphCount = CTRunGetGlyphCount(run);
    CFIndex count = range.length ? range.length : glyphCount - range.location;
    if (count < 0)
        count = 0;
    if (advances)
        CTRunGetAdvances(run, range, advances);
    if (origins) {
        for (CFIndex i = 0; i < count; ++i)
            origins[i] = CGPointZero;
    }
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

WK_POLYFILL_REPLACES("CoreText", void, CTFontDrawGlyphs, (CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count, CGContextRef context))
{
    // A font with no sbix table has no glyph this layer draws, so the whole run goes to CoreText.
    // Past this point it may, and a glyph carrying a record is never handed to the original: this
    // OS decodes an sbix strike in ImageIO, and a strike's bytes are a downloadable font's bytes.
    if (!glyphs || !positions || !context || !count || !wk_sbixFont(font)) {
        wk_drawGlyphRun(font, glyphs, positions, count, context);
        return;
    }

    // A colour bitmap contributes nothing to a text clip on this OS, and CG intersects the clip once
    // per CALL rather than once per glyph, so a clipping run reaches CoreText as ONE call carrying the
    // outlined glyphs alone. Measured on this OS with kCGTextClip and a full-page fill afterwards: an
    // outlined glyph clips to its own shape, a run of colour glyphs alone leaves an EMPTY clip, and a
    // call carrying no glyphs at all leaves the clip untouched -- so a run with nothing to outline
    // intersects the clip with an empty rectangle, which is the same outcome. The bitmaps are painted
    // before that call installs the clip.
    CGTextDrawingMode mode = WK_SYSTEM(CGContextGetTextDrawingMode) ? WK_SYSTEM(CGContextGetTextDrawingMode)(context) : kCGTextFill;

    // kCGTextInvisible paints nothing at all. The outlined glyphs still reach CoreText, which paints
    // nothing for them either, so whatever a call carries with it is unchanged; splitting the run is
    // free here because no clip is being intersected.
    if (mode == kCGTextInvisible) {
        size_t i = 0;
        while (i < count) {
            bool bitmap = false;
            size_t next = wk_sbixRunGroup(font, glyphs, count, i, &bitmap);
            if (!bitmap)
                wk_drawGlyphRun(font, &glyphs[i], &positions[i], next - i, context);
            i = next;
        }
        return;
    }

    if (mode >= kCGTextFillClip) {
        // A run this layer draws none of goes to CoreText whole, which is also the only shape that
        // needs no gathering.
        bool anyBitmap = false;
        for (size_t i = 0; i < count && !anyBitmap; ) {
            bool bitmap = false;
            i = wk_sbixRunGroup(font, glyphs, count, i, &bitmap);
            anyBitmap = bitmap;
        }
        if (!anyBitmap) {
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
            bool bitmap = false;
            size_t next = wk_sbixRunGroup(font, glyphs, count, i, &bitmap);
            for (size_t j = i; j < next; ++j) {
                if (bitmap) {
                    // kCGTextClip establishes a clip and paints no ink; the other clip modes fill or
                    // stroke as well, and a colour bitmap is what their fill looks like.
                    if (mode != kCGTextClip)
                        wk_drawSbixGlyph(font, glyphs[j], positions[j], context);
                } else if (outlined) {
                    outlinedPositions[outlinedCount] = positions[j];
                    outlined[outlinedCount] = glyphs[j];
                    ++outlinedCount;
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
        bool bitmap = false;
        size_t next = wk_sbixRunGroup(font, glyphs, count, i, &bitmap);
        if (bitmap) {
            for (size_t j = i; j < next; ++j)
                wk_drawSbixGlyph(font, glyphs[j], positions[j], context);
        } else
            wk_drawGlyphRun(font, &glyphs[i], &positions[i], next - i, context);
        i = next;
    }
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

WK_POLYFILL_REPLACES("CoreText", CGRect, CTFontGetBoundingRectsForGlyphs,
                     (CTFontRef font, CTFontOrientation orientation, const CGGlyph *glyphs, CGRect *boundingRects, CFIndex count))
{
    if (!WK_ORIGINAL(CTFontGetBoundingRectsForGlyphs))
        return CGRectNull;
    if (!font || !glyphs || count <= 0 || !wk_sbixFont(font))
        return WK_ORIGINAL(CTFontGetBoundingRectsForGlyphs)(font, orientation, glyphs, boundingRects, count);

    bool vertical = orientation == kCTFontOrientationVertical
        || (orientation == kCTFontOrientationDefault && (CTFontGetSymbolicTraits(font) & kCTFontTraitVertical));
    CGSize *translations = NULL;
    if (vertical) {
        translations = (CGSize *)malloc((size_t)count * sizeof(CGSize));
        if (!translations)
            return WK_ORIGINAL(CTFontGetBoundingRectsForGlyphs)(font, orientation, glyphs, boundingRects, count);
        CTFontGetVerticalTranslationsForGlyphs(font, glyphs, translations, count);
    }

    CGRect united = CGRectNull;
    for (CFIndex i = 0; i < count; ++i) {
        CGRect rect = CGRectZero;
        pthread_mutex_lock(&wkSbixLock);
        bool haveBitmap = wk_sbixBitmap(font, glyphs[i], CTFontGetSize(font), NULL, &rect);
        pthread_mutex_unlock(&wkSbixLock);
        if (!haveBitmap) {
            CGPathRef path = CTFontCreatePathForGlyph(font, glyphs[i], NULL);
            rect = path ? CGPathGetPathBoundingBox(path) : CGRectZero;
            if (path)
                CFRelease(path);
        }
        // A glyph that occupies nothing has no rectangle to move, and leaves the union alone.
        if (CGRectIsNull(rect) || CGRectIsInfinite(rect) || CGRectIsEmpty(rect))
            rect = CGRectZero;
        else if (vertical)
            rect = wk_rotateRectLeft(CGRectOffset(rect, translations[i].width, translations[i].height));
        if (boundingRects)
            boundingRects[i] = rect;
        if (!CGRectIsEmpty(rect))
            united = CGRectIsNull(united) ? rect : CGRectUnion(united, rect);
    }
    free(translations);
    return CGRectIsNull(united) ? CGRectZero : united;
}

// One run, through whichever implementation the context calls for.
static void wk_drawGlyphRun(CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count, CGContextRef context)
{
    if (font && glyphs && positions && count && context && wk_isInsideTransparencyLayer(context)
        && WK_SYSTEM(CGContextGetType) && WK_SYSTEM(CGContextGetType)(context) == WK_CG_CONTEXT_TYPE_PDF)
        wk_drawGlyphsInPDFTransparencyLayer(context, font, glyphs, positions, count);
    else if (WK_ORIGINAL(CTFontDrawGlyphs))
        WK_ORIGINAL(CTFontDrawGlyphs)(font, glyphs, positions, count, context);
}

// CTFontCreatePathForGlyph places an outline the same way CTFontDrawGlyphs places a
// glyph: device = CTM * textMatrix * (position + outline). Vertical runs arrive with
// the vertical text matrix already installed on the context, so reading it here keeps
// both orientations aligned with the system implementation.
static CGAffineTransform wk_glyphMatrix(const CGPoint *positions, size_t index, CGAffineTransform textMatrix)
{
    return CGAffineTransformConcat(CGAffineTransformMakeTranslation(positions[index].x, positions[index].y), textMatrix);
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
            CGAffineTransform matrix = wk_glyphMatrix(positions, i, textMatrix);
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
        CGAffineTransform matrix = wk_glyphMatrix(positions, i, textMatrix);
        CGPathRef glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], &matrix);
        size_t next = i + 1;
        if (glyphPath) {
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddPath(path, NULL, glyphPath);
            CFRelease(glyphPath);
            for (; next < count; ++next) {
                CGAffineTransform nextMatrix = wk_glyphMatrix(positions, next, textMatrix);
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
                CGAffineTransform nextMatrix = wk_glyphMatrix(positions, next, textMatrix);
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
