// CTFontGetVerticalTranslationsForGlyphs (polyfills/c/CoreText.c): a glyph set upright hangs from its font's
// ascent when the font carries no vmtx or VORG, as it does from the vertical origin a font with those
// tables names; the horizontal half-advance is 10.9's own.
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

static bool near(CGFloat a, CGFloat b)
{
    return a > b - 0.01 && a < b + 0.01;
}

static void expectTranslation(const char *what, CTFontRef font, const UniChar *characters, CFIndex length, CGFloat width, CGFloat height)
{
    CGGlyph glyphs[2] = { 0, 0 };
    CTFontGetGlyphsForCharacters(font, characters, glyphs, length);
    CGSize translation = { 0, 0 };
    CTFontGetVerticalTranslationsForGlyphs(font, glyphs, &translation, 1);
    char label[200];
    snprintf(label, sizeof(label), "%s: translation (%.2f, %.2f), expected (%.2f, %.2f)", what, translation.width, translation.height, width, height);
    check(glyphs[0] && near(translation.width, width) && near(translation.height, height), label);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <LayoutTests/fast/text/resources directory>\n", argv[0]);
        return 2;
    }
    char path[1024];
    snprintf(path, sizeof(path), "%s/Ahem-multi-code-unit.ttf", argv[1]);
    CGDataProviderRef provider = CGDataProviderCreateWithFilename(path);
    CGFontRef graphicsFont = provider ? CGFontCreateWithDataProvider(provider) : NULL;
    check(graphicsFont, "Ahem-multi-code-unit.ttf loads");
    if (graphicsFont) {
        CTFontRef ahem = CTFontCreateWithGraphicsFont(graphicsFont, 100, NULL, NULL);
        const UniChar supplementary[] = { 0xD840, 0xDC0B };
        const UniChar letter[] = { 'A' };
        expectTranslation("Ahem U+2000B", ahem, supplementary, 2, -50, -80);
        expectTranslation("Ahem A", ahem, letter, 1, -50, -80);
        CFRelease(ahem);
        CFRelease(graphicsFont);
    }
    if (provider)
        CGDataProviderRelease(provider);

    CTFontRef times = CTFontCreateWithName(CFSTR("Times-Roman"), 100, NULL);
    const UniChar x[] = { 'x' };
    const UniChar t[] = { 'T' };
    expectTranslation("Times x", times, x, 1, -25, -75);
    expectTranslation("Times T", times, t, 1, -30.52, -75);

    // A font that carries its own vertical metrics keeps 10.9's answer.
    CTFontRef hiragino = CTFontCreateWithName(CFSTR("HiraKakuProN-W3"), 100, NULL);
    const UniChar hiraganaA[] = { 0x3042 };
    expectTranslation("Hiragino U+3042", hiragino, hiraganaA, 1, -50, -88);
    expectTranslation("Hiragino x", hiragino, x, 1, -50, -88);

    snprintf(path, sizeof(path), "%s/../../../imported/w3c/web-platform-tests/fonts/noto/cjk/NotoSansCJKjp-Regular-subset-chws.otf", argv[1]);
    CGDataProviderRef cffProvider = CGDataProviderCreateWithFilename(path);
    CFDataRef cff = cffProvider ? CGDataProviderCopyData(cffProvider) : NULL;
    CTFontDescriptorRef cffDescriptor = cff ? CTFontManagerCreateFontDescriptorFromData(cff) : NULL;
    check(cffDescriptor != NULL, "CFF web font sanitizes and produces a descriptor");
    if (cffDescriptor) {
        CTFontRef font = CTFontCreateWithFontDescriptor(cffDescriptor, 100, NULL);
        CFStringRef name = CTFontCopyPostScriptName(font);
        check(name && CFEqual(name, CFSTR("NotoSansCJKjp-Regular")), "CFF descriptor retains the web font's identity");
        if (name) CFRelease(name);
        CFRelease(font); CFRelease(cffDescriptor);
    }
    if (cff) CFRelease(cff);
    if (cffProvider) CGDataProviderRelease(cffProvider);

    if (failures)
        return 1;
    printf("vertical origins: all cases match\n");
    return 0;
}
