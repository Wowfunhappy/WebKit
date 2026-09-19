// CTFontGetGlyphsForCharacters and CTFontGetVerticalGlyphsForCharacters (polyfills/c/CoreText.c) map every
// control character WebKit leaves to CoreText to the glyph U+0000 maps to, however long the run it is asked
// for in, as WebKit's glyph page 0 reads it (Font::platformGlyphInit). A carriage return therefore takes the
// zero-width .null glyph rather than a space-wide one; tab and line feed keep their space-wide glyph.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>

extern bool CTFontGetVerticalGlyphsForCharacters(CTFontRef, const UniChar[], CGGlyph[], CFIndex);

static int failures;

static void check(bool ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", what);
        ++failures;
    }
}

static void expectPage(const char *name, bool vertical)
{
    CFStringRef fontName = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CTFontRef font = CTFontCreateWithName(fontName, 16, NULL);
    CFRelease(fontName);
    UniChar page[256];
    CGGlyph glyphs[256];
    for (int c = 0; c < 256; ++c)
        page[c] = (UniChar)c;
    if (vertical)
        CTFontGetVerticalGlyphsForCharacters(font, page, glyphs, 256);
    else
        CTFontGetGlyphsForCharacters(font, page, glyphs, 256);
    const UniChar null = 0;
    CGGlyph alone = 0;
    CTFontGetGlyphsForCharacters(font, &null, &alone, 1);
    CGGlyph space = glyphs[0x20];
    char label[200];

    snprintf(label, sizeof(label), "%s%s: U+0000 in a page of 256 is glyph %u, as alone (%u)", name, vertical ? " vertical" : "", glyphs[0], alone);
    check(glyphs[0] == alone, label);
    snprintf(label, sizeof(label), "%s%s: U+000D is glyph %u, the U+0000 glyph %u", name, vertical ? " vertical" : "", glyphs[0x0D], alone);
    check(glyphs[0x0D] == alone, label);
    if (alone) {
        CGSize advance;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyphs[0x0D], &advance, 1);
        snprintf(label, sizeof(label), "%s%s: U+000D advances %.2f", name, vertical ? " vertical" : "", advance.width);
        check(advance.width == 0, label);
    }
    for (int c = 1; c < 0xA0; ++c) {
        if (!((c < 0x20 && c != 0x09 && c != 0x0A) || c >= 0x7F))
            continue;
        snprintf(label, sizeof(label), "%s%s: U+%04X is the U+0000 glyph", name, vertical ? " vertical" : "", c);
        check(glyphs[c] == alone, label);
    }
    CGSize tabAdvance, spaceAdvance;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyphs[0x09], &tabAdvance, 1);
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &space, &spaceAdvance, 1);
    snprintf(label, sizeof(label), "%s%s: U+0009 keeps a space-wide glyph (%.2f, space %.2f)", name, vertical ? " vertical" : "", tabAdvance.width, spaceAdvance.width);
    check(glyphs[0x09] && tabAdvance.width == spaceAdvance.width, label);
    snprintf(label, sizeof(label), "%s%s: 'A' still maps", name, vertical ? " vertical" : "");
    check(glyphs['A'] != 0, label);
    CFRelease(font);
}

int main(void)
{
    expectPage("Times-Roman", false);
    expectPage("Helvetica", false);
    expectPage("LucidaGrande", false);
    expectPage("Georgia", false);
    expectPage("Times-Roman", true);

    // A run with no control character keeps CoreText's answer, return value included.
    CTFontRef times = CTFontCreateWithName(CFSTR("Times-Roman"), 16, NULL);
    const UniChar text[] = { 'a', 'b', 0x3042 };
    CGGlyph glyphs[3];
    bool mapped = CTFontGetGlyphsForCharacters(times, text, glyphs, 3);
    check(!mapped && glyphs[0] && glyphs[1] && !glyphs[2], "Times 'a' 'b' U+3042 reports the kana unmapped");
    const UniChar carriageReturnOnly[] = { 'a', 0x0D };
    mapped = CTFontGetGlyphsForCharacters(times, carriageReturnOnly, glyphs, 2);
    check(mapped && glyphs[1] == 1, "Times 'a' U+000D maps both, U+000D to .null");
    CFRelease(times);

    if (failures)
        return 1;
    printf("control character glyphs: all cases match\n");
    return 0;
}
