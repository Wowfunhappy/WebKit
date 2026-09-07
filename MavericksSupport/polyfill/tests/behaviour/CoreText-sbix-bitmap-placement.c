// The CTFontDrawGlyphs and CTFontGetBoundingRectsForGlyphs replacements (polyfills/c/CoreText.c),
// measured against 10.9's own definitions on a colour-bitmap font. The sbix record says where the strike goes -- its lower-left corner at the pen
// on the baseline, moved by the record's origin offset, scaled by the point size over the strike's
// ppem -- and this program reads that from the font file, decodes the strike itself, and compares the
// ink each definition actually paints. The archive's lands on the record's rectangle; 10.9's lands
// below it. The archive's definition is the one this program's link-time reference binds.
//
// Three sizes, because the strike a size asks for is rarely the size it is drawn at: one that matches
// a strike exactly, one below the smallest strike that covers it, and one above every strike the font
// has, which falls back to the largest.
//
// The bounding rectangles are checked against the same record: a colour bitmap is measured by the
// rectangle it is painted in, and its vertical rectangle is that moved to the vertical origin and
// rotated left. 10.9 reports both the same distance low.
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { kSide = 1024, kPenX = 200, kPenY = 300 };

static const char *kFontPath = "/System/Library/Fonts/Apple Color Emoji.ttf";

typedef void (*DrawGlyphsFn)(CTFontRef, const CGGlyph *, const CGPoint *, size_t, CGContextRef);

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static DrawGlyphsFn systemDrawGlyphs(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreText.framework/Versions/A/CoreText",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CTFontDrawGlyphs", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (DrawGlyphsFn)NSAddressOfSymbol(found) : 0;
}

typedef CGRect (*BoundingRectsFn)(CTFontRef, CTFontOrientation, const CGGlyph *, CGRect *, CFIndex);

static CGRect systemBoundingRects(CTFontRef font, CTFontOrientation orientation, CGGlyph glyph)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreText.framework/Versions/A/CoreText",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CTFontGetBoundingRectsForGlyphs", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    BoundingRectsFn boundingRects = found ? (BoundingRectsFn)NSAddressOfSymbol(found) : 0;
    if (!boundingRects)
        return CGRectNull;
    CGRect rect = CGRectZero;
    boundingRects(font, orientation, &glyph, &rect, 1);
    return rect;
}

typedef struct { int count, minX, maxX, minY, maxY; } Coverage;

static Coverage coverage(const unsigned char *pixels, size_t bytesPerRow, size_t width, size_t height)
{
    Coverage c = { 0, (int)width, -1, (int)height, -1 };
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (!pixels[y * bytesPerRow + x * 4 + 3])
                continue;
            c.count++;
            if ((int)x < c.minX) c.minX = (int)x;
            if ((int)x > c.maxX) c.maxX = (int)x;
            if ((int)y < c.minY) c.minY = (int)y;
            if ((int)y > c.maxY) c.maxY = (int)y;
        }
    }
    return c;
}

static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

