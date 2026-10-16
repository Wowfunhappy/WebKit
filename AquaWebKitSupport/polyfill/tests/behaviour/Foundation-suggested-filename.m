// A Content-Disposition field whose characters are one per byte names its file from the UTF-8 reading of
// those bytes when they form UTF-8, and from the characters as they stand otherwise. A response that names
// no file (a blob: URL, no field) is "Unknown" with its MIME type's extension, wk_declared_types.h's types
// included; every other name is 10.9's own.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>

@interface NSURLResponse (SuggestedFilenameTest)
- (void)_setMIMEType:(NSString *)MIMEType;
@end

static int failures;

static NSString *bytesAsLatin1(const char *bytes)
{
    return [[[NSString alloc] initWithBytes:bytes length:strlen(bytes) encoding:NSISOLatin1StringEncoding] autorelease];
}

static void expect(NSString *field, NSString *MIMEType, NSString *expected, const char *what)
{
    NSDictionary *headers = field ? @{ @"Content-Disposition": field } : @{ };
    NSHTTPURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://127.0.0.1:8000/download/resources/literal-utf-8.py"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:headers] autorelease];
    if (MIMEType)
        [response _setMIMEType:MIMEType];
    NSString *actual = [response suggestedFilename];
    if ([actual isEqualToString:expected])
        return;
    printf("  FAIL: %s: expected \"%s\", got \"%s\"\n", what, [expected UTF8String], [actual UTF8String]);
    ++failures;
}

// A response whose URL names no file -- a blob: URL -- is named "Unknown" with its MIME type's extension.
static void expectUnnamed(NSString *MIMEType, NSString *expected, const char *what)
{
    NSURLResponse *response = [[[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"blob:http://127.0.0.1:8000/5ae2e5d0-0000-4000-8000-000000000000"] MIMEType:MIMEType expectedContentLength:-1 textEncodingName:nil] autorelease];
    NSString *actual = [response suggestedFilename];
    if ([actual isEqualToString:expected])
        return;
    printf("  FAIL: %s: expected \"%s\", got \"%s\"\n", what, [expected UTF8String], [actual UTF8String]);
    ++failures;
}

int main(void)
{
    @autoreleasepool {
        NSString *cyrillic = @"SUССЕSS.txt";
        expect(bytesAsLatin1("attachment; filename=SU\xd0\xa1\xd0\xa1\xd0\x95SS.txt"), nil, cyrillic, "UTF-8 bytes");
        expect(bytesAsLatin1("attachment; filename=\"SU\xd0\xa1\xd0\xa1\xd0\x95SS.txt\""), @"text/plain", cyrillic, "quoted UTF-8 bytes");
        expect(@"attachment; filename=SUССЕSS.txt", nil, cyrillic, "a field already holding the characters");
        expect(@"attachment; filename*=UTF-8''SU%D0%A1%D0%A1%D0%95SS.txt", nil, cyrillic, "RFC 5987 UTF-8");
        expect(@"attachment; filename*=ISO-8859-1''%C3%A9.txt", nil, [@"Ã©.txt" decomposedStringWithCanonicalMapping], "RFC 5987 ISO-8859-1 is not reread");
        expect(bytesAsLatin1("attachment; filename=SU\xf3\xf3\xe5SS.txt"), nil, [@"SUóóåSS.txt" decomposedStringWithCanonicalMapping], "bytes that are not UTF-8");
        expect(bytesAsLatin1("attachment; filename=a\xc0\xaf.txt"), nil, [@"aÀ¯.txt" decomposedStringWithCanonicalMapping], "an overlong UTF-8 form is not UTF-8");
        expect(@"attachment; filename=test file.txt", nil, @"test file.txt", "ASCII");
        expect(nil, @"text/html", @"literal-utf-8.py.html", "no field");
        expectUnnamed(@"font/otf", @"Unknown.otf", "a declared font type's extension");
        expectUnnamed(@"font/ttf", @"Unknown.ttf", "a declared font type's extension");
        expectUnnamed(@"image/png", @"Unknown.png", "LaunchServices' own extension");
        expect(@"attachment; filename=Makefile", @"application/octet-stream", @"Makefile", "a Content-Disposition name takes no octet-stream extension");
        expect(@"attachment; filename=README", @"text/plain", @"README.txt", "a Content-Disposition name keeps 10.9's own extension");
        NSURLResponse *license = [[[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"file:///tmp/LICENSE"] MIMEType:@"application/octet-stream" expectedContentLength:-1 textEncodingName:nil] autorelease];
        if (![[license suggestedFilename] isEqualToString:@"LICENSE"]) {
            printf("  FAIL: a file URL's name: expected \"LICENSE\", got \"%s\"\n", [[license suggestedFilename] UTF8String]);
            ++failures;
        }
        Class mappingsClass = NSClassFromString(@"NSURLFileTypeMappings");
        id mappings = [mappingsClass performSelector:@selector(sharedMappings)];
        NSString *otf = [mappings performSelector:@selector(MIMETypeForExtension:) withObject:@"otf"];
        NSString *ttf = [mappings performSelector:@selector(MIMETypeForExtension:) withObject:@"ttf"];
        if (![otf isEqualToString:@"font/otf"] || ![ttf isEqualToString:@"font/ttf"]) {
            printf("  FAIL: font MIME types: otf=%s ttf=%s\n", [otf UTF8String], [ttf UTF8String]);
            ++failures;
        }
    }
    if (failures)
        return 1;
    printf("  suggested filename: ok\n");
    return 0;
}
