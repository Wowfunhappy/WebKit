// -[NSURLResponse initWithCoder:] under requiresSecureCoding (methods/FoundationCoding.m). A response archived
// by a plain archiver -- its fields in the unkeyed sequence -- decodes with every field, as a plain
// unarchiver reads it. A field of a class the secure reading does not allow fails the decode, as does a
// version 7 archive, and a secure archiver's response still decodes.
#import <Foundation/Foundation.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"
extern CFTypeRef _CFKeyedArchiverUIDCreate(CFAllocatorRef, uint32_t);
extern uint32_t _CFKeyedArchiverUIDGetValue(CFTypeRef);
extern CFTypeID _CFKeyedArchiverUIDGetTypeID(void);

static int failures;
static void check(BOOL ok, const char *name)
{
    printf("  %s: %s\n", name, ok ? "ok" : "FAIL");
    failures += !ok;
}

static NSData *archive(id object, BOOL secure)
{
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:data] autorelease];
    archiver.requiresSecureCoding = secure;
    [archiver encodeObject:object forKey:@"response"];
    [archiver encodeObject:[NSUUID UUID] forKey:@"other"];
    [archiver finishEncoding];
    return data;
}

static id secureDecode(NSData *data)
{
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error] autorelease];
    unarchiver.decodingFailurePolicy = NSDecodingFailurePolicyRaiseException;
    id result = nil;
    @try {
        result = [unarchiver decodeObjectOfClass:NSURLResponse.class forKey:@"response"];
    } @catch (NSException *exception) {
        result = nil;
    }
    return result;
}

static NSMutableDictionary *propertyList(NSData *data)
{
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:NULL];
}

static NSData *serialize(NSDictionary *plist)
{
    return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

static id uid(uint32_t value)
{
    return [(id)_CFKeyedArchiverUIDCreate(NULL, value) autorelease];
}

static NSUInteger indexOfObject(NSArray *objects, id value)
{
    for (NSUInteger i = 0; i < objects.count; ++i) {
        if ([objects[i] isEqual:value])
            return i;
    }
    return NSNotFound;
}

int main(void)
{
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:@"https://example.test/page.html"];
        NSURLResponse *plainResponse = [[[NSURLResponse alloc] initWithURL:url MIMEType:@"text/html" expectedContentLength:1234 textEncodingName:@"utf-8"] autorelease];
        NSHTTPURLResponse *httpResponse = [[[NSHTTPURLResponse alloc] initWithURL:url statusCode:404 HTTPVersion:@"HTTP/1.1"
            headerFields:@{ @"Content-Type": @"text/plain; charset=iso-8859-1", @"X-Test": @"value" }] autorelease];

        NSData *plainArchive = archive(plainResponse, NO);
        check([[propertyList(plainArchive) description] rangeOfString:@"__nsurlrequest_proto_prop_obj_0"].location == NSNotFound
            && [[propertyList(archive(plainResponse, YES)) description] rangeOfString:@"__nsurlrequest_proto_prop_obj_0"].location != NSNotFound,
            "a plain archiver writes the unkeyed field sequence, a secure one the keyed fields");

        NSURLResponse *decoded = secureDecode(plainArchive);
        check([decoded isMemberOfClass:NSURLResponse.class] && [decoded.URL isEqual:url] && [decoded.MIMEType isEqual:@"text/html"]
            && decoded.expectedContentLength == 1234 && [decoded.textEncodingName isEqual:@"utf-8"],
            "a plain archive's response decodes under secure coding with every field");

        NSHTTPURLResponse *decodedHTTP = secureDecode(archive(httpResponse, NO));
        check([decodedHTTP isKindOfClass:NSHTTPURLResponse.class] && decodedHTTP.statusCode == 404
            && [decodedHTTP.allHeaderFields[@"X-Test"] isEqual:@"value"] && [decodedHTTP.textEncodingName isEqual:@"iso-8859-1"],
            "a plain archive's HTTP response decodes under secure coding with status and header fields");

        NSHTTPURLResponse *secureHTTP = secureDecode(archive(httpResponse, YES));
        check([secureHTTP isKindOfClass:NSHTTPURLResponse.class] && secureHTTP.statusCode == 404 && [secureHTTP.URL isEqual:url],
            "a secure archive's HTTP response decodes");

        NSMutableDictionary *tampered = propertyList(plainArchive);
        NSMutableArray *objects = tampered[@"$objects"];
        NSUInteger mime = indexOfObject(objects, @"text/html");
        id otherUID = tampered[@"$top"][@"other"];
        BOOL rewired = NO;
        for (id object in objects) {
            if (![object isKindOfClass:NSMutableDictionary.class])
                continue;
            for (NSString *key in [object allKeys]) {
                id value = object[key];
                if (CFGetTypeID((CFTypeRef)value) == _CFKeyedArchiverUIDGetTypeID() && _CFKeyedArchiverUIDGetValue((CFTypeRef)value) == mime) {
                    object[key] = otherUID;
                    rewired = YES;
                }
            }
        }
        check(rewired && mime != NSNotFound && !secureDecode(serialize(tampered)),
            "a field of a class the secure reading does not allow fails the decode");

        NSMutableDictionary *version7 = [NSMutableDictionary dictionaryWithDictionary:@{
            @"$archiver": @"NSKeyedArchiver",
            @"$version": @100000,
            @"$top": @{ @"response": uid(1) },
            @"$objects": @[
                @"$null",
                @{ @"$class": uid(5), @"$0": @7, @"$1": uid(2), @"$2": uid(4), @"$3": uid(0), @"$4": @77, @"$5": @0.0 },
                @{ @"$class": uid(3), @"NS.base": uid(0), @"NS.relative": uid(6) },
                @{ @"$classname": @"NSURL", @"$classes": @[ @"NSURL", @"NSObject" ] },
                @"image/png",
                @{ @"$classname": @"NSURLResponse", @"$classes": @[ @"NSURLResponse", @"NSObject" ] },
                @"https://example.test/old.html",
            ],
        }];
        NSURLResponse *old = secureDecode(serialize(version7));
        check(!old, "a version 7 archive's response does not decode under secure coding");
    }
    printf("Foundation-url-response-coding: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
