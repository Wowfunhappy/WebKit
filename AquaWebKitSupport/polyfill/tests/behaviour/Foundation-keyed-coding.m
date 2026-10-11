#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface NSKeyedUnarchiver (StrictCoding)
+ (id)_strictlyUnarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error;
@end

static int failures;
static unsigned nodeInitializations;
static BOOL zeroAfterFailure;
static BOOL throwProgrammerException;
static NSPropertyListFormat archiveFormat;
static void check(BOOL ok, const char *name)
{
    printf("  %s: %s\n", name, ok ? "ok" : "FAIL");
    failures += !ok;
}

@interface OrdinaryCoding : NSObject <NSCoding>
@end
@implementation OrdinaryCoding
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:@"ordinary" forKey:@"value"]; }
- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init])) return nil;
    if (![[coder decodeObjectForKey:@"value"] isEqual:@"ordinary"]) { [self release]; return nil; }
    return self;
}
@end

// A failing node reads its URL field as the wrong class, then checks what the coder answers afterwards.
@interface CodingNode : NSObject <NSSecureCoding> {
@public
    BOOL fail;
}
@end
@implementation CodingNode
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:fail forKey:@"fail"];
    [coder encodeInt:17 forKey:@"integer"];
    [coder encodeDouble:2.5 forKey:@"double"];
    [coder encodeObject:@"text" forKey:@"text"];
    [coder encodeObject:[NSURL URLWithString:@"https://node.test/"] forKey:@"url"];
    [coder encodeBytes:(const uint8_t *)"abc" length:3 forKey:@"bytes"];
    [coder encodeRect:NSMakeRect(1, 2, 3, 4) forKey:@"rect"];
}
- (id)initWithCoder:(NSCoder *)coder
{
    ++nodeInitializations;
    if (!(self = [super init]))
        return nil;
    if ([coder decodeBoolForKey:@"fail"]) {
        [coder decodeObjectOfClass:NSArray.class forKey:@"url"];
        NSUInteger length = 999;
        const uint8_t *bytes = [coder decodeBytesForKey:@"bytes" returnedLength:&length];
        zeroAfterFailure = ![coder decodeIntForKey:@"integer"] && ![coder decodeDoubleForKey:@"double"]
            && ![coder decodeObjectForKey:@"text"] && !bytes && !length
            && NSEqualRects([coder decodeRectForKey:@"rect"], NSZeroRect);
    }
    if (throwProgrammerException)
        [NSException raise:NSInvalidArgumentException format:@"programmer exception"];
    return self;
}
@end
@interface CodingSubclass : CodingNode
@end
@implementation CodingSubclass
@end

static unsigned laterInitializations;

@interface LaterCoding : NSObject <NSSecureCoding> @end
@implementation LaterCoding
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
- (id)initWithCoder:(NSCoder *)coder { (void)coder; ++laterInitializations; return [super init]; }
@end

@interface NestedDecoderCoding : NSObject <NSSecureCoding> @end
@implementation NestedDecoderCoding
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    CodingNode *node = [[CodingNode new] autorelease];
    node->fail = YES;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:node requiringSecureCoding:YES error:NULL];
    [coder encodeObject:data forKey:@"archive"];
    [coder encodeObject:@"outer value" forKey:@"value"];
}
- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init])) return nil;
    NSData *data = [coder decodeObjectOfClass:NSData.class forKey:@"archive"];
    NSError *error = nil;
    id inner = [NSKeyedUnarchiver unarchivedObjectOfClass:CodingNode.class fromData:data error:&error];
    NSString *outer = [coder decodeObjectOfClass:NSString.class forKey:@"value"];
    check(!inner && error && [outer isEqual:@"outer value"], "nested independent unarchiver keeps its failure separate");
    return self;
}
@end

static NSData *archive(id root, BOOL secure)
{
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *coder = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:data] autorelease];
    coder.outputFormat = archiveFormat;
    coder.requiresSecureCoding = secure;
    [coder encodeObject:root forKey:NSKeyedArchiveRootObjectKey];
    [coder encodeObject:@"good value" forKey:@"good"];
    [coder finishEncoding];
    return data;
}

static NSKeyedUnarchiver *decoder(NSData *data)
{
    NSError *error = nil;
    NSKeyedUnarchiver *coder = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error] autorelease];
    check(coder && !error && coder.requiresSecureCoding && [coder isKindOfClass:NSKeyedUnarchiver.class],
        "modern initializer requires secure coding");
    return coder;
}

static BOOL raises(NSKeyedUnarchiver *coder, Class cls, NSString *key, id *result)
{
    @try {
        *result = [coder decodeObjectOfClass:cls forKey:key];
    } @catch (NSException *exception) {
        (void)exception;
        return YES;
    }
    return NO;
}