// The record this font holds for the glyph, in the strike the sbix contract picks for pointSize: the
// smallest strike at least that big, else the largest there is. Read straight from the table, so the
// expectation comes from the font rather than from the code under test.
static int sbixRecord(CTFontRef font, CGGlyph glyph, double pointSize,
                      uint16_t *outPPEM, int16_t *originX, int16_t *originY, CGImageRef *outImage)
{
    CFDataRef table = CTFontCopyTable(font, kCTFontTableSbix, kCTFontTableOptionNoOptions);
    if (!table)
        return 0;
    const uint8_t *bytes = CFDataGetBytePtr(table);
    CFIndex length = CFDataGetLength(table);
    CFIndex glyphCount = CTFontGetGlyphCount(font);
    uint32_t chosen = 0, largest = 0;
    double chosenPPEM = 0, largestPPEM = 0;
    if (bytes && length >= 8 && glyphCount > 0 && glyph < glyphCount) {
        uint32_t strikeCount = be32(bytes + 4);
        CFIndex needed = 4 + (glyphCount + 1) * 4;
        for (uint32_t i = 0; i < strikeCount; i++) {
            uint32_t strikeOffset = be32(bytes + 8 + i * 4);
            if ((CFIndex)strikeOffset > length - needed)
                continue;
            const uint8_t *strike = bytes + strikeOffset;
            if (be32(strike + 4 + ((CFIndex)glyph + 1) * 4) <= be32(strike + 4 + (CFIndex)glyph * 4))
                continue;
            double ppem = be16(strike);
            if (ppem > largestPPEM) { largestPPEM = ppem; largest = strikeOffset; }
            if (ppem >= pointSize && (!chosenPPEM || ppem < chosenPPEM)) { chosenPPEM = ppem; chosen = strikeOffset; }
        }
    }
    if (!chosenPPEM) { chosenPPEM = largestPPEM; chosen = largest; }
    int found = 0;
    if (chosenPPEM) {
        const uint8_t *strike = bytes + chosen;
        uint32_t start = be32(strike + 4 + (CFIndex)glyph * 4);
        uint32_t end = be32(strike + 4 + ((CFIndex)glyph + 1) * 4);
        if (end > start && end - start >= 8 && (CFIndex)(chosen + end) <= length) {
            const uint8_t *record = strike + start;
            *outPPEM = (uint16_t)chosenPPEM;
            *originX = (int16_t)be16(record);
            *originY = (int16_t)be16(record + 2);
            CFDataRef imageData = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, record + 8, (CFIndex)(end - start - 8), kCFAllocatorNull);
            CGImageSourceRef source = imageData ? CGImageSourceCreateWithData(imageData, NULL) : NULL;
            *outImage = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
            if (source)
                CFRelease(source);
            if (imageData)
                CFRelease(imageData);
            found = *outImage != NULL;
        }
    }
    CFRelease(table);
    return found;
}

// Where the strike's own ink sits inside the image, in rows from the image's top.
static Coverage imageInk(CGImageRef image)
{
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image), bytesPerRow = width * 4;
    unsigned char *pixels = calloc(bytesPerRow, height);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, bytesPerRow, colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    Coverage ink = coverage(pixels, bytesPerRow, width, height);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    return ink;
}

static Coverage draw(CTFontRef font, CGGlyph glyph, DrawGlyphsFn drawGlyphs)
{
    size_t bytesPerRow = kSide * 4;
    unsigned char *pixels = calloc(bytesPerRow, kSide);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, bytesPerRow, colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGPoint position = CGPointMake(kPenX, kPenY);
    drawGlyphs(font, &glyph, &position, 1, context);
    Coverage ink = coverage(pixels, bytesPerRow, kSide, kSide);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    return ink;
}

static int within(int a, int b, int tolerance) { return a - b <= tolerance && b - a <= tolerance; }

