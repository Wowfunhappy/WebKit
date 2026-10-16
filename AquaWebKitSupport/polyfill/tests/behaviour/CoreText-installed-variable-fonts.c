// Installed variable fonts (wk_cutOfInstalledVariableFont, polyfills/c/CoreText.c). An installed variable
// face draws from a static cut of its file, as a variable web font does from its bytes, whatever tables it
// carries:
//   (a) Inter.var.subset.ttf without its STAT table, whose slnt axis has its default at its maximum, a font
//       10.9 reads no glyph of, registered for this process, advances 'n' as the font built from the same
//       bytes does;
//   (b) Amstelvar-Roman-VF104.ttf, which carries STAT and which 10.9 reads at its default instance,
//       registered for this process, advances 'H' at wght 900 as the font built from its bytes does, and
//       wider than at its default instance;
//   (c) every face of Inter.var.subset.ttf registered for this process -- its default and its seventeen
//       named instances, which 10.9 names alike ("Inter-Regular_") -- realized last to first and then
//       first to last, advances 'n' as the font built from its bytes does at that face's instance;
//   (d) Skia's ten named instances answer the PostScript name, symbolic traits and weight and width
//       traits 10.9 answers for them;
//   (e) Inter.var.subset.ttf as the first face of a font collection, registered for this process,
//       advances 'n' as the font built from its bytes does, and so does its Black named instance at that
//       instance;
//   (f) Skia asked for a variation answers the traits 10.9 answers for the uncut face at it: installed, as
//       10.9 realizes the installed face there; built from its bytes, as at its default, which is what
//       10.9 answers for a font outside its registry at any variation. Installed Inter at wght 700 is bold;
//   (g) one rule on every entry point: Skia's Black, Regular and Bold named instances asked for (3.2, 1)
//       through a descriptor, and Black and Regular copied under it, answer the same symbolic traits and
//       weight; Black by name, and a copy of it that changes only the size, answer the face's own, as 10.9
//       does (0x80000000, weight 0);
//   (h) the descriptor of every face of Inter.var.subset.ttf registered for this process, whose named
//       instances share a name, answers the variation, traits, style name, display name and file the face
//       answers.
//
// usage: installed_variable_fonts <Inter.var.subset.ttf> <Amstelvar-Roman-VF104.ttf> <Ahem.ttf> <scratch directory>
#include <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static CFDataRef readFile(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (!file)
        return NULL;
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    fseek(file, 0, SEEK_SET);
    UInt8 *bytes = length > 0 ? (UInt8 *)malloc((size_t)length) : NULL;
    CFDataRef data = bytes && fread(bytes, 1, (size_t)length, file) == (size_t)length ? CFDataCreate(kCFAllocatorDefault, bytes, length) : NULL;
    free(bytes);
    fclose(file);
    return data;
}

// The sfnt with one table left out of its directory.
static CFDataRef withoutTable(CFDataRef sfnt, const char *tag)
{
    CFMutableDataRef copy = CFDataCreateMutableCopy(kCFAllocatorDefault, 0, sfnt);
    UInt8 *bytes = CFDataGetMutableBytePtr(copy);
    unsigned count = (unsigned)(bytes[4] << 8 | bytes[5]);
    unsigned kept = 0;
    for (unsigned i = 0; i < count; i++) {
        UInt8 *record = bytes + 12 + 16 * i;
        if (!memcmp(record, tag, 4))
            continue;
        memmove(bytes + 12 + 16 * kept++, record, 16);
    }
    memset(bytes + 12 + 16 * kept, 0, 16 * (count - kept));
    bytes[4] = (UInt8)(kept >> 8);
    bytes[5] = (UInt8)kept;
    return copy;
}

static bool registerFile(const char *path, bool registering)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    bool done = registering ? CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, NULL)
        : CTFontManagerUnregisterFontsForURL(url, kCTFontManagerScopeProcess, NULL);
    CFRelease(url);
    return done;
}

static bool writeFile(const char *path, CFDataRef data)
{
    FILE *out = data ? fopen(path, "wb") : NULL;
    if (!out)
        return false;
    bool written = fwrite(CFDataGetBytePtr(data), 1, (size_t)CFDataGetLength(data), out) == (size_t)CFDataGetLength(data);
    fclose(out);
    return written;
}

