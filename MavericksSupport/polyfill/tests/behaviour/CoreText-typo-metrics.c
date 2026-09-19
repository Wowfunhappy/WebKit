// OS/2 fsSelection bit 7, USE_TYPO_METRICS (polyfills/c/CoreText.c). 10.9's CoreText reports hhea's
// ascender, descender and lineGap for every font and ignores the bit, which asks that
// sTypoAscender/sTypoDescender/sTypoLineGap be used in their place. WebCore reads all three straight
// into the font's metrics, so on a font that sets the bit every line box, baseline and canvas text
// measurement lands against the wrong numbers.
//
// The fixture is the font the canvas text-metric tests use: unitsPerEm 1024, hhea 1745/-805/92, OS/2
// sTypo 768/-256/92, fsSelection 0xC0. What a realized font owes at 40pt is 30 / 10 / 3.59375 --
// descent positive where the typo descender is negative -- and the three follow the font's scale: the
// point size times the font matrix's vertical scale, which is what CoreText applies to the hhea values.
// A font with the bit clear keeps 10.9's own answers exactly.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include "wk_polyfill.h"

#include <stdio.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static void checkClose(CGFloat actual, double expected, const char *what)
{
    if (fabs((double)actual - expected) > 0.001) {
        printf("FAIL: %s (expected %.5f, got %.5f)\n", what, expected, (double)actual);
        failures++;
    }
}

static CTFontDescriptorRef descriptorFromFile(const char *path)
{
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    CFURLRef url = string ? CFURLCreateWithFileSystemPath(kCFAllocatorDefault, string, kCFURLPOSIXPathStyle, false) : NULL;
    CFDataRef data = NULL;
    if (url)
        CFURLCreateDataAndPropertiesFromResource(kCFAllocatorDefault, url, &data, NULL, NULL, NULL);
    CTFontDescriptorRef descriptor = data ? CTFontManagerCreateFontDescriptorFromData(data) : NULL;
    if (data)
        CFRelease(data);
    if (url)
        CFRelease(url);
    if (string)
        CFRelease(string);
    return descriptor;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        printf("### CoreText typo metrics: no font path given\n");
        return 1;
    }
    CTFontDescriptorRef descriptor = descriptorFromFile(argv[1]);
    check(descriptor != NULL, "the fixture font parses");
    if (!descriptor)
        return 1;

    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 40, NULL);
    check(font != NULL, "the fixture font realizes at 40pt");
    if (!font)
        return 1;
    check(CTFontGetUnitsPerEm(font) == 1024, "the fixture font has 1024 units per em");
    checkClose(CTFontGetAscent(font), 30, "the typo ascender is the ascent at 40pt");
    checkClose(CTFontGetDescent(font), 10, "the typo descender is the descent at 40pt, positive");
    checkClose(CTFontGetLeading(font), 3.59375, "the typo line gap is the leading at 40pt");

    CTFontRef half = CTFontCreateCopyWithAttributes(font, 20, NULL, NULL);
    checkClose(CTFontGetAscent(half), 15, "half the point size is half the ascent");
    checkClose(CTFontGetDescent(half), 5, "half the point size is half the descent");
    if (half)
        CFRelease(half);

    CGAffineTransform doubled = CGAffineTransformMakeScale(2, 2);
    CTFontRef scaled = CTFontCreateWithFontDescriptor(descriptor, 40, &doubled);
    checkClose(CTFontGetAscent(scaled), 60, "a doubled matrix doubles the ascent");
    checkClose(CTFontGetDescent(scaled), 20, "a doubled matrix doubles the descent");
    checkClose(CTFontGetLeading(scaled), 7.1875, "a doubled matrix doubles the leading");
    if (scaled)
        CFRelease(scaled);

    CGAffineTransform flipped = CGAffineTransformMakeScale(1, -1);
    CTFontRef upsideDown = CTFontCreateWithFontDescriptor(descriptor, 40, &flipped);
    checkClose(CTFontGetAscent(upsideDown), -30, "a flipped matrix negates the ascent");
    checkClose(CTFontGetDescent(upsideDown), -10, "a flipped matrix negates the descent");
    if (upsideDown)
        CFRelease(upsideDown);

    CTFontRef nothing = CTFontCreateWithFontDescriptor(descriptor, 0, NULL);
    checkClose(CTFontGetAscent(nothing), 0, "a font of size 0 has no ascent");
    checkClose(CTFontGetDescent(nothing), 0, "a font of size 0 has no descent");
    checkClose(CTFontGetLeading(nothing), 0, "a font of size 0 has no leading");
    if (nothing)
        CFRelease(nothing);

    // A face with the bit clear keeps this OS's own hhea answers.
    CTFontRef helvetica = CTFontCreateWithName(CFSTR("Helvetica"), 40, NULL);
    checkClose(CTFontGetAscent(helvetica), 30.80078125, "Helvetica keeps its hhea ascent");
    checkClose(CTFontGetDescent(helvetica), 9.19921875, "Helvetica keeps its hhea descent");
    checkClose(CTFontGetLeading(helvetica), 0, "Helvetica keeps its hhea line gap");
    if (helvetica)
        CFRelease(helvetica);

    CFRelease(font);
    CFRelease(descriptor);

    if (failures) {
        printf("### CoreText typo metrics: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText typo metrics: USE_TYPO_METRICS fonts report their OS/2 typo metrics\n");
    return 0;
}
