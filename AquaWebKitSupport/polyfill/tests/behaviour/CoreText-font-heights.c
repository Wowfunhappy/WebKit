// The variable-font instancer (polyfills/c/VariableFontInstancer.cpp) bakes MVAR into a static instance's OS/2:
// Roboto Extremo's MVAR xhgt changes from 1052 to 914 at opsz=144 (independently checked with fontTools).
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "VariableFontInstancer.h"

static int failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        printf("FAIL: %s\n", message);
        ++failures;
    }
}

static CFDataRef readData(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file)
        return NULL;
    CFMutableDataRef result = CFDataCreateMutable(NULL, 0);
    UInt8 buffer[16384];
    size_t count;
    while ((count = fread(buffer, 1, sizeof buffer, file)))
        CFDataAppendBytes(result, buffer, count);
    fclose(file);
    return result;
}

static CFDictionaryRef opticalSize(double value)
{
    int32_t tag = 'opsz';
    CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt32Type, &tag);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberDoubleType, &value);
    CFDictionaryRef result = CFDictionaryCreate(NULL, (const void **)&key, (const void **)&number, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(key);
    CFRelease(number);
    return result;
}

static int16_t metric(CFDataRef table, size_t offset)
{
    if (!table || CFDataGetLength(table) < (CFIndex)(offset + 2))
        return 0;
    const UInt8 *bytes = CFDataGetBytePtr(table);
    return (int16_t)((bytes[offset] << 8) | bytes[offset + 1]);
}

static void variableHeights(const char *path, int capVaries)
{
    CFDataRef source = readData(path);
    check(source != NULL, "variable font fixture reads");
    if (!source)
        return;
    CFDictionaryRef variation = opticalSize(144);
    CFDataRef instance = wk_legacy_variable_font_instance(source, variation);
    check(instance != NULL, "nondefault MVAR instance is generated");
    CFDataRef os2 = instance ? wk_legacy_variable_font_copy_table(instance, 'OS/2') : NULL;
    check(metric(os2, 86) == (capVaries ? 1052 : 914), "instanced OS/2 x height");
    check(metric(os2, 88) == (capVaries ? 1318 : 1456), "instanced OS/2 cap height");
    CFDataRef remaining = instance ? wk_legacy_variable_font_copy_table(instance, 'MVAR') : NULL;
    check(!remaining, "static instance consumes MVAR");
    if (remaining)
        CFRelease(remaining);
    if (os2)
        CFRelease(os2);
    if (instance)
        CFRelease(instance);
    CFRelease(variation);
    CFRelease(source);
}

static CTFontRef fontWithAxes(CFDataRef data, double weight, double width)
{
    CTFontDescriptorRef base = CTFontManagerCreateFontDescriptorFromData(data);
    if (!base)
        return NULL;
    int32_t tags[] = { 'wght', 'wdth' };
    double values[] = { weight, width };
    CFMutableDictionaryRef axes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (unsigned i = 0; i < 2; ++i) {
        CFNumberRef key = CFNumberCreate(NULL, kCFNumberSInt32Type, &tags[i]);
        CFNumberRef value = CFNumberCreate(NULL, kCFNumberDoubleType, &values[i]);
        CFDictionarySetValue(axes, key, value);
        CFRelease(key);
        CFRelease(value);
    }
    const void *key = kCTFontVariationAttribute;
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, &key, (const void **)&axes, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes);
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 2048, NULL);
    CFRelease(descriptor);
    CFRelease(attributes);
    CFRelease(axes);
    CFRelease(base);
    return font;
}

static void shapedGlyph(CTFontRef font, CGGlyph expected)
{
    const void *key = kCTFontAttributeName;
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, &key, (const void **)&font, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef string = CFAttributedStringCreate(NULL, CFSTR("H"), attributes);
    CTLineRef line = CTLineCreateWithAttributedString(string);
    CFArrayRef runs = line ? CTLineGetGlyphRuns(line) : NULL;
    check(runs && CFArrayGetCount(runs) == 1, "conditional feature shapes one run");
    if (runs && CFArrayGetCount(runs) == 1) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, 0);
        CGGlyph glyph = 0;
        check(CTRunGetGlyphCount(run) == 1, "conditional feature shapes one glyph");
        if (CTRunGetGlyphCount(run) == 1)
            CTRunGetGlyphs(run, CFRangeMake(0, 1), &glyph);
        check(glyph == expected, "conditional feature selects the reference glyph ID");
    }
    if (line)
        CFRelease(line);
    CFRelease(string);
    CFRelease(attributes);
}

static void layoutVariations(const char *path)
{
    CFDataRef data = readData(path);
    check(data != NULL, "layout variation font reads");
    if (!data)
        return;
    const double weights[] = { 400, 1000, 1000 };
    const double widths[] = { 100, 90, 75 };
    for (unsigned i = 0; i < 3; ++i) {
        CTFontRef font = fontWithAxes(data, weights[i], widths[i]);
        check(font != NULL, "layout variation font realizes");
        if (font) {
            shapedGlyph(font, i == 2 ? 2 : 1);
            CFRelease(font);
        }
    }
    CFRelease(data);
}

static void remappedDefault(const char *path)
{
    CFDataRef source = readData(path);
    check(source != NULL, "origin-remapping font reads");
    if (!source)
        return;
    CFDataRef originalOS2 = wk_legacy_variable_font_copy_table(source, 'OS/2');
    int16_t expectedCap = metric(originalOS2, 88) + 100;
    if (originalOS2)
        CFRelease(originalOS2);
    CFDataRef instance = wk_legacy_variable_font_strip_variations(source);
    CFDataRef os2 = wk_legacy_variable_font_copy_table(instance, 'OS/2');
    check(metric(os2, 88) == expectedCap, "default instance applies constant MVAR");
    CFDataRef hmtx = wk_legacy_variable_font_copy_table(instance, 'hmtx');
    check(metric(hmtx, 4) == 1532, "default instance remaps glyph advance");
    if (os2)
        CFRelease(os2);
    if (hmtx)
        CFRelease(hmtx);
    // This synthetic avar2 table omits axis segment maps (axisCount=0).
    // OTS 9.2 requires the count to match fvar and drops this representation,
    // so public CoreText realization does not test the same remapped input.
    // Retain the raw instancer assertions above and the real avar1/avar2 public
    // checks; the synthetic public path is outside this merge's reduced scope.
    puts("SKIP: synthetic remapped-origin CoreText integration: OTS 9.2 drops its zero-axis avar2 table; raw instancer checks retained");
    CFRelease(instance);
    CFRelease(source);
}

int main(int argc, char **argv)
{
    if (argc != 4)
        return 1;
    char path[4096];
    snprintf(path, sizeof path, "%s/variable.ttf", argv[1]);
    variableHeights(path, 0);
    snprintf(path, sizeof path, "%s/variable-cap.ttf", argv[1]);
    variableHeights(path, 1);
    layoutVariations(argv[2]);
    layoutVariations(argv[3]);
    snprintf(path, sizeof path, "%s/remapped-origin.ttf", argv[1]);
    remappedDefault(path);
    printf("font heights: %d failure(s)\n", failures);
    return !!failures;
}
