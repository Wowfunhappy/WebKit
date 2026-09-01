// CTFontDescriptorGetOptions and CTFontIsSystemUIFont (polyfills/c/CoreText.c). 10.9 stores a
// descriptor's options and exposes the one that matters through CTFontDescriptorIsSystemUIFont, so
// both polyfills read that bit.
//
// The option is what the descriptor was created with, NOT a property of the names it carries. The
// discriminator below is a pair of descriptors built from identical attributes that differ only in
// the option argument: any implementation deriving the answer from the family or PostScript name
// reports the same value for both and is wrong. That pair is exactly the round trip WebKit performs,
// FontPlatformDataCoreText.cpp:289 -> IPC -> :554.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdio.h>

enum { kSystemUIFont = (1 << 1) };

extern uint32_t CTFontDescriptorGetOptions(CTFontDescriptorRef);
extern bool CTFontIsSystemUIFont(CTFontRef);
extern CTFontDescriptorRef CTFontDescriptorCreateWithAttributesAndOptions(CFDictionaryRef, uint32_t);

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static CFDictionaryRef attributesNaming(CFStringRef family)
{
    CFStringRef keys[1] = { kCTFontFamilyNameAttribute };
    CFTypeRef values[1] = { family };
    return CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys, values, 1,
                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

int main(void)
{
    CTFontRef system = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 13.0, NULL);
    CTFontDescriptorRef systemDescriptor = system ? CTFontCopyFontDescriptor(system) : NULL;
    check(systemDescriptor != NULL, "a descriptor copies off the system UI font");
    check(CTFontDescriptorGetOptions(systemDescriptor) == kSystemUIFont,
          "the system UI font's descriptor reports kCTFontDescriptorOptionSystemUIFont");
    check(CTFontIsSystemUIFont(system), "the system UI font answers the predicate");

    CFStringRef family = (CFStringRef)CTFontDescriptorCopyAttribute(systemDescriptor, kCTFontFamilyNameAttribute);
    CFDictionaryRef systemAttributes = attributesNaming(family);

    // The discriminator: identical attributes, differing only in the option.
    CTFontDescriptorRef named = CTFontDescriptorCreateWithAttributesAndOptions(systemAttributes, kSystemUIFont);
    CTFontDescriptorRef unnamed = CTFontDescriptorCreateWithAttributesAndOptions(systemAttributes, 0);
    check(CTFontDescriptorGetOptions(named) == kSystemUIFont,
          "the option named at creation is reported");
    check(CTFontDescriptorGetOptions(unnamed) == 0,
          "the SAME attributes without the option report none -- the option is not a function of the name");

    // It survives realization and the copy back.
    CTFontRef realized = CTFontCreateWithFontDescriptor(named, 13.0, NULL);
    CTFontDescriptorRef back = realized ? CTFontCopyFontDescriptor(realized) : NULL;
    check(CTFontDescriptorGetOptions(back) == kSystemUIFont,
          "the option survives realization and the descriptor copied back off the font");
    check(CTFontIsSystemUIFont(realized), "the realized font answers the predicate");

    // A font asked for by the system UI family's own name is not the system UI font.
    CTFontRef byName = family ? CTFontCreateWithName(family, 13.0, NULL) : NULL;
    check(byName && !CTFontIsSystemUIFont(byName),
          "a font requested by the system UI family name is not the system UI font");

    // An ordinary face, and a copy of the system font at another size.
    CTFontRef helvetica = CTFontCreateWithName(CFSTR("Helvetica"), 13.0, NULL);
    check(helvetica && !CTFontIsSystemUIFont(helvetica), "an ordinary face is not the system UI font");
    CTFontRef resized = CTFontCreateCopyWithAttributes(system, 30.0, NULL, NULL);
    check(resized && CTFontIsSystemUIFont(resized), "a resized copy of the system UI font still is one");

    // The system-ui cascade. SystemFontDatabaseCoreText::createFontByApplyingWeightWidthItalicsAnd
    // FallbackBehavior asks for the system font with a weight/width/slant traits descriptor, by
    // CTFontCreateCopyWithAttributes when it has a font to copy and CTFontCreateWithFontDescriptor
    // when it does not. Stock 10.9 keeps the option across both; so must this layer, or every
    // -apple-system font stops answering the predicate that decides system-font tracking and how
    // the font serializes.
    for (size_t i = 0; i < 3; i++) {
        CGFloat weight = i == 1 ? 0.4 : 0.0;
        float slant = i == 2 ? 0.07f : 0.0f;
        CGFloat width = 0.0;
        CFNumberRef weightNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &weight);
        CFNumberRef widthNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &width);
        CFNumberRef slantNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &slant);
        CFTypeRef traitKeys[] = { kCTFontWeightTrait, kCTFontWidthTrait, kCTFontSlantTrait };
        CFTypeRef traitValues[] = { weightNumber, widthNumber, slantNumber };
        CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault, traitKeys, traitValues, 3,
                                                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFTypeRef modKeys[] = { kCTFontTraitsAttribute };
        CFTypeRef modValues[] = { traits };
        CFDictionaryRef modAttributes = CFDictionaryCreate(kCFAllocatorDefault, modKeys, modValues, 1,
                                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef modification = CTFontDescriptorCreateWithAttributes(modAttributes);

        // (a) the copy route, which is what WebKit takes when it has the system font in hand.
        CTFontRef applied = CTFontCreateCopyWithAttributes(system, 13.0, NULL, modification);
        CTFontDescriptorRef appliedDescriptor = applied ? CTFontCopyFontDescriptor(applied) : NULL;
        check(CTFontDescriptorGetOptions(appliedDescriptor) == kSystemUIFont,
              "the system-ui cascade keeps the option through CTFontCreateCopyWithAttributes");
        check(applied && CTFontIsSystemUIFont(applied),
              "the weight/slant-applied system font still answers the predicate");

        // Carrying the option must not cost the face selection this layer exists to provide: stock
        // 10.9 answers the base face for every weight, and picking the bold one is the real work.
        if (i == 1) {
            CFStringRef appliedName = applied ? CTFontCopyPostScriptName(applied) : NULL;
            check(appliedName && CFStringFind(appliedName, CFSTR("Bold"), 0).location != kCFNotFound,
                  "weight .4 still selects the bold face");
            if (appliedName)
                CFRelease(appliedName);
        }

        // (b) the descriptor route, through wk_realizableDescriptor's rebuild.
        CFMutableDictionaryRef named = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, systemAttributes);
        CFDictionarySetValue(named, kCTFontTraitsAttribute, traits);
        CTFontDescriptorRef namedWithTraits = CTFontDescriptorCreateWithAttributesAndOptions(named, kSystemUIFont);
        CTFontRef realizedWithTraits = CTFontCreateWithFontDescriptor(namedWithTraits, 13.0, NULL);
        CTFontDescriptorRef realizedDescriptor = realizedWithTraits ? CTFontCopyFontDescriptor(realizedWithTraits) : NULL;
        check(CTFontDescriptorGetOptions(realizedDescriptor) == kSystemUIFont,
              "a traits-carrying system descriptor keeps the option through realization");

        if (realizedDescriptor) CFRelease(realizedDescriptor);
        if (realizedWithTraits) CFRelease(realizedWithTraits);
        if (namedWithTraits) CFRelease(namedWithTraits);
        CFRelease(named);
        if (appliedDescriptor) CFRelease(appliedDescriptor);
        if (applied) CFRelease(applied);
        CFRelease(modification);
        CFRelease(modAttributes);
        CFRelease(traits);
        CFRelease(slantNumber); CFRelease(widthNumber); CFRelease(weightNumber);
    }

    check(CTFontDescriptorGetOptions(NULL) == 0, "a null descriptor reports none");
    check(!CTFontIsSystemUIFont(NULL), "a null font is not the system UI font");

    if (resized) CFRelease(resized);
    if (helvetica) CFRelease(helvetica);
    if (byName) CFRelease(byName);
    if (back) CFRelease(back);
    if (realized) CFRelease(realized);
    if (unnamed) CFRelease(unnamed);
    if (named) CFRelease(named);
    if (systemAttributes) CFRelease(systemAttributes);
    if (family) CFRelease(family);
    if (systemDescriptor) CFRelease(systemDescriptor);
    if (system) CFRelease(system);

    if (!failures)
        printf("descriptor options: the real option bit, not derived from the font's name\n");
    return failures ? 1 : 0;
}
