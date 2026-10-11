// Foundation: the keyed-coding APIs WebKit sends that 10.9 lacks -- NSKeyedUnarchiver's
// -initForReadingFromData:error:, -setDecodingFailurePolicy: and its unarchivedObject... conveniences, and
// NSKeyedArchiver's -initRequiringSecureCoding:, -encodedData and +archivedDataWithRootObject:....
//
// The unarchivers these create are instances of WKPolyfillPriv_KeyedUnarchiver, a private NSKeyedUnarchiver
// subclass built at first use. Its decoders carry NSDecodingFailurePolicySetErrorAndReturn and strict
// secure decoding: Foundation's own sends during a decode reach them, and no system class is modified. A
// classic NSKeyedUnarchiver set to SetErrorAndReturn becomes one; an unarchiver of another subclass keeps
// its raising decoders.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <string.h>
#include "wk_symbols.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

@interface NSKeyedUnarchiver (WKStrictSecureDecoding)
+ (id)_strictlyUnarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error;
@end

typedef struct {
    NSDecodingFailurePolicy policy;
    BOOL strict;
} WKCoderState;

static const void *wk_coderKey(const char *name) { return sel_registerName(name); }
static WKCoderState *wk_coderState(id coder, BOOL create)
{
    const void *key = wk_coderKey("wk_keyedCodingState");
    NSMutableData *data = objc_getAssociatedObject(coder, key);
    if (!data && create) {
        data = [NSMutableData dataWithLength:sizeof(WKCoderState)];
        objc_setAssociatedObject(coder, key, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return [data mutableBytes];
}

static NSDecodingFailurePolicy wk_policy(id coder)
{
    WKCoderState *state = wk_coderState(coder, NO);
    return state ? state->policy : NSDecodingFailurePolicyRaiseException;
}

static BOOL wk_returnsErrors(id coder)
{
    return wk_policy(coder) == NSDecodingFailurePolicySetErrorAndReturn;
}

static NSError *wk_coderError(id coder)
{
    return objc_getAssociatedObject(coder, wk_coderKey("wk_keyedCodingError"));
}

static void wk_setCoderError(id coder, NSError *error)
{
    if (!error || !wk_coderError(coder))
        objc_setAssociatedObject(coder, wk_coderKey("wk_keyedCodingError"), error, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSError *wk_codingExceptionError(NSException *exception)
{
    id underlying = exception.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:NSError.class])
        return underlying;
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
        userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Invalid keyed archive"}];
}

static BOOL wk_isCodingException(NSException *exception)
{
    return [exception.name isEqual:NSInvalidUnarchiveOperationException]
        || [exception.name isEqual:@"NSArchiverArchiveInconsistency"];
}

// -failWithError:'s effect: the error is recorded under SetErrorAndReturn and raised otherwise.
static void wk_fail(id coder, NSString *description)
{
    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
        userInfo:@{NSLocalizedDescriptionKey:description}];
    if (wk_returnsErrors(coder)) {
        wk_setCoderError(coder, error);
        return;
    }
    @throw [NSException exceptionWithName:NSInvalidUnarchiveOperationException reason:description
        userInfo:@{NSUnderlyingErrorKey:error}];
}

static Ivar wk_genericKey, wk_flags, wk_offsetData, wk_containers, wk_helper, wk_allowedClasses;
static Ivar wk_archiveBytes, wk_archiveLength, wk_archiveObjects, wk_binaryObjectCache;

static void *wk_ivarAddress(id object, Ivar ivar) { return (char *)object + ivar_getOffset(ivar); }
static void *wk_pointerIvar(id object, Ivar ivar)
{
    void *value = NULL;
    if (object)
        memcpy(&value, wk_ivarAddress(object, ivar), sizeof(value));
    return value;
}

static CFTypeID (*wk_uidTypeID)(void);
static uint32_t (*wk_uidValue)(CFTypeRef);
static bool (*wk_binaryDictionaryValueOffset)(const uint8_t *, uint64_t, uint64_t, const void *, CFTypeRef, uint64_t *, uint64_t *, Boolean, CFMutableDictionaryRef);
static bool (*wk_binaryArrayValueOffset)(const uint8_t *, uint64_t, uint64_t, const void *, CFIndex, uint64_t *, CFMutableDictionaryRef);
static bool (*wk_binaryCreateObject)(const uint8_t *, uint64_t, uint64_t, const void *, CFAllocatorRef, CFOptionFlags, CFMutableDictionaryRef, CFPropertyListRef *);
static id (*wk_nativeDecodeBinary)(id, uint32_t, NSString *);
static id (*wk_nativeDecodeXML)(id, NSString *);
static IMP wk_nativePropertyList;

static BOOL wk_strictSecureDecoding(id coder)
{
    WKCoderState *state = wk_coderState(coder, NO);
    return state && state->strict && [coder requiresSecureCoding];
}

typedef struct {
    const uint8_t *bytes;
    uint64_t length;
    // The binary plist trailer, followed by the current container's offset (+32) and the $objects offset (+40).
    const uint8_t *offsets;
    CFMutableDictionaryRef cache;
} WKBinaryArchive;

static BOOL wk_binaryArchive(id coder, WKBinaryArchive *archive)
{
    archive->bytes = wk_pointerIvar(coder, wk_archiveBytes);
    memcpy(&archive->length, wk_ivarAddress(coder, wk_archiveLength), sizeof(archive->length));
    archive->offsets = wk_pointerIvar(coder, wk_offsetData);
    archive->cache = wk_pointerIvar(coder, wk_binaryObjectCache);
    return archive->bytes && archive->offsets;
}

// The nonzero object reference that Foundation's __decodeObject reads for key from the current container.
static BOOL wk_archivedReference(id coder, NSString *key, uint32_t *reference)
{
    CFArrayRef containers = wk_pointerIvar(coder, wk_containers);
    if (containers) {
        CFIndex depth = CFArrayGetCount(containers);
        if (!depth)
            return NO;
        CFTypeRef container = CFArrayGetValueAtIndex(containers, depth - 1);
        CFTypeRef value = NULL;
        if (CFGetTypeID(container) == CFArrayGetTypeID())
            value = CFArrayGetCount(container) ? CFArrayGetValueAtIndex(container, 0) : NULL;
        else if (CFGetTypeID(container) == CFDictionaryGetTypeID())
            value = CFDictionaryGetValue(container, (CFStringRef)key);
        if (!value || CFGetTypeID(value) != wk_uidTypeID())
            return NO;
        *reference = wk_uidValue(value);
        return *reference != 0;
    }
    WKBinaryArchive archive;
    uint64_t container, offset;
    if (!wk_binaryArchive(coder, &archive))
        return NO;
    memcpy(&container, archive.offsets + 32, sizeof(container));
    if (!wk_binaryDictionaryValueOffset(archive.bytes, archive.length, container, archive.offsets, (CFStringRef)key, NULL, &offset, false, archive.cache)
        || offset >= archive.length)
        return NO;
    uint8_t marker = archive.bytes[offset];
    uint64_t size = (marker & 0x0F) + 1, value = 0;
    if ((marker & 0xF0) != 0x80 || size > archive.length - offset - 1)
        return NO;
    for (uint64_t index = 1; index <= size; ++index)
        value = value << 8 | archive.bytes[offset + index];
    *reference = (uint32_t)value;
    return value != 0;
}

// Foundation returns these $objects entries directly instead of instantiating an archived class.
static Class wk_inlineValueClass(id coder, uint32_t reference)
{
    CFTypeRef value = NULL;
    BOOL binary = !wk_pointerIvar(coder, wk_containers);
    if (binary) {
        WKBinaryArchive archive;
        uint64_t objects, offset;
        if (!wk_binaryArchive(coder, &archive))
            return Nil;
        memcpy(&objects, archive.offsets + 40, sizeof(objects));
        if (!wk_binaryArrayValueOffset(archive.bytes, archive.length, objects, archive.offsets, reference, &offset, archive.cache)
            || offset >= archive.length || (archive.bytes[offset] >> 4) > 6
            || !wk_binaryCreateObject(archive.bytes, archive.length, offset, archive.offsets, NULL, 0, archive.cache, &value) || !value)
            return Nil;
    } else {
        CFArrayRef objects = wk_pointerIvar(coder, wk_archiveObjects);
        if (!objects || reference >= (uint64_t)CFArrayGetCount(objects))
            return Nil;
        value = CFRetain(CFArrayGetValueAtIndex(objects, reference));
    }
    CFTypeID type = CFGetTypeID(value);
    Class cls = Nil;
    if (type == CFStringGetTypeID())
        cls = CFEqual(value, CFSTR("$null")) ? Nil : NSString.class;
    else if (type == CFNumberGetTypeID() || type == CFBooleanGetTypeID())
        cls = NSNumber.class;
    else if (type == CFDataGetTypeID())
        cls = NSData.class;
    else if (binary && type == CFDateGetTypeID())
        cls = NSDate.class;
    else if (binary && type == CFNullGetTypeID())
        cls = NSNull.class;
    CFRelease(value);
    return cls;
}

// Strict secure decoding admits an inline property-list value only when its class is itself allowed.
static void wk_validateInlineValue(id coder, uint32_t reference, NSString *key)
{
    Class cls = wk_inlineValueClass(coder, reference);
    if (cls && ![[coder allowedClasses] containsObject:cls])
        [NSException raise:NSInvalidUnarchiveOperationException format:@"value for key '%@' was of unexpected class '%@'. Allowed classes are '%@'.",
            key, cls, [coder allowedClasses]];
}

static void wk_validateStrictReference(id coder, NSString *key)
{
    uint32_t reference;
    uint32_t flags;
    memcpy(&flags, wk_ivarAddress(coder, wk_flags), sizeof(flags));
    // Flag bit 0x2 marks a finished unarchiver.
    if (key && !(flags & 2u) && wk_archivedReference(coder, key, &reference))
        wk_validateInlineValue(coder, reference, key);
}

static NSString *wk_nextGenericKey(id coder)
{
    int32_t genericKey;
    memcpy(&genericKey, wk_ivarAddress(coder, wk_genericKey), sizeof(genericKey));
    return [NSString stringWithFormat:@"$%d", genericKey];
}

// Under SetErrorAndReturn a coding failure records the first error, and every decode from then on returns
// nil or zero. A decode that has recorded its failure ends with it, including when an initializer then
// raises over the nil it was handed: -[NSDictionary initWithCoder:] passes its NS.objects and NS.keys
// arrays to -initWithObjects:forKeys:, which raises when one of them failed.
#define WK_DECODE_BODY(call, empty) \
    if (!wk_returnsErrors(self)) return (call); \
    if (wk_coderError(self)) return (empty); \
    @try { \
        __typeof__(call) result = (call); \
        if (wk_coderError(self)) return (empty); \
        return result; \
    } @catch (NSException *exception) { \
        if (wk_isCodingException(exception)) \
            wk_setCoderError(self, wk_codingExceptionError(exception)); \
        else if (!wk_coderError(self)) \
            @throw; \
        return (empty); \
    }

#define WK_KEY_DECODER(name, type, empty) \
    static IMP wk_original_##name; \
    static type wk_##name(id self, SEL selector, NSString *key) { \
        WK_DECODE_BODY(((type (*)(id, SEL, NSString *))wk_original_##name)(self, selector, key), empty); \
    }
WK_KEY_DECODER(decodeBoolForKey, BOOL, NO)
WK_KEY_DECODER(decodeIntForKey, int, 0)
WK_KEY_DECODER(decodeInt32ForKey, int32_t, 0)
WK_KEY_DECODER(decodeInt64ForKey, int64_t, 0)
WK_KEY_DECODER(decodeIntegerForKey, NSInteger, 0)
WK_KEY_DECODER(decodeFloatForKey, float, 0)
WK_KEY_DECODER(decodeDoubleForKey, double, 0)
WK_KEY_DECODER(decodePropertyListForKey, id, nil)
WK_KEY_DECODER(decodePointForKey, NSPoint, NSZeroPoint)
WK_KEY_DECODER(decodeSizeForKey, NSSize, NSZeroSize)
WK_KEY_DECODER(decodeRectForKey, NSRect, NSZeroRect)
#undef WK_KEY_DECODER

static IMP wk_original_decodeObjectForKey, wk_original_decodeObject;
static id wk_decodeStrictObjectForKey(id self, SEL selector, NSString *key)
{
    // -decodeObjectForKey: reads the key without its leading '$'.
    if (wk_strictSecureDecoding(self))
        wk_validateStrictReference(self, [key hasPrefix:@"$"] ? [key substringFromIndex:1] : key);
    return ((id (*)(id, SEL, NSString *))wk_original_decodeObjectForKey)(self, selector, key);
}
static id wk_decodeObjectForKey(id self, SEL selector, NSString *key)
{
    WK_DECODE_BODY(wk_decodeStrictObjectForKey(self, selector, key), nil);
}
static id wk_decodeStrictObject(id self, SEL selector)
{
    if (wk_strictSecureDecoding(self))
        wk_validateStrictReference(self, wk_nextGenericKey(self));
    return ((id (*)(id, SEL))wk_original_decodeObject)(self, selector);
}
static id wk_decodeObject(id self, SEL selector)
{
    WK_DECODE_BODY(wk_decodeStrictObject(self, selector), nil);
}

#define WK_UNKEYED_DECODER(name, type, empty) \
    static IMP wk_original_##name; \
    static type wk_##name(id self, SEL selector) { \
        WK_DECODE_BODY(((type (*)(id, SEL))wk_original_##name)(self, selector), empty); \
    }
WK_UNKEYED_DECODER(decodeDataObject, id, nil)
WK_UNKEYED_DECODER(decodePropertyList, id, nil)
WK_UNKEYED_DECODER(decodePoint, NSPoint, NSZeroPoint)
WK_UNKEYED_DECODER(decodeSize, NSSize, NSZeroSize)
WK_UNKEYED_DECODER(decodeRect, NSRect, NSZeroRect)
#undef WK_UNKEYED_DECODER

// 10.9's -[NSURLResponse initWithCoder:] reads a secure archive's response fields as
// __nsurlrequest_proto_prop_obj_<n>, through -decodeObjectOfClasses:forKey:. A response archived by a plain
// archiver carries those fields in its unkeyed sequence instead, which answers the reads here, each checked
// against the classes the read names.
static BOOL wk_isUnkeyedResponseField(id coder, NSString *key)
{
    return [coder requiresSecureCoding] && [key hasPrefix:@"__nsurlrequest_proto_prop_obj_"]
        && ![coder containsValueForKey:@"__nsurlrequest_proto_prop_obj_0"];
}
static id wk_decodeUnkeyedResponseField(id coder, NSSet *classes)
{
    NSMutableArray *allowed = wk_pointerIvar(wk_pointerIvar(coder, wk_helper), wk_allowedClasses);
    NSUInteger depth = allowed.count;
    [allowed addObject:classes];
    @try {
        return [coder decodeObject];
    } @finally {
        while (allowed.count > depth)
            [allowed removeLastObject];
    }
}

static IMP wk_original_decodeObjectOfClass, wk_original_decodeObjectOfClasses;
static id wk_decodeObjectOfClass(id self, SEL selector, Class cls, NSString *key)
{
    WK_DECODE_BODY(((id (*)(id, SEL, Class, NSString *))wk_original_decodeObjectOfClass)(self, selector, cls, key), nil);
}
static id wk_decodeObjectOfClasses(id self, SEL selector, NSSet *classes, NSString *key)
{
    if (wk_isUnkeyedResponseField(self, key)) {
        WK_DECODE_BODY(wk_decodeUnkeyedResponseField(self, classes), nil);
    }
    WK_DECODE_BODY(((id (*)(id, SEL, NSSet *, NSString *))wk_original_decodeObjectOfClasses)(self, selector, classes, key), nil);
}

static IMP wk_original_decodeBytesForKey, wk_original_decodeBytesWithReturnedLength;
static const uint8_t *wk_decodeBytesForKey(id self, SEL selector, NSString *key, NSUInteger *length)
{
    if (length)
        *length = 0;
    WK_DECODE_BODY(((const uint8_t *(*)(id, SEL, NSString *, NSUInteger *))wk_original_decodeBytesForKey)(self, selector, key, length), (length ? (*length = 0) : 0, NULL));
}
static void *wk_decodeBytesWithReturnedLength(id self, SEL selector, NSUInteger *length)
{
    if (length)
        *length = 0;
    WK_DECODE_BODY(((void *(*)(id, SEL, NSUInteger *))wk_original_decodeBytesWithReturnedLength)(self, selector, length), (length ? (*length = 0) : 0, NULL));
}

// Native XML container entries carry a retain outside the array's non-owning callbacks; only _flags bit 0
// is container state.
static void wk_restoreContainers(id coder, uint32_t flags, CFIndex depth)
{
    uint32_t *currentFlags = wk_ivarAddress(coder, wk_flags);
    *currentFlags = (*currentFlags & ~1u) | (flags & 1u);
    CFMutableArrayRef containers = wk_pointerIvar(coder, wk_containers);
    while (containers && CFArrayGetCount(containers) > depth) {
        CFIndex index = CFArrayGetCount(containers) - 1;
        CFTypeRef object = CFArrayGetValueAtIndex(containers, index);
        CFArrayRemoveValueAtIndex(containers, index);
        CFRelease(object);
    }
}

// Native -_decodeArrayOfObjectsForKey: decodes its elements through Foundation's C decoders, not the public
// methods. Here each element observes the recorded error and the strict class check. Binary elements use
// __decodeObjectBinary(coder, uid, key); XML elements use __decodeObjectXML(coder, @"") over a copy of the
// raw UID array pushed on the native container stack. Both return +1 objects.
static id wk_decodeNativeArray(id self, NSString *key)
{
    NSArray *references = ((id (*)(id, SEL, NSString *))wk_nativePropertyList)(self, sel_registerName("_decodePropertyListForKey:"), key);
    if (!references)
        return nil;
    if (CFGetTypeID((CFTypeRef)references) != CFArrayGetTypeID())
        [NSException raise:NSInvalidUnarchiveOperationException format:@"Archive array is not an array for %@", key];
    NSString *binaryKey = [key hasPrefix:@"$"] ? [key substringFromIndex:1] : key;
    NSUInteger count = references.count;
    NSMutableArray *objects = [NSMutableArray arrayWithCapacity:count];
    CFMutableArrayRef containers = wk_pointerIvar(self, wk_containers);
    uint32_t flags;
    memcpy(&flags, wk_ivarAddress(self, wk_flags), sizeof(flags));
    CFIndex depth = containers ? CFArrayGetCount(containers) : 0;
    BOOL missing = NO;
    BOOL strict = wk_strictSecureDecoding(self);
    @try {
        if (containers) {
            CFMutableArrayRef pending = CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, (CFArrayRef)references);
            CFArrayAppendValue(containers, pending);
            *(uint32_t *)wk_ivarAddress(self, wk_flags) |= 1u;
        }
        for (NSUInteger index = 0; index < count; ++index) {
            if (wk_coderError(self))
                return nil;
            id object;
            CFTypeRef uid = (CFTypeRef)references[index];
            BOOL isReference = CFGetTypeID(uid) == wk_uidTypeID();
            if (strict && isReference && wk_uidValue(uid))
                wk_validateInlineValue(self, wk_uidValue(uid), containers ? @"" : binaryKey);
            if (containers)
                object = wk_nativeDecodeXML(self, @"");
            else {
                if (!isReference)
                    [NSException raise:NSInvalidUnarchiveOperationException format:@"Archive array contains a non-object reference for %@", key];
                object = wk_nativeDecodeBinary(self, wk_uidValue(uid), binaryKey);
            }
            @try {
                if (wk_coderError(self))
                    return nil;
                if (object)
                    [objects addObject:object];
                else
                    missing = YES;
            } @finally {
                [object release];
            }
        }
        return missing ? nil : [[objects copy] autorelease];
    } @finally {
        wk_restoreContainers(self, flags, depth);
    }
}

static IMP wk_original_decodeArrayOfObjects;
static id wk_decodeArrayOfObjects(id self, SEL selector, NSString *key)
{
    if (!wk_returnsErrors(self) && !wk_strictSecureDecoding(self))
        return ((id (*)(id, SEL, NSString *))wk_original_decodeArrayOfObjects)(self, selector, key);
    WK_DECODE_BODY(wk_decodeNativeArray(self, key), nil);
}
#undef WK_DECODE_BODY

static IMP wk_original_decodeValue, wk_original_decodeArray;
static void wk_decodeValueOrArray(id self, SEL selector, const char *type, NSUInteger count, void *output, BOOL array)
{
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    if (count && size > NSUIntegerMax / count)
        [NSException raise:NSInvalidArgumentException format:@"Decoded array size overflows"];
    size *= count;
    BOOL returnsErrors = wk_returnsErrors(self);
    if (returnsErrors && wk_coderError(self)) {
        memset(output, 0, size);
        return;
    }
    @try {
        // A keyed unarchiver reads an object value through the next generic key.
        if (!array && type && *type == '@' && wk_strictSecureDecoding(self))
            wk_validateStrictReference(self, wk_nextGenericKey(self));
        if (array)
            ((void (*)(id, SEL, const char *, NSUInteger, void *))wk_original_decodeArray)(self, selector, type, count, output);
        else
            ((void (*)(id, SEL, const char *, void *))wk_original_decodeValue)(self, selector, type, output);
        if (returnsErrors && wk_coderError(self))
            memset(output, 0, size);
    } @catch (NSException *exception) {
        if (!returnsErrors || !wk_isCodingException(exception))
            @throw;
        wk_setCoderError(self, wk_codingExceptionError(exception));
        memset(output, 0, size);
    }
}
static void wk_decodeValue(id self, SEL selector, const char *type, void *output)
{
    wk_decodeValueOrArray(self, selector, type, 1, output, NO);
}
static void wk_decodeArray(id self, SEL selector, const char *type, NSUInteger count, void *output)
{
    wk_decodeValueOrArray(self, selector, type, count, output, YES);
}

static IMP wk_original_validateAllowedClass;
static void wk_validateAllowedClass(id self, SEL selector, Class cls, NSString *key)
{
    ((void (*)(id, SEL, Class, NSString *))wk_original_validateAllowedClass)(self, selector, cls, key);
    if (wk_strictSecureDecoding(self) && ![[self allowedClasses] containsObject:cls])
        [NSException raise:NSInvalidUnarchiveOperationException format:@"Strict secure decoding rejects class %@ for %@", cls, key];
}

static Class wk_unarchiverClass;

static void wk_override(SEL selector, IMP replacement, IMP *original)
{
    Method method = class_getInstanceMethod(NSKeyedUnarchiver.class, selector);
    *original = method_getImplementation(method);
    class_addMethod(wk_unarchiverClass, selector, replacement, method_getTypeEncoding(method));
}

static void wk_buildKeyedUnarchiverClass(void *context)
{
    (void)context;
    Class coder = NSKeyedUnarchiver.class;
    Class helper = objc_getClass("_NSKeyedUnarchiverHelper");
    wk_genericKey = class_getInstanceVariable(coder, "_genericKey");
    wk_flags = class_getInstanceVariable(coder, "_flags");
    wk_offsetData = class_getInstanceVariable(coder, "_offsetData");
    wk_containers = class_getInstanceVariable(coder, "_containers");
    wk_helper = class_getInstanceVariable(coder, "_helper");
    wk_allowedClasses = class_getInstanceVariable(helper, "_allowedClasses");
    wk_archiveBytes = class_getInstanceVariable(coder, "_bytes");
    wk_archiveLength = class_getInstanceVariable(coder, "_len");
    wk_archiveObjects = class_getInstanceVariable(coder, "_objects");
    wk_binaryObjectCache = class_getInstanceVariable(coder, "_reserved0");
    wk_image foundation, coreFoundation;
    wk_find_image("/Foundation.framework/Versions/C/Foundation", &foundation);
    wk_find_image("/CoreFoundation.framework/Versions/A/CoreFoundation", &coreFoundation);
    wk_nativeDecodeBinary = wk_symbol_in_image(&foundation, "__decodeObjectBinary");
    wk_nativeDecodeXML = wk_symbol_in_image(&foundation, "__decodeObjectXML");
    wk_uidTypeID = wk_symbol_in_image(&coreFoundation, "__CFKeyedArchiverUIDGetTypeID");
    wk_uidValue = wk_symbol_in_image(&coreFoundation, "__CFKeyedArchiverUIDGetValue");
    wk_binaryDictionaryValueOffset = wk_symbol_in_image(&coreFoundation, "___CFBinaryPlistGetOffsetForValueFromDictionary3");
    wk_binaryArrayValueOffset = wk_symbol_in_image(&coreFoundation, "___CFBinaryPlistGetOffsetForValueFromArray2");
    wk_binaryCreateObject = wk_symbol_in_image(&coreFoundation, "___CFBinaryPlistCreateObject");
    wk_nativePropertyList = method_getImplementation(class_getInstanceMethod(coder, sel_registerName("_decodePropertyListForKey:")));

    wk_unarchiverClass = objc_allocateClassPair(coder, "WKPolyfillPriv_KeyedUnarchiver", 0);
#define OVERRIDE(name, methodName) wk_override(@selector(methodName), (IMP)wk_##name, &wk_original_##name)
    OVERRIDE(decodeArrayOfObjects, _decodeArrayOfObjectsForKey:);
    OVERRIDE(decodeObjectForKey, decodeObjectForKey:);
    OVERRIDE(decodeBoolForKey, decodeBoolForKey:);
    OVERRIDE(decodeIntForKey, decodeIntForKey:);
    OVERRIDE(decodeInt32ForKey, decodeInt32ForKey:);
    OVERRIDE(decodeInt64ForKey, decodeInt64ForKey:);
    OVERRIDE(decodeIntegerForKey, decodeIntegerForKey:);
    OVERRIDE(decodeFloatForKey, decodeFloatForKey:);
    OVERRIDE(decodeDoubleForKey, decodeDoubleForKey:);
    OVERRIDE(decodePropertyListForKey, decodePropertyListForKey:);
    OVERRIDE(decodePointForKey, decodePointForKey:);
    OVERRIDE(decodeSizeForKey, decodeSizeForKey:);
    OVERRIDE(decodeRectForKey, decodeRectForKey:);
    OVERRIDE(decodeObject, decodeObject);
    OVERRIDE(decodeDataObject, decodeDataObject);
    OVERRIDE(decodePropertyList, decodePropertyList);
    OVERRIDE(decodePoint, decodePoint);
    OVERRIDE(decodeSize, decodeSize);
    OVERRIDE(decodeRect, decodeRect);
    OVERRIDE(decodeObjectOfClass, decodeObjectOfClass:forKey:);
    OVERRIDE(decodeObjectOfClasses, decodeObjectOfClasses:forKey:);
    OVERRIDE(decodeBytesForKey, decodeBytesForKey:returnedLength:);
    OVERRIDE(decodeBytesWithReturnedLength, decodeBytesWithReturnedLength:);
    OVERRIDE(decodeValue, decodeValueOfObjCType:at:);
    OVERRIDE(decodeArray, decodeArrayOfObjCType:count:at:);
    OVERRIDE(validateAllowedClass, validateAllowedClass:forKey:);
#undef OVERRIDE
    objc_registerClassPair(wk_unarchiverClass);
}

static Class wk_keyedUnarchiverClass(void)
{
    static dispatch_once_t once;
    dispatch_once_f(&once, NULL, wk_buildKeyedUnarchiverClass);
    return wk_unarchiverClass;
}

// A classic unarchiver adopts this layer's decoders; the subclass adds no storage.
static void wk_adoptKeyedUnarchiver(id coder)
{
    Class cls = wk_keyedUnarchiverClass();
    if (object_getClass(coder) == NSKeyedUnarchiver.class)
        object_setClass(coder, cls);
}

static void wk_setPolicy(id coder, NSDecodingFailurePolicy policy)
{
    if (policy != NSDecodingFailurePolicyRaiseException && policy != NSDecodingFailurePolicySetErrorAndReturn)
        [NSException raise:NSInvalidArgumentException format:@"Invalid decoding failure policy"];
    if (policy == NSDecodingFailurePolicySetErrorAndReturn)
        wk_adoptKeyedUnarchiver(coder);
    wk_coderState(coder, YES)->policy = policy;
}

static id wk_initializeUnarchiver(id object, NSData *data, NSError **error)
{
    if (error) *error = nil;
    @try {
        object = [object initForReadingWithData:data];
        if (!object && error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError userInfo:nil];
        return object;
    } @catch (NSException *exception) {
        if (!wk_isCodingException(exception) && ![exception.name isEqual:NSInvalidArgumentException])
            @throw;
        if (error) *error = wk_codingExceptionError(exception);
        return nil;
    }
}

// The root under the archive's root key, in the classes given; a failure, including a root outside those
// classes under secure coding, is the returned error.
static id wk_topLevelDecode(NSKeyedUnarchiver *coder, NSSet *classes, NSError **error)
{
    NSError *failure = nil;
    id result = nil;
    @try {
        result = [coder decodeObjectOfClasses:classes forKey:NSKeyedArchiveRootObjectKey];
        if (result && coder.requiresSecureCoding) {
            BOOL allowed = NO;
            for (Class cls in classes) {
                if ([result isKindOfClass:cls]) { allowed = YES; break; }
            }
            if (!allowed)
                wk_fail(coder, @"Decoded root is outside the allowed classes");
        }
        failure = wk_coderError(coder);
    } @catch (NSException *exception) {
        if (!wk_isCodingException(exception))
            @throw;
        failure = wk_codingExceptionError(exception);
    }
    if (error)
        *error = [[failure retain] autorelease];
    return failure ? nil : result;
}

static id wk_unarchive(Class cls, NSSet *classes, NSData *data, NSError **error, BOOL strict)
{
    NSKeyedUnarchiver *coder = nil;
    id result = nil;
    if (error) *error = nil;
    @try {
        Class unarchiverClass = cls == NSKeyedUnarchiver.class ? wk_keyedUnarchiverClass() : cls;
        coder = wk_initializeUnarchiver([unarchiverClass alloc], data, error);
        if (!coder)
            return nil;
        coder.requiresSecureCoding = YES;
        wk_setPolicy(coder, NSDecodingFailurePolicySetErrorAndReturn);
        wk_coderState(coder, YES)->strict = strict;
        result = [wk_topLevelDecode(coder, classes, error) retain];
    } @catch (NSException *exception) {
        if (!wk_isCodingException(exception))
            @throw;
        if (error) *error = wk_codingExceptionError(exception);
    } @finally {
        [coder finishDecoding];
        [coder release];
    }
    return [result autorelease];
}

// Classic unarchivers default to NSDecodingFailurePolicyRaiseException; -initForReadingFromData:error:
// requires secure coding and defaults to NSDecodingFailurePolicySetErrorAndReturn.
WK_POLYFILL_ADD_METHODS(NSKeyedUnarchiver)
- (instancetype)initForReadingFromData:(NSData *)data error:(NSError **)error
{
    wk_adoptKeyedUnarchiver(self);
    NSKeyedUnarchiver *coder = wk_initializeUnarchiver(self, data, error);
    if (!coder)
        return nil;
    coder.requiresSecureCoding = YES;
    wk_setPolicy(coder, NSDecodingFailurePolicySetErrorAndReturn);
    return (id)coder;
}
- (void)setDecodingFailurePolicy:(NSDecodingFailurePolicy)policy
{
    wk_setPolicy(self, policy);
}
+ (id)unarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error
{
    return wk_unarchive(self, classes, data, error, NO);
}
+ (id)unarchivedObjectOfClass:(Class)cls fromData:(NSData *)data error:(NSError **)error
{
    return wk_unarchive(self, cls ? [NSSet setWithObject:cls] : nil, data, error, NO);
}
// Strict secure decoding admits exactly the allowed classes, subclasses included only when listed, checked
// before an object is allocated, and holds an inline property-list value to the same rule.
+ (id)_strictlyUnarchivedObjectOfClasses:(NSSet *)classes fromData:(NSData *)data error:(NSError **)error
{
    return wk_unarchive(self, classes, data, error, YES);
}
@end

WK_POLYFILL_ADD_METHODS(NSKeyedArchiver)
- (instancetype)initRequiringSecureCoding:(BOOL)requiresSecureCoding
{
    NSKeyedArchiver *archiver = [(NSKeyedArchiver *)self initForWritingWithMutableData:[NSMutableData data]];
    archiver.requiresSecureCoding = requiresSecureCoding;
    return (id)archiver;
}
// The archiver's own data stream, finished: the caller's mutable buffer when it supplied one.
- (NSData *)encodedData
{
    [(NSKeyedArchiver *)self finishEncoding];
    CFTypeRef stream = wk_pointerIvar(self, class_getInstanceVariable(NSKeyedArchiver.class, "_stream"));
    return stream && CFGetTypeID(stream) == CFDataGetTypeID() ? (NSData *)stream : nil;
}
+ (NSData *)archivedDataWithRootObject:(id)object requiringSecureCoding:(BOOL)requiresSecureCoding error:(NSError **)error
{
    if (error) *error = nil;
    NSKeyedArchiver *archiver = nil;
    NSData *result = nil;
    @try {
        archiver = [[self alloc] initRequiringSecureCoding:requiresSecureCoding];
        [archiver encodeObject:object forKey:NSKeyedArchiveRootObjectKey];
        result = [archiver.encodedData retain];
    } @catch (NSException *exception) {
        if (![exception.name isEqual:NSInvalidArchiveOperationException] && !wk_isCodingException(exception))
            @throw;
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderInvalidValueError
            userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Invalid object for keyed archive"}];
    } @finally {
        [archiver release];
    }
    return [result autorelease];
}
@end
