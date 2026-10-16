// UTType answers wk_declared_types.h's types: from the table alone for a type 10.9's LaunchServices has no
// declaration for (public.heic), and from LaunchServices' declaration plus the table's MIME type for one
// LaunchServices declares without a MIME type (the OpenType and TrueType fonts). A type LaunchServices declares
// answers every tag class its declaration carries.
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static int failures;

static void check(BOOL ok, const char *what)
{
    if (ok)
        return;
    printf("  FAIL: %s\n", what);
    ++failures;
}

static BOOL tagIs(NSDictionary *tags, NSString *tagClass, NSString *value)
{
    NSArray *values = [tags objectForKey:tagClass];
    return [values isKindOfClass:[NSArray class]] && [values containsObject:value];
}

int main(void)
{
    @autoreleasepool {
        NSDictionary *otf = [UTType typeWithIdentifier:@"public.opentype-font"].tags;
        printf("  public.opentype-font tags: %s\n", [[otf description] UTF8String]);
        check(tagIs(otf, @"public.filename-extension", @"otf"), "the OpenType font keeps LaunchServices' otf extension");
        check(tagIs(otf, @"public.mime-type", @"font/otf"), "the OpenType font carries font/otf");
        check(tagIs(otf, @"com.apple.ostype", @"OTTO"), "the OpenType font keeps its OSType tag");

        // Every tag class of a declaration, a single string as a one-element array.
        NSDictionary *png = [UTType typeWithIdentifier:@"public.png"].tags;
        check(tagIs(png, @"com.apple.nspboard-type", @"Apple PNG pasteboard type"), "public.png carries its pasteboard type");
        check(tagIs(png, @"public.mime-type", @"image/png"), "public.png carries image/png");
        NSDictionary *rtf = [UTType typeWithIdentifier:@"public.rtf"].tags;
        check(tagIs(rtf, @"com.apple.nspboard-type", @"NSRTFPboardType"), "public.rtf carries every pasteboard type");

        NSDictionary *ttf = [UTType typeWithIdentifier:@"public.truetype-ttf-font"].tags;
        check(tagIs(ttf, @"public.filename-extension", @"ttf"), "the TrueType font keeps LaunchServices' ttf extension");
        check(tagIs(ttf, @"public.mime-type", @"font/ttf"), "the TrueType font carries font/ttf");

        UTType *byExtension = [UTType typeWithFilenameExtension:@"otf"];
        check([byExtension.identifier isEqualToString:@"public.opentype-font"], "otf names public.opentype-font");
        check([byExtension.preferredMIMEType isEqualToString:@"font/otf"], "public.opentype-font prefers font/otf");

        NSDictionary *heic = [UTType typeWithIdentifier:@"public.heic"].tags;
        check(tagIs(heic, @"public.filename-extension", @"heic") && tagIs(heic, @"public.mime-type", @"image/heic"),
            "public.heic answers from the table");
    }
    if (failures)
        return 1;
    printf("  declared types: ok\n");
    return 0;
}
