// Weight and width selection over a family (polyfills/c/CoreText.c). 10.9's matcher reads
// kCTFontWeightTrait and kCTFontWidthTrait in an attributes descriptor as filters it cannot satisfy
// and hands back the source face unchanged, so CTFontCreateCopyWithAttributes makes the choice itself.
//
// Both halves of "what did the caller ask for" have to read the attributes the descriptor CARRIES,
// because matching answers for every descriptor: kCTFontNameAttribute comes back as the default
// face's name, and kCTFontTraitsAttribute as a full traits dictionary with a weight and a width in
// it. Read either through CTFontDescriptorCopyAttribute and a copy whose attributes hold no traits
// at all -- the shape UnrealizedCoreTextFont::realize uses on every font WebKit realizes -- either
// skips selection entirely or runs it at weight 0.0 and drops every bold face back to its regular.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdio.h>
#include <string.h>

extern const CGFloat kCTFontWeightRegular;
extern const CGFloat kCTFontWeightBold;

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static void postScriptName(CTFontRef font, char *out, size_t size)
{
    strncpy(out, "(null)", size);
    out[size - 1] = 0;
    if (!font)
        return;
    CFStringRef name = CTFontCopyPostScriptName(font);
    if (name) {
        CFStringGetCString(name, out, size, kCFStringEncodingUTF8);
        CFRelease(name);
    }
}

static CTFontRef copyWithAttributes(CTFontRef font, CFDictionaryRef attributes)
{
    CTFontDescriptorRef modification = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontRef copy = modification ? CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), NULL, modification) : NULL;
    if (modification)
        CFRelease(modification);
    return copy;
}

// A copy asking for `weight` on CoreText's normalized scale, optionally naming a face outright.
static CTFontRef copyAtWeight(CTFontRef font, CGFloat weight, CFStringRef namedFace)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &weight);
    CFTypeRef traitKeys[] = { kCTFontWeightTrait };
    CFTypeRef traitValues[] = { number };
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, traitKeys, traitValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCTFontTraitsAttribute, traits);
    if (namedFace)
        CFDictionarySetValue(attributes, kCTFontNameAttribute, namedFace);
    CTFontRef copy = copyWithAttributes(font, attributes);
    CFRelease(attributes);
    CFRelease(traits);
    CFRelease(number);
    return copy;
}

// The attribute sets WebKit realizes a font through that ask for no face at all: an empty
// modification, and the feature-settings-and-variations shape UnrealizedCoreTextFont builds. Neither
// names a weight, so neither may move the source off its own face.
static CFDictionaryRef emptyAttributes(void)
{
    return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static CFDictionaryRef featureSettingsAttributes(void)
{
    CFTypeRef featureKeys[] = { kCTFontFeatureTypeIdentifierKey, kCTFontFeatureSelectorIdentifierKey };
    int type = 1, selector = 0;
    CFNumberRef typeNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &type);
    CFNumberRef selectorNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &selector);
    CFTypeRef featureValues[] = { typeNumber, selectorNumber };
    CFDictionaryRef feature = CFDictionaryCreate(kCFAllocatorDefault, featureKeys, featureValues, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef features = CFArrayCreate(kCFAllocatorDefault, (const void **)&feature, 1, &kCFTypeArrayCallBacks);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCTFontFeatureSettingsAttribute, features);
    CFRelease(features);
    CFRelease(feature);
    CFRelease(selectorNumber);
    CFRelease(typeNumber);
    return attributes;
}

// A copy asking for no face keeps the source's, whatever weight that face is.
static void checkFaceSurvivesAttributesNamingNoFace(CTFontRef font, const char *label)
{
    if (!font) {
        char missing[160];
        snprintf(missing, sizeof missing, "%s realizes", label);
        check(0, missing);
        return;
    }
    char sourceName[128], name[128], what[200];
    postScriptName(font, sourceName, sizeof sourceName);

    struct { const char *shape; CFDictionaryRef (*build)(void); } shapes[] = {
        { "empty attributes", emptyAttributes },
        { "feature-settings attributes", featureSettingsAttributes },
    };
    for (unsigned i = 0; i < sizeof(shapes) / sizeof(shapes[0]); ++i) {
        CFDictionaryRef attributes = shapes[i].build();
        CTFontRef copy = copyWithAttributes(font, attributes);
        postScriptName(copy, name, sizeof name);
        snprintf(what, sizeof what, "%s: %s keep the face (%s, wanted %s)", label, shapes[i].shape, name, sourceName);
        check(!strcmp(name, sourceName), what);
        if (copy)
            CFRelease(copy);
        CFRelease(attributes);
    }
}

