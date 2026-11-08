// UTType answers wk_declared_types.h's types: from the table alone for a type 10.9's LaunchServices has no
// declaration for (public.heic), and from LaunchServices' declaration plus the table's MIME type for one
// LaunchServices declares without a MIME type (the OpenType and TrueType fonts). A type LaunchServices declares
// answers every tag class its declaration carries. A type is declared when LaunchServices knows a bundle that
// declares it, including one whose declaration it cannot read back (public.cd-media); one no bundle declares
// is not. A type's tags and parent types come from LaunchServices' database, which knows public.cd-media's
// parent although its declaration does not answer.
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@interface UTType (WKDeclaredTypesProbeSPI)
- (NSOrderedSet *)_parentTypes;
@end

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
        check(tagIs(png, @"com.apple.ostype", @"PNGf"), "public.png carries its OSType");
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

        check([UTType typeWithIdentifier:@"public.cd-media"].isDeclared, "public.cd-media, which a bundle declares, is declared");
        check(UTTypeIsDeclared(CFSTR("public.cd-media")), "and UTTypeIsDeclared agrees");
        check(UTTypeIsDeclared(CFSTR("public.png")) && [UTType typeWithIdentifier:@"public.png"].isDeclared, "public.png is declared");
        check(![UTType typeWithIdentifier:@"org.aquawebkit.undeclared-probe"] && !UTTypeIsDeclared(CFSTR("org.aquawebkit.undeclared-probe")),
            "a type no bundle declares is not");
        NSOrderedSet *mediaParents = [[UTType typeWithIdentifier:@"public.cd-media"] _parentTypes];
        check(mediaParents.count == 1 && [[[mediaParents firstObject] identifier] isEqualToString:@"public.cd-based-media"],
            "public.cd-media's parent is public.cd-based-media");
        NSOrderedSet *cssParents = [[UTType typeWithIdentifier:@"public.css"] _parentTypes];
        check([[cssParents valueForKey:@"identifier"] containsObject:@"public.text"], "public.css's parents include public.text");
    }
    if (failures)
        return 1;
    printf("  declared types: ok\n");
    return 0;
}
