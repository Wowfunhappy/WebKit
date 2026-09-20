// CTFontDescriptorCreateMatchingFontDescriptors and CTFontDescriptorCreateMatchingFontDescriptor
// (polyfills/c/CoreText.c): a descriptor with kCTFontUserInstalledAttribute false, matched with that
// attribute mandatory, matches only the faces of families a stock macOS Tahoe installation provides
// (polyfills/c/wk_font_catalog.c), and a Tahoe family this system has no face of matches its stand-in.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>

// The layer supplies this on 10.9.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
extern const CFStringRef kCTFontUserInstalledAttribute;
#pragma clang diagnostic pop

static int failures;

static void check(bool ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", what);
        ++failures;
    }
}

static CTFontDescriptorRef createFamilyDescriptor(CFStringRef family, bool systemFontsOnly, CFSetRef *mandatory)
{
    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attributes, kCTFontFamilyNameAttribute, family);
    *mandatory = NULL;
    if (systemFontsOnly) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        CFDictionarySetValue(attributes, kCTFontUserInstalledAttribute, kCFBooleanFalse);
        const void *keys[] = { kCTFontFamilyNameAttribute, kCTFontUserInstalledAttribute };
#pragma clang diagnostic pop
        *mandatory = CFSetCreate(NULL, keys, 2, &kCFTypeSetCallBacks);
    }
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    CFRelease(attributes);
    return descriptor;
}

static CFIndex matchCount(CFStringRef family, bool systemFontsOnly)
{
    CFSetRef mandatory;
    CTFontDescriptorRef descriptor = createFamilyDescriptor(family, systemFontsOnly, &mandatory);
    CFArrayRef matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatory);
    CFIndex count = matches ? CFArrayGetCount(matches) : 0;
    if (matches)
        CFRelease(matches);
    if (mandatory)
        CFRelease(mandatory);
    CFRelease(descriptor);
    return count;
}

static bool singleMatch(CFStringRef family, bool systemFontsOnly)
{
    CFSetRef mandatory;
    CTFontDescriptorRef descriptor = createFamilyDescriptor(family, systemFontsOnly, &mandatory);
    CTFontDescriptorRef match = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatory);
    bool found = match != NULL;
    if (match)
        CFRelease(match);
    if (mandatory)
        CFRelease(mandatory);
    CFRelease(descriptor);
    return found;
}

extern CTFontRef CTFontCreateForCharactersWithLanguageAndOption(CTFontRef, const UniChar *, CFIndex, CFStringRef, unsigned long, CFIndex *);
extern const CFStringRef kCTFontFallbackOptionAttribute;
typedef const UniChar *(*TextProvider)(CFIndex, CFIndex *, CFDictionaryRef *, void *);
extern CTLineRef CTLineCreateWithUniCharProvider(TextProvider, void (*)(const UniChar *, void *), void *);
extern CTTypesetterRef CTTypesetterCreateWithUniCharProviderAndOptions(TextProvider, void (*)(const UniChar *, void *), void *, CFDictionaryRef);

typedef struct {
    const UniChar *characters;
    CFIndex length;
    CFDictionaryRef attributes;
} ShapingText;

static const UniChar *provideShapingText(CFIndex index, CFIndex *count, CFDictionaryRef *attributes, void *context)
{
    ShapingText *text = context;
    if (index < 0 || index >= text->length) {
        *count = 0;
        return NULL;
    }
    *count = text->length - index;
    *attributes = text->attributes;
    return text->characters + index;
}