int main(void)
{
    char name[128];

    // An enumerable family: the bold member is a candidate the family's own enumeration offers.
    CTFontRef helvetica = CTFontCreateWithName(CFSTR("Helvetica"), 19.8, NULL);
    check(helvetica != NULL, "Helvetica realizes");
    if (helvetica) {
        CTFontRef bold = copyAtWeight(helvetica, kCTFontWeightBold, NULL);
        postScriptName(bold, name, sizeof name);
        check(!strcmp(name, "Helvetica-Bold"), "a bold weight over Helvetica selects Helvetica-Bold");
        if (bold)
            CFRelease(bold);

        CTFontRef regular = copyAtWeight(helvetica, kCTFontWeightRegular, NULL);
        postScriptName(regular, name, sizeof name);
        check(!strcmp(name, "Helvetica"), "a regular weight over Helvetica stays on Helvetica");
        if (regular)
            CFRelease(regular);

        // A named face is the caller's choice, whatever weight sits beside it.
        CTFontRef named = copyAtWeight(helvetica, kCTFontWeightBold, CFSTR("Helvetica-Light"));
        postScriptName(named, name, sizeof name);
        check(!strcmp(name, "Helvetica-Light"), "a named face wins over a weight beside it");
        if (named)
            CFRelease(named);
        CFRelease(helvetica);
    }

    // The system UI family, which this host will not enumerate: its members are reachable through the
    // bold symbolic trait, and a bold request has to land on the heavier one.
    CTFontRef system = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 19.8, NULL);
    check(system != NULL, "the system UI font realizes");
    if (system) {
        char regularName[128];
        postScriptName(system, regularName, sizeof regularName);

        CTFontRef bold = copyAtWeight(system, kCTFontWeightBold, NULL);
        postScriptName(bold, name, sizeof name);
        check(bold && (CTFontGetSymbolicTraits(bold) & kCTFontTraitBold) != 0,
              "a bold weight over the system UI font selects a bold face");
        check(strcmp(name, regularName) != 0, "the bold system face is not the regular one");
        if (bold)
            CFRelease(bold);

        CTFontRef regular = copyAtWeight(system, kCTFontWeightRegular, NULL);
        postScriptName(regular, name, sizeof name);
        check(!strcmp(name, regularName), "a regular weight over the system UI font stays on it");
        if (regular)
            CFRelease(regular);
        CFRelease(system);
    }

    // Bold faces asked for nothing stay bold. These are the sources a page's every bold run realizes
    // from, across enumerable families and the system UI family alike.
    const CFStringRef boldFaces[] = {
        CFSTR("Helvetica-Bold"), CFSTR("HelveticaNeue-Bold"), CFSTR("Georgia-Bold"),
        CFSTR("Menlo-Bold"), CFSTR("AvenirNext-DemiBold"),
    };
    for (unsigned i = 0; i < sizeof(boldFaces) / sizeof(boldFaces[0]); ++i) {
        CTFontRef font = CTFontCreateWithName(boldFaces[i], 19.8, NULL);
        char label[128];
        CFStringGetCString(boldFaces[i], label, sizeof label, kCFStringEncodingUTF8);
        checkFaceSurvivesAttributesNamingNoFace(font, label);
        if (font)
            CFRelease(font);
    }
    CTFontRef emphasized = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, 19.8, NULL);
    checkFaceSurvivesAttributesNamingNoFace(emphasized, "the emphasized system UI font");
    if (emphasized)
        CFRelease(emphasized);

    if (failures) {
        printf("### CoreText face selection: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText face selection: weight requests choose a face, and nothing else moves one\n");
    return 0;
}
