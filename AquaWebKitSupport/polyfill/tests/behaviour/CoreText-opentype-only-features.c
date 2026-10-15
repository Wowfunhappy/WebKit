// OpenType feature settings with no AAT pair (wk_openTypeOnlySettings and wk_shapingFont,
// polyfills/c/CoreText.c). The fixture's GSUB maps cv01 'k' to glyph 1, and its salt AlternateSubst gives
// 'n', 'o' and 'p' three alternates each, glyph 1 at the first, second and third; neither tag has an entry
// in the AAT registry, and 10.9's engine applies neither on its own. Through a descriptor from font data:
//
//   (a) the descriptor and the font realized from it read the setting back;
//   (b) a copy that clears the tag drops it, and a copy that does not keeps it;
//   (c) cv01 and salt turned on substitute in a CTLine and in CTFontShapeGlyphs called as WebCore calls it,
//       and the run reports the font it was given;
//   (d) a value of 0 substitutes nothing;
//   (e) a font copy keeps the setting, and the setting is part of the font's identity;
//   (f) salt 2 and 3 substitute their own alternate and no other, and salt 4, past every glyph's
//       alternates, substitutes nothing;
//   (i) swsh 2, a registry tag at a value no AAT selector names, substitutes 'r' alone, its second
//       alternate, and afrc, which 10.9 does not reach through its AAT pair, substitutes 'U'.
// Through the gsubtest font, which names all twenty stylistic sets and every feature:
//   (j) pwid and hlig apply through a borrowed stylistic set, and hlig leaves hist, which shares its AAT
//       pair, off.
// Through installed fonts:
//   (g) numr and dnom set Seravek's '1' as one.numr and one.dnom, the apple.com footnote case;
//   (h) nalt, which AppleSDGothicNeo-Regular's GSUB has, leaves that font as 10.9 shapes it, from its morx.
//
// usage: opentype_only_features <FontWithFancyFeatures.otf> <gsubtest-lookup3.otf>
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

extern CGSize CTFontShapeGlyphs(CTFontRef, CGGlyph[], CGSize[], CGPoint[], CFIndex[], const UniChar[], CFIndex,
    CFOptionFlags, CFStringRef, void (^)(CFRange, CGGlyph **, CGSize **, CGPoint **, CFIndex **));

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

// kCTFontOpenTypeFeatureTag/Value are 10.10+ in the SDK; the layer supplies both on 10.9.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
static CFDictionaryRef openTypeSetting(CFStringRef tag, int value)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    const void *keys[] = { kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue };
    const void *values[] = { tag, number };
    CFDictionaryRef setting = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    return setting;
}

// The value `settings` gives `tag` last, or -1 when it names it nowhere.
static int settingValue(CFTypeRef settings, CFStringRef tag)
{
    int stated = -1;
    for (CFIndex i = 0; settings && CFGetTypeID(settings) == CFArrayGetTypeID() && i < CFArrayGetCount((CFArrayRef)settings); i++) {
        CFTypeRef element = CFArrayGetValueAtIndex((CFArrayRef)settings, i);
        if (!element || CFGetTypeID(element) != CFDictionaryGetTypeID())
            continue;
        CFTypeRef named = CFDictionaryGetValue((CFDictionaryRef)element, kCTFontOpenTypeFeatureTag);
        CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)element, kCTFontOpenTypeFeatureValue);
        int number = 1;
        if (named && CFEqual(named, tag) && (!value || CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)))
            stated = number;
    }
    return stated;
}
#pragma clang diagnostic pop

static CFDictionaryRef settingsAttributes(CFTypeRef element)
{
    const void *elements[] = { element };
    CFArrayRef settings = CFArrayCreate(kCFAllocatorDefault, elements, 1, &kCFTypeArrayCallBacks);
    const void *keys[] = { kCTFontFeatureSettingsAttribute };
    const void *values[] = { settings };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(settings);
    return attributes;
}

static CTFontDescriptorRef copyWithSetting(CTFontDescriptorRef base, CFTypeRef element)
{
    CFDictionaryRef attributes = settingsAttributes(element);
    CTFontDescriptorRef copy = CTFontDescriptorCreateCopyWithAttributes(base, attributes);
    CFRelease(attributes);
    return copy;
}

