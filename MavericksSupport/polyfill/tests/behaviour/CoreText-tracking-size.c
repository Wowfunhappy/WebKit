// Tracking at an optical size (polyfills/c/CoreText.c). A font's 'trak' value is looked up at its
// optical size, and a size past either end of the table takes the value at that end. The expected
// advances are this OS's own at an optical size inside each table's range.
//
//   Apple Color Emoji  trak sizes 0 9 16 22 29, values 0 46 46 30 0 (upem 800)
//   Skia               trak sizes 9 .. 19, track 0 values 15 .. -25 (upem 2048)
//   Hoefler Text       trak sizes 2 .. 197, track 0 values 100 .. -100 (upem 2000)
//
// A font that names no optical size is not tracked, which is what fast/text/variations/optical-sizing-trak
// asserts for a face with no STAT table (no face on this OS carries one), and "auto" is tracked, which is
// what fast/text/trak-optimizeLegibility asserts with the fixture passed as the first argument.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void checkNear(double actual, double expected, const char *what)
{
    if (!(fabs(actual - expected) <= 1e-6)) {
        printf("FAIL: %s (expected %.9f, got %.9f)\n", what, expected, actual);
        failures++;
    }
}

static const UniChar emoji[] = { 0xD83D, 0xDE01 };
static const UniChar letter[] = { 'A' };

static double advance(CTFontRef font, const UniChar *characters, CFIndex length)
{
    CGGlyph glyphs[2] = { 0 };
    CGSize size = CGSizeZero;
    if (!font || !CTFontGetGlyphsForCharacters(font, characters, glyphs, length))
        return NAN;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, glyphs, &size, 1);
    return size.width;
}

static CFDictionaryRef attributesNaming(CFStringRef name, CFTypeRef opticalSize)
{
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (name)
        CFDictionarySetValue(attributes, kCTFontNameAttribute, name);
    if (opticalSize)
        CFDictionarySetValue(attributes, kCTFontOpticalSizeAttribute, opticalSize);
    return attributes;
}

// Realized from a descriptor naming the face and the optical size.
static double measureDescriptor(CFStringRef name, CFTypeRef opticalSize, CGFloat size, const UniChar *characters, CFIndex length)
{
    CFDictionaryRef attributes = attributesNaming(name, opticalSize);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, size, NULL) : NULL;
    double result = advance(font, characters, length);
    if (font)
        CFRelease(font);
    if (descriptor)
        CFRelease(descriptor);
    CFRelease(attributes);
    return result;
}

// Realized as a copy of the face at that size, the attributes carrying the optical size.
static double measureCopy(CFStringRef name, CFTypeRef opticalSize, CGFloat size, const UniChar *characters, CFIndex length)
{
    CTFontRef base = CTFontCreateWithName(name, size, NULL);
    CFDictionaryRef attributes = attributesNaming(NULL, opticalSize);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontRef font = base && descriptor ? CTFontCreateCopyWithAttributes(base, size, NULL, descriptor) : NULL;
    double result = advance(font, characters, length);
    if (font)
        CFRelease(font);
    if (descriptor)
        CFRelease(descriptor);
    CFRelease(attributes);
    if (base)
        CFRelease(base);
    return result;
}

static double measureNamed(CFStringRef name, CGFloat size, const UniChar *characters, CFIndex length)
{
    CTFontRef font = CTFontCreateWithName(name, size, NULL);
    double result = advance(font, characters, length);
    if (font)
        CFRelease(font);
    return result;
}

static CFNumberRef number(double value)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
}

