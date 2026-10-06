// Images carried inside fonts: sbix strikes. A font
// is downloadable, so these are page-controlled bytes. They decode through the same libpng, libjpeg and
// libtiff WebCore decodes every other image with, never through CGImageSourceCreateWithData: nothing in
// this port hands page bytes to 10.9's ImageIO.
#include "wk_font_image.h"
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <jpeglib.h>
#include <png.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tiffio.h>

typedef struct {
    const uint8_t *bytes;
    size_t length;
    size_t offset;
} WKFontImageSource;

// Present on this OS, declared 10.12 in the SDK this builds against.
WK_SYSTEM_FN("CoreGraphics", CGColorSpaceRef, CGColorSpaceCreateWithICCData, (CFTypeRef));

// The image's own colour space when it carries an ICC profile, sRGB otherwise. 10.10+ CoreText
// paints an sbix strike through the profile ImageIO attaches to the image, so a profiled image
// tagged sRGB here would draw in the wrong colours. Only a three-component profile describes the
// RGBA the decoders below produce; an image that carries any other kind is drawn as sRGB.
static CGColorSpaceRef wk_fontImageColorSpace(const uint8_t *profile, size_t profileLength)
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

static void wk_fontImagePixelsRelease(void *info, const void *data, size_t size) { (void)data; (void)size; free(info); }

// Takes ownership of pixels and space either way. Premultiplies unless the decoder already did, because
// CGImageCreate below is told the alpha is premultiplied, which is what a drawn glyph needs.
static CGImageRef wk_fontImageFromRGBA(uint8_t *pixels, size_t width, size_t height,
                                       CGColorSpaceRef space, bool premultiplied)
{
    size_t stride = width * 4;
    if (!premultiplied && pixels) {
        for (size_t i = 0; i < height * stride; i += 4) {
            uint8_t alpha = pixels[i + 3];
            if (alpha == 255)
                continue;
            pixels[i] = (uint8_t)((pixels[i] * alpha + 127) / 255);
            pixels[i + 1] = (uint8_t)((pixels[i + 1] * alpha + 127) / 255);
            pixels[i + 2] = (uint8_t)((pixels[i + 2] * alpha + 127) / 255);
        }
    }
    CGDataProviderRef provider = pixels && space ? CGDataProviderCreateWithData(pixels, pixels, height * stride, wk_fontImagePixelsRelease) : NULL;
    if (!provider) {
        free(pixels);
        if (space)
            CGColorSpaceRelease(space);
        return NULL;
    }
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, space,
                                     kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault,
                                     provider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return image;
}

// Four bytes a pixel and a row pointer each, both of which have to be expressible, and no more pixels
// than the caller's maximum.
static bool wk_fontImageUsableDimensions(size_t width, size_t height, size_t maximumPixels)
{
    return width && height && height <= SIZE_MAX / sizeof(void *) && width <= (SIZE_MAX / 4) / height
        && width <= maximumPixels / height;
}

static void wk_fontImagePNGRead(png_structp png, png_bytep out, png_size_t count)
{
    WKFontImageSource *source = (WKFontImageSource *)png_get_io_ptr(png);
    if (!source || count > source->length - source->offset) {
        png_error(png, "truncated");
        return;
    }
    memcpy(out, source->bytes + source->offset, count);
    source->offset += count;
}

static void wk_fontImagePNGError(png_structp png, png_const_charp message)
{
    (void)message;
    longjmp(png_jmpbuf(png), 1);
}

static void wk_fontImagePNGWarning(png_structp png, png_const_charp message) { (void)png; (void)message; }

CGImageRef wk_fontImageDecodePNG(const uint8_t *bytes, size_t length, size_t maximumPixels)
{
    if (!bytes || length < 8 || png_sig_cmp((png_const_bytep)bytes, 0, 8))
        return NULL;

    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, wk_fontImagePNGError, wk_fontImagePNGWarning);
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

    WKFontImageSource source = { bytes, length, 0 };
    png_set_read_fn(png, &source, wk_fontImagePNGRead);
    png_read_info(png, info);

    png_uint_32 width = 0, height = 0;
    int depth = 0, colorType = 0;
    png_get_IHDR(png, info, &width, &height, &depth, &colorType, NULL, NULL, NULL);
    if (!wk_fontImageUsableDimensions(width, height, maximumPixels))
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
    CGColorSpaceRef space = wk_fontImageColorSpace(profile, profileLength);
    uint8_t *owned = pixels;
    pixels = NULL;
    free(rows);
    rows = NULL;
    png_destroy_read_struct(&png, &info, NULL);
    return wk_fontImageFromRGBA(owned, width, height, space, false);
}

typedef struct {
    struct jpeg_error_mgr base;
    jmp_buf escape;
} WKFontImageJPEGError;

