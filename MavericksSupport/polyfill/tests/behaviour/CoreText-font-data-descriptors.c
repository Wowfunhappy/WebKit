// Descriptors from CTFontManagerCreateFontDescriptorFromData (polyfills/c/CoreText.c) realize their
// own font's data for as long as anything built from them lives:
//
//   * A CFF font is read through a temporary file, because 10.9's in-memory CFF reader answers vertical
//     metrics wrong. Its vertical advances and translations match the system reader of the same file.
//   * 10.9 closes font files it is not drawing from once enough fonts are open, and reopens them by
//     path. The face keeps its outlines, and realizes at a new size as itself rather than LastResort,
//     after hundreds of other faces open. Its file goes away once no font uses it.
//   * A descriptor narrowed with traits or feature settings realizes the same face, CFF, TrueType and
//     GX alike, and so does a CFF font copied with such attributes.
//   * A variation request keyed by string names no axis: realizing or copying with one answers the
//     face at its default instance, for static and variable fonts alike.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static CTFontDescriptorRef descriptorFromFile(const char *path)
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

static CTFontRef systemReaderFont(const char *path, CGFloat size)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFArrayRef descriptors = url ? CTFontManagerCreateFontDescriptorsFromURL(url) : NULL;
    CTFontRef font = descriptors && CFArrayGetCount(descriptors)
        ? CTFontCreateWithFontDescriptor((CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0), size, NULL) : NULL;
    if (descriptors)
        CFRelease(descriptors);
    if (url)
        CFRelease(url);
    return font;
}

static CGGlyph glyphFor(CTFontRef font, UniChar character)
{
    CGGlyph glyph = 0;
    CTFontGetGlyphsForCharacters(font, &character, &glyph, 1);
    return glyph;
}

static CGRect outlineBounds(CTFontRef font, CGGlyph glyph)
{
    CGPathRef path = CTFontCreatePathForGlyph(font, glyph, NULL);
    CGRect bounds = path ? CGPathGetBoundingBox(path) : CGRectNull;
    if (path)
        CGPathRelease(path);
    return bounds;
}

static int fontFileExists(CTFontRef font, char *path, size_t length)
{
    CFURLRef url = (CFURLRef)CTFontCopyAttribute(font, kCTFontURLAttribute);
    int ok = url && CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, (CFIndex)length);
    if (url)
        CFRelease(url);
    return ok && !access(path, F_OK);
}

static int sameName(CTFontRef font, CTFontRef other)
{
    CFStringRef name = font ? CTFontCopyPostScriptName(font) : NULL;
    CFStringRef otherName = other ? CTFontCopyPostScriptName(other) : NULL;
    int same = name && otherName && CFEqual(name, otherName);
    if (name)
        CFRelease(name);
    if (otherName)
        CFRelease(otherName);
    return same;
}

static int nearly(CGFloat a, CGFloat b)
{
    return fabs(a - b) < 0.0005;
}

static void checkVerticalMetrics(const char *path, CTFontDescriptorRef descriptor)
{
    const CGFloat size = 20;
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    CTFontRef reference = systemReaderFont(path, size);
    check(reference != NULL, "the system reader opens the CFF font");
    if (!reference) {
        CFRelease(font);
        return;
    }
    CGGlyph glyph = glyphFor(font, 'p');
    CGSize advance, referenceAdvance, translation, referenceTranslation;
    CTFontGetAdvancesForGlyphs(font, kCTFontOrientationVertical, &glyph, &advance, 1);
    CTFontGetAdvancesForGlyphs(reference, kCTFontOrientationVertical, &glyph, &referenceAdvance, 1);
    CTFontGetVerticalTranslationsForGlyphs(font, &glyph, &translation, 1);
    CTFontGetVerticalTranslationsForGlyphs(reference, &glyph, &referenceTranslation, 1);
    check(nearly(advance.width, referenceAdvance.width) && nearly(advance.height, referenceAdvance.height),
        "the CFF vertical advance matches the system reader of the file");
    check(nearly(translation.width, referenceTranslation.width) && nearly(translation.height, referenceTranslation.height),
        "the CFF vertical translation matches the system reader of the file");
    CFRelease(reference);
    CFRelease(font);
}

