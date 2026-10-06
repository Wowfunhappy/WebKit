#import <Foundation/Foundation.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"
extern void wk_initializeFoundationCoding(void);
@interface NSKeyedUnarchiver (StrictCoding)
- (void)_enableStrictSecureDecodingMode;
+ (id)_strictlyUnarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error;
@end

static int failures;
static unsigned nodeInitializations;
static BOOL zeroAfterFailure;
static BOOL throwProgrammerException;
static NSMutableDictionary *unrelatedDictionary;
static NSPropertyListFormat archiveFormat;
static void check(BOOL ok, const char *name)
{
    printf("  %s: %s\n", name, ok ? "ok" : "FAIL");
    failures += !ok;
}

@interface ReturningCoder : NSCoder
@end
@implementation ReturningCoder
- (NSDecodingFailurePolicy)decodingFailurePolicy { return NSDecodingFailurePolicySetErrorAndReturn; }
@end

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

@interface CodingNode : NSObject <NSSecureCoding> {
@public
    BOOL fail;
    BOOL returnAfterFailure;
}
@end
@implementation CodingNode
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:fail forKey:@"fail"];
    [coder encodeBool:returnAfterFailure forKey:@"returnAfterFailure"];
    [coder encodeInt:17 forKey:@"integer"];
    [coder encodeDouble:2.5 forKey:@"double"];
    [coder encodeObject:@"text" forKey:@"text"];
    [coder encodeBytes:(const uint8_t *)"abc" length:3 forKey:@"bytes"];
    [coder encodeRect:NSMakeRect(1, 2, 3, 4) forKey:@"rect"];
}
- (id)initWithCoder:(NSCoder *)coder
{
    ++nodeInitializations;
    if (!(self = [super init]))
        return nil;
    BOOL shouldReturn = [coder decodeBoolForKey:@"returnAfterFailure"];
    if ([coder decodeBoolForKey:@"fail"]) {
        [coder failWithError:[NSError errorWithDomain:@"CodingNode" code:91 userInfo:nil]];
        [coder failWithError:[NSError errorWithDomain:@"CodingNode" code:92 userInfo:nil]];
        NSUInteger length = 999;
        const uint8_t *bytes = [coder decodeBytesForKey:@"bytes" returnedLength:&length];
        zeroAfterFailure = ![coder decodeIntForKey:@"integer"] && ![coder decodeDoubleForKey:@"double"]
            && ![coder decodeObjectForKey:@"text"] && !bytes && !length
            && NSEqualRects([coder decodeRectForKey:@"rect"], NSZeroRect);
        if (unrelatedDictionary)
            unrelatedDictionary[@"side effect"] = @"preserved";
        if (throwProgrammerException)
            [NSException raise:NSInvalidArgumentException format:@"programmer exception"];
        if (shouldReturn)
            return self;
        [self release];
        return nil;
    }
    return self;
}
@end
@interface CodingSubclass : CodingNode
@end
@implementation CodingSubclass
@end

static unsigned laterInitializations;
static unsigned childRejections;

@interface LaterCoding : NSObject <NSSecureCoding> @end
@implementation LaterCoding
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
- (id)initWithCoder:(NSCoder *)coder { (void)coder; ++laterInitializations; return [super init]; }
@end

@interface RecoveringCoding : NSObject <NSSecureCoding> @end
@implementation RecoveringCoding
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    CodingNode *child = [[CodingNode new] autorelease];
    child->fail = YES;
    child->returnAfterFailure = YES;
    [coder encodeObject:child forKey:@"bad"];
}
- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init])) return nil;
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
        NSError *error = nil;
        id child = [coder decodeTopLevelObjectOfClass:CodingNode.class forKey:@"bad" error:&error];
        childRejections += !child && error.code == 91;
    }
    return self;
}
@end