// The modern API is WebKit's: a host app in the same process sees 10.9's classes.
static void checkPublicSelectorsAbsent(void)
{
    const char *instanceSelectors[] = { "initForReadingFromData:error:", "setDecodingFailurePolicy:", "decodingFailurePolicy",
        "error", "failWithError:", "_enableStrictSecureDecodingMode", "decodeTopLevelObjectForKey:error:" };
    const char *classSelectors[] = { "unarchivedObjectOfClass:fromData:error:", "unarchivedObjectOfClasses:fromData:error:",
        "_strictlyUnarchivedObjectOfClasses:fromData:error:", "unarchiveTopLevelObjectWithData:error:" };
    BOOL absent = YES;
    for (size_t i = 0; i < sizeof(instanceSelectors) / sizeof(*instanceSelectors); ++i)
        absent &= !class_respondsToSelector(NSKeyedUnarchiver.class, sel_registerName(instanceSelectors[i]));
    for (size_t i = 0; i < sizeof(classSelectors) / sizeof(*classSelectors); ++i)
        absent &= !class_respondsToSelector(object_getClass(NSKeyedUnarchiver.class), sel_registerName(classSelectors[i]));
    absent &= !class_respondsToSelector(NSKeyedArchiver.class, sel_registerName("initRequiringSecureCoding:"));
    absent &= !class_respondsToSelector(NSKeyedArchiver.class, sel_registerName("encodedData"));
    absent &= !class_respondsToSelector(object_getClass(NSKeyedArchiver.class), sel_registerName("archivedDataWithRootObject:requiringSecureCoding:error:"));
    check(absent, "NSKeyedUnarchiver and NSKeyedArchiver answer no public modern selector");
}