static void wk_fontImageJPEGFail(j_common_ptr cinfo) { longjmp(((WKFontImageJPEGError *)cinfo->err)->escape, 1); }
static void wk_fontImageJPEGSilent(j_common_ptr cinfo) { (void)cinfo; }

CGImageRef wk_fontImageDecodeJPEG(const uint8_t *bytes, size_t length, size_t maximumPixels)
{
    if (!bytes || length < 4)
        return NULL;

    struct jpeg_decompress_struct cinfo;
    WKFontImageJPEGError error;
    memset(&cinfo, 0, sizeof(cinfo));
    cinfo.err = jpeg_std_error(&error.base);
    error.base.error_exit = wk_fontImageJPEGFail;
    error.base.output_message = wk_fontImageJPEGSilent;

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
    if (cinfo.output_components != 4 || !wk_fontImageUsableDimensions(cinfo.output_width, cinfo.output_height, maximumPixels))
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

    CGColorSpaceRef space = wk_fontImageColorSpace(profile, profileLength);
    uint8_t *owned = pixels;
    pixels = NULL;
    free(rows);
    rows = NULL;
    free(profile);
    profile = NULL;
    jpeg_destroy_decompress(&cinfo);
    return wk_fontImageFromRGBA(owned, width, height, space, true);
}

static tmsize_t wk_fontImageTIFFRead(thandle_t handle, void *buffer, tmsize_t count)
{
    WKFontImageSource *source = (WKFontImageSource *)handle;
    if (count < 0 || (size_t)count > source->length - source->offset)
        count = (tmsize_t)(source->length - source->offset);
    memcpy(buffer, source->bytes + source->offset, (size_t)count);
    source->offset += (size_t)count;
    return count;
}

static tmsize_t wk_fontImageTIFFWrite(thandle_t handle, void *buffer, tmsize_t count)
{
    (void)handle; (void)buffer; (void)count;
    return 0;
}

static toff_t wk_fontImageTIFFSeek(thandle_t handle, toff_t offset, int whence)
{
    WKFontImageSource *source = (WKFontImageSource *)handle;
    uint64_t base = whence == SEEK_CUR ? source->offset : (whence == SEEK_END ? source->length : 0);
    uint64_t wanted = base + offset;
    if (wanted > source->length)
        wanted = source->length;
    source->offset = (size_t)wanted;
    return (toff_t)source->offset;
}

static int wk_fontImageTIFFClose(thandle_t handle) { (void)handle; return 0; }
static toff_t wk_fontImageTIFFSize(thandle_t handle) { return (toff_t)((WKFontImageSource *)handle)->length; }

// The image is already a contiguous span of the font, so libtiff reads an uncompressed tile
// straight out of it rather than through a staging buffer of its own.
static int wk_fontImageTIFFMap(thandle_t handle, void **base, toff_t *size)
{
    WKFontImageSource *source = (WKFontImageSource *)handle;
    *base = (void *)source->bytes;
    *size = (toff_t)source->length;
    return 1;
}

static void wk_fontImageTIFFUnmap(thandle_t handle, void *base, toff_t size) { (void)handle; (void)base; (void)size; }

// Per handle rather than libtiff's process-global setters: WebCore's own TIFF decoder shares this
// vendored copy, and an image that will not decode is this function's answer, not a line on the
// process's stderr. Returning 1 tells libtiff the diagnostic is handled.
static int wk_fontImageTIFFSilent(TIFF *tiff, void *context, const char *module, const char *format, va_list arguments)
{
    (void)tiff; (void)context; (void)module; (void)format; (void)arguments;
    return 1;
}

CGImageRef wk_fontImageDecodeTIFF(const uint8_t *bytes, size_t length, size_t maximumPixels)
{
    if (!bytes || length < 8)
        return NULL;

    TIFFOpenOptions *options = TIFFOpenOptionsAlloc();
    if (!options)
        return NULL;
    TIFFOpenOptionsSetErrorHandlerExtR(options, wk_fontImageTIFFSilent, NULL);
    TIFFOpenOptionsSetWarningHandlerExtR(options, wk_fontImageTIFFSilent, NULL);

    WKFontImageSource source = { bytes, length, 0 };
    TIFF *tiff = TIFFClientOpenExt("font image", "r", (thandle_t)&source, wk_fontImageTIFFRead, wk_fontImageTIFFWrite,
                                   wk_fontImageTIFFSeek, wk_fontImageTIFFClose, wk_fontImageTIFFSize,
                                   wk_fontImageTIFFMap, wk_fontImageTIFFUnmap, options);
    TIFFOpenOptionsFree(options);
    if (!tiff)
        return NULL;

    uint32_t width = 0, height = 0;
    TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
    TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);
    if (!wk_fontImageUsableDimensions(width, height, maximumPixels)) {
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
    CGColorSpaceRef space = wk_fontImageColorSpace((const uint8_t *)profile, profile ? profileLength : 0);
    TIFFClose(tiff);
    return wk_fontImageFromRGBA(pixels, width, height, space, true);
}
