// kCTFontOpticalSizeAttribute resolution (polyfills/c/CoreText.c). The attribute takes a CFNumber on
// 10.9 -- the optical size, in points, a realized font's advances are looked up at -- and this
// CoreText reads it as a number whatever it holds, so the CFString forms "auto" and "none" that
// later CoreText accepts pick up uninitialized memory instead. Apple Color Emoji is the face on this
// machine whose advances depend on the value, so it is the one that measures the difference: a string
// value takes its advance to roughly -5e8, and to a different number on each run.
//
// What a realized font owes:
//   "auto"  measures the same as the point size spelled out, through every realization entry point --
//           including a descriptor the attribute reaches by merge -- and keeps following the point
//           size, so a copy taken at another size measures like a direct realization at that size and
//           still reports the request.
//   "none"  measures the same as no optical size at all.
// And whichever form it names, the font realized is still the one the descriptor describes: a
// descriptor minted from font data is bound to a CGFont rather than named by its attributes, and a
// font carrying that binding has no file URL, where one CoreText matched from an attributes
// dictionary does.
// Every repeat measures the same, because the defect this covers reads uninitialized memory.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

// The advance Apple Color Emoji gives U+26A0 in the realized font.
static double emojiAdvance(CTFontRef font)
{
    const UniChar character = 0x26A0;
    CGGlyph glyph = 0;
    CGSize advance = CGSizeZero;
    if (!font || !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        return NAN;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
    return advance.width;
}

static CFDictionaryRef opticalSizeAttributes(CFTypeRef opticalSize)
{
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (opticalSize)
        CFDictionarySetValue(attributes, kCTFontOpticalSizeAttribute, opticalSize);
    return attributes;
}

// Realized straight from a descriptor built with the attribute in hand.
static CTFontRef fontFromDescriptor(CFTypeRef opticalSize, CGFloat size)
{
    CFMutableDictionaryRef attributes = (CFMutableDictionaryRef)opticalSizeAttributes(opticalSize);
    CFDictionarySetValue(attributes, kCTFontNameAttribute, CFSTR("AppleColorEmoji"));
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, size, NULL) : NULL;
    if (descriptor)
        CFRelease(descriptor);
    CFRelease(attributes);
    return font;
}

// Realized from a descriptor the attribute reaches by merge, which is the shape a web font takes:
// UnrealizedCoreTextFont::realize merges its attributes onto the @font-face descriptor.
static CTFontRef fontFromMergedDescriptor(CFTypeRef opticalSize, CGFloat size)
{
    CFTypeRef nameKeys[] = { kCTFontNameAttribute };
    CFTypeRef nameValues[] = { CFSTR("AppleColorEmoji") };
    CFDictionaryRef nameAttributes = CFDictionaryCreate(kCFAllocatorDefault, nameKeys, nameValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef base = CTFontDescriptorCreateWithAttributes(nameAttributes);
    CFDictionaryRef attributes = opticalSizeAttributes(opticalSize);
    CTFontDescriptorRef merged = base ? CTFontDescriptorCreateCopyWithAttributes(base, attributes) : NULL;
    CTFontRef font = merged ? CTFontCreateWithFontDescriptor(merged, size, NULL) : NULL;
    if (merged)
        CFRelease(merged);
    CFRelease(attributes);
    if (base)
        CFRelease(base);
    CFRelease(nameAttributes);
    return font;
}

// Realized as a copy of a font already at that size.
static CTFontRef fontFromCopy(CFTypeRef opticalSize, CGFloat size)
{
    CTFontRef base = CTFontCreateWithName(CFSTR("AppleColorEmoji"), size, NULL);
    if (!base)
        return NULL;
    CFDictionaryRef attributes = opticalSizeAttributes(opticalSize);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontRef copy = descriptor ? CTFontCreateCopyWithAttributes(base, size, NULL, descriptor) : NULL;
    if (descriptor)
        CFRelease(descriptor);
    CFRelease(attributes);
    CFRelease(base);
    return copy;
}

// A descriptor over the bytes of a font file, which is the shape CSS @font-face data takes.
static CTFontDescriptorRef descriptorFromFontData(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file)
        return NULL;
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    UInt8 buffer[65536];
    size_t read;
    while ((read = fread(buffer, 1, sizeof buffer, file)))
        CFDataAppendBytes(data, buffer, (CFIndex)read);
    fclose(file);
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData(data);
    CFRelease(data);
    return descriptor;
}

static bool fontCarriesAFileURL(CTFontRef font)
{
    CFTypeRef url = font ? CTFontCopyAttribute(font, kCTFontURLAttribute) : NULL;
    if (!url)
        return false;
    CFRelease(url);
    return true;
}

static double measure(CTFontRef font)
{
    double advance = emojiAdvance(font);
    if (font)
        CFRelease(font);
    return advance;
}

