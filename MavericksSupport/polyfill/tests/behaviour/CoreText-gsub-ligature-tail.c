// A web font sanitized through the OTS parser (polyfills/c/ots_font_parser.cpp) keeps a GSUB ligature whose
// record ends the table. This OS bounds a ligature's component array two bytes past the record
// (OTL::GSUB::ApplyLigatureSubst), so Ahem-GSUB-ligatures.ttf's "B U+200D -> p" ligature, the last record
// of its GSUB, forms only when the sanitized GSUB carries two bytes past it.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void check(bool ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", what);
        ++failures;
    }
}

static CFIndex lineGlyphs(CTFontRef font, const UniChar *characters, CFIndex length, CGGlyph *glyphs, CFIndex capacity)
{
    const void *keys[] = { kCTFontAttributeName };
    const void *values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef string = CFStringCreateWithCharacters(NULL, characters, length);
    CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CFIndex count = 0;
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex runCount = CTRunGetGlyphCount(run);
        CGGlyph runGlyphs[16];
        CTRunGetGlyphs(run, CFRangeMake(0, runCount < 16 ? runCount : 16), runGlyphs);
        for (CFIndex i = 0; i < runCount && i < 16; i++) {
            if (runGlyphs[i] != 0xFFFF && count < capacity)
                glyphs[count++] = runGlyphs[i];
        }
    }
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(string);
    CFRelease(attributes);
    return count;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <LayoutTests/fast/text/resources/Ahem-GSUB-ligatures.ttf>\n", argv[0]);
        return 2;
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), false);
    CFDataRef data = NULL;
    CFURLCreateDataAndPropertiesFromResource(NULL, url, &data, NULL, NULL, NULL);
    CFRelease(url);
    check(data, "Ahem-GSUB-ligatures.ttf reads");
    if (!data)
        return 1;
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData(data);
    check(descriptor, "Ahem-GSUB-ligatures.ttf sanitizes");
    if (!descriptor)
        return 1;
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 48, NULL);

    CGGlyph glyphs[8];
    const UniChar joined[] = { 'B', 0x200D };
    CFIndex count = lineGlyphs(font, joined, 2, glyphs, 8);
    const UniChar p[] = { 'p' };
    CGGlyph pGlyph = 0;
    CTFontGetGlyphsForCharacters(font, p, &pGlyph, 1);
    char label[160];
    snprintf(label, sizeof(label), "B U+200D forms the ligature glyph %u (got %ld glyphs, first %u)", pGlyph, (long)count, count ? glyphs[0] : 0);
    check(count == 1 && glyphs[0] == pGlyph, label);

    const UniChar ab[] = { 'A', 'B' };
    count = lineGlyphs(font, ab, 2, glyphs, 8);
    check(count == 1, "A B still forms its ligature");

    CFRelease(font);
    CFRelease(descriptor);
    CFRelease(data);
    if (failures)
        return 1;
    printf("gsub ligature tail: all cases match\n");
    return 0;
}