static int descriptorValue(CTFontDescriptorRef descriptor, CFStringRef tag)
{
    CFTypeRef settings = CTFontDescriptorCopyAttribute(descriptor, kCTFontFeatureSettingsAttribute);
    int value = settingValue(settings, tag);
    if (settings)
        CFRelease(settings);
    return value;
}

static int attributesValue(CTFontDescriptorRef descriptor, CFStringRef tag)
{
    CFDictionaryRef attributes = CTFontDescriptorCopyAttributes(descriptor);
    int value = settingValue(attributes ? CFDictionaryGetValue(attributes, kCTFontFeatureSettingsAttribute) : NULL, tag);
    if (attributes)
        CFRelease(attributes);
    return value;
}

static int fontValue(CTFontRef font, CFStringRef tag)
{
    CFTypeRef settings = CTFontCopyAttribute(font, kCTFontFeatureSettingsAttribute);
    int value = settingValue(settings, tag);
    if (settings)
        CFRelease(settings);
    return value;
}

// The glyph `character` takes in a CTLine set in `font`, and whether the run reports `font`.
static CGGlyph lineGlyph(CTFontRef font, UniChar character, bool *reportsFont)
{
    CFStringRef string = CFStringCreateWithCharacters(kCFAllocatorDefault, &character, 1);
    const void *keys[] = { kCTFontAttributeName };
    const void *values[] = { font };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef attributed = CFAttributedStringCreate(kCFAllocatorDefault, string, attributes);
    CTLineRef line = CTLineCreateWithAttributedString(attributed);
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CGGlyph glyph = 0xFFFF;
    *reportsFont = false;
    if (CFArrayGetCount(runs) == 1 && CTRunGetGlyphCount((CTRunRef)CFArrayGetValueAtIndex(runs, 0)) == 1) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, 0);
        CTRunGetGlyphs(run, CFRangeMake(0, 1), &glyph);
        CTFontRef runFont = (CTFontRef)CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        *reportsFont = runFont == font || (runFont && CFEqual(runFont, font));
    }
    CFRelease(line);
    CFRelease(attributed);
    CFRelease(attributes);
    CFRelease(string);
    return glyph;
}

typedef struct {
    CGGlyph glyphs[4];
    CGSize advances[4];
    CGPoint origins[4];
    CFIndex indexes[4];
    CFIndex count;
} Shaped;

// The glyph `character` takes from CTFontShapeGlyphs, given its nominal glyph and advance as WebCore gives them.
static CGGlyph shapedGlyph(CTFontRef font, UniChar character)
{
    Shaped storage;
    memset(&storage, 0, sizeof storage);
    Shaped *run = &storage;
    run->count = 1;
    CTFontGetGlyphsForCharacters(font, &character, run->glyphs, 1);
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, run->glyphs, run->advances, 1);
    run->advances[0] = CGSizeMake((float)run->advances[0].width, 0);
    CTFontShapeGlyphs(font, run->glyphs, run->advances, run->origins, run->indexes, &character, 1, 0, NULL,
        ^(CFRange range, CGGlyph **outGlyphs, CGSize **outAdvances, CGPoint **outOrigins, CFIndex **outIndexes) {
            run->count += range.length;
            *outGlyphs = run->glyphs;
            *outAdvances = run->advances;
            *outOrigins = run->origins;
            *outIndexes = run->indexes;
        });
    return run->count == 1 ? run->glyphs[0] : 0xFFFF;
}

static CTFontRef fontWithSetting(CTFontDescriptorRef base, CFTypeRef element)
{
    CTFontDescriptorRef descriptor = copyWithSetting(base, element);
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 40, NULL);
    CFRelease(descriptor);
    return font;
}

