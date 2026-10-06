// Variable fonts built from sfnt bytes (polyfills/c/CoreText.c). A font CTFontManagerCreateFontDescriptorFromData
// describes realizes on this OS from a static cut of its bytes, and 10.9 reports no axes, no variation
// and no variation tables for such a font. Newer CoreText answers all three from the variable font, which
// is where WebCore reads an @font-face's weight, width and slope ranges, its axis defaults and whether it
// is a TrueType GX font.
//
// argv[1] is variabletest_matching.ttf (WPT css-fonts): axes wdth 50/100/200, slnt -90/0/90, ital 0/0/1
// and wght 100/400/900 (minimum/default/maximum). Its em is 1000 units, so at 1000pt a glyph's ink width
// is its width in units: 'P' is 800 wide at the default instance, 1800 at wght 900 and 1400 at wght 700;
// 'M' is 1000 wide, and 1800 at wdth 200. argv[2] is /Library/Fonts/Skia.ttf, the file the installed
// Skia is: its axes answer exactly as the installed face's do, and 'a' measures 31.0938 wide at 80pt on
// the defaults and 34.2969 at the weight WebCore asks a GX font for at CSS weight 700.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdio.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static void checkWidth(double width, double expected, const char *what)
{
    if (!(fabs(width - expected) <= 0.001)) {
        printf("FAIL: %s (expected %.4f, got %.4f)\n", what, expected, width);
        failures++;
    }
}

static CTFontDescriptorRef descriptorFromFile(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file)
        return NULL;
    CFMutableDataRef bytes = CFDataCreateMutable(kCFAllocatorDefault, 0);
    UInt8 buffer[65536];
    size_t read;
    while ((read = fread(buffer, 1, sizeof buffer, file)) > 0)
        CFDataAppendBytes(bytes, buffer, (CFIndex)read);
    fclose(file);
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData(bytes);
    CFRelease(bytes);
    return descriptor;
}

static double inkWidth(CTFontRef font, UniChar character)
{
    CGGlyph glyph = 0;
    if (!font || !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        return NAN;
    return CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &glyph, NULL, 1).size.width;
}

static uint32_t tagOf(const char *tag)
{
    return ((uint32_t)(unsigned char)tag[0] << 24) | ((uint32_t)(unsigned char)tag[1] << 16)
        | ((uint32_t)(unsigned char)tag[2] << 8) | (unsigned char)tag[3];
}

// A kCTFontVariationAttribute modification: axes keyed by CFNumber tag, or by CFString tag when asked.
static CTFontDescriptorRef variation(const char *tags, const double *values, unsigned count, int stringKeys)
{
    CFMutableDictionaryRef request = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (unsigned i = 0; i < count; ++i) {
        const char *tag = tags + 5 * i;
        long long number = tagOf(tag);
        CFTypeRef key = stringKeys ? (CFTypeRef)CFStringCreateWithBytes(kCFAllocatorDefault, (const UInt8 *)tag, 4, kCFStringEncodingASCII, false)
                                   : (CFTypeRef)CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &number);
        CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &values[i]);
        CFDictionarySetValue(request, key, value);
        CFRelease(key);
        CFRelease(value);
    }
    const void *keys[] = { kCTFontVariationAttribute };
    const void *attributeValues[] = { request };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, attributeValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    CFRelease(request);
    return descriptor;
}

static CTFontRef realize(CTFontDescriptorRef base, CTFontDescriptorRef modification, CGFloat size)
{
    CFDictionaryRef attributes = CTFontDescriptorCopyAttributes(modification);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes);
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    CFRelease(descriptor);
    CFRelease(attributes);
    return font;
}

static CTFontRef copyFont(CTFontRef font, CGFloat size, CTFontDescriptorRef modification)
{
    return font ? CTFontCreateCopyWithAttributes(font, size, NULL, modification) : NULL;
}

// kCTFontVariationAxesAttribute is 10.13+ in the SDK; the layer supplies it on this OS.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
static CFArrayRef descriptorAxes(CTFontDescriptorRef descriptor)
{
    return descriptor ? (CFArrayRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontVariationAxesAttribute) : NULL;
}
#pragma clang diagnostic pop

static double numberIn(CFDictionaryRef dictionary, CFTypeRef key)
{
    CFNumberRef number = dictionary ? (CFNumberRef)CFDictionaryGetValue(dictionary, key) : NULL;
    double value = NAN;
    if (number && CFGetTypeID(number) == CFNumberGetTypeID())
        CFNumberGetValue(number, kCFNumberDoubleType, &value);
    return value;
}

static double variationValue(CFDictionaryRef variation, const char *tag)
{
    int32_t number = (int32_t)tagOf(tag);
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &number);
    double value = numberIn(variation, key);
    CFRelease(key);
    return value;
}

static int hasTable(CTFontRef font, CTFontTableTag tag)
{
    CFArrayRef tables = font ? CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions) : NULL;
    int found = tables && CFArrayContainsValue(tables, CFRangeMake(0, CFArrayGetCount(tables)), (const void *)(uintptr_t)tag);
    if (tables)
        CFRelease(tables);
    CFDataRef table = font ? CTFontCopyTable(font, tag, kCTFontTableOptionNoOptions) : NULL;
    if (table)
        CFRelease(table);
    return found && table;
}

