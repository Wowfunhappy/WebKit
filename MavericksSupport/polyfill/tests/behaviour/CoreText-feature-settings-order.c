// Feature settings reduced to AAT dictionaries (wk_featureSettingsAsAAT, polyfills/c/CoreText.c). A feature
// keeps its last setting whichever form names it, and 10.9 applies the last entry of an exclusive AAT type,
// so what the descriptor carries must end with each feature's last setting:
//
//   (a) [{smcp, 1}, {pcap, 0}]: pcap's off selector is kLowerCaseType's default, and smcp stays on, so
//       kLowerCaseSmallCapsSelector is the type's last entry;
//   (b) [{kNumberSpacingType, kMonospacedNumbersSelector}, {tnum, 0}] -- -apple-system-monospaced-numbers
//       followed by font-feature-settings "tnum" 0 -- ends with tnum off;
//   (c) the reverse of (b) ends with tnum on.
//
// Each is read back from descriptors made by CTFontDescriptorCreateWithAttributes and by
// CTFontDescriptorCreateCopyWithAttributes, and shaped through a descriptor from
// CTFontManagerCreateFontDescriptorFromData, whose CGFont-bound descriptor must apply the settings it is
// copied with. The fixture maps each feature to one glyph: tnum turns 'S' into glyph 1, smcp 'J'.
//
// usage: feature_settings_order <FontWithFancyFeatures.otf>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdio.h>

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

static CFDictionaryRef aatSetting(int type, int selector)
{
    CFNumberRef t = number(type), s = number(selector);
    const void *keys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
    const void *values[] = { t, s };
    CFDictionaryRef setting = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(t);
    CFRelease(s);
    return setting;
}

// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK; the layer supplies both on 10.9.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
static CFDictionaryRef openTypeSetting(CFStringRef tag, int value)
{
    CFNumberRef v = number(value);
    const void *keys[] = { kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue };
    const void *values[] = { tag, v };
    CFDictionaryRef setting = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(v);
    return setting;
}
#pragma clang diagnostic pop

static CFDictionaryRef settingsAttributes(CFTypeRef first, CFTypeRef second)
{
    const void *elements[] = { first, second };
    CFArrayRef settings = CFArrayCreate(kCFAllocatorDefault, elements, second ? 2 : 1, &kCFTypeArrayCallBacks);
    const void *keys[] = { kCTFontFeatureSettingsAttribute };
    const void *values[] = { settings };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(settings);
    return attributes;
}

// The selector a descriptor's settings state last for `type`, or -1 for none.
static int lastSelector(CTFontDescriptorRef descriptor, int type)
{
    CFTypeRef settings = descriptor ? CTFontDescriptorCopyAttribute(descriptor, kCTFontFeatureSettingsAttribute) : NULL;
    int stated = -1;
    for (CFIndex i = 0; settings && CFGetTypeID(settings) == CFArrayGetTypeID() && i < CFArrayGetCount((CFArrayRef)settings); i++) {
        CFTypeRef element = CFArrayGetValueAtIndex((CFArrayRef)settings, i);
        int elementType = 0, selector = 0;
        if (!element || CFGetTypeID(element) != CFDictionaryGetTypeID())
            continue;
        CFNumberRef typeNumber = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)element, kCTFontFeatureTypeIdentifierKey);
        CFNumberRef selectorNumber = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)element, kCTFontFeatureSelectorIdentifierKey);
        if (typeNumber && selectorNumber && CFNumberGetValue(typeNumber, kCFNumberIntType, &elementType)
            && CFNumberGetValue(selectorNumber, kCFNumberIntType, &selector) && elementType == type)
            stated = selector;
    }
    if (settings)
        CFRelease(settings);
    return stated;
}

// The glyph `character` shapes to in a line set in the font `descriptor` realizes.
static CGGlyph shapedGlyph(CTFontDescriptorRef descriptor, UniChar character)
{
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, 40, NULL) : NULL;
    if (!font)
        return 0xFFFF;
    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, &character, 1);
    const void *keys[] = { kCTFontAttributeName };
    const void *values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, string, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CGGlyph glyph = 0xFFFF;
    if (CFArrayGetCount(runs) && CTRunGetGlyphCount((CTRunRef)CFArrayGetValueAtIndex(runs, 0)) >= 1)
        CTRunGetGlyphs((CTRunRef)CFArrayGetValueAtIndex(runs, 0), CFRangeMake(0, 1), &glyph);
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
    CFRelease(font);
    return glyph;
}

static CTFontDescriptorRef descriptorFromFontData(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file)
        return NULL;
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    UInt8 buffer[65536];
    size_t count;
    while ((count = fread(buffer, 1, sizeof buffer, file)))
        CFDataAppendBytes(data, buffer, (CFIndex)count);
    fclose(file);
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData(data);
    CFRelease(data);
    return descriptor;
}

