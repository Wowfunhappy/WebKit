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

extern const CFStringRef kCTFontUIFontDesignTrait;
extern const CFStringRef kCTFontUIFontDesignDefault;
extern const CFStringRef kCTFontUIFontDesignMonospaced;
extern const CGFloat kCTFontWeightThin;
extern const CGFloat kCTFontWeightLight;
extern const CGFloat kCTFontWeightRegular;
extern const CGFloat kCTFontWeightMedium;
extern const CGFloat kCTFontWeightSemibold;
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

// The descriptor SystemFontDatabaseCoreText::createFontByApplyingWeightWidthItalicsAndFallbackBehavior
// writes: a traits dictionary carrying a weight, a width, a slant and the UI design token, over the
// family or face the caller names, or over nothing at all -- which is the ui-serif / ui-monospace /
// ui-rounded shape, since createSystemDesignFont has no font to copy from. 10.9 fails the whole match
// on any of the three trait values it cannot satisfy and falls back to the system UI font, family name
// and all, so every one of these shapes goes through the layer's own selection.
static CTFontRef fontFromUpstreamDescriptor(CGFloat weight, CGFloat width, bool italic, CFStringRef design,
                                            CFStringRef family, CFStringRef face)
{
    const float slantValue = italic ? 0.07f : 0.0f;
    CFNumberRef weightNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &weight);
    CFNumberRef widthNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &width);
    CFNumberRef slantNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &slantValue);
    CFTypeRef traitKeys[] = { kCTFontWeightTrait, kCTFontWidthTrait, kCTFontSlantTrait, kCTFontUIFontDesignTrait };
    CFTypeRef traitValues[] = { weightNumber, widthNumber, slantNumber, design };
    CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, traitKeys, traitValues, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCTFontTraitsAttribute, traits);
    if (family)
        CFDictionarySetValue(attributes, kCTFontFamilyNameAttribute, family);
    if (face)
        CFDictionarySetValue(attributes, kCTFontNameAttribute, face);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, 19.8, NULL) : NULL;
    if (descriptor)
        CFRelease(descriptor);
    CFRelease(attributes);
    CFRelease(traits);
    CFRelease(slantNumber);
    CFRelease(widthNumber);
    CFRelease(weightNumber);
    return font;
}

