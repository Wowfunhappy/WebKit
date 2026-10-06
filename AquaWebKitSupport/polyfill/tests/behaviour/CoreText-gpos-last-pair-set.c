// A web font sanitized through the OTS parser (polyfills/c/ots_font_parser.cpp) kerns the last glyph each
// GPOS PairPos format 1 subtable covers. This OS applies a format 1 pair only when the first glyph's Coverage
// index is below pairSetCount - 1 (OTL::GPOS::ApplyPairPos), so that glyph's pairs kern only once the
// sanitized GPOS makes its PairSet reachable.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <math.h>
#include <string.h>

extern bool CTFontTransformGlyphs(CTFontRef, CGGlyph[], CGSize[], CFIndex, uint32_t);

static int failures;

static void check(bool ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", what);
        ++failures;
    }
}

static CTFontRef sanitizedFont(const char *path, CGFloat size)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFDataRef data = NULL;
    CFURLCreateDataAndPropertiesFromResource(NULL, url, &data, NULL, NULL, NULL);
    CFRelease(url);
    if (!data)
        return NULL;
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData(data);
    CFRelease(data);
    if (!descriptor)
        return NULL;
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    CFRelease(descriptor);
    return font;
}

// The kerning 10.9's positioning applies between two glyphs.
static double kerning(CTFontRef font, CGGlyph first, CGGlyph second)
{
    CGGlyph glyphs[2] = { first, second };
    CGSize advances[2];
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, advances, 2);
    double unkerned = advances[0].width + advances[1].width;
    CTFontTransformGlyphs(font, glyphs, advances, 2, 2);
    return advances[0].width + advances[1].width - unkerned;
}

static void expectKerning(const char *what, CTFontRef font, CGGlyph first, CGGlyph second, double expected)
{
    double value = kerning(font, first, second);
    char label[200];
    snprintf(label, sizeof(label), "%s: kerning %.2f, expected %.2f", what, value, expected);
    check(value > expected - 0.05 && value < expected + 0.05, label);
}

static uint16_t readU16(const uint8_t *p)
{
    return (uint16_t)((p[0] << 8) | p[1]);
}

static uint32_t readU32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void putU16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)(value >> 8);
    p[1] = (uint8_t)value;
}

static void putU32(uint8_t *p, uint32_t value)
{
    putU16(p, (uint16_t)(value >> 16));
    putU16(p + 2, (uint16_t)value);
}

// A GPOS with one latn/kern feature and two lookups: lookup 0 (at 0x34) is PairPos format 1 at 0x4c, with
// XPlacement value records so its bytes 4..9 read 1, 1, 1; lookup 1 is SinglePos format 1 at 0x44. When
// `overlapping`, the SinglePos Coverage is those bytes -- format 1, one glyph, glyph 1 -- at 0x50;
// otherwise it is a separate table with the same content at 0x66.
static size_t buildPairPosGPOS(uint8_t *g, bool overlapping)
{
    static const uint8_t common[] = {
        0x00, 0x01, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x1e, 0x00, 0x2e,
        /* ScriptList */ 0x00, 0x01, 'l', 'a', 't', 'n', 0x00, 0x08,
        /* Script */ 0x00, 0x04, 0x00, 0x00,
        /* LangSys */ 0x00, 0x00, 0xff, 0xff, 0x00, 0x01, 0x00, 0x00,
        /* FeatureList */ 0x00, 0x01, 'k', 'e', 'r', 'n', 0x00, 0x08,
        /* Feature */ 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        /* LookupList */ 0x00, 0x02, 0x00, 0x06, 0x00, 0x0e,
        /* Lookup 0 at 0x34 */ 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x18,
        /* Lookup 1 at 0x3c */ 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08,
        /* SinglePos at 0x44 */ 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0xff, 0xce,
        /* PairPos at 0x4c */ 0x00, 0x01, 0x00, 0x14, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x0c,
        /* PairSet at 0x58 */ 0x00, 0x01, 0x00, 0x0d, 0xff, 0x9c, 0x00, 0x00,
        /* Coverage at 0x60 */ 0x00, 0x01, 0x00, 0x01, 0x00, 0x0d,
    };
    memcpy(g, common, sizeof(common));
    size_t length = sizeof(common);
    if (overlapping)
        putU16(g + 0x46, 0x50 - 0x44);
    else {
        static const uint8_t coverage[] = { 0x00, 0x01, 0x00, 0x01, 0x00, 0x01 };
        memcpy(g + length, coverage, sizeof(coverage));
        putU16(g + 0x46, (uint16_t)(length - 0x44));
        length += sizeof(coverage);
    }
    return length;
}

// The GPOS the OTS parser gives csstest-weights-900-kerned.ttf with its GPOS replaced by `gpos`.
static CFDataRef sanitizedGPOS(const char *path, const uint8_t *gpos, size_t gposLength)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFDataRef original = NULL;
    CFURLCreateDataAndPropertiesFromResource(NULL, url, &original, NULL, NULL, NULL);
    CFRelease(url);
    if (!original)
        return NULL;
    CFMutableDataRef font = CFDataCreateMutableCopy(NULL, 0, original);
    CFRelease(original);
    CFDataSetLength(font, (CFDataGetLength(font) + 3) & ~(CFIndex)3);
    const CFIndex placed = CFDataGetLength(font);
    CFDataAppendBytes(font, gpos, (CFIndex)gposLength);
    CFDataSetLength(font, (CFDataGetLength(font) + 3) & ~(CFIndex)3);
    uint8_t *sfnt = CFDataGetMutableBytePtr(font);
    for (uint16_t i = 0; i < readU16(sfnt + 4); i++) {
        uint8_t *record = sfnt + 12 + 16 * i;
        if (readU32(record) == 0x47504f53) {
            putU32(record + 8, (uint32_t)placed);
            putU32(record + 12, (uint32_t)gposLength);
        }
    }
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData(font);
    CFRelease(font);
    if (!descriptor)
        return NULL;
    CTFontRef realized = CTFontCreateWithFontDescriptor(descriptor, 12, NULL);
    CFRelease(descriptor);
    CFDataRef table = CTFontCopyTable(realized, kCTFontTableGPOS, kCTFontTableOptionNoOptions);
    CFRelease(realized);
    return table;
}

