// Clearing a feature type through CTFontDescriptorCreateCopyWithAttributes (polyfills/c/CoreText.c).
// A copy MERGES feature settings and states a type's LAST entry, so a clear is expressed as the
// cleared type restated at the selector its own feature list marks default. What the copy owes:
//
//   a cleared type goes back to its default selector, and the ORIGINAL's identity survives -- a
//   descriptor built from font data is bound to a CGFont, and a font carrying that binding has no
//   file URL where one CoreText matched from an attributes dictionary does;
//   a caller restating the type in the same copy wins over the default;
//   a type whose feature list marks NO default selector gets no entry at all -- there is no default
//   to state, and the selectors such a type lists are not one (PT Mono offers 4 and 20 for
//   kLigaturesType and marks neither, where Hoefler Text marks 2).
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static CFNumberRef number(int value)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static CFDictionaryRef featureSetting(int type, CFTypeRef selector)
{
    CFNumberRef typeNumber = number(type);
    const void *keys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
    const void *values[] = { typeNumber, selector };
    CFDictionaryRef setting = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(typeNumber);
    return setting;
}

static CFDictionaryRef settingsAttributes(CFTypeRef settings)
{
    const void *keys[] = { kCTFontFeatureSettingsAttribute };
    const void *values[] = { settings };
    return CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

// A descriptor for `name` carrying one feature setting.
static CTFontDescriptorRef namedDescriptorWithSetting(CFStringRef name, int type, int selector)
{
    CFNumberRef selectorNumber = number(selector);
    CFDictionaryRef setting = featureSetting(type, selectorNumber);
    CFArrayRef settings = CFArrayCreate(kCFAllocatorDefault, (const void *[]){ setting }, 1, &kCFTypeArrayCallBacks);
    const void *keys[] = { kCTFontNameAttribute, kCTFontFeatureSettingsAttribute };
    const void *values[] = { name, settings };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    CFRelease(settings);
    CFRelease(setting);
    CFRelease(selectorNumber);
    return descriptor;
}

// The selector a descriptor's settings state for `type`, or INT_MIN for none.
#define WK_NO_SETTING (-2147483647 - 1)
static int statedSelector(CTFontDescriptorRef descriptor, int type)
{
    CFDictionaryRef attributes = descriptor ? CTFontDescriptorCopyAttributes(descriptor) : NULL;
    CFTypeRef settings = attributes ? CFDictionaryGetValue(attributes, kCTFontFeatureSettingsAttribute) : NULL;
    int stated = WK_NO_SETTING;
    if (settings && CFGetTypeID(settings) == CFArrayGetTypeID()) {
        for (CFIndex i = 0; i < CFArrayGetCount((CFArrayRef)settings); i++) {
            CFTypeRef element = CFArrayGetValueAtIndex((CFArrayRef)settings, i);
            if (!element || CFGetTypeID(element) != CFDictionaryGetTypeID())
                continue;
            int elementType = 0, selector = 0;
            CFNumberRef typeNumber = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)element, kCTFontFeatureTypeIdentifierKey);
            CFNumberRef selectorNumber = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)element, kCTFontFeatureSelectorIdentifierKey);
            if (!typeNumber || !selectorNumber
                || !CFNumberGetValue(typeNumber, kCFNumberIntType, &elementType)
                || !CFNumberGetValue(selectorNumber, kCFNumberIntType, &selector)
                || elementType != type)
                continue;
            stated = selector;   // the merge states a type's last entry
        }
    }
    if (attributes)
        CFRelease(attributes);
    return stated;
}

// The glyphs a line of `text` shapes to in the font the descriptor realizes.
static CFIndex shapedGlyphs(CTFontDescriptorRef descriptor, const char *text)
{
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, 40, NULL) : NULL;
    if (!font)
        return -1;
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, text, kCFStringEncodingUTF8);
    const void *keys[] = { kCTFontAttributeName };
    const void *values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, string, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex glyphs = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(runs); i++)
        glyphs += CTRunGetGlyphCount((CTRunRef)CFArrayGetValueAtIndex(runs, i));
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
    CFRelease(font);
    return glyphs;
}

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

static bool carriesAFileURL(CTFontDescriptorRef descriptor)
{
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, 20, NULL) : NULL;
    CFTypeRef url = font ? CTFontCopyAttribute(font, kCTFontURLAttribute) : NULL;
    if (url)
        CFRelease(url);
    if (font)
        CFRelease(font);
    return url != NULL;
}