static void familyName(CTFontRef font, char *out, size_t size)
{
    strncpy(out, "(null)", size);
    out[size - 1] = 0;
    if (!font)
        return;
    CFStringRef name = CTFontCopyFamilyName(font);
    if (name) {
        CFStringGetCString(name, out, size, kCFStringEncodingUTF8);
        CFRelease(name);
    }
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

// Every weight a family answers, checked against the face CSS font matching names for it: the
// searched side of the request first (lighter at or below 500, heavier above), nearest on that side.
typedef struct { CGFloat weight; const char *face; } wk_weight_expectation;

static void checkWeights(CFStringRef family, const wk_weight_expectation *expectations, unsigned count)
{
    char familyLabel[128];
    CFStringGetCString(family, familyLabel, sizeof familyLabel, kCFStringEncodingUTF8);
    CTFontRef font = CTFontCreateWithName(family, 19.8, NULL);
    char what[256];
    snprintf(what, sizeof what, "%s realizes", familyLabel);
    check(font != NULL, what);
    if (!font)
        return;
    for (unsigned i = 0; i < count; ++i) {
        CTFontRef selected = copyAtWeight(font, expectations[i].weight, NULL);
        char name[128];
        postScriptName(selected, name, sizeof name);
        snprintf(what, sizeof what, "weight %.2f over %s selects %s (got %s)",
                 (double)expectations[i].weight, familyLabel, expectations[i].face, name);
        check(!strcmp(name, expectations[i].face), what);
        if (selected)
            CFRelease(selected);
    }
    CFRelease(font);
}

int main(void)
{
    char name[128];

    // A family with faces on both sides of regular, and one with a face at every landmark this port
    // can be asked for: the weights that have to reach a lighter face and the weights that have to
    // reach a heavier one, over the same enumeration.
    const wk_weight_expectation helveticaWeights[] = {
        { kCTFontWeightLight, "Helvetica-Light" },
        { kCTFontWeightRegular, "Helvetica" },
        { kCTFontWeightMedium, "Helvetica" },
        { kCTFontWeightSemibold, "Helvetica-Bold" },
        { kCTFontWeightBold, "Helvetica-Bold" },
    };
    checkWeights(CFSTR("Helvetica"), helveticaWeights, sizeof helveticaWeights / sizeof helveticaWeights[0]);

    const wk_weight_expectation helveticaNeueWeights[] = {
        { kCTFontWeightThin, "HelveticaNeue-Thin" },
        { kCTFontWeightLight, "HelveticaNeue-Light" },
        { kCTFontWeightRegular, "HelveticaNeue" },
        { kCTFontWeightMedium, "HelveticaNeue-Medium" },
        { kCTFontWeightSemibold, "HelveticaNeue-Bold" },
        { kCTFontWeightBold, "HelveticaNeue-Bold" },
    };
    checkWeights(CFSTR("Helvetica Neue"), helveticaNeueWeights, sizeof helveticaNeueWeights / sizeof helveticaNeueWeights[0]);

    // A named face is the caller's choice, whatever weight sits beside it.
    CTFontRef helvetica = CTFontCreateWithName(CFSTR("Helvetica"), 19.8, NULL);
    if (helvetica) {
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

        CTFontRef medium = copyAtWeight(system, kCTFontWeightMedium, NULL);
        postScriptName(medium, name, sizeof name);
        check(!strcmp(name, regularName), "a medium weight over the system UI font stays on it");
        if (medium)
            CFRelease(medium);

        CTFontRef semibold = copyAtWeight(system, kCTFontWeightSemibold, NULL);
        postScriptName(semibold, name, sizeof name);
        check(semibold && (CTFontGetSymbolicTraits(semibold) & kCTFontTraitBold) != 0,
              "a semibold weight over the system UI font selects a bold face");
        if (semibold)
            CFRelease(semibold);
        CFRelease(system);
    }

    // The descriptor route over a family: the weight, the slant, and the two together have to reach a
    // face of the family the descriptor names, not the system UI font 10.9 falls back to.
    struct { CGFloat weight; bool italic; const char *face; } neueDescriptors[] = {
        { kCTFontWeightRegular, false, "HelveticaNeue" },
        { kCTFontWeightMedium, false, "HelveticaNeue-Medium" },
        { kCTFontWeightBold, false, "HelveticaNeue-Bold" },
        { kCTFontWeightRegular, true, "HelveticaNeue-Italic" },
        { kCTFontWeightBold, true, "HelveticaNeue-BoldItalic" },
    };
    for (unsigned i = 0; i < sizeof(neueDescriptors) / sizeof(neueDescriptors[0]); ++i) {
        CTFontRef font = fontFromUpstreamDescriptor(neueDescriptors[i].weight, 0.0, neueDescriptors[i].italic,
                                                    kCTFontUIFontDesignDefault, CFSTR("Helvetica Neue"), NULL);
        char what[256];
        postScriptName(font, name, sizeof name);
        snprintf(what, sizeof what, "a descriptor over Helvetica Neue at weight %.2f%s realizes %s (got %s)",
                 (double)neueDescriptors[i].weight, neueDescriptors[i].italic ? " italic" : "",
                 neueDescriptors[i].face, name);
        check(!strcmp(name, neueDescriptors[i].face), what);
        if (font)
            CFRelease(font);
    }

    // The same descriptor naming no font at all, which is what ui-serif and ui-rounded realize
    // through: the system UI font, at the face the weight asks for.
    struct { CGFloat weight; int bold; const char *label; } designWeights[] = {
        { kCTFontWeightRegular, 0, "regular" },
        { kCTFontWeightMedium, 0, "medium" },
        { kCTFontWeightSemibold, 1, "semibold" },
        { kCTFontWeightBold, 1, "bold" },
    };
    char systemFamily[128];
    CTFontRef systemUI = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 19.8, NULL);
    familyName(systemUI, systemFamily, sizeof systemFamily);
    if (systemUI)
        CFRelease(systemUI);
    for (unsigned i = 0; i < sizeof(designWeights) / sizeof(designWeights[0]); ++i) {
        CTFontRef font = fontFromUpstreamDescriptor(designWeights[i].weight, 0.0, false,
                                                    kCTFontUIFontDesignDefault, NULL, NULL);
        char what[256], family[128];
        familyName(font, family, sizeof family);
        snprintf(what, sizeof what, "a %s weight on a descriptor naming no font realizes a %s face of %s (got %s)",
                 designWeights[i].label, designWeights[i].bold ? "bold" : "regular", systemFamily, family);
        check(font && !strcmp(family, systemFamily)
              && !!(CTFontGetSymbolicTraits(font) & kCTFontTraitBold) == !!designWeights[i].bold, what);
        if (font)
            CFRelease(font);
    }

    // ui-monospace: the monospaced design token names Menlo, which carries the weight and the slant
    // the same descriptor asks for beside it.
    struct { CGFloat weight; bool italic; const char *face; } monospaced[] = {
        { kCTFontWeightRegular, false, "Menlo-Regular" },
        { kCTFontWeightBold, false, "Menlo-Bold" },
        { kCTFontWeightRegular, true, "Menlo-Italic" },
        { kCTFontWeightBold, true, "Menlo-BoldItalic" },
    };
    for (unsigned i = 0; i < sizeof(monospaced) / sizeof(monospaced[0]); ++i) {
        CTFontRef font = fontFromUpstreamDescriptor(monospaced[i].weight, 0.0, monospaced[i].italic,
                                                    kCTFontUIFontDesignMonospaced, NULL, NULL);
        char what[256];
        postScriptName(font, name, sizeof name);
        snprintf(what, sizeof what, "the monospaced design token at weight %.2f%s realizes %s (got %s)",
                 (double)monospaced[i].weight, monospaced[i].italic ? " italic" : "", monospaced[i].face, name);
        check(!strcmp(name, monospaced[i].face), what);
        check(font && (CTFontGetSymbolicTraits(font) & kCTFontTraitMonoSpace) != 0,
              "the monospaced design token realizes a monospaced face");
        if (font)
            CFRelease(font);
    }

    // A face the descriptor names is the caller's choice here too -- and the face selection this
    // route runs realizes its own answer through this same entry point, so the name has to stop it.
    {
        CTFontRef font = fontFromUpstreamDescriptor(kCTFontWeightBold, 0.0, false,
                                                    kCTFontUIFontDesignDefault, NULL, CFSTR("Helvetica-Light"));
        postScriptName(font, name, sizeof name);
        check(!strcmp(name, "Helvetica-Light"), "a named face on a descriptor wins over the weight beside it");
        if (font)
            CFRelease(font);
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
