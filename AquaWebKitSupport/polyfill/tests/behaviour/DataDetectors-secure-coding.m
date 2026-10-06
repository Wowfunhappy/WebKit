#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>

extern void wk_initializeDDSecureCoding(void);
@interface NSObject (DDTest)
- (void)setHighlightFrame:(NSRect)value;
- (void)setAimFrame:(NSRect)value;
- (void)setEventTitle:(NSString *)value;
- (void)setReferenceDate:(NSDate *)value;
- (void)setAuthorUUID:(NSString *)value;
- (void)setAuthorEmailAddress:(NSString *)value;
- (void)setAuthorName:(NSString *)value;
- (void)setMatchedString:(NSString *)value;
- (void)setSelectionString:(NSString *)value;
- (void)setURL:(NSURL *)value;
- (void)setImmediate:(BOOL)value;
- (void)setIsRightClick:(BOOL)value;
- (void)setAllResults:(NSArray *)value;
- (void)setMainResult:(CFTypeRef)value;
- (NSArray *)allResults;
- (CFTypeRef)mainResult;
- (CFTypeRef)dd_createResult;
@end

static int failures;
static void check(BOOL ok, const char *name)
{
    printf("  %s: %s\n", name, ok ? "ok" : "FAIL");
    failures += !ok;
}

@interface CaptureCoder : NSCoder {
@public
    NSMutableDictionary *fields;
}
@end
@implementation CaptureCoder
- (id)init { if ((self = [super init])) fields = [NSMutableDictionary new]; return self; }
- (void)dealloc { [fields release]; [super dealloc]; }
- (BOOL)allowsKeyedCoding { return YES; }
- (void)encodeObject:(id)object forKey:(NSString *)key { if (object) fields[key] = object; }
- (void)encodeRect:(NSRect)rect forKey:(NSString *)key { fields[key] = NSStringFromRect(rect); }
- (void)encodeBool:(BOOL)value forKey:(NSString *)key { fields[key] = @(value); }
@end

static NSDictionary *fields(id object)
{
    CaptureCoder *coder = [[CaptureCoder new] autorelease];
    [object encodeWithCoder:coder];
    return [[coder->fields copy] autorelease];
}

@interface ArchiveFixture : NSObject <NSSecureCoding> {
@public
    NSDictionary *values;
}
@end
@implementation ArchiveFixture
+ (BOOL)supportsSecureCoding { return YES; }
- (Class)classForKeyedArchiver { return NSClassFromString(@"DDActionContext"); }
- (id)initWithCoder:(NSCoder *)coder { (void)coder; return [self init]; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeRect:NSZeroRect forKey:@"highlightFrame"];
    [coder encodeRect:NSZeroRect forKey:@"aimFrame"];
    for (NSString *key in values)
        [coder encodeObject:values[key] forKey:key];
}
@end

static unsigned unexpectedInitializations;
@interface UnexpectedObject : NSObject <NSSecureCoding>
@end
@implementation UnexpectedObject
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder { (void)coder; }
- (id)initWithCoder:(NSCoder *)coder { (void)coder; ++unexpectedInitializations; return [self init]; }
@end

static id roundTrip(id object, BOOL secure)
{
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:data] autorelease];
    archiver.requiresSecureCoding = secure;
    [archiver encodeObject:object forKey:@"root"];
    [archiver finishEncoding];
    NSKeyedUnarchiver *unarchiver = [[[NSKeyedUnarchiver alloc] initForReadingWithData:data] autorelease];
    unarchiver.requiresSecureCoding = secure;
    id result = secure ? [unarchiver decodeObjectOfClass:NSClassFromString(@"DDActionContext") forKey:@"root"]
        : [unarchiver decodeObjectForKey:@"root"];
    [unarchiver finishDecoding];
    return result;
}

static id decodeFields(NSDictionary *dictionary)
{
    ArchiveFixture *fixture = [[ArchiveFixture new] autorelease];
    fixture->values = dictionary;
    return roundTrip(fixture, YES);
}

static void reject(NSDictionary *dictionary, const char *name)
{
    BOOL rejected = NO;
    @try { rejected = !decodeFields(dictionary); }
    @catch (NSException *exception) { (void)exception; rejected = YES; }
    check(rejected, name);
}