static void checkShapingFallback(CTFontRef base, bool allowUserFonts, int route)
{
    int option = allowUserFonts ? 3 : 1;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &option);
    const void *keys[] = { kCTFontFallbackOptionAttribute };
    const void *values[] = { number };
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(options);
    CTFontRef font = CTFontCreateCopyWithAttributes(base, 16, NULL, descriptor);
    check((bool)CFEqual(font, base) == allowUserFonts, "font equality distinguishes the fallback policy");
    CFTypeRef reported = CTFontCopyAttribute(font, kCTFontFallbackOptionAttribute);
    check(reported && CFEqual(reported, number), "the realized font reports its fallback policy");
    if (reported) CFRelease(reported);
    CTFontDescriptorRef roundTrip = CTFontCopyFontDescriptor(font);
    reported = CTFontDescriptorCopyAttribute(roundTrip, kCTFontFallbackOptionAttribute);
    check(reported && CFEqual(reported, number), "the font descriptor preserves the fallback policy");
    if (reported) CFRelease(reported);
    CFRelease(roundTrip);
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, (const void **)&kCTFontAttributeName, (const void **)&font, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const UniChar characters[] = { 'A', 0xD980, 0xDC0B, 'B' };
    ShapingText text = { characters, 4, attributes };
    CTLineRef line = NULL;
    if (!route) {
        CFStringRef string = CFStringCreateWithCharacters(NULL, characters, 4);
        CFAttributedStringRef attributed = CFAttributedStringCreate(NULL, string, attributes);
        line = CTLineCreateWithAttributedString(attributed);
        CFRelease(attributed);
        CFRelease(string);
    } else if (route == 1)
        line = CTLineCreateWithUniCharProvider(provideShapingText, NULL, &text);
    else {
        int level = route - 2;
        CFNumberRef levelNumber = CFNumberCreate(NULL, kCFNumberIntType, &level);
        CFDictionaryRef typesetterOptions = CFDictionaryCreate(NULL, (const void **)&kCTTypesetterOptionForcedEmbeddingLevel,
            (const void **)&levelNumber, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTTypesetterRef typesetter = CTTypesetterCreateWithUniCharProviderAndOptions(provideShapingText, NULL, &text, typesetterOptions);
        if (typesetter) {
            line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 0));
            CFRelease(typesetter);
        }
        CFRelease(typesetterOptions);
        CFRelease(levelNumber);
    }
    check(line != NULL, "restricted and unrestricted text can be shaped");
    bool usedRegisteredFont = false, usedMissingGlyph = false, keptPrimaryFont = false;
    CFArrayRef runs = line ? CTLineGetGlyphRuns(line) : NULL;
    for (CFIndex i = 0; runs && i < CFArrayGetCount(runs); ++i) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, i);
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFStringRef name = CTFontCopyPostScriptName(runFont);
        usedRegisteredFont |= CFEqual(name, CFSTR("Ahem3"));
        keptPrimaryFont |= CFEqual(name, CFSTR("Times-Roman"));
        CFRelease(name);
        CFIndex count = CTRunGetGlyphCount(run);
        CGGlyph *glyphs = malloc((size_t)count * sizeof(CGGlyph));
        CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
        for (CFIndex j = 0; j < count; ++j)
            usedMissingGlyph |= !glyphs[j];
        free(glyphs);
    }
    printf("shaping route %d allow-user=%d registered=%d missing=%d primary=%d\n", route, allowUserFonts, usedRegisteredFont, usedMissingGlyph, keptPrimaryFont);
    check(usedRegisteredFont == allowUserFonts, "shaping respects the user-installed fallback option");
    check(usedMissingGlyph != allowUserFonts, "restricted supplementary character has a missing glyph");
    check(keptPrimaryFont, "covered characters retain their primary font");
    if (line) CFRelease(line);
    CFRelease(attributes); CFRelease(font); CFRelease(descriptor); CFRelease(options); CFRelease(number);
}

static void checkExtendedFallback(const char *path)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    check(CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, NULL), "the extended-character font registers");
    CTFontRef font = CTFontCreateWithName(CFSTR("Times-Roman"), 16, NULL);
    const UniChar characters[] = { 0xD980, 0xDC0B };
    CFIndex covered = 0;
    CTFontRef allowed = CTFontCreateForCharactersWithLanguageAndOption(font, characters, 2, NULL, 3, &covered);
    check(allowed && covered == 2, "unrestricted fallback covers the registered supplementary character");
    CTFontRef restricted = CTFontCreateForCharactersWithLanguageAndOption(font, characters, 2, NULL, 1, &covered);
    check(!restricted && !covered, "system-only fallback does not use the registered font or a missing glyph");
    for (int route = 0; route < 4; ++route) {
        checkShapingFallback(font, true, route);
        checkShapingFallback(font, false, route);
    }
    if (restricted) CFRelease(restricted);
    if (allowed) CFRelease(allowed);
    CFRelease(font);
    CTFontManagerUnregisterFontsForURL(url, kCTFontManagerScopeProcess, NULL);
    CFRelease(url);
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <Ahem.ttf> <FakeHelvetica-SingleExtendedCharacter.ttf>\n", argv[0]);
        return 2;
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), false);
    check(CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, NULL), "Ahem registers for this process");
    CFRelease(url);

    check(matchCount(CFSTR("Ahem"), false) == 1, "Ahem matches when user-installed fonts are allowed");
    check(matchCount(CFSTR("Ahem"), true) == 0, "Ahem does not match when only shipped fonts may");
    check(singleMatch(CFSTR("Ahem"), false), "the single-match form finds Ahem when user-installed fonts are allowed");
    check(!singleMatch(CFSTR("Ahem"), true), "the single-match form finds no Ahem when only shipped fonts may");
    check(matchCount(CFSTR("Helvetica"), true) >= 4, "Helvetica keeps its shipped faces when only shipped fonts may match");
    check(matchCount(CFSTR("Lucida Grande"), true) >= 2, "Lucida Grande matches when only shipped fonts may");
    check(matchCount(CFSTR("Skia"), false) >= 1, "Skia, which this OS ships, matches when user-installed fonts are allowed");
    check(matchCount(CFSTR("Skia"), true) == 0, "Skia, which Tahoe does not install, does not match when only shipped fonts may");
    check(matchCount(CFSTR("hiragino sans"), true) == matchCount(CFSTR("Hiragino Kaku Gothic ProN"), true)
        && matchCount(CFSTR("Hiragino Kaku Gothic ProN"), true) > 0, "Hiragino Sans matches as its stand-in, Hiragino Kaku Gothic ProN");
    check(matchCount(CFSTR("Rockwell"), false) == matchCount(CFSTR("Superclarendon"), false), "Rockwell matches as its stand-in, Superclarendon");
    check(matchCount(CFSTR("Noto Sans Cuneiform"), false) == 0, "a Tahoe family without Latin letters has no stand-in");
    CTFontRef lastResort = CTFontCreateWithName(CFSTR("LastResort"), 12, NULL);
    CFStringRef lastResortName = lastResort ? CTFontCopyPostScriptName(lastResort) : NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
    CFTypeRef lastResortUserInstalled = lastResort ? CTFontCopyAttribute(lastResort, kCTFontUserInstalledAttribute) : NULL;