static void checkFileLifetime(const char *path, CTFontDescriptorRef descriptor)
{
    const CGFloat size = 14;
    enum { otherFaces = 300 };
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    CGGlyph glyph = glyphFor(font, 'p');
    CGRect bounds = outlineBounds(font, glyph);
    check(glyph != 0 && !CGRectIsEmpty(bounds), "the CFF face maps and outlines 'p'");
    char file[1024];
    check(fontFileExists(font, file, sizeof file), "the CFF face's file exists while the face is alive");

    CTFontRef others[otherFaces];
    for (int i = 0; i < otherFaces; ++i) {
        CTFontDescriptorRef otherDescriptor = descriptorFromFile(path);
        others[i] = otherDescriptor ? CTFontCreateWithFontDescriptor(otherDescriptor, size, NULL) : NULL;
        if (otherDescriptor)
            CFRelease(otherDescriptor);
        if (others[i])
            outlineBounds(others[i], glyphFor(others[i], 'p'));
    }

    check(CGRectEqualToRect(outlineBounds(font, glyph), bounds), "the outline is unchanged once other faces opened files");
    CTFontRef resized = CTFontCreateWithFontDescriptor(descriptor, 2 * size, NULL);
    check(glyphFor(resized, 'p') == glyph, "the face realizes at a new size as itself, not LastResort");
    check(CGRectEqualToRect(outlineBounds(resized, glyph),
            CGRectMake(2 * bounds.origin.x, 2 * bounds.origin.y, 2 * bounds.size.width, 2 * bounds.size.height)),
        "the outline at twice the size is twice the outline");

    CFRelease(resized);
    CFRelease(font);
    for (int i = 0; i < otherFaces; ++i) {
        if (others[i])
            CFRelease(others[i]);
    }
    CFRelease(descriptor);
    check(access(file, F_OK), "the CFF face's file is removed once no font uses it");
}

static void checkNarrowedDescriptors(CTFontDescriptorRef descriptor, const char *flavor)
{
    char what[160];
    const CGFloat size = 20;
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);

    CGFloat weight = 0.4;
    CFNumberRef weightNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &weight);
    const void *traitKeys[] = { kCTFontWeightTrait };
    const void *traitValues[] = { weightNumber };
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, traitKeys, traitValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *attributeKeys[] = { kCTFontTraitsAttribute };
    const void *attributeValues[] = { traits };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, attributeKeys, attributeValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef weighted = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes);

    CTFontRef fromWeighted = CTFontCreateWithFontDescriptor(weighted, size, NULL);
    snprintf(what, sizeof what, "a %s descriptor narrowed with a weight trait realizes the same face", flavor);
    check(sameName(fromWeighted, font) && glyphFor(fromWeighted, 'p') == glyphFor(font, 'p'), what);

    int zero = 0;
    CFNumberRef selector = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    CFNumberRef type = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    const void *featureKeys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
    const void *featureValues[] = { type, selector };
    CFDictionaryRef feature = CFDictionaryCreate(kCFAllocatorDefault, featureKeys, featureValues, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef features = CFArrayCreate(kCFAllocatorDefault, (const void **)&feature, 1, &kCFTypeArrayCallBacks);
    const void *featureAttributeKeys[] = { kCTFontFeatureSettingsAttribute };
    const void *featureAttributeValues[] = { features };
    CFDictionaryRef featureAttributes = CFDictionaryCreate(kCFAllocatorDefault, featureAttributeKeys, featureAttributeValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef withFeatures = CTFontDescriptorCreateCopyWithAttributes(weighted, featureAttributes);
    CTFontRef fromFeatures = CTFontCreateWithFontDescriptor(withFeatures, size, NULL);
    snprintf(what, sizeof what, "a %s descriptor narrowed with traits and feature settings realizes the same face", flavor);
    check(sameName(fromFeatures, font) && glyphFor(fromFeatures, 'p') == glyphFor(font, 'p'), what);

    const void *copyKeys[] = { kCTFontTraitsAttribute, kCTFontFeatureSettingsAttribute };
    const void *copyValues[] = { traits, features };
    CFDictionaryRef copyAttributes = CFDictionaryCreate(kCFAllocatorDefault, copyKeys, copyValues, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef copyDescriptor = CTFontDescriptorCreateWithAttributes(copyAttributes);
    CTFontRef copy = CTFontCreateCopyWithAttributes(font, 25, NULL, copyDescriptor);
    snprintf(what, sizeof what, "a %s font copied with traits and feature settings is the same face", flavor);
    check(sameName(copy, font) && glyphFor(copy, 'p') == glyphFor(font, 'p'), what);

    CFRelease(copy);
    CFRelease(copyDescriptor);
    CFRelease(copyAttributes);
    CFRelease(fromFeatures);
    CFRelease(withFeatures);
    CFRelease(featureAttributes);
    CFRelease(features);
    CFRelease(feature);
    CFRelease(type);
    CFRelease(selector);
    CFRelease(fromWeighted);
    CFRelease(weighted);
    CFRelease(attributes);
    CFRelease(traits);
    CFRelease(weightNumber);
    CFRelease(font);
}

static void checkWeightNarrowing(CTFontDescriptorRef descriptor, const char *flavor)
{
    char what[160];
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 20, NULL);
    CGFloat weight = 0.4;
    CFNumberRef weightNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &weight);
    const void *traitKeys[] = { kCTFontWeightTrait };
    const void *traitValues[] = { weightNumber };
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, traitKeys, traitValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { kCTFontTraitsAttribute };
    const void *values[] = { traits };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef weighted = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes);
    CTFontRef fromWeighted = CTFontCreateWithFontDescriptor(weighted, 20, NULL);
    snprintf(what, sizeof what, "a %s descriptor narrowed with a weight trait realizes the same face", flavor);
    check(sameName(fromWeighted, font) && glyphFor(fromWeighted, 'P') == glyphFor(font, 'P'), what);
    CFRelease(fromWeighted);
    CFRelease(weighted);
    CFRelease(attributes);
    CFRelease(traits);
    CFRelease(weightNumber);
    CFRelease(font);
}