static unsigned be16(const UInt8 *bytes) { return (unsigned)(bytes[0] << 8 | bytes[1]); }
static uint32_t be32(const UInt8 *bytes) { return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3]; }
static void put32(UInt8 *bytes, uint32_t value)
{
    bytes[0] = (UInt8)(value >> 24);
    bytes[1] = (UInt8)(value >> 16);
    bytes[2] = (UInt8)(value >> 8);
    bytes[3] = (UInt8)value;
}

// A font collection of the given sfnts, each table copied once per face.
static CFDataRef collection(CFDataRef *faces, unsigned count)
{
    CFMutableDataRef result = CFDataCreateMutable(kCFAllocatorDefault, 0);
    size_t headerLength = 12 + 4 * count;
    size_t directoriesLength = 0;
    for (unsigned f = 0; f < count; f++)
        directoriesLength += 12 + 16 * be16(CFDataGetBytePtr(faces[f]) + 4);
    CFDataSetLength(result, (CFIndex)(headerLength + directoriesLength));
    UInt8 *bytes = CFDataGetMutableBytePtr(result);
    memcpy(bytes, "ttcf", 4);
    put32(bytes + 4, 0x00010000);
    put32(bytes + 8, count);
    size_t directory = headerLength;
    for (unsigned f = 0; f < count; f++) {
        const UInt8 *face = CFDataGetBytePtr(faces[f]);
        unsigned tables = be16(face + 4);
        bytes = CFDataGetMutableBytePtr(result);
        put32(bytes + 12 + 4 * f, (uint32_t)directory);
        memcpy(bytes + directory, face, 12 + 16 * tables);
        for (unsigned t = 0; t < tables; t++) {
            const UInt8 *record = face + 12 + 16 * t;
            uint32_t offset = be32(record + 8), length = be32(record + 12);
            CFIndex at = CFDataGetLength(result);
            CFDataAppendBytes(result, face + offset, length);
            static const UInt8 padding[4];
            CFDataAppendBytes(result, padding, (CFIndex)((4 - length % 4) % 4));
            put32(CFDataGetMutableBytePtr(result) + directory + 12 + 16 * t + 8, (uint32_t)at);
        }
        directory += 12 + 16 * tables;
    }
    return result;
}

// The traits of the font `descriptor` realizes under a wght (and wdth) request of `count` values.
static void traitsOf(CTFontDescriptorRef descriptor, const double *values, unsigned count, CTFontSymbolicTraits *symbolic,
                     double *weight, double *width)
{
    CFMutableDictionaryRef variation = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    static const long long tags[] = { 'wght', 'wdth' };
    for (unsigned i = 0; i < count; i++) {
        CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &tags[i]);
        CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &values[i]);
        CFDictionarySetValue(variation, key, value);
        CFRelease(key);
        CFRelease(value);
    }
    const void *keys[] = { kCTFontVariationAttribute };
    const void *attributeValues[] = { variation };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, attributeValues, count ? 1 : 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef varied = descriptor ? CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes) : NULL;
    CTFontRef font = varied ? CTFontCreateWithFontDescriptor(varied, 40, NULL) : NULL;
    CFDictionaryRef traits = font ? CTFontCopyTraits(font) : NULL;
    *symbolic = font ? CTFontGetSymbolicTraits(font) : ~0u;
    *weight = *width = -9;
    if (traits) {
        CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(traits, kCTFontWeightTrait), kCFNumberDoubleType, weight);
        CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(traits, kCTFontWidthTrait), kCFNumberDoubleType, width);
        CFRelease(traits);
    }
    if (font)
        CFRelease(font);
    if (varied)
        CFRelease(varied);
    CFRelease(attributes);
    CFRelease(variation);
}