@interface CyclicParent : NSObject <NSSecureCoding> { @public id child; } @end
@interface CyclicChild : NSObject <NSSecureCoding> { @public CyclicParent *parent; } @end
@implementation CyclicParent
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:child forKey:@"child"]; }
- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init])) return nil;
    child = [[coder decodeObjectOfClass:CyclicChild.class forKey:@"child"] retain];
    [coder failWithError:[NSError errorWithDomain:@"cyclic parent" code:17 userInfo:nil]];
    [self release];
    return nil;
}
- (void)dealloc { [child release]; [super dealloc]; }
@end
@implementation CyclicChild
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:parent forKey:@"parent"]; }
- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init])) return nil;
    parent = [[coder decodeObjectOfClass:CyclicParent.class forKey:@"parent"] retain];
    return self;
}
- (void)dealloc { [parent release]; [super dealloc]; }
@end

@interface NestedDecoderCoding : NSObject <NSSecureCoding> @end
@implementation NestedDecoderCoding
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    CodingNode *node = [[CodingNode new] autorelease];
    node->fail = YES;
    node->returnAfterFailure = YES;
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
    check(!inner && error.code == 91 && [outer isEqual:@"outer value"] && !coder.error,
        "nested independent unarchiver keeps its failure and cache transaction separate");
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

