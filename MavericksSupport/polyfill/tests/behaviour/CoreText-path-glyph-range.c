// The CTFontCreatePathForGlyph replacement (polyfills/c/CoreText.c) on a glyph ID the font does not
// have. WebCore measures and draws deletedGlyph (0xFFFF) through this function; on a colour-bitmap
// font 10.9's own definition indexes the sbix strike offsets with that ID and dereferences what it
// reads there, and on Apple Color Emoji that faults. The archive's definition returns NULL for it, as
// 10.9 does for an outline font, and still hands out the real outline of a glyph the font has.
//
// The probe links libpolyfill.a the way WebKit does, so its reference binds the archive's definition;
// the first check establishes that before any call reaches CoreText.
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

static const char *kFontPath = "/System/Library/Fonts/Apple Color Emoji.ttf";

typedef CGPathRef (*PathForGlyphFn)(CTFontRef, CGGlyph, const CGAffineTransform *);

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static PathForGlyphFn systemPathForGlyph(void)
{
    const struct mach_header *image = NSAddImage("/System/Library/Frameworks/CoreText.framework/Versions/A/CoreText",
        NSADDIMAGE_OPTION_RETURN_ON_ERROR);
    NSSymbol found = image ? NSLookupSymbolInImage(image, "_CTFontCreatePathForGlyph", NSLOOKUPSYMBOLINIMAGE_OPTION_RETURN_ON_ERROR) : 0;
    return found ? (PathForGlyphFn)NSAddressOfSymbol(found) : 0;
}

static CTFontRef fontAtPath(const char *path, CGFloat size)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFArrayRef descriptors = url ? CTFontManagerCreateFontDescriptorsFromURL(url) : NULL;
    CTFontRef font = (descriptors && CFArrayGetCount(descriptors))
        ? CTFontCreateWithFontDescriptor((CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0), size, NULL)
        : NULL;
    if (descriptors)
        CFRelease(descriptors);
    if (url)
        CFRelease(url);
    return font;
}

int main(void)
{
    PathForGlyphFn system = systemPathForGlyph();
    check(system != NULL, "10.9's CoreText exports CTFontCreatePathForGlyph");
    PathForGlyphFn bound = CTFontCreatePathForGlyph;
    check(system && bound != system, "the probe's CTFontCreatePathForGlyph is the archive's definition");
    if (failures)
        return 1;

    CTFontRef emoji = fontAtPath(kFontPath, 16);
    check(emoji != NULL, "Apple Color Emoji.ttf opens");
    CTFontRef outline = CTFontCreateWithName(CFSTR("Helvetica"), 16, NULL);
    check(outline != NULL, "Helvetica opens");
    if (!emoji || !outline)
        return 1;

    CFIndex emojiGlyphs = CTFontGetGlyphCount(emoji);
    CGGlyph outOfRange[] = { 0xFFFF, 0xFFFE, (CGGlyph)emojiGlyphs };
    for (size_t i = 0; i < sizeof outOfRange / sizeof outOfRange[0]; ++i) {
        char what[96];
        snprintf(what, sizeof what, "emoji glyph 0x%04x (font has %ld) has no path", outOfRange[i], (long)emojiGlyphs);
        CGPathRef path = CTFontCreatePathForGlyph(emoji, outOfRange[i], NULL);
        check(path == NULL, what);
        if (path)
            CFRelease(path);
    }

    // Glyph 0 is the emoji font's outlined .notdef: the archive's path is 10.9's path.
    CGPathRef ours = CTFontCreatePathForGlyph(emoji, 0, NULL);
    CGPathRef theirs = system(emoji, 0, NULL);
    check(ours && !CGRectIsEmpty(CGPathGetPathBoundingBox(ours)), "emoji glyph 0 has a non-empty outline");
    check(ours && theirs && CGRectEqualToRect(CGPathGetPathBoundingBox(ours), CGPathGetPathBoundingBox(theirs)),
        "emoji glyph 0's outline matches 10.9's");
    if (ours)
        CFRelease(ours);
    if (theirs)
        CFRelease(theirs);

    const UniChar character = 'a';
    CGGlyph glyph = 0;
    check(CTFontGetGlyphsForCharacters(outline, &character, &glyph, 1), "Helvetica maps 'a'");
    CGAffineTransform shift = CGAffineTransformMakeTranslation(10, 20);
    ours = CTFontCreatePathForGlyph(outline, glyph, &shift);
    theirs = system(outline, glyph, &shift);
    check(ours && theirs && !CGRectIsEmpty(CGPathGetPathBoundingBox(ours))
        && CGRectEqualToRect(CGPathGetPathBoundingBox(ours), CGPathGetPathBoundingBox(theirs)),
        "Helvetica 'a' under a transform matches 10.9's outline");
    if (ours)
        CFRelease(ours);
    if (theirs)
        CFRelease(theirs);
    CGPathRef beyond = CTFontCreatePathForGlyph(outline, 0xFFFF, NULL);
    check(beyond == NULL, "Helvetica glyph 0xffff has no path");

    CFRelease(emoji);
    CFRelease(outline);
    if (failures) {
        printf("CoreText-path-glyph-range: %d FAILED\n", failures);
        return 1;
    }
    printf("CoreText-path-glyph-range: ok\n");
    return 0;
}
