// Strict secure decoding of the property-list values a keyed archive stores inline in $objects
// (methods/FoundationCoding.m). Foundation returns an inline string, number, boolean or data directly, so
// ordinary secure decoding admits it whatever the allowed classes are. Strict decoding admits it only
// when its class is itself one of the innermost allowed classes, for every decode entry point and
// in both archive formats.
#import <Foundation/Foundation.h>
#include <stdio.h>

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"
@interface NSKeyedUnarchiver (StrictCoding)
+ (id)_strictlyUnarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error;
@end

static int failures;
static void check(BOOL ok, const char *name)
{
    printf("  %s: %s\n", name, ok ? "ok" : "FAIL");
    failures += !ok;
}

typedef enum { FieldKeyedString, FieldUnkeyed, FieldValueType } FieldMode;

@interface Field : NSObject <NSSecureCoding> {
@public
    FieldMode mode;
    id value;
}
@end
@implementation Field
+ (BOOL)supportsSecureCoding { return YES; }
- (void)dealloc
{
    [value release];
    [super dealloc];
}
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:mode forKey:@"mode"];
    if (mode == FieldKeyedString)
        [coder encodeObject:value forKey:@"value"];
    else if (mode == FieldUnkeyed)
        [coder encodeObject:value];
    else
        [coder encodeValueOfObjCType:@encode(id) at:&value];
}
- (id)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init]))
        return nil;
    mode = [coder decodeIntForKey:@"mode"];
    if (mode == FieldKeyedString)
        value = [[coder decodeObjectOfClass:NSString.class forKey:@"value"] retain];
    else if (mode == FieldUnkeyed)
        value = [[coder decodeObject] retain];
    else {
        id decoded = nil;
        [coder decodeValueOfObjCType:@encode(id) at:&decoded];
        value = decoded;
    }
    return self;
}
@end

static NSData *archive(id root, NSPropertyListFormat format)
{
    NSMutableData *data = [NSMutableData data];
    NSKeyedArchiver *archiver = [[[NSKeyedArchiver alloc] initForWritingWithMutableData:data] autorelease];
    archiver.outputFormat = format;
    archiver.requiresSecureCoding = YES;
    [archiver encodeObject:root forKey:NSKeyedArchiveRootObjectKey];
    [archiver finishEncoding];
    return data;
}

static Field *field(FieldMode mode, id value)
{
    Field *result = [[Field new] autorelease];
    result->mode = mode;
    result->value = [value retain];
    return result;
}

static id strictly(NSSet *classes, NSData *data, NSError **error)
{
    *error = nil;
    return [NSKeyedUnarchiver _strictlyUnarchivedObjectOfClasses:classes fromData:data error:error];
}

static NSSet *classes(Class first, ...)
{
    NSMutableSet *set = [NSMutableSet setWithObject:first];
    va_list arguments;
    va_start(arguments, first);
    for (Class cls; (cls = va_arg(arguments, Class));)
        [set addObject:cls];
    va_end(arguments);
    return set;
}