#pragma clang diagnostic pop
    check(lastResortName && CFEqual(lastResortName, CFSTR("LastResort")) && lastResortUserInstalled == kCFBooleanFalse,
        "the LastResort face is the system's");
    if (lastResortUserInstalled) CFRelease(lastResortUserInstalled);
    if (lastResortName) CFRelease(lastResortName);
    if (lastResort) CFRelease(lastResort);
    check(singleMatch(CFSTR("Helvetica"), true), "the single-match form finds Helvetica when only shipped fonts may");

    CFSetRef mandatory;
    CTFontDescriptorRef family = createFamilyDescriptor(CFSTR("Avenir Next"), true, &mandatory);
    int italic = kCTFontItalicTrait;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &italic);
    const void *traitKeys[] = { kCTFontSymbolicTrait };
    const void *traitValues[] = { number };
    CFDictionaryRef traits = CFDictionaryCreate(NULL, traitKeys, traitValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { kCTFontTraitsAttribute };
    const void *values[] = { traits };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef request = CTFontDescriptorCreateCopyWithAttributes(family, attributes);
    CTFontDescriptorRef match = CTFontDescriptorCreateMatchingFontDescriptor(request, mandatory);
    CFStringRef name = match ? CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) : NULL;
    check(name && CFEqual(name, CFSTR("AvenirNext-Italic")), "Avenir Next italic preserves the OS single best match");
    if (name) CFRelease(name);
    if (match) CFRelease(match);
    CFRelease(request); CFRelease(attributes); CFRelease(traits); CFRelease(number); CFRelease(family); CFRelease(mandatory);

    // A font installed for all users whose family Tahoe does not provide is the user's.
    char installed[] = "/Library/Fonts/wk-provenance-test-XXXXXX.ttf";
    int fd = mkstemps(installed, 4);
    check(fd >= 0, "create the temporary all-users font file");
    if (fd >= 0) {
        FILE *source = fopen(argv[1], "rb");
        check(source != NULL, "open the source font");
        unsigned char buffer[8192];
        size_t length;
        while (source && (length = fread(buffer, 1, sizeof(buffer), source)))
            check(write(fd, buffer, length) == (ssize_t)length, "write the all-users font file");
        if (source) fclose(source);
        close(fd);
        CFURLRef installedURL = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)installed, strlen(installed), false);
        CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL(installedURL);
        const void *urlKeys[] = { kCTFontURLAttribute };
        const void *urlValues[] = { installedURL };
        CFDictionaryRef urlAttributes = CFDictionaryCreate(NULL, urlKeys, urlValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef installedDescriptor = descriptors && CFArrayGetCount(descriptors)
            ? CTFontDescriptorCreateCopyWithAttributes(CFArrayGetValueAtIndex(descriptors, 0), urlAttributes) : NULL;
        CTFontRef installedFont = installedDescriptor ? CTFontCreateWithFontDescriptor(installedDescriptor, 12, NULL) : NULL;
        CFTypeRef actualURL = installedFont ? CTFontCopyAttribute(installedFont, kCTFontURLAttribute) : NULL;
        check(actualURL && CFEqual(actualURL, installedURL), "the classifier reads the all-users copy's URL");
        if (actualURL) CFRelease(actualURL);
        if (installedDescriptor) CFRelease(installedDescriptor);
        CFRelease(urlAttributes);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
        CFTypeRef userInstalled = installedFont ? CTFontCopyAttribute(installedFont, kCTFontUserInstalledAttribute) : NULL;
#pragma clang diagnostic pop
        check(userInstalled == kCFBooleanTrue, "a font in /Library/Fonts whose family Tahoe does not provide is user-installed");
        if (userInstalled) CFRelease(userInstalled);
        if (installedFont) CFRelease(installedFont);
        if (descriptors) CFRelease(descriptors);
        CFRelease(installedURL);
        unlink(installed);
    }

    checkExtendedFallback(argv[2]);

    if (failures)
        return 1;
    printf("user installed matching: all cases match\n");
    return 0;
}