// The traits of the face of that name, or of a copy of it at `copySize` (0 for none) under a wght and wdth
// request of `count` values.
static void copyTraitsOf(CFStringRef name, const double *values, unsigned count, CGFloat copySize,
                         CTFontSymbolicTraits *symbolic, double *weight)
{
    CTFontRef face = CTFontCreateWithName(name, 40, NULL);
    CTFontRef font = face;
    if (copySize > 0) {
        CFMutableDictionaryRef variation = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        static const long long tags[] = { 'wght', 'wdth' };
        for (unsigned i = 0; i < count; i++) {
            CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &tags[i]);
            CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &values[i]);
            CFDictionarySetValue(variation, key, value);
            CFRelease(key);
            CFRelease(value);
        }
        const void *keys[] = { kCTFontVariationAttribute };
        const void *attributeValues[] = { variation };
        CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, attributeValues, count ? 1 : 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef request = CTFontDescriptorCreateWithAttributes(attributes);
        font = CTFontCreateCopyWithAttributes(face, copySize, NULL, request);
        CFRelease(request);
        CFRelease(attributes);
        CFRelease(variation);
    }
    CFDictionaryRef traits = font ? CTFontCopyTraits(font) : NULL;
    *symbolic = font ? CTFontGetSymbolicTraits(font) : ~0u;
    *weight = -9;
    if (traits) {
        CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(traits, kCTFontWeightTrait), kCFNumberDoubleType, weight);
        CFRelease(traits);
    }
    if (font && font != face)
        CFRelease(font);
    if (face)
        CFRelease(face);
}

static double faceAdvance(CTFontDescriptorRef descriptor)
{
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 40, NULL);
    UniChar character = 'n';
    CGGlyph glyph = 0;
    CGSize advance = CGSizeZero;
    if (font && CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
    if (font)
        CFRelease(font);
    return advance.width;
}

// The font built from `sfnt` at its `instance`th named instance, counting as 10.9 lists a variable font's
// faces: the default face first, and no named instance that sits at the defaults (-1 for the default).
static double instanceAdvance(CFDataRef sfnt, CTFontDescriptorRef fromData, int instance)
{
    if (instance < 0)
        return faceAdvance(fromData);
    const UInt8 *bytes = CFDataGetBytePtr(sfnt);
    const UInt8 *fvar = NULL;
    for (unsigned t = 0; t < be16(bytes + 4); t++) {
        if (!memcmp(bytes + 12 + 16 * t, "fvar", 4))
            fvar = bytes + be32(bytes + 12 + 16 * t + 8);
    }
    if (!fvar)
        return -1;
    unsigned axesOffset = be16(fvar + 4), axisCount = be16(fvar + 8), axisSize = be16(fvar + 10);
    unsigned instanceCount = be16(fvar + 12), instanceSize = be16(fvar + 14);
    const UInt8 *record = NULL;
    for (unsigned i = 0, listed = 0; i < instanceCount && !record; i++) {
        const UInt8 *candidate = fvar + axesOffset + axisCount * axisSize + i * instanceSize;
        bool atDefaults = true;
        for (unsigned a = 0; a < axisCount; a++)
            atDefaults = atDefaults && be32(candidate + 4 + 4 * a) == be32(fvar + axesOffset + a * axisSize + 8);
        if (!atDefaults && listed++ == (unsigned)instance)
            record = candidate;
    }
    if (!record)
        return -1;
    CFMutableDictionaryRef variation = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (unsigned a = 0; a < axisCount; a++) {
        long long tag = be32(fvar + axesOffset + a * axisSize);
        double value = (int32_t)be32(record + 4 + 4 * a) / 65536.0;
        CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &tag);
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
        CFDictionarySetValue(variation, key, number);
        CFRelease(key);
        CFRelease(number);
    }
    const void *keys[] = { kCTFontVariationAttribute };
    const void *values[] = { variation };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef varied = CTFontDescriptorCreateCopyWithAttributes(fromData, attributes);
    double advance = faceAdvance(varied);
    CFRelease(varied);
    CFRelease(attributes);
    CFRelease(variation);
    return advance;
}