static void checkAxes(CFArrayRef axes, const char *what)
{
    static const struct { const char *tag; double minimum, defaultValue, maximum; const char *name; } expected[] = {
        { "wdth", 50, 100, 200, "Width" }, { "slnt", -90, 0, 90, "Slant" },
        { "ital", 0, 0, 1, "Italic" }, { "wght", 100, 400, 900, "Weight" },
    };
    char detail[256];
    snprintf(detail, sizeof detail, "%s: four axes", what);
    check(axes && CFArrayGetCount(axes) == 4, detail);
    for (CFIndex i = 0; axes && i < CFArrayGetCount(axes) && i < 4; ++i) {
        CFDictionaryRef axis = (CFDictionaryRef)CFArrayGetValueAtIndex(axes, i);
        CFNumberRef identifier = (CFNumberRef)CFDictionaryGetValue(axis, kCTFontVariationAxisIdentifierKey);
        int32_t tag = 0;
        CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, expected[i].name, kCFStringEncodingASCII);
        snprintf(detail, sizeof detail, "%s: axis %s", what, expected[i].tag);
        check(identifier && CFNumberGetType(identifier) == kCFNumberSInt32Type
            && CFNumberGetValue(identifier, kCFNumberSInt32Type, &tag) && (uint32_t)tag == tagOf(expected[i].tag)
            && numberIn(axis, kCTFontVariationAxisMinimumValueKey) == expected[i].minimum
            && numberIn(axis, kCTFontVariationAxisDefaultValueKey) == expected[i].defaultValue
            && numberIn(axis, kCTFontVariationAxisMaximumValueKey) == expected[i].maximum
            && CFEqual(CFDictionaryGetValue(axis, kCTFontVariationAxisNameKey), name), detail);
        CFRelease(name);
    }
}

static void variableTest(const char *path)
{
    CTFontDescriptorRef base = descriptorFromFile(path);
    check(base != NULL, "variabletest_matching.ttf builds a descriptor");
    if (!base)
        return;

    CFArrayRef axes = descriptorAxes(base);
    checkAxes(axes, "the descriptor's kCTFontVariationAxesAttribute");
    CFTypeRef baseVariation = CTFontDescriptorCopyAttribute(base, kCTFontVariationAttribute);
    check(baseVariation != NULL, "the descriptor answers kCTFontVariationAttribute");
    if (baseVariation)
        CFRelease(baseVariation);

    CTFontRef font = CTFontCreateWithFontDescriptor(base, 1000, NULL);
    CFArrayRef fontAxes = font ? CTFontCopyVariationAxes(font) : NULL;
    check(axes && fontAxes && CFEqual(axes, fontAxes), "CTFontCopyVariationAxes answers the descriptor's axes");
    check(hasTable(font, kCTFontTableFvar) && hasTable(font, kCTFontTableSTAT), "the font lists and copies its fvar and STAT tables");
    CTFontDescriptorRef own = font ? CTFontCopyFontDescriptor(font) : NULL;
    CFArrayRef ownAxes = descriptorAxes(own);
    check(axes && ownAxes && CFEqual(axes, ownAxes), "the font's own descriptor answers the axes");
    checkWidth(inkWidth(font, 'P'), 800, "'P' at the default instance");

    static const double weight900[] = { 900 };
    static const double weight1000[] = { 1000 };
    static const double weight400[] = { 400 };
    static const double width200[] = { 200 };
    static const double webCoreSet[] = { 900, 100, 0 };
    CTFontDescriptorRef heavy = variation("wght", weight900, 1, 0);
    CTFontDescriptorRef heavier = variation("wght", weight1000, 1, 0);
    CTFontDescriptorRef regular = variation("wght", weight400, 1, 0);
    CTFontDescriptorRef wide = variation("wdth", width200, 1, 0);
    CTFontDescriptorRef everything = variation("wght\0wdth\0slnt", webCoreSet, 3, 0);
    CTFontDescriptorRef stringKeyed = variation("wght", weight900, 1, 1);

    CTFontRef instance = realize(base, heavy, 1000);
    checkWidth(inkWidth(instance, 'P'), 1800, "'P' realized at wght 900");
    CFDictionaryRef realized = instance ? CTFontCopyVariation(instance) : NULL;
    check(variationValue(realized, "wght") == 900 && variationValue(realized, "wdth") == 100
        && realized && CFDictionaryGetCount(realized) == 4, "CTFontCopyVariation names every axis at its realized value");
    CFDictionaryRef attribute = instance ? (CFDictionaryRef)CTFontCopyAttribute(instance, kCTFontVariationAttribute) : NULL;
    check(realized && attribute && CFEqual(realized, attribute), "CTFontCopyAttribute answers the same variation");
    CFArrayRef instanceAxes = instance ? CTFontCopyVariationAxes(instance) : NULL;
    check(axes && instanceAxes && CFEqual(axes, instanceAxes), "an instance reports the axes");

    CTFontRef set = realize(base, everything, 1000);
    checkWidth(inkWidth(set, 'P'), 1800, "'P' under the wght/wdth/slnt set WebCore asks for");
    CTFontRef clamped = realize(base, heavier, 1000);
    checkWidth(inkWidth(clamped, 'P'), 1800, "'P' at a weight above the axis maximum");
    CTFontRef strings = realize(base, stringKeyed, 1000);
    checkWidth(inkWidth(strings, 'P'), 800, "a request keyed by string names no axis");

    CTFontRef copied = copyFont(font, 0, heavy);
    checkWidth(inkWidth(copied, 'P'), 1800, "'P' in a copy taken at wght 900");
    check(copied && CTFontGetSize(copied) == 1000, "a copy at size 0 keeps the font's size");
    CTFontRef back = copyFont(copied, 0, regular);
    checkWidth(inkWidth(back, 'P'), 800, "a copy of that instance taken back at wght 400");
    CTFontRef plain = copyFont(copied, 500, NULL);
    checkWidth(inkWidth(plain, 'P'), 900, "a copy of the instance with no attributes keeps its instance");
    CFArrayRef plainAxes = plain ? CTFontCopyVariationAxes(plain) : NULL;
    check(axes && plainAxes && CFEqual(axes, plainAxes), "that copy reports the axes");
    CTFontRef widened = copyFont(copied, 0, wide);
    checkWidth(inkWidth(widened, 'M'), 1800, "'M' in a copy taken at wdth 200");
    CTFontDescriptorRef instanceDescriptor = instance ? CTFontCopyFontDescriptor(instance) : NULL;
    CTFontRef again = instanceDescriptor ? CTFontCreateWithFontDescriptor(instanceDescriptor, 1000, NULL) : NULL;
    checkWidth(inkWidth(again, 'P'), 1800, "an instance's own descriptor realizes that instance");

    CFTypeRef releases[] = { axes, fontAxes, own, ownAxes, font, heavy, heavier, regular, wide, everything, stringKeyed,
        instance, realized, attribute, instanceAxes, set, clamped, strings, copied, back, plain, plainAxes, widened,
        instanceDescriptor, again, base };
    for (size_t i = 0; i < sizeof releases / sizeof releases[0]; ++i) {
        if (releases[i])
            CFRelease(releases[i]);
    }
}