static NSKeyedUnarchiver *decoder(NSData *data, NSDecodingFailurePolicy policy)
{
    NSError *error = nil;
    NSKeyedUnarchiver *coder = [[[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error] autorelease];
    check(coder && !error && coder.requiresSecureCoding
        && coder.decodingFailurePolicy == NSDecodingFailurePolicySetErrorAndReturn, "modern initializer defaults");
    coder.decodingFailurePolicy = policy;
    return coder;
}

int main(void)
{
    wk_initializeFoundationCoding();
    for (unsigned format = 0; format < 2; ++format) {
      @autoreleasepool {
        archiveFormat = format ? NSPropertyListXMLFormat_v1_0 : NSPropertyListBinaryFormat_v1_0;
        printf("FORMAT %s\n", format ? "XML" : "binary");
        ReturningCoder *returning = [[ReturningCoder new] autorelease];
        NSError *custom = [NSError errorWithDomain:@"override" code:23 userInfo:nil];
        [returning failWithError:custom];
        check([returning.error isEqual:custom], "NSCoder failure handling honors subclass policy override");
        CodingNode *node = [[CodingNode new] autorelease];
        NSData *valid = archive(node, YES);
        NSKeyedUnarchiver *classic = [[[NSKeyedUnarchiver alloc] initForReadingWithData:valid] autorelease];
        check(classic.decodingFailurePolicy == NSDecodingFailurePolicyRaiseException && !classic.error,
            "classic initializer retains exception policy");

        NSKeyedUnarchiver *coder = decoder(valid, NSDecodingFailurePolicySetErrorAndReturn);
        BOOL threw = NO;
        id wrong = nil;
        @try { wrong = [coder decodeObjectOfClass:NSURL.class forKey:NSKeyedArchiveRootObjectKey]; }
        @catch (NSException *exception) { (void)exception; threw = YES; }
        check(!threw && !wrong && coder.error, "return policy converts native class-validation failure");
        check(![coder decodeObjectOfClass:NSString.class forKey:@"good"], "error prevents subsequent object decoding");
        NSError *error = nil;
        check(![coder decodeTopLevelObjectOfClass:NSString.class forKey:@"good" error:&error] && error && !coder.error,
            "top-level call consumes pending error");
        error = nil;
        check([[coder decodeTopLevelObjectOfClass:NSString.class forKey:@"good" error:&error] isEqual:@"good value"] && !error,
            "top-level error consumption restores usable archive state");
        [coder finishDecoding];

        for (NSUInteger policy = 0; policy < 2; ++policy) {
            node->fail = YES;
            coder = decoder(archive(node, YES), (NSDecodingFailurePolicy)policy);
            error = nil;
            id result = [coder decodeTopLevelObjectOfClass:CodingNode.class forKey:NSKeyedArchiveRootObjectKey error:&error];
            check(!result && [error.domain isEqual:@"CodingNode"] && error.code == 91 && !coder.error,
                "failWithError preserves first error through top-level decode");
            if (policy == NSDecodingFailurePolicySetErrorAndReturn)
                check(zeroAfterFailure, "failed nested coder returns nil/zero including buffers and structs");
            error = nil;
            check([[coder decodeTopLevelObjectOfClass:NSString.class forKey:@"good" error:&error] isEqual:@"good value"] && !error,
                "nested failure restores native archive cursor for another top-level key");
            [coder finishDecoding];
        }

        coder = decoder(valid, NSDecodingFailurePolicyRaiseException);
        threw = NO;
        @try { [coder decodeObjectOfClass:NSURL.class forKey:NSKeyedArchiveRootObjectKey]; }
        @catch (NSException *exception) { (void)exception; threw = YES; }
        check(threw && !coder.error, "exception policy raises and keeps error property nil");
        [coder finishDecoding];

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
        error = nil;
        OrdinaryCoding *ordinary = [[OrdinaryCoding new] autorelease];
        check(![NSKeyedArchiver archivedDataWithRootObject:ordinary requiringSecureCoding:YES error:&error] && error,
            "secure archive rejects NSCoding-only object with NSError");
        error = nil;
        NSData *ordinaryData = [NSKeyedArchiver archivedDataWithRootObject:ordinary requiringSecureCoding:NO error:&error];
        check(ordinaryData && !error && [[NSKeyedUnarchiver unarchiveTopLevelObjectWithData:ordinaryData error:&error]
            isKindOfClass:OrdinaryCoding.class] && !error, "nonsecure convenience preserves NSCoding-only objects");
        node->fail = YES;
        node->returnAfterFailure = YES;
        coder = decoder(archive(node, YES), NSDecodingFailurePolicySetErrorAndReturn);
        for (unsigned attempt = 0; attempt < 2; ++attempt) {
            error = nil;
            check(![coder decodeTopLevelObjectOfClass:CodingNode.class forKey:NSKeyedArchiveRootObjectKey error:&error]
                && error && error.code == 91, "failed initializer returning self cannot become a valid cached object");
        }
        NSSet *arrayClasses = [NSSet setWithObjects:NSArray.class, CodingNode.class, LaterCoding.class, nil];
        for (unsigned secure = 0; secure < 2; ++secure) {
            for (unsigned returnsSelf = 0; returnsSelf < 2; ++returnsSelf) {
                node->returnAfterFailure = returnsSelf;
                coder = decoder(archive(@[node, [[LaterCoding new] autorelease]], YES), NSDecodingFailurePolicySetErrorAndReturn);
                coder.requiresSecureCoding = secure;
                laterInitializations = 0;
                for (unsigned attempt = 0; attempt < 2; ++attempt) {
                    error = nil;
                    id result = [coder decodeTopLevelObjectOfClasses:arrayClasses forKey:NSKeyedArchiveRootObjectKey error:&error];
                    check(!result && error.code == 91 && !laterInitializations,
                        "array failure stops later initializers and retains failed elements for retry");
                }
            }
        }
        unrelatedDictionary = [[NSMutableDictionary alloc] init];
        throwProgrammerException = YES;
        coder = decoder(archive(@[node, [[LaterCoding new] autorelease]], YES), NSDecodingFailurePolicySetErrorAndReturn);
        threw = NO;
        @try { [coder decodeTopLevelObjectOfClasses:arrayClasses forKey:NSKeyedArchiveRootObjectKey error:&error]; }
        @catch (NSException *exception) { threw = [exception.name isEqual:NSInvalidArgumentException]; }
        check(threw, "programmer exception after failWithError propagates unchanged");
        check([unrelatedDictionary[@"side effect"] isEqual:@"preserved"], "failed decoding leaves unrelated Foundation dictionaries unchanged");
        [unrelatedDictionary release];
        unrelatedDictionary = nil;
        throwProgrammerException = NO;

        childRejections = 0;
        coder = decoder(archive([[RecoveringCoding new] autorelease], YES), NSDecodingFailurePolicySetErrorAndReturn);
        error = nil;
        id recovered = [coder decodeTopLevelObjectOfClass:RecoveringCoding.class forKey:NSKeyedArchiveRootObjectKey error:&error];
        check(recovered && !error && childRejections == 2, "nested top-level recovery preserves the active parent and rejects both child attempts");

        LaterCoding *shared = [[LaterCoding new] autorelease];
        NSArray *positive = @[shared, @[shared, @"text"], shared];
        coder = decoder(archive(positive, YES), NSDecodingFailurePolicySetErrorAndReturn);
        laterInitializations = 0;
        error = nil;
        NSArray *decodedArray = [coder decodeTopLevelObjectOfClasses:arrayClasses forKey:NSKeyedArchiveRootObjectKey error:&error];
        check(decodedArray && !error && laterInitializations == 1 && decodedArray[0] == decodedArray[2]
            && decodedArray[0] == decodedArray[1][0], "nested arrays preserve shared object identity");
        check([coder decodeTopLevelObjectOfClasses:arrayClasses forKey:NSKeyedArchiveRootObjectKey error:&error] == decodedArray && !error,
            "successful array retains native cached root identity");

        error = nil;
        check([NSKeyedUnarchiver unarchivedObjectOfClass:NestedDecoderCoding.class
            fromData:archive([[NestedDecoderCoding new] autorelease], YES) error:&error] && !error,
            "outer unarchiver completes after a separate inner unarchiver fails");
        NSMutableArray *many = [NSMutableArray arrayWithCapacity:2048];
        for (unsigned i = 0; i < 2048; ++i)
            [many addObject:[[LaterCoding new] autorelease]];
        NSData *manyData = archive(many, YES);
        laterInitializations = 0;
        error = nil;
        NSArray *manyBack = [NSKeyedUnarchiver unarchivedObjectOfClasses:arrayClasses fromData:manyData error:&error];
        check(manyBack.count == 2048 && laterInitializations == 2048 && !error,
            "large array commits every distinct decoded object through the growing undo journal");

        CyclicParent *parent = [[CyclicParent alloc] init];
        CyclicChild *child = [[CyclicChild alloc] init];
        parent->child = [child retain];
        child->parent = [parent retain];
        NSMutableData *cycleData = [NSMutableData data];
        NSKeyedArchiver *cycleEncoder = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:cycleData] autorelease];
        cycleEncoder.outputFormat = archiveFormat;
        [cycleEncoder encodeObject:parent forKey:@"parent"];
        [cycleEncoder encodeObject:child forKey:@"child"];
        [cycleEncoder finishEncoding];
        [parent->child release]; parent->child = nil;
        [child->parent release]; child->parent = nil;
        [parent release]; [child release];
        coder = decoder(cycleData, NSDecodingFailurePolicySetErrorAndReturn);
        error = nil;
        check(![coder decodeTopLevelObjectOfClass:CyclicParent.class forKey:@"parent" error:&error] && error.code == 17,
            "cyclic parent failure reports its first error");
        error = nil;
        check(![coder decodeTopLevelObjectOfClass:CyclicChild.class forKey:@"child" error:&error] && error.code == 17,
            "child cached within a failed parent cannot expose that parent after recovery");

        error = nil;
        check(![NSKeyedUnarchiver unarchivedObjectOfClass:NSString.class fromData:[NSData dataWithBytes:"bad" length:3] error:&error]
            && error, "malformed archive reports NSError");
        error = nil;
        check(![[[NSKeyedUnarchiver alloc] initForReadingFromData:[NSData data] error:&error] autorelease] && error,
            "empty archive reports NSError from initializer");
      }
    }
    printf("Foundation-keyed-coding: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
