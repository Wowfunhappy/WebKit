// kCTFontUserInstalledAttribute (polyfills/c/CoreText.c). The attribute answers whether a font was
// installed onto this system rather than shipped with it. 10.9's CoreText has no such attribute, so
// the answer comes from the font's own URL. This OS ships faces in /System/Library/Fonts and in
// /Library/Fonts alike; a font built from data carries no URL at all, having never been installed
// from a file.
//
// The probe links libpolyfill.a the way WebKit does, so the functions it calls are the archive's.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdbool.h>
#include <stdio.h>

extern const CFStringRef kCTFontUserInstalledAttribute;

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static int userInstalled(CTFontRef font)
{
    CFTypeRef value = font ? CTFontCopyAttribute(font, kCTFontUserInstalledAttribute) : NULL;
    if (!value)
        return -1;
    int answer = value == (CFTypeRef)kCFBooleanTrue ? 1 : (value == (CFTypeRef)kCFBooleanFalse ? 0 : -1);
    CFRelease(value);
    return answer;
}

static CTFontRef fontFromFontData(const char *path, CGFloat size)
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
    CTFontRef font = descriptor ? CTFontCreateWithFontDescriptor(descriptor, size, NULL) : NULL;
    if (descriptor)
        CFRelease(descriptor);
    return font;
}

int main(void)
{
    const CGFloat size = 20;

    CTFontRef systemFace = CTFontCreateWithName(CFSTR("Menlo-Regular"), size, NULL);
    check(systemFace != NULL, "Menlo realizes");
    check(userInstalled(systemFace) == 0, "a face under /System/Library/Fonts is not user-installed");
    if (systemFace)
        CFRelease(systemFace);

    // /Library/Fonts is the OS's other font directory here -- Andale Mono is one of the 231 faces
    // 10.9 installs into it, and upstream's determinePitch special-cases another of them, Osaka-Mono.
    CTFontRef libraryFace = CTFontCreateWithName(CFSTR("AndaleMono"), size, NULL);
    check(libraryFace != NULL, "Andale Mono realizes");
    check(userInstalled(libraryFace) == 0, "a face under /Library/Fonts is not user-installed");
    if (libraryFace)
        CFRelease(libraryFace);

    CTFontRef fromData = fontFromFontData("/System/Library/Fonts/Symbol.ttf", size);
    check(fromData != NULL, "a font built from font data realizes");
    check(userInstalled(fromData) == 1, "a font built from font data is user-installed");
    if (fromData)
        CFRelease(fromData);

    if (failures) {
        printf("### CoreText font provenance: %d failure(s)\n", failures);
        return 1;
    }
    printf("CoreText font provenance: user-installed follows the font's own URL\n");
    return 0;
}