int main(void)
{
    @autoreleasepool {
        wk_initializeDDSecureCoding();
        check(dlopen("/System/Library/PrivateFrameworks/DataDetectors.framework/DataDetectors", RTLD_LAZY) != NULL,
            "load native framework after initializer");
        Class cls = NSClassFromString(@"DDActionContext");
        check([cls conformsToProtocol:@protocol(NSSecureCoding)] && [cls supportsSecureCoding], "native class supports secure coding");
        id context = [[[cls alloc] init] autorelease];
        [context setHighlightFrame:NSMakeRect(1, 2, 30, 40)];
        [context setAimFrame:NSMakeRect(-1, 20, 3, 4)];
        [context setEventTitle:@"event"];
        [context setReferenceDate:[NSDate dateWithTimeIntervalSince1970:12345678]];
        [context setAuthorUUID:@"author-id"];
        [context setAuthorEmailAddress:@"author@test.invalid"];
        [context setAuthorName:@"author"];
        [context setMatchedString:@"match"];
        [context setSelectionString:@"selection"];
        [context setURL:[NSURL URLWithString:@"https://www.apple.com/path?q=1"]];
        [context setImmediate:YES];
        [context setIsRightClick:YES];
        NSDictionary *resultDictionary = @{@"AR":@"{2, 5}", @"T":@"PhoneNumber", @"MS":@"12345", @"V":@"12345",
            @"C":@{@"text":@"value", @"number":@12, @"data":[NSData dataWithBytes:"abc" length:3],
                @"nested":@{@"k":@"v"}, @17:@"numeric key"},
            @"SR":@[@{@"AR":@"{3, 2}", @"T":@"PhoneNumber", @"MS":@"23"}]};
        CFTypeRef result = [resultDictionary dd_createResult];
        [context setMainResult:result];
        [context setAllResults:@[(id)result]];
        CFRelease(result);
        NSDictionary *before = fields(context);
        check(before.count == 14, "exercise all fourteen native archive fields");
        id decoded = roundTrip(context, YES);
        check([fields(decoded) isEqual:before], "all fields and nested results survive secure archive");
        check([decoded class] == cls, "decoded object retains native class");
        id copy = [[context copy] autorelease];
        check([copy class] == cls && [fields(roundTrip(copy, YES)) isEqual:fields(copy)], "native copy remains securely archivable");
        check([fields(roundTrip(context, NO)) isEqual:before], "ordinary NSCoding preserves native decoder behavior");
        id empty = roundTrip([[[cls alloc] init] autorelease], YES);
        check(empty && ![empty mainResult] && [empty allResults] && ![empty allResults].count, "nil/default fields decode to native defaults");
        check(decodeFields(@{@"mainResult":@{}}) != nil, "missing result range and type retain native defaults");
        check(decodeFields(@{@"allResults":@[@{@"SR":@[@{}]}]}) != nil, "nested default results decode");
        id sharedContext;
        @autoreleasepool {
            NSMutableString *shared = [NSMutableString stringWithString:@"shared"];
            sharedContext = [decodeFields(@{@"eventTitle":shared, @"authorName":shared}) retain];
        }
        NSDictionary *sharedFields = fields(sharedContext);
        id title = sharedFields[@"eventTitle"];
        check([title isKindOfClass:NSMutableString.class] && title == sharedFields[@"authorName"],
            "native decoder retention preserves mutable shared strings after unarchiver release");
        if ([title isKindOfClass:NSMutableString.class]) {
            [title appendString:@" changed"];
            check([fields(sharedContext)[@"authorName"] isEqual:@"shared changed"], "shared identity survives mutation");
        }
        [sharedContext release];

        for (NSString *key in @[@"eventTitle", @"authorABUUID", @"authorEmailAddress", @"authorName", @"matchedString", @"selectionString"])
            reject(@{key:@42}, [[@"wrong string field " stringByAppendingString:key] UTF8String]);
        reject(@{@"referenceDate":@"date"}, "wrong date type");
        reject(@{@"url":@"url"}, "wrong URL type");
        reject(@{@"allResults":@{}}, "wrong allResults container");
        reject(@{@"allResults":@[@"result"]}, "wrong allResults member");
        reject(@{@"mainResult":@[]}, "wrong mainResult type");
        for (NSString *key in @[@"AR", @"T", @"MS", @"V"])
            reject(@{@"mainResult":@{key:@42}}, [[@"wrong result field " stringByAppendingString:key] UTF8String]);
        reject(@{@"mainResult":@{@"SR":@{}}}, "wrong subresult container");
        reject(@{@"mainResult":@{@"SR":@[@1]}}, "wrong subresult member");
        reject(@{@"mainResult":@{@"C":@[]}}, "wrong contextual-data container");
        reject(@{@"mainResult":@{@"C":@{@"nested":@{@"k":@[]}}}}, "context does not inherit SR array allowance");
        reject(@{@"mainResult":@{@"C":@{@"date":[NSDate date]}}}, "context rejects date objects");
        id unexpected = [[UnexpectedObject new] autorelease];
        reject(@{@"eventTitle":unexpected}, "reject unexpected top-level secure class");
        reject(@{@"mainResult":@{@"C":@{@"unexpected":unexpected}}}, "reject unexpected nested secure class");
        check(!unexpectedInitializations, "unexpected classes rejected before initWithCoder executes");
        NSMutableDictionary *cyclic = [NSMutableDictionary dictionary];
        cyclic[@"SR"] = @[cyclic];
        reject(@{@"mainResult":cyclic}, "reject cyclic SR before native recursive conversion");
        [cyclic removeAllObjects];
    }
    printf("DataDetectors-secure-coding: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
