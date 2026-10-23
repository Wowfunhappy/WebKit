// CTFontDescriptorCopyAttribute(kCTFontTraitsAttribute) on an installed face (polyfills/c/CoreText.c).
// The descriptor answers the symbolic traits the realized font answers through CTFontGetSymbolicTraits:
// 10.9's registry traits with the italic the face's OS/2 or head table declares and the color glyphs a
// COLR table provides. The descriptor reads those tables from the face's file, so every installed face
// is compared, including the faces of collections (.ttc) and suitcases (.dfont).
//
// Seravek-MediumItalic is the face 10.9's registry reports upright although its fsSelection is italic.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <stdio.h>
#include <string.h>

static int failures;

// The descriptor's symbolic traits, or false when it answers none.
static int descriptorSymbolic(CTFontDescriptorRef descriptor, uint32_t *symbolic)
{
    CFDictionaryRef traits = (CFDictionaryRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute);
    CFNumberRef number = traits ? (CFNumberRef)CFDictionaryGetValue(traits, kCTFontSymbolicTrait) : NULL;
    int64_t value = 0;
    int found = number && CFNumberGetValue(number, kCFNumberSInt64Type, &value);
    *symbolic = (uint32_t)value;
    if (traits)
        CFRelease(traits);
    return found;
}

int main(void)
{
    CTFontCollectionRef collection = CTFontCollectionCreateFromAvailableFonts(NULL);
    CFArrayRef descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection);
    CFIndex count = descriptors ? CFArrayGetCount(descriptors) : 0;
    int sawSeravekItalic = 0;
    for (CFIndex i = 0; i < count; i++) {
        CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, i);
        uint32_t fromDescriptor;
        int answered = descriptorSymbolic(descriptor, &fromDescriptor);
        CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 12, NULL);
        uint32_t fromFont = font ? CTFontGetSymbolicTraits(font) : 0;
        CFStringRef name = font ? CTFontCopyPostScriptName(font) : NULL;
        char nameBytes[256] = "?";
        if (name)
            CFStringGetCString(name, nameBytes, sizeof(nameBytes), kCFStringEncodingUTF8);
        if (!answered || fromDescriptor != fromFont) {
            printf("FAIL: %s descriptor symbolic %#x, realized font %#x\n", nameBytes, fromDescriptor, fromFont);
            failures++;
        }
        if (!strcmp(nameBytes, "Seravek-MediumItalic")) {
            sawSeravekItalic = 1;
            if (!answered || !(fromDescriptor & kCTFontTraitItalic)) {
                printf("FAIL: Seravek-MediumItalic's descriptor is not italic\n");
                failures++;
            }
        }
        if (name)
            CFRelease(name);
        if (font)
            CFRelease(font);
    }
    if (!count) {
        printf("FAIL: no installed faces\n");
        failures++;
    }
    if (!sawSeravekItalic)
        printf("note: Seravek-MediumItalic is not installed here\n");
    if (descriptors)
        CFRelease(descriptors);
    if (collection)
        CFRelease(collection);
    if (!failures)
        printf("descriptor traits: %ld installed faces answer their realized font's symbolic traits\n", (long)count);
    return failures ? 1 : 0;
}