int main(void)
{
    for (unsigned format = 0; format < 2; ++format) {
      @autoreleasepool {
        archiveFormat = format ? NSPropertyListXMLFormat_v1_0 : NSPropertyListBinaryFormat_v1_0;
        printf("FORMAT %s\n", format ? "XML" : "binary");
        CodingNode *node = [[CodingNode new] autorelease];
        NSData *valid = archive(node, YES);
        id wrong = nil;
        NSKeyedUnarchiver *classic = [[[NSKeyedUnarchiver alloc] initForReadingWithData:valid] autorelease];
        classic.requiresSecureCoding = YES;
        check(raises(classic, NSURL.class, NSKeyedArchiveRootObjectKey, &wrong), "classic initializer retains exception policy");
        check(object_getClass(classic) == NSKeyedUnarchiver.class, "classic unarchiver keeps its class");

        NSKeyedUnarchiver *coder = decoder(valid);
        check(!raises(coder, NSURL.class, NSKeyedArchiveRootObjectKey, &wrong) && !wrong,
            "return policy converts native class-validation failure");
        check(![coder decodeObjectOfClass:NSString.class forKey:@"good"], "error prevents subsequent object decoding");
        [coder finishDecoding];

        coder = decoder(valid);
        coder.decodingFailurePolicy = NSDecodingFailurePolicyRaiseException;
        check(raises(coder, NSURL.class, NSKeyedArchiveRootObjectKey, &wrong), "exception policy raises");
        [coder finishDecoding];

        classic = [[[NSKeyedUnarchiver alloc] initForReadingWithData:valid] autorelease];
        classic.requiresSecureCoding = YES;
        classic.decodingFailurePolicy = NSDecodingFailurePolicySetErrorAndReturn;
        check(!raises(classic, NSURL.class, NSKeyedArchiveRootObjectKey, &wrong) && !wrong,
            "classic unarchiver set to return errors converts failures");
        [classic finishDecoding];

        node->fail = YES;
        zeroAfterFailure = NO;
        NSError *error = nil;
        check(![NSKeyedUnarchiver unarchivedObjectOfClass:CodingNode.class fromData:archive(node, YES) error:&error] && error,
            "nested failure fails the root with an error");
        check(zeroAfterFailure, "failed coder returns nil/zero including buffers and structs");
        node->fail = NO;

        CodingSubclass *subclass = [[CodingSubclass new] autorelease];
        NSData *subclassData = archive(subclass, YES);
        error = nil;
        check([[NSKeyedUnarchiver unarchivedObjectOfClass:CodingNode.class fromData:subclassData error:&error] isKindOfClass:CodingSubclass.class]
            && !error, "ordinary secure decoding accepts allowed subclasses");
        unsigned before = nodeInitializations;
        error = nil;
        id strict = [NSKeyedUnarchiver _strictlyUnarchivedObjectOfClasses:[NSSet setWithObject:CodingNode.class]
            fromData:subclassData error:&error];
        check(!strict && error && nodeInitializations == before, "strict mode rejects subclasses before initWithCoder");

        NSMutableData *backing = [NSMutableData data];
        NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:backing] autorelease];
        [archiver encodeObject:@"value" forKey:NSKeyedArchiveRootObjectKey];
        check(archiver.encodedData == backing, "encodedData retains caller's mutable buffer identity");
        NSUInteger size = backing.length;
        check(archiver.encodedData == backing && backing.length == size, "encodedData finishing is idempotent");
        archiver = [[[NSKeyedArchiver alloc] initRequiringSecureCoding:YES] autorelease];
        [archiver encodeObject:@"value" forKey:NSKeyedArchiveRootObjectKey];
        error = nil;
        check([[NSKeyedUnarchiver unarchivedObjectOfClass:NSString.class fromData:archiver.encodedData error:&error] isEqual:@"value"]
            && !error, "modern archiver convenience round trip");
        for (id scalar in @[@42, @"scalar", [NSData dataWithBytes:"abc" length:3]]) {
            error = nil;
            check(![NSKeyedUnarchiver unarchivedObjectOfClass:CodingNode.class fromData:archive(scalar, YES) error:&error]
                && error, "modern typed convenience rejects implicit scalar root");
        }
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:5];
        for (NSDictionary *dictionary in @[@{date: @1}, [NSMutableDictionary dictionaryWithObject:@1 forKey:date], @{@"key": date}]) {
            error = nil;
            check(![NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil]
                fromData:archive(dictionary, YES) error:&error] && error.code == NSCoderReadCorruptError,
                "dictionary with a disallowed key or value reports the decoding error");
        }
        error = nil;
        OrdinaryCoding *ordinary = [[OrdinaryCoding new] autorelease];
        check(![NSKeyedArchiver archivedDataWithRootObject:ordinary requiringSecureCoding:YES error:&error] && error,
            "secure archive rejects NSCoding-only object with NSError");
        error = nil;
        NSData *ordinaryData = [NSKeyedArchiver archivedDataWithRootObject:ordinary requiringSecureCoding:NO error:&error];
        check(ordinaryData && !error && [[NSKeyedUnarchiver unarchiveObjectWithData:ordinaryData] isKindOfClass:OrdinaryCoding.class],
            "nonsecure archive preserves NSCoding-only objects");

        NSSet *arrayClasses = [NSSet setWithObjects:NSArray.class, CodingNode.class, LaterCoding.class, nil];
        node->fail = YES;
        laterInitializations = 0;
        error = nil;
        check(![NSKeyedUnarchiver unarchivedObjectOfClasses:arrayClasses fromData:archive(@[node, [[LaterCoding new] autorelease]], YES)
            error:&error] && error && !laterInitializations, "array failure stops later initializers");
        throwProgrammerException = YES;
        error = nil;
        BOOL threw = NO;
        @try {
            check(![NSKeyedUnarchiver unarchivedObjectOfClasses:arrayClasses fromData:archive(@[node], YES) error:&error] && error,
                "an initializer's raise after its coder failed ends the decode with the failure");
        } @catch (NSException *exception) {
            (void)exception;
            check(NO, "an initializer's raise after its coder failed ends the decode with the failure");
        }
        node->fail = NO;
        @try {
            [NSKeyedUnarchiver unarchivedObjectOfClasses:arrayClasses fromData:archive(@[node], YES) error:&error];
        } @catch (NSException *exception) {
            threw = [exception.name isEqual:NSInvalidArgumentException];
        }
        check(threw, "programmer exception without a coding failure propagates unchanged");
        throwProgrammerException = NO;

        LaterCoding *shared = [[LaterCoding new] autorelease];
        NSArray *positive = @[shared, @[shared, @"text"], shared];
        laterInitializations = 0;
        error = nil;
        NSArray *decodedArray = [NSKeyedUnarchiver unarchivedObjectOfClasses:[arrayClasses setByAddingObject:NSString.class]
            fromData:archive(positive, YES) error:&error];
        check(decodedArray && !error && laterInitializations == 1 && decodedArray[0] == decodedArray[2]
            && decodedArray[0] == decodedArray[1][0], "nested arrays preserve shared object identity");

        error = nil;
        check([NSKeyedUnarchiver unarchivedObjectOfClass:NestedDecoderCoding.class
            fromData:archive([[NestedDecoderCoding new] autorelease], YES) error:&error] && !error,
            "outer unarchiver completes after a separate inner unarchiver fails");
        NSMutableArray *many = [NSMutableArray arrayWithCapacity:2048];
        for (unsigned i = 0; i < 2048; ++i)
            [many addObject:[[LaterCoding new] autorelease]];
        laterInitializations = 0;
        error = nil;
        NSArray *manyBack = [NSKeyedUnarchiver unarchivedObjectOfClasses:arrayClasses fromData:archive(many, YES) error:&error];
        check(manyBack.count == 2048 && laterInitializations == 2048 && !error, "large array decodes every distinct object");

        error = nil;
        check(![NSKeyedUnarchiver unarchivedObjectOfClass:NSString.class fromData:[NSData dataWithBytes:"bad" length:3] error:&error]
            && error, "malformed archive reports NSError");
        error = nil;
        check(![[[NSKeyedUnarchiver alloc] initForReadingFromData:[NSData data] error:&error] autorelease] && error,
            "empty archive reports NSError from initializer");
      }
    }
    checkPublicSelectorsAbsent();
    printf("Foundation-keyed-coding: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
