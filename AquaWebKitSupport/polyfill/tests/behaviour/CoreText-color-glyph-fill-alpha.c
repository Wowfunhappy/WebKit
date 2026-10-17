#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Colour glyphs against the text fill colour: an sbix glyph paints nothing when the fill alpha is 0 and
// paints its image unchanged at any other fill alpha and in stroke-only mode; a COLR glyph paints its
// palette colours whatever the fill alpha. Colour glyphs paint as filled layers in every text drawing mode:
// WebKit's stroke-color-COLR expectation for current macOS (upstream 8434dfb, webkit.org/b/262223) has
// stroked COLR text fill its layers with no outline, and a layer naming the foreground (palette entry
// 0xFFFF) fills with the text fill colour.

enum { Side = 300 };

static CTFontRef fontFromProvider(CGDataProviderRef provider)
{
    assert(provider);
    CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
    assert(cgFont);
    CTFontRef font = CTFontCreateWithGraphicsFont(cgFont, 100, NULL, NULL);
    assert(font);
    CGFontRelease(cgFont);
    CGDataProviderRelease(provider);
    return font;
}

static CTFontRef loadFont(const char *path)
{
    return fontFromProvider(CGDataProviderCreateWithFilename(path));
}

static uint16_t be16(const unsigned char *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32(const unsigned char *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

// The font at `path` with its first COLR layer record naming the foreground (palette entry 0xFFFF).
static CTFontRef loadFontWithForegroundLayer(const char *path)
{
    FILE *file = fopen(path, "rb");
    assert(file);
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    fseek(file, 0, SEEK_SET);
    unsigned char *bytes = malloc(length);
    assert(bytes);
    size_t read = fread(bytes, 1, length, file);
    assert(read == (size_t)length);
    fclose(file);
    uint16_t tables = be16(bytes + 4);
    unsigned char *colr = NULL;
    for (uint16_t i = 0; i < tables; ++i) {
        const unsigned char *record = bytes + 12 + 16 * i;
        if (!memcmp(record, "COLR", 4))
            colr = bytes + be32(record + 8);
    }
    assert(colr && be16(colr) == 0 && be16(colr + 12) > 0);
    unsigned char *firstLayer = colr + be32(colr + 8);
    firstLayer[2] = 0xFF;
    firstLayer[3] = 0xFF;
    CFDataRef data = CFDataCreateWithBytesNoCopy(NULL, bytes, length, kCFAllocatorMalloc);
    CTFontRef font = fontFromProvider(CGDataProviderCreateWithCFData(data));
    CFRelease(data);
    return font;
}

static unsigned char *draw(CTFontRef font, CGFloat fillAlpha, CGTextDrawingMode mode)
{
    unsigned char *pixels = calloc(1, Side * Side * 4);
    assert(pixels);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels, Side, Side, 8, Side * 4, space, kCGImageAlphaPremultipliedLast);
    assert(context);
    UniChar character = 'A';
    CGGlyph glyph;
    assert(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1));
    CGPoint position = CGPointMake(50, 100);
    CGContextSetRGBFillColor(context, 0, 0.5, 0, fillAlpha);
    CGContextSetRGBStrokeColor(context, 0, 0, 1, 1);
    CGContextSetLineWidth(context, 2);
    CGContextSetTextDrawingMode(context, mode);
    CTFontDrawGlyphs(font, &glyph, &position, 1, context);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return pixels;
}

static size_t paintedPixels(const unsigned char *pixels)
{
    size_t painted = 0;
    for (size_t i = 0; i < Side * Side; ++i)
        painted += pixels[i * 4 + 3] != 0;
    return painted;
}

static unsigned check(const char *name, int pass)
{
    printf("%s %s\n", pass ? "PASS" : "FAIL", name);
    return !pass;
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    CTFontRef sbix = loadFont(argv[1]);
    CTFontRef colr = loadFont(argv[2]);
    size_t bytes = Side * Side * 4;
    unsigned failures = 0;

    unsigned char *sbixOpaque = draw(sbix, 1, kCGTextFill);
    unsigned char *sbixTransparent = draw(sbix, 0, kCGTextFill);
    unsigned char *sbixHalf = draw(sbix, 0.5, kCGTextFill);
    unsigned char *sbixStroke = draw(sbix, 1, kCGTextStroke);
    failures += check("sbix with an opaque fill paints its image", paintedPixels(sbixOpaque) > 0);
    failures += check("sbix with fill alpha 0 paints nothing", !paintedPixels(sbixTransparent));
    failures += check("sbix with fill alpha 0.5 paints its image unchanged", !memcmp(sbixHalf, sbixOpaque, bytes));
    failures += check("sbix in stroke-only mode paints its image", !memcmp(sbixStroke, sbixOpaque, bytes));

    unsigned char *colrOpaque = draw(colr, 1, kCGTextFill);
    unsigned char *colrTransparent = draw(colr, 0, kCGTextFill);
    unsigned char *colrStroke = draw(colr, 1, kCGTextStroke);
    failures += check("COLR with an opaque fill paints its layers", paintedPixels(colrOpaque) > 0);
    failures += check("COLR with fill alpha 0 paints its palette colours", !memcmp(colrTransparent, colrOpaque, bytes));
    failures += check("COLR in stroke-only mode fills its layers", !memcmp(colrStroke, colrOpaque, bytes));

    // draw() fills with opaque green (0, 0.5, 0) and strokes with blue.
    CTFontRef foreground = loadFontWithForegroundLayer(argv[2]);
    unsigned char *foregroundFill = draw(foreground, 1, kCGTextFill);
    unsigned char *foregroundStroke = draw(foreground, 1, kCGTextStroke);
    size_t green = 0, blue = 0;
    for (size_t i = 0; i < Side * Side; ++i) {
        const unsigned char *pixel = foregroundStroke + i * 4;
        green += pixel[0] == 0 && (pixel[1] == 127 || pixel[1] == 128) && pixel[2] == 0 && pixel[3] == 255;
        blue += pixel[2] > pixel[0] && pixel[2] > pixel[1];
    }
    failures += check("a COLR foreground layer in stroke-only mode fills with the fill colour", green > 0);
    failures += check("a COLR foreground layer in stroke-only mode draws no outline", !blue);
    failures += check("a COLR foreground layer paints the same in fill and stroke-only modes", !memcmp(foregroundStroke, foregroundFill, bytes));
    free(colrStroke);
    free(foregroundFill);
    free(foregroundStroke);
    CFRelease(foreground);

    free(sbixOpaque);
    free(sbixTransparent);
    free(sbixHalf);
    free(sbixStroke);
    free(colrOpaque);
    free(colrTransparent);
    CFRelease(sbix);
    CFRelease(colr);
    return failures != 0;
}