int main(void)
{
    @autoreleasepool {
        NSData *bytes = [NSData dataWithBytes:"abc" length:3];
        NSError *error;
        for (unsigned xml = 0; xml < 2; ++xml) {
            NSPropertyListFormat format = xml ? NSPropertyListXMLFormat_v1_0 : NSPropertyListBinaryFormat_v1_0;
            printf("%s archives\n", xml ? "XML" : "binary");

            NSArray *values = @[@"text", @42, @2.5, @YES, bytes];
            id decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes(NSArray.class, nil) fromData:archive(values, format) error:&error];
            check([decoded isEqual:values] && !error, "ordinary secure decoding admits unlisted inline array elements");
            Field *number = field(FieldKeyedString, @7);
            decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:Field.class fromData:archive(number, format) error:&error];
            check([((Field *)decoded)->value isEqual:@7] && !error, "ordinary secure decoding admits an inline number for a string field");

            for (id element in values) {
                decoded = strictly(classes(NSArray.class, nil), archive(@[element], format), &error);
                check(!decoded && error, "strict decoding rejects an unlisted inline array element");
            }
            decoded = strictly(classes(NSArray.class, NSString.class, NSNumber.class, NSData.class, nil), archive(values, format), &error);
            check([decoded isEqual:values] && !error, "strict decoding admits listed inline array elements");
            decoded = strictly(classes(NSArray.class, NSMutableString.class, NSNumber.class, NSData.class, nil), archive(values, format), &error);
            check(!decoded && error, "strict decoding matches an inline string's class exactly");
            decoded = strictly(classes(NSArray.class, NSString.class, NSData.class, nil), archive(@[@YES], format), &error);
            check(!decoded && error, "strict decoding reads an inline boolean as a number");

            decoded = strictly(classes(NSDictionary.class, NSString.class, nil), archive(@{@"key": @1}, format), &error);
            check(!decoded && error, "strict decoding rejects an unlisted inline dictionary value");
            decoded = strictly(classes(NSDictionary.class, NSNumber.class, nil), archive(@{@"key": @1}, format), &error);
            check(!decoded && error, "strict decoding rejects an unlisted inline dictionary key");
            decoded = strictly(classes(NSDictionary.class, NSString.class, NSNumber.class, nil), archive(@{@"key": @1}, format), &error);
            check([decoded isEqual:@{@"key": @1}] && !error, "strict decoding admits listed inline dictionary entries");
            decoded = strictly(classes(NSArray.class, nil), archive(@[@[@"deep"]], format), &error);
            check(!decoded && error, "strict decoding rejects an unlisted inline value in a nested array");
            decoded = strictly(classes(NSURL.class, nil), archive(@"root", format), &error);
            check(!decoded && error, "strict decoding rejects an unlisted inline root");
            decoded = strictly(classes(NSString.class, nil), archive(@"root", format), &error);
            check([decoded isEqual:@"root"] && !error, "strict decoding admits a listed inline root");

            NSDictionary *preferences = @{@"strings": @[@"a", [NSMutableString stringWithString:@"b"]], @"date": [NSDate dateWithTimeIntervalSince1970:1],
                @"data": bytes, @"flag": @NO, @"nested": [NSMutableDictionary dictionaryWithObject:@3 forKey:@"n"], @"list": [NSMutableArray arrayWithObject:@4]};
            decoded = strictly(classes(NSString.class, NSMutableString.class, NSNumber.class, NSDate.class, NSDictionary.class, NSMutableDictionary.class,
                NSArray.class, NSMutableArray.class, NSData.class, NSMutableData.class, nil), archive(preferences, format), &error);
            check([decoded isEqual:preferences] && !error, "strict decoding admits a property list whose classes are all listed");

            decoded = strictly(classes(Field.class, NSString.class, nil), archive(field(FieldKeyedString, @"text"), format), &error);
            check([((Field *)decoded)->value isEqual:@"text"] && !error, "strict field decoding admits the requested inline class");
            decoded = strictly(classes(Field.class, NSString.class, NSNumber.class, nil), archive(field(FieldKeyedString, @7), format), &error);
            check(!decoded && error, "strict field decoding checks an inline value against the field's own classes");
            decoded = strictly(classes(Field.class, nil), archive(field(FieldKeyedString, nil), format), &error);
            check(decoded && !((Field *)decoded)->value && !error, "strict decoding admits an archived nil");
            for (FieldMode mode = FieldUnkeyed; mode <= FieldValueType; ++mode) {
                decoded = strictly(classes(Field.class, nil), archive(field(mode, @"text"), format), &error);
                check(!decoded && error, mode == FieldUnkeyed ? "strict unkeyed decoding rejects an unlisted inline value"
                    : "strict object-type value decoding rejects an unlisted inline value");
                decoded = strictly(classes(Field.class, NSString.class, nil), archive(field(mode, @"text"), format), &error);
                check([((Field *)decoded)->value isEqual:@"text"] && !error, mode == FieldUnkeyed ? "strict unkeyed decoding admits a listed inline value"
                    : "strict object-type value decoding admits a listed inline value");
            }

        }
    }
    printf("Foundation-strict-inline-values: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
