// Noto's OS/2 values exclude glyph overshoot. Roboto Extremo's MVAR xhgt
// changes from 1052 to 914 at opsz=144 (independently checked with fontTools).
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "VariableFontInstancer.h"

static int failures;
static CGFloat (*nativeCap)(CTFontRef);
static CGFloat (*nativeX)(CTFontRef);

static void check(int condition, const char *message)
{
    if (!condition) {
        printf("FAIL: %s\n", message);
        ++failures;
    }
}

static void closeTo(CGFloat actual, CGFloat expected, const char *message)
{
    if (!(fabs(actual - expected) < 0.00001)) {
        printf("FAIL: %s: got %.9g, expected %.9g\n", message, actual, expected);
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

static CTFontDescriptorRef fromURL(const char *path)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CFArrayRef descriptors = url ? CTFontManagerCreateFontDescriptorsFromURL(url) : NULL;
    CTFontDescriptorRef descriptor = descriptors && CFArrayGetCount(descriptors) ? (CTFontDescriptorRef)CFRetain(CFArrayGetValueAtIndex(descriptors, 0)) : NULL;
    if (descriptors)
        CFRelease(descriptors);
    if (url)
        CFRelease(url);
    return descriptor;
}

static void staticHeights(const char *path, int cap, int x, int fallbackCap, int fallbackX)
{
    CTFontDescriptorRef descriptor = fromURL(path);
    check(descriptor != NULL, path);
    if (!descriptor)
        return;
    const CGAffineTransform matrices[] = {
        { 1, 0, 0, 1, 0, 0 }, { 2, 0, 0, 2, 0, 0 },
        { 1, 0, 0, -1, 0, 0 }, { 0, 1, -1, 0, 7, 9 },
        { 1.5, 0.25, 0.5, 0.75, 11, -13 }
    };
    for (size_t m = 0; m < sizeof matrices / sizeof *matrices; ++m) {
        for (unsigned size = 14; size <= 84; size += 14) {
            CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, &matrices[m]);
            check(font != NULL, "font realizes with matrix and size");
            if (!font)
                continue;
            CGAffineTransform transform = CGAffineTransformScale(CTFontGetMatrix(font), CTFontGetSize(font) / CTFontGetUnitsPerEm(font), CTFontGetSize(font) / CTFontGetUnitsPerEm(font));
            closeTo(CTFontGetCapHeight(font), fallbackCap ? nativeCap(font) : CGPointApplyAffineTransform(CGPointMake(0, cap), transform).y, "cap height");
            closeTo(CTFontGetXHeight(font), fallbackX ? nativeX(font) : CGPointApplyAffineTransform(CGPointMake(0, x), transform).y, "x height");
            CFRelease(font);
        }
    }
    CFRelease(descriptor);
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
    CTFontDescriptorRef base = CTFontManagerCreateFontDescriptorFromData(source);
    const void *key = kCTFontVariationAttribute;
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, &key, (const void **)&variation, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = base ? CTFontDescriptorCreateCopyWithAttributes(base, attributes) : NULL;
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, 64, NULL) : NULL;
    check(font != NULL, "CoreText realizes the MVAR font");
    if (font) {
        closeTo(CTFontGetXHeight(font), (capVaries ? 1052 : 914) / 32., "CoreText varied x height");
        closeTo(CTFontGetCapHeight(font), (capVaries ? 1318 : 1456) / 32., "CoreText varied cap height");
        CFRelease(font);
    }
    if (descriptor)
        CFRelease(descriptor);
    if (base)
        CFRelease(base);
    CFRelease(attributes);
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
    void *coreText = dlopen("/System/Library/Frameworks/CoreText.framework/CoreText", RTLD_NOW | RTLD_LOCAL);
    nativeCap = (CGFloat (*)(CTFontRef))dlsym(coreText, "CTFontGetCapHeight");
    nativeX = (CGFloat (*)(CTFontRef))dlsym(coreText, "CTFontGetXHeight");
    check(nativeCap && nativeX, "native comparison APIs resolve");
    if (!nativeCap || !nativeX)
        return 1;
    struct { const char *name; int cap; int x; int fallbackCap; int fallbackX; } cases[] = {
        { "ordinary", 1462, 1098, 0, 0 }, { "signed", -500, -250, 0, 0 },
        { "zero", 0, 0, 1, 1 }, { "old-version", 0, 0, 1, 1 },
        { "truncated", 0, 1098, 1, 0 }, { "missing", 0, 0, 1, 1 }
    };
    char path[4096];
    for (size_t i = 0; i < sizeof cases / sizeof *cases; ++i) {
        snprintf(path, sizeof path, "%s/%s.ttf", argv[1], cases[i].name);
        staticHeights(path, cases[i].cap, cases[i].x, cases[i].fallbackCap, cases[i].fallbackX);
    }
    snprintf(path, sizeof path, "%s/variable.ttf", argv[1]);
    variableHeights(path, 0);
    snprintf(path, sizeof path, "%s/variable-cap.ttf", argv[1]);
    variableHeights(path, 1);
    layoutVariations(argv[2]);
    layoutVariations(argv[3]);
    snprintf(path, sizeof path, "%s/remapped-origin.ttf", argv[1]);
    remappedDefault(path);
    printf("CoreText font heights: %d failure(s)\n", failures);
    return !!failures;
}
