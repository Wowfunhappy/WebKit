// CTFontDescriptorCreateForCSSFamily (polyfills/c/CoreText.c): a generic family names the font 10.9's own
// fallback table (DefaultFontFallbacks.plist in the CoreText bundle) gives the language, and its base font
// for every other language. WebCore reads the answer's family name.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <string.h>

// The layer supplies these on 10.9.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
extern CTFontDescriptorRef CTFontDescriptorCreateForCSSFamily(CFStringRef cssFamily, CFStringRef language);
extern const CFStringRef kCTFontCSSFamilySerif;
extern const CFStringRef kCTFontCSSFamilySansSerif;
extern const CFStringRef kCTFontCSSFamilyMonospace;
extern const CFStringRef kCTFontCSSFamilyCursive;
extern const CFStringRef kCTFontCSSFamilyFantasy;
#pragma clang diagnostic pop

static int failures;

static void familyName(CTFontDescriptorRef descriptor, char *buffer, size_t size)
{
    buffer[0] = 0;
    CFStringRef family = descriptor ? (CFStringRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) : NULL;
    if (family) {
        CFStringGetCString(family, buffer, (CFIndex)size, kCFStringEncodingUTF8);
        CFRelease(family);
    }
}

static void expectFont(const char *what, CFStringRef cssFamily, CFStringRef language, CFStringRef postScriptName)
{
    CTFontDescriptorRef answer = CTFontDescriptorCreateForCSSFamily(cssFamily, language);
    CTFontDescriptorRef expected = CTFontDescriptorCreateWithNameAndSize(postScriptName, 0);
    char got[128], want[128];
    familyName(answer, got, sizeof(got));
    familyName(expected, want, sizeof(want));
    if (!want[0] || strcmp(got, want)) {
        fprintf(stderr, "FAIL %s: family \"%s\", expected \"%s\"\n", what, got, want);
        ++failures;
    }
    if (answer)
        CFRelease(answer);
    if (expected)
        CFRelease(expected);
}

int main(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    CFStringRef serif = kCTFontCSSFamilySerif, sansSerif = kCTFontCSSFamilySansSerif;
    CFStringRef monospace = kCTFontCSSFamilyMonospace, cursive = kCTFontCSSFamilyCursive;
#pragma clang diagnostic pop

    expectFont("serif, en", serif, CFSTR("en"), CFSTR("Times-Roman"));
    expectFont("serif, no language", serif, NULL, CFSTR("Times-Roman"));
    expectFont("sans-serif, en-US", sansSerif, CFSTR("en-US"), CFSTR("Helvetica"));
    expectFont("serif, ja", serif, CFSTR("ja"), CFSTR("HiraMinProN-W3"));
    expectFont("sans-serif, ja-JP", sansSerif, CFSTR("ja-JP"), CFSTR("HiraKakuProN-W3"));
    expectFont("serif, zh-Hans", serif, CFSTR("zh-Hans"), CFSTR("STSongti-SC-Regular"));
    expectFont("serif, zh", serif, CFSTR("zh"), CFSTR("STSongti-SC-Regular"));
    expectFont("serif, zh-CN", serif, CFSTR("zh-CN"), CFSTR("STSongti-SC-Regular"));
    expectFont("serif, zh-Hant", serif, CFSTR("zh-Hant"), CFSTR("STSongti-TC-Regular"));
    expectFont("serif, zh-TW", serif, CFSTR("zh-TW"), CFSTR("STSongti-TC-Regular"));
    expectFont("sans-serif, zh-HK", sansSerif, CFSTR("zh-HK"), CFSTR("STHeitiTC-Light"));
    expectFont("sans-serif, zh_MO", sansSerif, CFSTR("zh_MO"), CFSTR("STHeitiTC-Light"));
    expectFont("sans-serif, zh-Hans-HK", sansSerif, CFSTR("zh-Hans-HK"), CFSTR("STHeitiSC-Light"));
    expectFont("serif, ko", serif, CFSTR("ko"), CFSTR("AppleMyungjo"));
    expectFont("sans-serif, ko-KR", sansSerif, CFSTR("ko-KR"), CFSTR("AppleSDGothicNeo-Regular"));
    expectFont("monospace, ja", monospace, CFSTR("ja"), CFSTR("HiraKakuProN-W3"));
    expectFont("cursive, zh-TW", cursive, CFSTR("zh-TW"), CFSTR("STKaiTi-TC-Regular"));
    expectFont("cursive, fr", cursive, CFSTR("fr"), CFSTR("Apple-Chancery"));
    expectFont("serif, jav (no entry)", serif, CFSTR("jav"), CFSTR("Times-Roman"));

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    expectFont("fantasy, zh-Hant", kCTFontCSSFamilyFantasy, CFSTR("zh-Hant"), CFSTR("DFKaiShu-SB-Estd-BF"));
#pragma clang diagnostic pop
    CTFontRef chancery = CTFontCreateWithName(CFSTR("Apple-Chancery"), 16, NULL);
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(chancery);
    CFDictionaryRef dictionaries[] = { CTFontCopyTraits(chancery),
        (CFDictionaryRef)CTFontCopyAttribute(chancery, kCTFontTraitsAttribute),
        (CFDictionaryRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) };
    if (!(CTFontGetSymbolicTraits(chancery) & kCTFontTraitItalic)) {
        fprintf(stderr, "FAIL Apple Chancery loses its native italic trait\n");
        ++failures;
    }
    for (unsigned i = 0; i < 3; ++i) {
        int bits = 0;
        CFNumberRef value = dictionaries[i] ? CFDictionaryGetValue(dictionaries[i], kCTFontSymbolicTrait) : NULL;
        if (!value || !CFNumberGetValue(value, kCFNumberIntType, &bits) || !(bits & kCTFontTraitItalic)) {
            fprintf(stderr, "FAIL Apple Chancery traits dictionary %u is inconsistent\n", i);
            ++failures;
        }
        if (dictionaries[i]) CFRelease(dictionaries[i]);
    }
    CFRelease(descriptor); CFRelease(chancery);
    CTFontRef italic = CTFontCreateWithName(CFSTR("AvenirNext-Italic"), 16, NULL);
    if (!(CTFontGetSymbolicTraits(italic) & kCTFontTraitItalic)) {
        fprintf(stderr, "FAIL a styled italic face loses its italic trait\n");
        ++failures;
    }
    CFRelease(italic);

    if (failures)
        return 1;
    printf("css family language: all cases match\n");
    return 0;
}