static void runSize(CTFontDescriptorRef descriptor, double pointSize)
{
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, pointSize, NULL);
    UniChar characters[2] = { 0xD83D, 0xDE00 };   // U+1F600 GRINNING FACE
    CGGlyph glyphs[2] = { 0, 0 };
    CTFontGetGlyphsForCharacters(font, characters, glyphs, 2);
    uint16_t ppem = 0;
    int16_t originX = 0, originY = 0;
    CGImageRef strike = NULL;
    if (!glyphs[0] || !sbixRecord(font, glyphs[0], pointSize, &ppem, &originX, &originY, &strike)) {
        printf("FATAL: no sbix record for U+1F600 at %g pt in %s\n", pointSize, kFontPath);
        failures++;
        return;
    }

    // The rectangle the record puts the strike in, in the context's pixels: the image's lower-left
    // corner at the pen plus the origin offset, everything scaled by the point size over the ppem.
    double scale = pointSize / ppem;
    Coverage inImage = imageInk(strike);
    int height = (int)CGImageGetHeight(strike);
    Coverage expected;
    expected.count = inImage.count;
    expected.minX = (int)(kPenX + (originX + inImage.minX) * scale);
    expected.maxX = (int)(kPenX + (originX + inImage.maxX + 1) * scale) - 1;
    // Rows count down from the image's top edge, which sits height above the lower-left corner; the
    // context's rows count down from its own top edge, which is kSide above the pen's baseline.
    expected.minY = (int)(kSide - kPenY - (originY + height - inImage.minY) * scale);
    expected.maxY = (int)(kSide - kPenY - (originY + height - inImage.maxY - 1) * scale) - 1;
    // A resampled edge spreads a pixel either way; an unscaled strike is drawn pixel for pixel.
    int tolerance = scale == 1 ? 0 : 1;

    char what[128];
    Coverage ours = draw(font, glyphs[0], CTFontDrawGlyphs);
    printf("  %g pt from the %u-ppem strike (scale %.3f): expected=[%d..%d]x[%d..%d] archive's=[%d..%d]x[%d..%d]\n",
        pointSize, ppem, scale, expected.minX, expected.maxX, expected.minY, expected.maxY,
        ours.minX, ours.maxX, ours.minY, ours.maxY);
    snprintf(what, sizeof what, "%g pt: the archive's definition paints the glyph", pointSize);
    check(ours.count > 0, what);
    snprintf(what, sizeof what, "%g pt: the archive's ink spans the record's columns", pointSize);
    check(within(ours.minX, expected.minX, tolerance) && within(ours.maxX, expected.maxX, tolerance), what);
    snprintf(what, sizeof what, "%g pt: the archive's ink spans the record's rows", pointSize);
    check(within(ours.minY, expected.minY, tolerance) && within(ours.maxY, expected.maxY, tolerance), what);

    DrawGlyphsFn system = systemDrawGlyphs();
    if (system) {
        Coverage theirs = draw(font, glyphs[0], system);
        printf("  %g pt: 10.9's=[%d..%d]x[%d..%d]\n", pointSize, theirs.minX, theirs.maxX, theirs.minY, theirs.maxY);
        snprintf(what, sizeof what, "%g pt: 10.9's ink spans the record's columns", pointSize);
        check(within(theirs.minX, expected.minX, tolerance) && within(theirs.maxX, expected.maxX, tolerance), what);
        snprintf(what, sizeof what, "%g pt: 10.9's ink sits below the record's rows", pointSize);
        check(theirs.minY > expected.minY + tolerance && theirs.maxY > expected.maxY + tolerance, what);
    }

    // The rectangles the record predicts, in both orientations: a colour bitmap is measured by the
    // rectangle it is painted in, and a vertical rectangle is that moved to the vertical origin and
    // rotated left.
    CGRect recordRect = CGRectMake(originX * scale, originY * scale,
                                   CGImageGetWidth(strike) * scale, height * scale);
    CGSize translation = CGSizeZero;
    CTFontGetVerticalTranslationsForGlyphs(font, glyphs, &translation, 1);
    CGRect moved = CGRectOffset(recordRect, translation.width, translation.height);
    CGRect verticalRecordRect = CGRectMake(-CGRectGetMaxY(moved), CGRectGetMinX(moved), moved.size.height, moved.size.width);

    CGRect ourHorizontal = CGRectZero, ourVertical = CGRectZero;
    CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, glyphs, &ourHorizontal, 1);
    CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationVertical, glyphs, &ourVertical, 1);
    printf("  %g pt: record=(%.2f,%.2f %.2fx%.2f) archive's H=(%.2f,%.2f %.2fx%.2f) V=(%.2f,%.2f %.2fx%.2f)\n",
        pointSize, recordRect.origin.x, recordRect.origin.y, recordRect.size.width, recordRect.size.height,
        ourHorizontal.origin.x, ourHorizontal.origin.y, ourHorizontal.size.width, ourHorizontal.size.height,
        ourVertical.origin.x, ourVertical.origin.y, ourVertical.size.width, ourVertical.size.height);
    snprintf(what, sizeof what, "%g pt: the archive's horizontal rectangle is the record's", pointSize);
    check(CGRectEqualToRect(ourHorizontal, recordRect), what);
    snprintf(what, sizeof what, "%g pt: the archive's vertical rectangle is the record's, at the vertical origin", pointSize);
    check(CGRectEqualToRect(ourVertical, verticalRecordRect), what);

    CGRect theirHorizontal = systemBoundingRects(font, kCTFontOrientationHorizontal, glyphs[0]);
    CGRect theirVertical = systemBoundingRects(font, kCTFontOrientationVertical, glyphs[0]);
    if (!CGRectIsNull(theirHorizontal)) {
        printf("  %g pt: 10.9's H=(%.2f,%.2f %.2fx%.2f) V=(%.2f,%.2f %.2fx%.2f)\n", pointSize,
            theirHorizontal.origin.x, theirHorizontal.origin.y, theirHorizontal.size.width, theirHorizontal.size.height,
            theirVertical.origin.x, theirVertical.origin.y, theirVertical.size.width, theirVertical.size.height);
        snprintf(what, sizeof what, "%g pt: 10.9's horizontal rectangle sits below the record's", pointSize);
        check(theirHorizontal.origin.y < recordRect.origin.y, what);
        snprintf(what, sizeof what, "%g pt: 10.9's vertical rectangle sits below the record's", pointSize);
        check(theirVertical.origin.y < verticalRecordRect.origin.y, what);
    }

    CGImageRelease(strike);
    CFRelease(font);
}