int main(int argc, char **argv)
{
    char what[200];

    // Apple Color Emoji: this OS's effective size, tracked inside the table and held at its last size.
    struct { CGFloat size; double untracked; double tracked; } emojiSizes[] = {
        { 16, 20.0, 21.15 },
        { 24, 24.0001, 24.642959821 },
        { 64, 64.0001, 64.0001 },
        { 200, 200.0001, 200.0001 },
    };
    for (unsigned i = 0; i < sizeof(emojiSizes) / sizeof(emojiSizes[0]); ++i) {
        CGFloat size = emojiSizes[i].size;
        CFNumberRef points = number(size);
        snprintf(what, sizeof what, "Apple Color Emoji at %gpt with no optical size", size);
        checkNear(measureNamed(CFSTR("AppleColorEmoji"), size, emoji, 2), emojiSizes[i].untracked, what);
        checkNear(measureDescriptor(CFSTR("AppleColorEmoji"), NULL, size, emoji, 2), emojiSizes[i].untracked, what);
        snprintf(what, sizeof what, "Apple Color Emoji at %gpt, optical size \"auto\" through a descriptor", size);
        checkNear(measureDescriptor(CFSTR("AppleColorEmoji"), CFSTR("auto"), size, emoji, 2), emojiSizes[i].tracked, what);
        snprintf(what, sizeof what, "Apple Color Emoji at %gpt, optical size \"auto\" through a copy", size);
        checkNear(measureCopy(CFSTR("AppleColorEmoji"), CFSTR("auto"), size, emoji, 2), emojiSizes[i].tracked, what);
        snprintf(what, sizeof what, "Apple Color Emoji at %gpt, the point size as the optical size", size);
        checkNear(measureDescriptor(CFSTR("AppleColorEmoji"), points, size, emoji, 2), emojiSizes[i].tracked, what);
        checkNear(measureCopy(CFSTR("AppleColorEmoji"), points, size, emoji, 2), emojiSizes[i].tracked, what);
        CFRelease(points);
    }

    // A copy of an "auto" font at another size takes the optical size of the new size.
    {
        CFDictionaryRef attributes = attributesNaming(CFSTR("AppleColorEmoji"), CFSTR("auto"));
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
        CTFontRef small = CTFontCreateWithFontDescriptor(descriptor, 16, NULL);
        CTFontRef resized = small ? CTFontCreateCopyWithAttributes(small, 64, NULL, NULL) : NULL;
        checkNear(advance(resized, emoji, 2), 64.0001, "an \"auto\" Apple Color Emoji copied from 16pt to 64pt");
        if (resized)
            CFRelease(resized);
        if (small)
            CFRelease(small);
        CFRelease(descriptor);
        CFRelease(attributes);
    }

    // The first size holds as the last does, on tables of more than one track.
    checkNear(measureDescriptor(CFSTR("Skia-Regular"), CFSTR("auto"), 64, letter, 1), 41.65625, "Skia at 64pt, \"auto\"");
    checkNear(measureDescriptor(CFSTR("Skia-Regular"), CFSTR("auto"), 8, letter, 1), 5.36328125, "Skia at 8pt, \"auto\"");
    checkNear(measureDescriptor(CFSTR("HoeflerText-Regular"), CFSTR("auto"), 1, letter, 1), 0.784, "Hoefler Text at 1pt, \"auto\"");

    // A face with no tracking table measures the same under every form.
    double helvetica = measureNamed(CFSTR("Helvetica"), 64, letter, 1);
    checkNear(helvetica, 42.6875, "Helvetica at 64pt with no optical size");
    checkNear(measureDescriptor(CFSTR("Helvetica"), CFSTR("auto"), 64, letter, 1), helvetica, "Helvetica at 64pt, \"auto\"");

    // fast/text/variations/optical-sizing-trak: no optical size measures as "none".
    double hoefler = measureDescriptor(CFSTR("HoeflerText-Regular"), NULL, 10, letter, 1);
    checkNear(hoefler, 7.34, "Hoefler Text at 10pt with no optical size");
    checkNear(measureDescriptor(CFSTR("HoeflerText-Regular"), CFSTR("none"), 10, letter, 1), hoefler, "Hoefler Text at 10pt, \"none\"");

    // fast/text/trak-optimizeLegibility: the fixture's one tracking value is 500 units at every size.
    if (argc < 2) {
        printf("FAIL: no Ahem-trak fixture path given\n");
        failures++;
    } else {
        FILE *file = fopen(argv[1], "rb");
        CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
        UInt8 buffer[65536];
        size_t read;
        while (file && (read = fread(buffer, 1, sizeof buffer, file)))
            CFDataAppendBytes(data, buffer, (CFIndex)read);
        if (file)
            fclose(file);
        CTFontDescriptorRef fromData = CFDataGetLength(data) ? CTFontManagerCreateFontDescriptorFromData(data) : NULL;
        CFDictionaryRef automatic = attributesNaming(NULL, CFSTR("auto"));
        CTFontDescriptorRef tracked = fromData ? CTFontDescriptorCreateCopyWithAttributes(fromData, automatic) : NULL;
        CTFontRef plainFont = fromData ? CTFontCreateWithFontDescriptor(fromData, 64, NULL) : NULL;
        CTFontRef trackedFont = tracked ? CTFontCreateWithFontDescriptor(tracked, 64, NULL) : NULL;
        const UniChar a = 'a';
        checkNear(advance(plainFont, &a, 1), 64, "Ahem-trak at 64pt with no optical size");
        checkNear(advance(trackedFont, &a, 1), 96, "Ahem-trak at 64pt, \"auto\"");
        if (trackedFont)
            CFRelease(trackedFont);
        if (plainFont)
            CFRelease(plainFont);
        if (tracked)
            CFRelease(tracked);
        CFRelease(automatic);
        if (fromData)
            CFRelease(fromData);
        CFRelease(data);
    }

    if (failures) {
        printf("### CoreText tracking size: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText tracking size: 'trak' follows the optical size and holds past the table's ends\n");
    return 0;
}