int main(void)
{
    const CGFloat size = 19.8;
    const CGFloat resizedTo = 40;
    CFNumberRef points = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &size);

    struct {
        const char *route;
        CTFontRef (*realize)(CFTypeRef, CGFloat);
    } routes[] = {
        { "a descriptor", fontFromDescriptor },
        { "a merged descriptor", fontFromMergedDescriptor },
        { "a copy", fontFromCopy },
    };

    for (unsigned r = 0; r < sizeof(routes) / sizeof(routes[0]); ++r) {
        double absent = measure(routes[r].realize(NULL, size));
        double spelledOut = measure(routes[r].realize(points, size));
        char what[200];

        snprintf(what, sizeof what, "%s: an emoji advance with no optical size is a real measurement", routes[r].route);
        check(absent > 0 && absent < 4 * size, what);
        snprintf(what, sizeof what, "%s: an emoji advance at a spelled-out optical size is a real measurement", routes[r].route);
        check(spelledOut > 0 && spelledOut < 4 * size, what);

        for (int repeat = 0; repeat < 3; ++repeat) {
            double automatic = measure(routes[r].realize(CFSTR("auto"), size));
            double none = measure(routes[r].realize(CFSTR("none"), size));
            snprintf(what, sizeof what, "%s: \"auto\" measures the point size (%g, wanted %g)", routes[r].route, automatic, spelledOut);
            check(automatic == spelledOut, what);
            snprintf(what, sizeof what, "%s: \"none\" measures no optical size (%g, wanted %g)", routes[r].route, none, absent);
            check(none == absent, what);
        }
    }

    // "auto" follows the point size across a resize: FontPlatformData::updateSize copies a realized
    // font at a new size with no attributes at all, and the copy owes the optical size of a font
    // realized at that size outright.
    CFNumberRef resizedPoints = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &resizedTo);
    double realizedAtResizedSize = measure(fontFromDescriptor(CFSTR("auto"), resizedTo));
    double spelledOutAtResizedSize = measure(fontFromDescriptor(resizedPoints, resizedTo));
    CTFontRef automaticFont = fontFromDescriptor(CFSTR("auto"), size);
    CTFontRef resized = automaticFont ? CTFontCreateCopyWithAttributes(automaticFont, resizedTo, NULL, NULL) : NULL;
    double resizedAdvance = emojiAdvance(resized);

    char what[200];
    snprintf(what, sizeof what, "\"auto\" at the resized point size is a real measurement (%g)", realizedAtResizedSize);
    check(realizedAtResizedSize == spelledOutAtResizedSize && realizedAtResizedSize > 0, what);
    snprintf(what, sizeof what, "a resized copy follows the point size (%g, wanted %g)", resizedAdvance, realizedAtResizedSize);
    check(resizedAdvance == realizedAtResizedSize, what);

    // And the request survives the copy, so a further resize resolves from "auto" again.
    CFTypeRef reported = automaticFont ? CTFontCopyAttribute(automaticFont, kCTFontOpticalSizeAttribute) : NULL;
    check(reported && CFGetTypeID(reported) == CFStringGetTypeID()
          && CFEqual((CFStringRef)reported, CFSTR("auto")), "a font realized for \"auto\" reports \"auto\"");
    if (reported)
        CFRelease(reported);
    CFTypeRef reportedByCopy = resized ? CTFontCopyAttribute(resized, kCTFontOpticalSizeAttribute) : NULL;
    check(reportedByCopy && CFGetTypeID(reportedByCopy) == CFStringGetTypeID()
          && CFEqual((CFStringRef)reportedByCopy, CFSTR("auto")), "a resized copy reports \"auto\" too");
    if (reportedByCopy)
        CFRelease(reportedByCopy);

    // The realization a descriptor minted from data goes through keeps that descriptor's binding,
    // whichever form of the attribute it carries.
    CTFontDescriptorRef fromData = descriptorFromFontData("/System/Library/Fonts/Symbol.ttf");
    check(fromData != NULL, "a descriptor over font data");
    CFTypeRef opticalSizes[] = { NULL, CFSTR("auto"), CFSTR("none"), points };
    const char *spellings[] = { "no optical size", "\"auto\"", "\"none\"", "the point size" };
    for (unsigned i = 0; fromData && i < sizeof(opticalSizes) / sizeof(opticalSizes[0]); ++i) {
        CFDictionaryRef attributes = opticalSizeAttributes(opticalSizes[i]);
        CTFontDescriptorRef merged = CTFontDescriptorCreateCopyWithAttributes(fromData, attributes);
        CTFontRef font = merged ? CTFontCreateWithFontDescriptor(merged, size, NULL) : NULL;
        snprintf(what, sizeof what, "a font built from data keeps its binding under %s", spellings[i]);
        check(font && !fontCarriesAFileURL(font), what);
        if (font)
            CFRelease(font);
        if (merged)
            CFRelease(merged);
        CFRelease(attributes);
    }
    if (fromData)
        CFRelease(fromData);

    if (resized)
        CFRelease(resized);
    if (automaticFont)
        CFRelease(automaticFont);
    CFRelease(resizedPoints);
    CFRelease(points);

    if (failures) {
        printf("### CoreText optical size: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText optical size: the string forms resolve and follow the point size\n");
    return 0;
}