// What a text clip lets through: paint the run in a clipping mode, fill the whole context, and count
// the pixels the fill reached. A colour bitmap adds nothing to the clip, so a run of them alone leaves
// nothing to fill through, while a run that also carries an outlined glyph leaves that glyph's shape.
static long clipLetsThrough(CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count, DrawGlyphsFn drawGlyphs)
{
    size_t bytesPerRow = kSide * 4;
    unsigned char *pixels = calloc(bytesPerRow, kSide);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, bytesPerRow, colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGContextSetTextMatrix(context, CGAffineTransformIdentity);
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextSetTextDrawingMode(context, kCGTextClip);
    drawGlyphs(font, glyphs, positions, count, context);
    CGContextSetTextDrawingMode(context, kCGTextFill);
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, kSide, kSide));
    long filled = 0;
    for (size_t y = 0; y < kSide; y++) {
        for (size_t x = 0; x < kSide; x++) {
            const unsigned char *p = pixels + y * bytesPerRow + x * 4;
            // kCGImageAlphaPremultipliedFirst, host order: B G R A on a little-endian machine.
            if (p[2] > 200 && p[1] < 60 && p[0] < 60)
                filled++;
        }
    }
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(pixels);
    return filled;
}

// The clip a mixed run leaves has to be the one CoreText leaves, glyph for glyph, and a run of colour
// bitmaps alone has to leave an empty one rather than an untouched one.
static void runClipModes(CTFontDescriptorRef descriptor)
{
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 160, NULL);
    UniChar characters[2] = { 0xD83D, 0xDE00 };
    CGGlyph colour[2] = { 0, 0 };
    CTFontGetGlyphsForCharacters(font, characters, colour, 2);
    // Glyph 0 is .notdef, the one glyph of this font that carries an outline rather than a strike.
    CGGlyph colourOnly[2] = { colour[0], colour[0] };
    CGPoint colourPositions[2] = { { 200, 300 }, { 400, 300 } };
    CGGlyph mixed[3] = { colour[0], 0, colour[0] };
    CGPoint mixedPositions[3] = { { 200, 300 }, { 400, 300 }, { 600, 300 } };

    DrawGlyphsFn system = systemDrawGlyphs();
    long ours = clipLetsThrough(font, colourOnly, colourPositions, 2, CTFontDrawGlyphs);
    check(!ours, "a clipping run of colour bitmaps alone leaves an empty clip");
    if (system) {
        long theirs = clipLetsThrough(font, colourOnly, colourPositions, 2, system);
        printf("  colour-only clip: archive's lets %ld px through, 10.9's %ld\n", ours, theirs);
        check(ours == theirs, "10.9 leaves the same empty clip");

        ours = clipLetsThrough(font, mixed, mixedPositions, 3, CTFontDrawGlyphs);
        theirs = clipLetsThrough(font, mixed, mixedPositions, 3, system);
        printf("  mixed clip: archive's lets %ld px through, 10.9's %ld\n", ours, theirs);
        check(theirs > 0 && ours == theirs, "a mixed clipping run leaves the outlined glyph's clip, as 10.9 does");
    }
    CFRelease(font);
}

int main(void)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)kFontPath, strlen(kFontPath), false);
    CFArrayRef descriptors = url ? CTFontManagerCreateFontDescriptorsFromURL(url) : NULL;
    if (!descriptors || !CFArrayGetCount(descriptors)) {
        printf("FATAL: no font descriptor for %s\n", kFontPath);
        return 1;
    }
    CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0);

    // 160 is a strike this font carries, 100 falls between its 96- and 160-ppem strikes, and 320 is
    // past the largest strike there is.
    runSize(descriptor, 160);
    runSize(descriptor, 100);
    runSize(descriptor, 320);
    runClipModes(descriptor);

    if (failures)
        printf("CTFontDrawGlyphs sbix probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