int main(void)
{
    const int ligatures = kLigaturesType;
    const int commonOff = kCommonLigaturesOffSelector;   // 3
    const int commonOn = kCommonLigaturesOnSelector;     // 2

    CFDictionaryRef clearsEverything = settingsAttributes(kCFNull);
    CFDictionaryRef clearedElement = featureSetting(ligatures, kCFNull);
    CFArrayRef clearsTheType = CFArrayCreate(kCFAllocatorDefault, (const void *[]){ clearedElement }, 1, &kCFTypeArrayCallBacks);
    CFDictionaryRef clearsTheTypeAttributes = settingsAttributes(clearsTheType);

    // Hoefler Text marks selector 2 the default for kLigaturesType, so a clear states it and "fi"
    // ligates again.
    CTFontDescriptorRef ligaturesOff = namedDescriptorWithSetting(CFSTR("HoeflerText-Regular"), ligatures, commonOff);
    check(shapedGlyphs(ligaturesOff, "fi") == 2, "ligatures off leaves \"fi\" as two glyphs");

    CTFontDescriptorRef everythingCleared = CTFontDescriptorCreateCopyWithAttributes(ligaturesOff, clearsEverything);
    check(statedSelector(everythingCleared, ligatures) == commonOn, "a full clear states the default selector");
    check(shapedGlyphs(everythingCleared, "fi") == 1, "a full clear ligates \"fi\" again");

    CTFontDescriptorRef typeCleared = CTFontDescriptorCreateCopyWithAttributes(ligaturesOff, clearsTheTypeAttributes);
    check(statedSelector(typeCleared, ligatures) == commonOn, "a type clear states the default selector");
    check(shapedGlyphs(typeCleared, "fi") == 1, "a type clear ligates \"fi\" again");

    // A caller restating the type in the same copy wins over the default.
    {
        CFNumberRef offNumber = number(commonOff);
        CFDictionaryRef offSetting = featureSetting(ligatures, offNumber);
        CFArrayRef both = CFArrayCreate(kCFAllocatorDefault, (const void *[]){ clearedElement, offSetting }, 2, &kCFTypeArrayCallBacks);
        CFDictionaryRef attributes = settingsAttributes(both);
        CTFontDescriptorRef restated = CTFontDescriptorCreateCopyWithAttributes(ligaturesOff, attributes);
        check(statedSelector(restated, ligatures) == commonOff, "the caller's own setting wins over the default");
        check(shapedGlyphs(restated, "fi") == 2, "the caller's own setting still shapes two glyphs");
        CFRelease(restated);
        CFRelease(attributes);
        CFRelease(both);
        CFRelease(offSetting);
        CFRelease(offNumber);
    }

    // PT Mono offers 4 and 20 for kLigaturesType and marks neither the default, so a clear has no
    // default to state and states nothing for that type.
    {
        CTFontDescriptorRef noDefault = namedDescriptorWithSetting(CFSTR("PTMono-Bold"), ligatures, kRareLigaturesOnSelector);
        CTFontDescriptorRef cleared = CTFontDescriptorCreateCopyWithAttributes(noDefault, clearsEverything);
        check(statedSelector(cleared, ligatures) == kRareLigaturesOnSelector,
              "a type with no default selector keeps what it had rather than gaining an invented one");
        CFRelease(cleared);
        CFRelease(noDefault);
    }

    // A clear on a descriptor minted from font data keeps that descriptor's CGFont binding.
    {
        CTFontDescriptorRef fromData = descriptorFromFontData("/System/Library/Fonts/Symbol.ttf");
        check(fromData != NULL, "a descriptor over font data");
        CTFontDescriptorRef cleared = fromData ? CTFontDescriptorCreateCopyWithAttributes(fromData, clearsEverything) : NULL;
        check(cleared && !carriesAFileURL(cleared), "a clear keeps a font built from data");
        if (cleared)
            CFRelease(cleared);
        if (fromData)
            CFRelease(fromData);
    }

    CFRelease(typeCleared);
    CFRelease(everythingCleared);
    CFRelease(ligaturesOff);
    CFRelease(clearsTheTypeAttributes);
    CFRelease(clearsTheType);
    CFRelease(clearedElement);
    CFRelease(clearsEverything);

    if (failures) {
        printf("### CoreText feature clear: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText feature clear: a cleared type goes back to the default its font names\n");
    return 0;
}