// The last selector `type` gets when `first` then `second` are given to a new descriptor and to a copy.
static void checkLastSelector(CFTypeRef first, CFTypeRef second, int type, int expected, const char *what)
{
    CFDictionaryRef attributes = settingsAttributes(first, second);
    CTFontDescriptorRef created = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontDescriptorRef base = CTFontDescriptorCreateWithNameAndSize(CFSTR("Helvetica"), 12);
    CTFontDescriptorRef copied = CTFontDescriptorCreateCopyWithAttributes(base, attributes);
    char message[256];
    snprintf(message, sizeof message, "%s (CTFontDescriptorCreateWithAttributes: last selector %d, expected %d)", what, lastSelector(created, type), expected);
    check(lastSelector(created, type) == expected, message);
    snprintf(message, sizeof message, "%s (CTFontDescriptorCreateCopyWithAttributes: last selector %d, expected %d)", what, lastSelector(copied, type), expected);
    check(lastSelector(copied, type) == expected, message);
    CFRelease(copied);
    CFRelease(base);
    CFRelease(created);
    CFRelease(attributes);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        printf("usage: %s <FontWithFancyFeatures.otf>\n", argv[0]);
        return 2;
    }
    const int tnumOn = kMonospacedNumbersSelector;
    CFDictionaryRef smcpOn = openTypeSetting(CFSTR("smcp"), 1);
    CFDictionaryRef pcapOff = openTypeSetting(CFSTR("pcap"), 0);
    CFDictionaryRef tnumOff = openTypeSetting(CFSTR("tnum"), 0);
    CFDictionaryRef monospacedNumbers = aatSetting(kNumberSpacingType, tnumOn);

    checkLastSelector(smcpOn, pcapOff, kLowerCaseType, kLowerCaseSmallCapsSelector, "(a) smcp on then pcap off leaves small caps last");
    checkLastSelector(monospacedNumbers, tnumOff, kNumberSpacingType, 4, "(b) AAT monospaced numbers then tnum 0 leaves tnum off");
    checkLastSelector(tnumOff, monospacedNumbers, kNumberSpacingType, tnumOn, "(c) tnum 0 then AAT monospaced numbers leaves tnum on");

    CTFontDescriptorRef fromData = descriptorFromFontData(argv[1]);
    check(fromData != NULL, "CTFontManagerCreateFontDescriptorFromData returns a descriptor for the fixture");
    if (fromData) {
        CGGlyph plainS = shapedGlyph(fromData, 'S'), plainJ = shapedGlyph(fromData, 'J');
        check(plainS != 1 && plainJ != 1, "the fixture's 'S' and 'J' shape to their own glyphs without settings");

        CFDictionaryRef smcpOnly = settingsAttributes(smcpOn, NULL);
        CTFontDescriptorRef smallCaps = CTFontDescriptorCreateCopyWithAttributes(fromData, smcpOnly);
        check(shapedGlyph(smallCaps, 'J') == 1, "an OpenType setting takes effect through a descriptor from font data");
        CFDictionaryRef aatOnly = settingsAttributes(monospacedNumbers, NULL);
        CTFontDescriptorRef tabular = CTFontDescriptorCreateCopyWithAttributes(fromData, aatOnly);
        check(shapedGlyph(tabular, 'S') == 1, "an AAT setting takes effect through a descriptor from font data");

        CFDictionaryRef onThenOff = settingsAttributes(monospacedNumbers, tnumOff);
        CTFontDescriptorRef endsOff = CTFontDescriptorCreateCopyWithAttributes(fromData, onThenOff);
        check(shapedGlyph(endsOff, 'S') == plainS, "(b) shaped: tnum 0 after AAT monospaced numbers leaves 'S' unsubstituted");
        CFDictionaryRef offThenOn = settingsAttributes(tnumOff, monospacedNumbers);
        CTFontDescriptorRef endsOn = CTFontDescriptorCreateCopyWithAttributes(fromData, offThenOn);
        check(shapedGlyph(endsOn, 'S') == 1, "(c) shaped: AAT monospaced numbers after tnum 0 substitutes 'S'");

        CFRelease(endsOn);
        CFRelease(offThenOn);
        CFRelease(endsOff);
        CFRelease(onThenOff);
        CFRelease(tabular);
        CFRelease(aatOnly);
        CFRelease(smallCaps);
        CFRelease(smcpOnly);
        CFRelease(fromData);
    }

    CFRelease(monospacedNumbers);
    CFRelease(tnumOff);
    CFRelease(pcapOff);
    CFRelease(smcpOn);
    if (failures)
        return 1;
    printf("feature settings order: PASS\n");
    return 0;
}