static void checkStringKeyedVariation(CTFontDescriptorRef descriptor, const char *flavor)
{
    char what[160];
    const CGFloat size = 20;
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    double heavy = 900;
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &heavy);
    const void *axisKeys[] = { CFSTR("wght") };
    const void *axisValues[] = { value };
    CFDictionaryRef variation = CFDictionaryCreate(kCFAllocatorDefault, axisKeys, axisValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { kCTFontVariationAttribute };
    const void *values[] = { variation };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CTFontDescriptorRef keyed = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes);
    CTFontRef realized = CTFontCreateWithFontDescriptor(keyed, size, NULL);
    snprintf(what, sizeof what, "a %s descriptor with a string-keyed variation realizes the default instance", flavor);
    check(sameName(realized, font) && CTFontGetAdvancesForGlyphs(realized, kCTFontOrientationHorizontal, (CGGlyph[]){ glyphFor(font, 'P') }, NULL, 1)
        == CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, (CGGlyph[]){ glyphFor(font, 'P') }, NULL, 1), what);

    CTFontDescriptorRef modification = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontRef copy = CTFontCreateCopyWithAttributes(font, 0, NULL, modification);
    snprintf(what, sizeof what, "a %s font copied with a string-keyed variation is the default instance", flavor);
    check(sameName(copy, font) && CTFontGetAdvancesForGlyphs(copy, kCTFontOrientationHorizontal, (CGGlyph[]){ glyphFor(font, 'P') }, NULL, 1)
        == CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, (CGGlyph[]){ glyphFor(font, 'P') }, NULL, 1), what);

    CFRelease(copy);
    CFRelease(modification);
    CFRelease(realized);
    CFRelease(keyed);
    CFRelease(attributes);
    CFRelease(variation);
    CFRelease(value);
    CFRelease(font);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        printf("usage: %s cff-font.otf truetype-font.ttf gx-variable-font.ttf\n", argv[0]);
        return 2;
    }

    CTFontDescriptorRef cff = descriptorFromFile(argv[1]);
    CTFontDescriptorRef trueType = descriptorFromFile(argv[2]);
    CTFontDescriptorRef variable = descriptorFromFile(argv[3]);
    check(cff && trueType && variable, "every font makes a descriptor");
    if (!cff || !trueType || !variable)
        return 1;

    checkVerticalMetrics(argv[1], cff);
    checkNarrowedDescriptors(cff, "CFF");
    checkWeightNarrowing(trueType, "TrueType");
    checkWeightNarrowing(variable, "GX variable");
    checkStringKeyedVariation(cff, "CFF");
    checkStringKeyedVariation(trueType, "TrueType");
    checkStringKeyedVariation(variable, "GX variable");
    CFRelease(variable);
    CFRelease(trueType);
    checkFileLifetime(argv[1], cff);

    if (!failures)
        printf("PASS\n");
    return failures ? 1 : 0;
}