static CGGlyph namedGlyph(CTFontRef font, CFStringRef name)
{
    CGFontRef graphicsFont = CTFontCopyGraphicsFont(font, NULL);
    CGGlyph glyph = graphicsFont ? CGFontGetGlyphWithGlyphName(graphicsFont, name) : 0;
    if (graphicsFont)
        CGFontRelease(graphicsFont);
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

int main(int argc, char **argv)
{
    if (argc < 3) {
        printf("usage: %s <FontWithFancyFeatures.otf> <gsubtest-lookup3.otf>\n", argv[0]);
        return 2;
    }
    CTFontDescriptorRef fromData = descriptorFromFontData(argv[1]);
    check(fromData != NULL, "CTFontManagerCreateFontDescriptorFromData returns a descriptor for the fixture");
    if (!fromData)
        return 1;

    CTFontRef plain = CTFontCreateWithFontDescriptor(fromData, 40, NULL);
    bool reportsFont = false;
    check(lineGlyph(plain, 'k', &reportsFont) != 1 && lineGlyph(plain, 'n', &reportsFont) != 1,
        "the fixture's 'k' and 'n' take their own glyphs without settings");

    CFDictionaryRef cv01On = openTypeSetting(CFSTR("cv01"), 1);
    CFDictionaryRef cv01Off = openTypeSetting(CFSTR("cv01"), 0);
    CFDictionaryRef saltOn = openTypeSetting(CFSTR("salt"), 1);
    const void *clearElements[] = { CFSTR("cv01"), kCFNull };
    CFArrayRef cv01Clear = CFArrayCreate(kCFAllocatorDefault, clearElements, 2, &kCFTypeArrayCallBacks);

    // (a)
    CFDictionaryRef cv01Attributes = settingsAttributes(cv01On);
    CTFontDescriptorRef created = CTFontDescriptorCreateWithAttributes(cv01Attributes);
    check(descriptorValue(created, CFSTR("cv01")) == 1, "(a) CTFontDescriptorCopyAttribute reads cv01 back from a new descriptor");
    check(attributesValue(created, CFSTR("cv01")) == 1, "(a) CTFontDescriptorCopyAttributes reads cv01 back from a new descriptor");
    CTFontDescriptorRef withCV01 = copyWithSetting(fromData, cv01On);
    CTFontRef cv01Font = CTFontCreateWithFontDescriptor(withCV01, 40, NULL);
    check(descriptorValue(withCV01, CFSTR("cv01")) == 1, "(a) a copy of the fixture's descriptor reads cv01 back");
    check(fontValue(cv01Font, CFSTR("cv01")) == 1, "(a) CTFontCopyAttribute reads cv01 back from the realized font");
    CTFontDescriptorRef fontDescriptor = CTFontCopyFontDescriptor(cv01Font);
    check(descriptorValue(fontDescriptor, CFSTR("cv01")) == 1, "(a) CTFontCopyFontDescriptor carries cv01");

    // (b)
    CTFontDescriptorRef cleared = copyWithSetting(withCV01, cv01Clear);
    check(descriptorValue(cleared, CFSTR("cv01")) == -1, "(b) a copy clearing cv01 drops it");
    CTFontDescriptorRef kept = copyWithSetting(withCV01, saltOn);
    check(descriptorValue(kept, CFSTR("cv01")) == 1 && descriptorValue(kept, CFSTR("salt")) == 1,
        "(b) a copy naming salt keeps cv01 and adds salt");

    // (c)
    check(lineGlyph(cv01Font, 'k', &reportsFont) == 1, "(c) cv01 substitutes 'k' in a CTLine");
    check(reportsFont, "(c) the CTLine's run reports the font it was given");
    check(shapedGlyph(cv01Font, 'k') == 1, "(c) cv01 substitutes 'k' in CTFontShapeGlyphs");
    CTFontRef bothFont = CTFontCreateWithFontDescriptor(kept, 40, NULL);
    check(lineGlyph(bothFont, 'k', &reportsFont) == 1 && lineGlyph(bothFont, 'n', &reportsFont) == 1,
        "(c) cv01 and salt together substitute 'k' and 'n' in a CTLine");
    check(shapedGlyph(bothFont, 'k') == 1 && shapedGlyph(bothFont, 'n') == 1,
        "(c) cv01 and salt together substitute 'k' and 'n' in CTFontShapeGlyphs");

    // (d)
    CTFontDescriptorRef withCV01Off = copyWithSetting(fromData, cv01Off);
    CTFontRef cv01OffFont = CTFontCreateWithFontDescriptor(withCV01Off, 40, NULL);
    check(lineGlyph(cv01OffFont, 'k', &reportsFont) != 1 && shapedGlyph(cv01OffFont, 'k') != 1, "(d) cv01 0 substitutes nothing");

    // (e)
    CTFontRef copied = CTFontCreateCopyWithAttributes(cv01Font, 20, NULL, NULL);
    check(fontValue(copied, CFSTR("cv01")) == 1 && shapedGlyph(copied, 'k') == 1, "(e) a font copy keeps cv01");
    CTFontRef plainAtSize = CTFontCreateWithFontDescriptor(fromData, 40, NULL);
    check(!CFEqual(cv01Font, plainAtSize), "(e) a font carrying cv01 is not equal to the same font without it");

    // (f)
    const UniChar alternated[] = { 'n', 'o', 'p' };
    for (int value = 2; value <= 4; value++) {
        CFDictionaryRef setting = openTypeSetting(CFSTR("salt"), value);
        CTFontRef font = fontWithSetting(fromData, setting);
        for (int i = 0; i < 3; i++) {
            bool expected = i + 1 == value;
            char message[128];
            snprintf(message, sizeof message, "(f) salt %d %s '%c' in a CTLine", value, expected ? "substitutes" : "leaves", alternated[i]);
            check((lineGlyph(font, alternated[i], &reportsFont) == 1) == expected, message);
            snprintf(message, sizeof message, "(f) salt %d %s '%c' in CTFontShapeGlyphs", value, expected ? "substitutes" : "leaves", alternated[i]);
            check((shapedGlyph(font, alternated[i]) == 1) == expected, message);
        }
        CFRelease(font);
        CFRelease(setting);
    }

    // (g)
    CTFontDescriptorRef seravek = CTFontDescriptorCreateWithNameAndSize(CFSTR("Seravek"), 40);
    CFDictionaryRef numrOn = openTypeSetting(CFSTR("numr"), 1);
    CFDictionaryRef dnomOn = openTypeSetting(CFSTR("dnom"), 1);
    CTFontRef numrFont = fontWithSetting(seravek, numrOn);
    CTFontRef dnomFont = fontWithSetting(seravek, dnomOn);
    CGGlyph numerator = namedGlyph(numrFont, CFSTR("one.numr"));
    CGGlyph denominator = namedGlyph(dnomFont, CFSTR("one.dnom"));
    check(numerator && denominator, "(g) Seravek is installed with one.numr and one.dnom");
    check(lineGlyph(numrFont, '1', &reportsFont) == numerator && shapedGlyph(numrFont, '1') == numerator,
        "(g) numr sets Seravek's '1' as one.numr in a CTLine and in CTFontShapeGlyphs");
    check(lineGlyph(dnomFont, '1', &reportsFont) == denominator && shapedGlyph(dnomFont, '1') == denominator,
        "(g) dnom sets Seravek's '1' as one.dnom in a CTLine and in CTFontShapeGlyphs");

    // (h)
    CTFontDescriptorRef gothic = CTFontDescriptorCreateWithNameAndSize(CFSTR("AppleSDGothicNeo-Regular"), 40);
    CTFontRef gothicPlain = CTFontCreateWithFontDescriptor(gothic, 40, NULL);
    CFDictionaryRef naltOn = openTypeSetting(CFSTR("nalt"), 1);
    CTFontRef gothicNalt = fontWithSetting(gothic, naltOn);
    const UniChar gothicCharacters[] = { 0xAC04, 0xAC19, '1' };
    for (int i = 0; i < 3; i++) {
        bool plainReports = false;
        CGGlyph expected = lineGlyph(gothicPlain, gothicCharacters[i], &plainReports);
        check(lineGlyph(gothicNalt, gothicCharacters[i], &reportsFont) == expected && shapedGlyph(gothicNalt, gothicCharacters[i]) == expected,
            "(h) nalt leaves AppleSDGothicNeo-Regular, a morx font, as 10.9 shapes it");
    }

    // (i)
    CFDictionaryRef swshTwo = openTypeSetting(CFSTR("swsh"), 2);
    CTFontRef swshFont = fontWithSetting(fromData, swshTwo);
    check(lineGlyph(swshFont, 'r', &reportsFont) == 1 && shapedGlyph(swshFont, 'r') == 1
        && lineGlyph(swshFont, 'q', &reportsFont) != 1 && shapedGlyph(swshFont, 's') != 1,
        "(i) swsh 2 substitutes 'r' alone in a CTLine and in CTFontShapeGlyphs");
    CFDictionaryRef afrcOn = openTypeSetting(CFSTR("afrc"), 1);
    CTFontRef afrcFont = fontWithSetting(fromData, afrcOn);
    check(lineGlyph(afrcFont, 'U', &reportsFont) == 1 && shapedGlyph(afrcFont, 'U') == 1,
        "(i) afrc substitutes 'U' in a CTLine and in CTFontShapeGlyphs");

    // (j)
    CTFontDescriptorRef gsubtest = descriptorFromFontData(argv[2]);
    check(gsubtest != NULL, "CTFontManagerCreateFontDescriptorFromData returns a descriptor for the gsubtest font");
    if (gsubtest) {
        CFDictionaryRef pwidOn = openTypeSetting(CFSTR("pwid"), 1);
        CFDictionaryRef hligOn = openTypeSetting(CFSTR("hlig"), 1);
        CTFontRef pwidFont = fontWithSetting(gsubtest, pwidOn);
        CTFontRef hligFont = fontWithSetting(gsubtest, hligOn);
        CGGlyph pwidPass = namedGlyph(pwidFont, CFSTR("pwid.pass"));
        CGGlyph hligPass = namedGlyph(hligFont, CFSTR("hlig.pass"));
        const UniChar pwidAlternate = 0xE2D9, hligAlternate = 0xE231, histAlternate = 0xE229;
        CGGlyph histNominal = 0;
        CTFontGetGlyphsForCharacters(hligFont, &histAlternate, &histNominal, 1);
        check(lineGlyph(pwidFont, pwidAlternate, &reportsFont) == pwidPass && shapedGlyph(pwidFont, pwidAlternate) == pwidPass,
            "(j) pwid applies through a borrowed stylistic set");
        check(lineGlyph(hligFont, hligAlternate, &reportsFont) == hligPass && shapedGlyph(hligFont, hligAlternate) == hligPass,
            "(j) hlig applies through a borrowed stylistic set");
        check(lineGlyph(hligFont, histAlternate, &reportsFont) == histNominal && shapedGlyph(hligFont, histAlternate) == histNominal,
            "(j) hlig leaves hist off");
        CFRelease(hligFont);
        CFRelease(pwidFont);
        CFRelease(hligOn);
        CFRelease(pwidOn);
        CFRelease(gsubtest);
    }

    CFRelease(afrcFont);
    CFRelease(afrcOn);
    CFRelease(swshFont);
    CFRelease(swshTwo);
    CFRelease(gothicNalt);
    CFRelease(naltOn);
    CFRelease(gothicPlain);
    CFRelease(gothic);
    CFRelease(dnomFont);
    CFRelease(numrFont);
    CFRelease(dnomOn);
    CFRelease(numrOn);
    CFRelease(seravek);
    CFRelease(plainAtSize);
    CFRelease(copied);
    CFRelease(cv01OffFont);
    CFRelease(withCV01Off);
    CFRelease(bothFont);
    CFRelease(kept);
    CFRelease(cleared);
    CFRelease(fontDescriptor);
    CFRelease(cv01Font);
    CFRelease(withCV01);
    CFRelease(created);
    CFRelease(cv01Attributes);
    CFRelease(cv01Clear);
    CFRelease(saltOn);
    CFRelease(cv01Off);
    CFRelease(cv01On);
    CFRelease(plain);
    CFRelease(fromData);

    if (failures)
        return 1;
    printf("PASS: OpenType-only feature settings ride descriptors and fonts and apply in shaping\n");
    return 0;
}