static CTFontDescriptorRef withWeight(CTFontDescriptorRef descriptor, double weight)
{
    if (weight < 0)
        return (CTFontDescriptorRef)CFRetain(descriptor);
    long long tag = 'wght';
    CFNumberRef axis = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongLongType, &tag);
    CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &weight);
    CFDictionaryRef variation = CFDictionaryCreate(kCFAllocatorDefault, (const void **)&axis, (const void **)&value, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { kCTFontVariationAttribute };
    const void *values[] = { variation };
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef result = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes);
    CFRelease(attributes);
    CFRelease(variation);
    CFRelease(value);
    CFRelease(axis);
    return result;
}

static double advanceOf(CTFontDescriptorRef descriptor, double weight, UniChar character)
{
    CTFontDescriptorRef varied = withWeight(descriptor, weight);
    CTFontRef font = CTFontCreateWithFontDescriptor(varied, 40, NULL);
    CFRelease(varied);
    CGGlyph glyph = 0;
    CGSize advance = CGSizeZero;
    if (font && CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
    if (font)
        CFRelease(font);
    return advance.width;
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        printf("usage: %s <Inter.var.subset.ttf> <Amstelvar-Roman-VF104.ttf> <Ahem.ttf> <scratch directory>\n", argv[0]);
        return 2;
    }

    // (a)
    CFDataRef inter = readFile(argv[1]);
    CFDataRef interWithoutStat = inter ? withoutTable(inter, "STAT") : NULL;
    char path[1024];
    snprintf(path, sizeof path, "%s/Inter-without-STAT.ttf", argv[4]);
    check(writeFile(path, interWithoutStat) && registerFile(path, true), "(a) Inter without STAT registers for this process");
    CTFontDescriptorRef installedInter = CTFontDescriptorCreateWithNameAndSize(CFSTR("Inter-Regular"), 0);
    CTFontDescriptorRef interFromData = interWithoutStat ? CTFontManagerCreateFontDescriptorFromData(interWithoutStat) : NULL;
    double installed = advanceOf(installedInter, -1, 'n');
    double fromData = interFromData ? advanceOf(interFromData, -1, 'n') : 0;
    if (!(installed > 0 && fabs(installed - fromData) < 0.01)) {
        printf("FAIL: (a) installed Inter without STAT advances 'n' %.3f, the font from its bytes %.3f\n", installed, fromData);
        failures++;
    }

    registerFile(path, false);

    // (b)
    check(registerFile(argv[2], true), "(b) Amstelvar registers for this process");
    CFDataRef amstelvar = readFile(argv[2]);
    CTFontDescriptorRef installedAmstelvar = CTFontDescriptorCreateWithNameAndSize(CFSTR("Amstelvar-Roman"), 0);
    CTFontDescriptorRef amstelvarFromData = amstelvar ? CTFontManagerCreateFontDescriptorFromData(amstelvar) : NULL;
    double installedDefault = advanceOf(installedAmstelvar, -1, 'H');
    double installedBlack = advanceOf(installedAmstelvar, 900, 'H');
    double fromDataBlack = amstelvarFromData ? advanceOf(amstelvarFromData, 900, 'H') : 0;
    if (!(installedDefault > 0 && installedBlack > installedDefault && fabs(installedBlack - fromDataBlack) < 0.01)) {
        printf("FAIL: (b) installed Amstelvar advances 'H' %.3f at its default and %.3f at wght 900, the font from its bytes %.3f\n",
            installedDefault, installedBlack, fromDataBlack);
        failures++;
    }

    // (c)
    check(registerFile(argv[1], true), "(c) Inter registers for this process");
    CFURLRef interURL = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), false);
    CFArrayRef faces = CTFontManagerCreateFontDescriptorsFromURL(interURL);
    CFDataRef interData = readFile(argv[1]);
    CTFontDescriptorRef interDataDescriptor = interData ? CTFontManagerCreateFontDescriptorFromData(interData) : NULL;
    CFIndex faceCount = faces ? CFArrayGetCount(faces) : 0;
    check(faceCount == 18, "(c) Inter has a default face and seventeen named instances");
    for (int pass = 0; pass < 2 && interDataDescriptor; pass++) {
        for (CFIndex n = 0; n < faceCount; n++) {
            CFIndex i = pass ? n : faceCount - 1 - n;
            double advance = faceAdvance((CTFontDescriptorRef)CFArrayGetValueAtIndex(faces, i));
            double expected = instanceAdvance(interData, interDataDescriptor, (int)i - 1);
            if (!(advance > 0 && fabs(advance - expected) < 0.01)) {
                printf("FAIL: (c) Inter face %ld advances 'n' %.3f, its instance %.3f (%s)\n", (long)i, advance, expected,
                    pass ? "first to last" : "last to first");
                failures++;
            }
        }
    }
    // (h)
    for (CFIndex i = 0; i < faceCount; i++) {
        CTFontRef face = CTFontCreateWithFontDescriptor((CTFontDescriptorRef)CFArrayGetValueAtIndex(faces, i), 40, NULL);
        CTFontDescriptorRef own = face ? CTFontCopyFontDescriptor(face) : NULL;
        if (!own) {
            check(false, "(h) Inter's face has a descriptor");
            continue;
        }
        static const char *const names[] = { "variation", "traits", "style name", "display name", "file" };
        CFTypeRef fromFont[] = { CTFontCopyVariation(face), CTFontCopyTraits(face), CTFontCopyName(face, kCTFontStyleNameKey),
            CTFontCopyDisplayName(face), CTFontCopyAttribute(face, kCTFontURLAttribute) };
        CFTypeRef fromDescriptor[] = { CTFontDescriptorCopyAttribute(own, kCTFontVariationAttribute),
            CTFontDescriptorCopyAttribute(own, kCTFontTraitsAttribute), CTFontDescriptorCopyAttribute(own, kCTFontStyleNameAttribute),
            CTFontDescriptorCopyAttribute(own, kCTFontDisplayNameAttribute), CTFontDescriptorCopyAttribute(own, kCTFontURLAttribute) };
        for (size_t a = 0; a < sizeof names / sizeof names[0]; a++) {
            if (!fromDescriptor[a] || !fromFont[a] || !CFEqual(fromDescriptor[a], fromFont[a])) {
                printf("FAIL: (h) Inter face %ld's descriptor answers a %s other than the face's\n", (long)i, names[a]);
                failures++;
            }
            if (fromFont[a])
                CFRelease(fromFont[a]);
            if (fromDescriptor[a])
                CFRelease(fromDescriptor[a]);
        }
        CFRelease(own);
        CFRelease(face);
    }
    registerFile(argv[1], false);

    // (d)
    static const char *const skiaFaces[] = { "Skia-Regular", "Skia-Regular_Black", "Skia-Regular_Extended",
        "Skia-Regular_Condensed", "Skia-Regular_Light", "Skia-Regular_Black-Extended", "Skia-Regular_Light-Extended",
        "Skia-Regular_Black-Condensed", "Skia-Regular_Light-Condensed", "Skia-Regular_Bold" };
    for (size_t i = 0; i < sizeof skiaFaces / sizeof skiaFaces[0]; i++) {
        CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, skiaFaces[i], kCFStringEncodingUTF8);
        CTFontRef font = CTFontCreateWithName(name, 40, NULL);
        CFStringRef postScriptName = font ? CTFontCopyPostScriptName(font) : NULL;
        CFDictionaryRef traits = font ? CTFontCopyTraits(font) : NULL;
        double weight = -1, width = -1;
        if (traits) {
            CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(traits, kCTFontWeightTrait), kCFNumberDoubleType, &weight);
            CFNumberGetValue((CFNumberRef)CFDictionaryGetValue(traits, kCTFontWidthTrait), kCFNumberDoubleType, &width);
        }
        CTFontSymbolicTraits symbolic = font ? CTFontGetSymbolicTraits(font) : ~0u;
        // 10.9 answers every one of them with no bold, expanded or condensed bit and weight and width traits of 0.
        if (!postScriptName || !CFEqual(postScriptName, name)
            || (symbolic & (kCTFontTraitBold | kCTFontTraitExpanded | kCTFontTraitCondensed)) || weight != 0 || width != 0) {
            printf("FAIL: (d) %s answers symbolic traits %#x, weight %.2f, width %.2f\n", skiaFaces[i], symbolic, weight, width);
            failures++;
        }
        CFTypeRef releasesSkia[] = { name, font, postScriptName, traits };
        for (size_t r = 0; r < sizeof releasesSkia / sizeof releasesSkia[0]; r++) {
            if (releasesSkia[r])
                CFRelease(releasesSkia[r]);
        }
    }

    // (e)
    CFDataRef ahem = readFile(argv[3]);
    CFDataRef members[2] = { interData, ahem };
    CFDataRef pair = interData && ahem ? collection(members, 2) : NULL;
    snprintf(path, sizeof path, "%s/Inter-and-Ahem.ttc", argv[4]);
    check(writeFile(path, pair) && registerFile(path, true), "(e) the collection registers for this process");
    double fromCollection = advanceOf(installedInter, -1, 'n');
    double fromBytes = interDataDescriptor ? faceAdvance(interDataDescriptor) : 0;
    if (!(fromCollection > 0 && fabs(fromCollection - fromBytes) < 0.01)) {
        printf("FAIL: (e) Inter from a collection advances 'n' %.3f, the font from its bytes %.3f\n", fromCollection, fromBytes);
        failures++;
    }
    // Black is Inter's sixteenth named instance; 10.9 names it "Inter-Regular_", style "Regular Black".
    CFURLRef pairURL = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFArrayRef pairFaces = CTFontManagerCreateFontDescriptorsFromURL(pairURL);
    double black = 0;
    for (CFIndex i = 0; pairFaces && i < CFArrayGetCount(pairFaces); i++) {
        CTFontDescriptorRef face = (CTFontDescriptorRef)CFArrayGetValueAtIndex(pairFaces, i);
        CFStringRef style = (CFStringRef)CTFontDescriptorCopyAttribute(face, kCTFontStyleNameAttribute);
        if (style && CFEqual(style, CFSTR("Regular Black")))
            black = faceAdvance(face);
        if (style)
            CFRelease(style);
    }
    double blackFromBytes = interDataDescriptor ? instanceAdvance(interData, interDataDescriptor, 15) : -1;
    if (!(black > fromBytes && fabs(black - blackFromBytes) < 0.01)) {
        printf("FAIL: (e) Inter's Black named instance from a collection advances 'n' %.3f, its instance %.3f\n", black, blackFromBytes);
        failures++;
    }
    if (pairFaces)
        CFRelease(pairFaces);
    CFRelease(pairURL);
    registerFile(path, false);

    // (f)
    static const double requests[][2] = { { 3.2, 1 }, { 1, 1.3 }, { 3.2, 1.3 }, { 2.5, 1 }, { 1, 1.2 } };
    // 10.9 realizing installed Skia at each request: symbolic traits, weight and width.
    static const struct { CTFontSymbolicTraits symbolic; double weight, width; } installedAnswers[] = {
        { 0x80000002, 0.80, 0 }, { 0x80000020, 0, 0.44 }, { 0x80000022, 0.80, 0.44 }, { 0x80000002, 0.55, 0 }, { 0x80000020, 0, 0.29 } };
    CFDataRef skia = readFile("/Library/Fonts/Skia.ttf");
    CTFontDescriptorRef skiaFromData = skia ? CTFontManagerCreateFontDescriptorFromData(skia) : NULL;
    CTFontDescriptorRef skiaInstalled = CTFontDescriptorCreateWithNameAndSize(CFSTR("Skia-Regular"), 0);
    CTFontSymbolicTraits dataDefaultSymbolic = 0;
    double dataDefaultWeight = 0, dataDefaultWidth = 0;
    traitsOf(skiaFromData, NULL, 0, &dataDefaultSymbolic, &dataDefaultWeight, &dataDefaultWidth);
    for (size_t i = 0; i < sizeof requests / sizeof requests[0]; i++) {
        CTFontSymbolicTraits symbolic = 0;
        double weight = 0, width = 0;
        traitsOf(skiaInstalled, requests[i], 2, &symbolic, &weight, &width);
        if (symbolic != installedAnswers[i].symbolic || fabs(weight - installedAnswers[i].weight) > 0.005
            || fabs(width - installedAnswers[i].width) > 0.005) {
            printf("FAIL: (f) installed Skia at wght %.1f wdth %.1f answers symbolic traits %#x, weight %.2f, width %.2f\n",
                requests[i][0], requests[i][1], symbolic, weight, width);
            failures++;
        }
        traitsOf(skiaFromData, requests[i], 2, &symbolic, &weight, &width);
        if (symbolic != dataDefaultSymbolic || weight != dataDefaultWeight || width != dataDefaultWidth) {
            printf("FAIL: (f) Skia from its bytes at wght %.1f wdth %.1f answers symbolic traits %#x, weight %.2f, width %.2f\n",
                requests[i][0], requests[i][1], symbolic, weight, width);
            failures++;
        }
    }
    check(registerFile(argv[1], true), "(f) Inter registers for this process");
    const double bold[] = { 700 };
    CTFontSymbolicTraits interBold = 0;
    double interWeight = 0, interWidth = 0;
    traitsOf(installedInter, bold, 1, &interBold, &interWeight, &interWidth);
    if (interBold != kCTFontTraitBold) {
        printf("FAIL: (f) installed Inter at wght 700 answers symbolic traits %#x\n", interBold);
        failures++;
    }
    registerFile(argv[1], false);
    // (g)
    {
        static const char *const faces[] = { "Skia-Regular_Black", "Skia-Regular", "Skia-Regular_Bold" };
        const double black[] = { 3.2, 1 };
        CTFontSymbolicTraits first = 0;
        double firstWeight = 0;
        for (size_t i = 0; i < 5; i++) {
            CTFontSymbolicTraits symbolic = 0;
            double weight = 0, width = 0;
            CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, faces[i < 3 ? i : i - 3], kCFStringEncodingUTF8);
            if (i < 3) {
                CTFontDescriptorRef named = CTFontDescriptorCreateWithNameAndSize(name, 0);
                traitsOf(named, black, 2, &symbolic, &weight, &width);
                CFRelease(named);
            } else
                copyTraitsOf(name, black, 2, 40, &symbolic, &weight);
            CFRelease(name);
            if (!i) {
                first = symbolic;
                firstWeight = weight;
            } else if (symbolic != first || fabs(weight - firstWeight) > 0.005) {
                printf("FAIL: (g) %s %s at (3.2, 1) answers symbolic traits %#x weight %.2f, Black's descriptor %#x %.2f\n",
                    i < 3 ? "descriptor of" : "copy of", faces[i < 3 ? i : i - 3], symbolic, weight, first, firstWeight);
                failures++;
            }
        }
        CTFontSymbolicTraits symbolic = 0;
        double weight = -1;
        copyTraitsOf(CFSTR("Skia-Regular_Black"), NULL, 0, 0, &symbolic, &weight);
        CTFontSymbolicTraits copySymbolic = 0;
        double copyWeight = -1;
        copyTraitsOf(CFSTR("Skia-Regular_Black"), NULL, 0, 20, &copySymbolic, &copyWeight);
        if (symbolic != 0x80000000 || weight != 0 || copySymbolic != 0x80000000 || copyWeight != 0) {
            printf("FAIL: (g) Black by name answers %#x weight %.2f, its copy at size 20 %#x weight %.2f\n",
                symbolic, weight, copySymbolic, copyWeight);
            failures++;
        }
    }

    CFTypeRef skiaReleases[] = { skia, skiaFromData, skiaInstalled };
    for (size_t i = 0; i < sizeof skiaReleases / sizeof skiaReleases[0]; i++) {
        if (skiaReleases[i])
            CFRelease(skiaReleases[i]);
    }

    CFTypeRef releases[] = { inter, interWithoutStat, installedInter, interFromData, amstelvar, installedAmstelvar, amstelvarFromData,
        interURL, faces, interData, interDataDescriptor, ahem, pair };
    for (size_t i = 0; i < sizeof releases / sizeof releases[0]; i++) {
        if (releases[i])
            CFRelease(releases[i]);
    }
    if (failures) {
        printf("### CoreText installed variable fonts: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText installed variable fonts: an installed variable face draws from a static cut of its file\n");
    return 0;
}
