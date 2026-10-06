// A Content-Disposition field whose characters are one per byte names its file from the UTF-8 reading of
// those bytes when they form UTF-8, and from the characters as they stand otherwise.
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
    }
    if (failures)
        return 1;
    printf("  suggested filename: ok\n");
    return 0;
}