static void skia(const char *path)
{
    CTFontDescriptorRef base = descriptorFromFile(path);
    CTFontRef installed = CTFontCreateWithName(CFSTR("Skia-Regular"), 80, NULL);
    CTFontRef font = base ? CTFontCreateWithFontDescriptor(base, 80, NULL) : NULL;
    check(font && installed, "Skia builds from its file and by name");
    CFArrayRef installedAxes = installed ? CTFontCopyVariationAxes(installed) : NULL;
    CFArrayRef axes = font ? CTFontCopyVariationAxes(font) : NULL;
    CFArrayRef baseAxes = descriptorAxes(base);
    check(installedAxes && CFArrayGetCount(installedAxes) == 2, "the installed Skia reports its two axes");
    check(installedAxes && axes && CFEqual(installedAxes, axes), "Skia from its bytes reports the installed face's axes");
    check(installedAxes && baseAxes && CFEqual(installedAxes, baseAxes), "Skia's descriptor answers the same axes");
    check(hasTable(font, kCTFontTableFvar) && !hasTable(font, kCTFontTableSTAT), "Skia lists fvar and no STAT, a TrueType GX font");

    static const double weight700[] = { 1.5453503 };
    static const double weight700Everything[] = { 1.5453503, 1, 0 };
    CTFontDescriptorRef bold = variation("wght", weight700, 1, 0);
    CTFontDescriptorRef everything = variation("wght\0wdth\0slnt", weight700Everything, 3, 0);
    checkWidth(inkWidth(font, 'a'), 31.09375, "Skia's 'a' at the default instance");
    CTFontRef realized = realize(base, bold, 80);
    checkWidth(inkWidth(realized, 'a'), 34.296875, "Skia's 'a' realized at wght 1.5454");
    CTFontRef set = realize(base, everything, 80);
    checkWidth(inkWidth(set, 'a'), 34.296875, "Skia's 'a' under the wght/wdth/slnt set WebCore asks for");
    CTFontRef copied = copyFont(font, 80, everything);
    checkWidth(inkWidth(copied, 'a'), 34.296875, "Skia's 'a' in a copy under that set");

    CFTypeRef releases[] = { base, installed, font, installedAxes, axes, baseAxes, bold, everything, realized, set, copied };
    for (size_t i = 0; i < sizeof releases / sizeof releases[0]; ++i) {
        if (releases[i])
            CFRelease(releases[i]);
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        printf("### CoreText variation axes from data: usage: %s variabletest_matching.ttf Skia.ttf\n", argv[0]);
        return 1;
    }
    variableTest(argv[1]);
    skia(argv[2]);
    if (failures) {
        printf("### CoreText variation axes from data: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText variation axes from data: a font built from bytes reports and realizes its axes\n");
    return 0;
}