// A GPOS the rewrite refuses comes out of the parser as it went in, or not at all.
static void expectRefusal(const char *path, const char *label, const uint8_t *bytes, size_t length)
{
    CFDataRef sanitized = sanitizedGPOS(path, bytes, length);
    check(!sanitized || ((size_t)CFDataGetLength(sanitized) == length && !memcmp(CFDataGetBytePtr(sanitized), bytes, length)), label);
    if (sanitized) CFRelease(sanitized);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <web-platform-tests directory>\n", argv[0]);
        return 2;
    }
    char path[1024];

    // csstest-weights-900-kerned.ttf kerns "9 9" by -2883 units of 2048 through one PairPos format 1 subtable
    // covering one glyph.
    snprintf(path, sizeof(path), "%s/css/css-fonts/variations/resources/csstest-weights-900-kerned.ttf", argv[1]);
    CTFontRef weights = sanitizedFont(path, 2048);
    check(weights, "csstest-weights-900-kerned.ttf sanitizes");
    if (weights) {
        const UniChar nine = '9';
        CGGlyph glyph = 0;
        CTFontGetGlyphsForCharacters(weights, &nine, &glyph, 1);
        expectKerning("csstest-weights 9 9, the only covered glyph", weights, glyph, glyph, -2883);
        CFRelease(weights);
    }

    // Lato-Medium.ttf's first kerning subtable (in an Extension lookup) ends its Coverage with glyph 335,
    // which kerns glyph 106 by -66 units of 2000; a glyph covered earlier keeps its own pairs.
    snprintf(path, sizeof(path), "%s/fonts/Lato-Medium.ttf", argv[1]);
    CTFontRef lato = sanitizedFont(path, 2000);
    check(lato, "Lato-Medium.ttf sanitizes");
    if (lato) {
        expectKerning("Lato glyph 335, the last covered glyph, with 106", lato, 335, 106, -66);
        const UniChar av[] = { 'A', 'V' };
        CGGlyph glyphs[2] = { 0, 0 };
        CTFontGetGlyphsForCharacters(lato, av, glyphs, 2);
        check(kerning(lato, glyphs[0], glyphs[1]) < -50, "Lato A V still kerns");
        CFRelease(lato);
    }

    // A hand-built GPOS whose second lookup's Coverage starts 4 bytes into the first lookup's PairPos
    // subtable, inside the bytes an Extension subtable would take, comes through unchanged; the same GPOS
    // with that Coverage elsewhere is rewritten.
    snprintf(path, sizeof(path), "%s/css/css-fonts/variations/resources/csstest-weights-900-kerned.ttf", argv[1]);
    uint8_t overlapping[128], separate[128];
    size_t overlappingLength = buildPairPosGPOS(overlapping, true);
    size_t separateLength = buildPairPosGPOS(separate, false);
    CFDataRef sanitizedOverlapping = sanitizedGPOS(path, overlapping, overlappingLength);
    CFDataRef sanitizedSeparate = sanitizedGPOS(path, separate, separateLength);
    check(sanitizedOverlapping && (size_t)CFDataGetLength(sanitizedOverlapping) == overlappingLength
        && !memcmp(CFDataGetBytePtr(sanitizedOverlapping), overlapping, overlappingLength),
        "GPOS with a Coverage inside a PairPos subtable's first 8 bytes comes through unchanged");
    check(sanitizedSeparate && CFDataGetLength(sanitizedSeparate) > (CFIndex)separateLength
        && readU16(CFDataGetBytePtr(sanitizedSeparate) + 0x34) == 9,
        "the same GPOS with that Coverage elsewhere has its PairPos lookup made an Extension lookup");
    if (sanitizedOverlapping)
        CFRelease(sanitizedOverlapping);
    if (sanitizedSeparate)
        CFRelease(sanitizedSeparate);

    uint8_t bad[256];
    size_t badLength = buildPairPosGPOS(bad, false);
    putU16(bad + 0x4e, 10);
    expectRefusal(path, "Coverage below the offset array end is not moved", bad, badLength);
    badLength = buildPairPosGPOS(bad, false);
    putU16(bad + 0x50, 0x10);
    putU16(bad + 0x5c, 8);
    expectRefusal(path, "a Device below the offset array end is not moved", bad, badLength);
    badLength = buildPairPosGPOS(bad, false);
    putU16(bad + 0x62, 2);
    putU16(bad + 0x66, 14);
    expectRefusal(path, "Coverage count larger than PairSetCount gains no pairs", bad, badLength);
    badLength = buildPairPosGPOS(bad, false);
    putU16(bad + 0x60, 2);
    putU16(bad + 0x64, 13); putU16(bad + 0x66, 14); putU16(bad + 0x68, 0);
    expectRefusal(path, "format 2 Coverage count must also equal PairSetCount", bad, badLength);
    badLength = buildPairPosGPOS(bad, false);
    putU16(bad + 0x46, 0x4c - 0x44);
    expectRefusal(path, "Coverage at the PairPos first byte prevents an Extension stub", bad, badLength);

    if (failures)
        return 1;
    printf("gpos last pair set: all cases match\n");
    return 0;
}
