#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "wk_symbols.h"

#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wunguarded-availability"

typedef struct {
    NSDecodingFailurePolicy policy;
    NSUInteger depth;
    BOOL strict;
    void *transaction;
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

static NSDecodingFailurePolicy wk_getDecodingPolicy(id self, SEL selector)
{
    (void)selector;
    WKCoderState *state = wk_coderState(self, NO);
    return state ? state->policy : NSDecodingFailurePolicyRaiseException;
}

static void wk_setDecodingPolicy(id self, SEL selector, NSDecodingFailurePolicy policy)
{
    (void)selector;
    if (!self)
        return;
    if (policy != NSDecodingFailurePolicyRaiseException && policy != NSDecodingFailurePolicySetErrorAndReturn)
        [NSException raise:NSInvalidArgumentException format:@"Invalid decoding failure policy"];
    wk_coderState(self, YES)->policy = policy;
}

static NSError *wk_getDecodingError(id self, SEL selector)
{
    (void)selector;
    return [self decodingFailurePolicy] == NSDecodingFailurePolicySetErrorAndReturn ? wk_coderError(self) : nil;
}

static void wk_failWithError(id self, SEL selector, NSError *error)
{
    (void)selector;
    if (!error)
        [NSException raise:NSInvalidArgumentException format:@"A decoding failure requires an error"];
    if ([self decodingFailurePolicy] == NSDecodingFailurePolicySetErrorAndReturn) {
        wk_setCoderError(self, error);
        return;
    }
    @throw [NSException exceptionWithName:NSInvalidUnarchiveOperationException reason:error.localizedDescription
        userInfo:@{NSUnderlyingErrorKey:error}];
}

static Ivar wk_genericKey, wk_flags, wk_offsetData, wk_containers, wk_helper, wk_allowedClasses, wk_lastRef, wk_temporaryObjects, wk_archiveStream;
static Ivar wk_objectReferences, wk_referenceObjects, wk_replacements;

static void *wk_ivarAddress(id object, Ivar ivar) { return (char *)object + ivar_getOffset(ivar); }
static void *wk_pointerIvar(id object, Ivar ivar)
{
    void *value = NULL;
    if (object)
        memcpy(&value, wk_ivarAddress(object, ivar), sizeof(value));
    return value;
}

typedef struct {
    int32_t genericKey;
    uint32_t flags;
    uint32_t lastRef;
    uint64_t offset;
    NSUInteger allowedDepth;
    CFIndex containerDepth;
} WKDecodePosition;

static WKDecodePosition wk_decodePosition(id coder)
{
    WKDecodePosition position = { 0 };
    memcpy(&position.genericKey, wk_ivarAddress(coder, wk_genericKey), sizeof(position.genericKey));
    memcpy(&position.flags, wk_ivarAddress(coder, wk_flags), sizeof(position.flags));
    id helper = wk_pointerIvar(coder, wk_helper);
    if (helper) {
        memcpy(&position.lastRef, wk_ivarAddress(helper, wk_lastRef), sizeof(position.lastRef));
        position.allowedDepth = [(NSArray *)wk_pointerIvar(helper, wk_allowedClasses) count];
    }
    void *offsetData = wk_pointerIvar(coder, wk_offsetData);
    // Native binary archive cursor: the current container occupies byte 32 of its 48-byte offset record.
    if (offsetData)
        memcpy(&position.offset, (char *)offsetData + 32, sizeof(position.offset));
    CFArrayRef containers = wk_pointerIvar(coder, wk_containers);
    position.containerDepth = containers ? CFArrayGetCount(containers) : 0;
    return position;
}

static void wk_restoreContainerPosition(id coder, WKDecodePosition position)
{
    uint32_t *flags = wk_ivarAddress(coder, wk_flags);
    *flags = (*flags & ~1u) | (position.flags & 1u);
    CFMutableArrayRef containers = wk_pointerIvar(coder, wk_containers);
    // Native XML container entries carry a retain outside the array's non-owning callbacks.
    while (containers && CFArrayGetCount(containers) > position.containerDepth) {
        CFIndex index = CFArrayGetCount(containers) - 1;
        CFTypeRef object = CFArrayGetValueAtIndex(containers, index);
        CFArrayRemoveValueAtIndex(containers, index);
        CFRelease(object);
    }
}

static void wk_restoreDecodePosition(id coder, WKDecodePosition position)
{
    memcpy(wk_ivarAddress(coder, wk_genericKey), &position.genericKey, sizeof(position.genericKey));
    id helper = wk_pointerIvar(coder, wk_helper);
    if (helper) {
        memcpy(wk_ivarAddress(helper, wk_lastRef), &position.lastRef, sizeof(position.lastRef));
        NSMutableArray *allowed = wk_pointerIvar(helper, wk_allowedClasses);
        while (allowed.count > position.allowedDepth)
            [allowed removeLastObject];
    }
    void *offsetData = wk_pointerIvar(coder, wk_offsetData);
    if (offsetData)
        memcpy((char *)offsetData + 32, &position.offset, sizeof(position.offset));
    wk_restoreContainerPosition(coder, position);
}

typedef struct {
    CFMutableDictionaryRef map;
    const void *key;
    const void *oldValue;
    BOOL existed;
    BOOL objectKey;
    BOOL objectValue;
} WKCacheUndo;

typedef struct {
    WKCacheUndo *records;
    size_t count;
    size_t capacity;
} WKCacheTransaction;

typedef struct WKActiveDecode {
    id coder;
    WKCacheTransaction *transaction;
    struct WKActiveDecode *previous;
} WKActiveDecode;
static __thread WKActiveDecode *wk_activeDecode;

static void wk_reserveUndoRecord(WKCacheTransaction *transaction)
{
    if (transaction->count == transaction->capacity) {
        size_t capacity = transaction->capacity ? transaction->capacity * 2 : 16;
        if (capacity < transaction->capacity || capacity > SIZE_MAX / sizeof(WKCacheUndo))
            [NSException raise:NSMallocException format:@"Keyed archive undo journal is too large"];
        void *records = realloc(transaction->records, capacity * sizeof(WKCacheUndo));
        if (!records)
            [NSException raise:NSMallocException format:@"Cannot allocate keyed archive undo journal"];
        transaction->records = records;
        transaction->capacity = capacity;
    }
}

static void wk_journalCacheMutation(CFMutableDictionaryRef map, const void *key)
{
    for (WKActiveDecode *active = wk_activeDecode; active; active = active->previous) {
        BOOL objectKey, objectValue;
        if (map == wk_pointerIvar(active->coder, wk_objectReferences)) {
            objectKey = YES;
            objectValue = NO;
        } else if (map == wk_pointerIvar(active->coder, wk_referenceObjects)) {
            objectKey = NO;
            objectValue = YES;
        } else if (map == wk_pointerIvar(active->coder, wk_replacements)) {
            objectKey = YES;
            objectValue = YES;
        } else if (map == wk_pointerIvar(active->coder, wk_temporaryObjects)) {
            // Temporary values may name an allocation consumed by initWithCoder:. Undo stores raw slots.
            objectKey = NO;
            objectValue = NO;
        } else
            continue;
        WKCacheTransaction *transaction = active->transaction;
        wk_reserveUndoRecord(transaction);
        const void *oldValue = NULL;
        BOOL existed = CFDictionaryGetValueIfPresent(map, key, &oldValue);
        CFRetain(map);
        if (objectKey && key) CFRetain(key);
        if (objectValue && existed && oldValue) CFRetain(oldValue);
        transaction->records[transaction->count++] = (WKCacheUndo) { map, key, oldValue, existed, objectKey, objectValue };
        return;
    }
}

// Foundation's cache commits participate in the active decoder transaction; other CF dictionaries retain native behavior.
static void wk_foundationCacheSetValue(CFMutableDictionaryRef map, const void *key, const void *value)
{
    wk_journalCacheMutation(map, key);
    CFDictionarySetValue(map, key, value);
}
static void wk_foundationCacheRemoveValue(CFMutableDictionaryRef map, const void *key)
{
    wk_journalCacheMutation(map, key);
    CFDictionaryRemoveValue(map, key);
}

static void wk_finishCacheRecords(WKCacheTransaction *transaction, size_t savepoint, BOOL rollback)
{
    while (transaction->count > savepoint) {
        WKCacheUndo record = transaction->records[--transaction->count];
        if (rollback) {
            if (record.existed)
                CFDictionarySetValue(record.map, record.key, record.oldValue);
            else
                CFDictionaryRemoveValue(record.map, record.key);
        }
        if (record.objectKey && record.key) CFRelease(record.key);
        if (record.objectValue && record.existed && record.oldValue) CFRelease(record.oldValue);
        CFRelease(record.map);
    }
}

typedef struct {
    WKCoderState *state;
    WKDecodePosition position;
    WKCacheTransaction storage;
    WKActiveDecode active;
    size_t savepoint;
} WKDecodeScope;

static void wk_beginDecode(id coder, WKCoderState *state, WKDecodeScope *scope)
{
    memset(scope, 0, sizeof(*scope));
    scope->state = state;
    scope->position = wk_decodePosition(coder);
    if (!state->depth)
        state->transaction = &scope->storage;
    WKCacheTransaction *transaction = state->transaction;
    scope->savepoint = transaction->count;
    scope->active = (WKActiveDecode) { coder, transaction, wk_activeDecode };
    if (!wk_activeDecode || wk_activeDecode->coder != coder)
        wk_activeDecode = &scope->active;
    ++state->depth;
}

static void wk_endDecode(id coder, WKDecodeScope *scope, BOOL failed)
{
    WKCoderState *state = scope->state;
    WKCacheTransaction *transaction = scope->active.transaction;
    wk_activeDecode = scope->active.previous;
    --state->depth;
    if (failed) {
        wk_restoreDecodePosition(coder, scope->position);
        wk_finishCacheRecords(transaction, scope->savepoint, YES);
    }
    if (!state->depth) {
        wk_finishCacheRecords(transaction, 0, NO);
        free(transaction->records);
        state->transaction = NULL;
    }
}

// Each native decode boundary restores its cursor while propagating a failure. Successful object caches remain native.
#define WK_DECODE_BODY(call, empty) \
    WKCoderState *state = wk_coderState(self, NO); \
    if (!state && [self decodingFailurePolicy] == NSDecodingFailurePolicySetErrorAndReturn) state = wk_coderState(self, YES); \
    if (!state) return (call); \
    if (wk_coderError(self)) return (empty); \
    WKDecodeScope scope; \
    wk_beginDecode(self, state, &scope); \
    BOOL failed = NO; \
    @try { \
        __typeof__(call) result = (call); \
        if (wk_coderError(self)) { failed = YES; return (empty); } \
        return result; \
    } @catch (NSException *exception) { \
        failed = YES; \
        if ([self decodingFailurePolicy] == NSDecodingFailurePolicySetErrorAndReturn && wk_isCodingException(exception)) { \
            wk_setCoderError(self, wk_codingExceptionError(exception)); \
            return (empty); \
        } \
        @throw; \
    } @finally { \
        wk_endDecode(self, &scope, failed); \
    }

#define WK_KEY_DECODER(name, type, empty) \
    static IMP wk_original_##name; \
    static type wk_##name(id self, SEL selector, NSString *key) { \
        WK_DECODE_BODY(((type (*)(id, SEL, NSString *))wk_original_##name)(self, selector, key), empty); \
    }
WK_KEY_DECODER(decodeObjectForKey, id, nil)
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

#define WK_UNKEYED_DECODER(name, type, empty) \
    static IMP wk_original_##name; \
    static type wk_##name(id self, SEL selector) { \
        WK_DECODE_BODY(((type (*)(id, SEL))wk_original_##name)(self, selector), empty); \
    }
WK_UNKEYED_DECODER(decodeObject, id, nil)
WK_UNKEYED_DECODER(decodeDataObject, id, nil)
WK_UNKEYED_DECODER(decodePropertyList, id, nil)
WK_UNKEYED_DECODER(decodePoint, NSPoint, NSZeroPoint)
WK_UNKEYED_DECODER(decodeSize, NSSize, NSZeroSize)
WK_UNKEYED_DECODER(decodeRect, NSRect, NSZeroRect)
#undef WK_UNKEYED_DECODER

static IMP wk_original_decodeObjectOfClass, wk_original_decodeObjectOfClasses;
static id wk_decodeObjectOfClass(id self, SEL selector, Class cls, NSString *key)
{
    WK_DECODE_BODY(((id (*)(id, SEL, Class, NSString *))wk_original_decodeObjectOfClass)(self, selector, cls, key), nil);
}
static id wk_decodeObjectOfClasses(id self, SEL selector, NSSet *classes, NSString *key)
{
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
static IMP wk_original_decodeArrayOfObjects, wk_nativePropertyList;
static id (*wk_nativeDecodeBinary)(id, uint32_t, NSString *);
static id (*wk_nativeDecodeXML)(id, NSString *);
static CFTypeID (*wk_uidTypeID)(void);
static uint32_t (*wk_uidValue)(CFTypeRef);

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
    WKDecodePosition position = wk_decodePosition(self);
    BOOL missing = NO;
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
            if (containers)
                object = wk_nativeDecodeXML(self, @"");
            else {
                CFTypeRef uid = (CFTypeRef)references[index];
                if (CFGetTypeID(uid) != wk_uidTypeID())
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
        wk_restoreContainerPosition(self, position);
    }
}

// The native collection helper calls the C decoders directly. Each element observes the pending error.
static id wk_decodeArrayOfObjects(id self, SEL selector, NSString *key)
{
    if (!wk_coderState(self, NO) && [self decodingFailurePolicy] != NSDecodingFailurePolicySetErrorAndReturn)
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
    WKCoderState *state = wk_coderState(self, NO);
    if (!state && [self decodingFailurePolicy] == NSDecodingFailurePolicySetErrorAndReturn)
        state = wk_coderState(self, YES);
    if (state && wk_coderError(self)) {
        memset(output, 0, size);
        return;
    }
    WKDecodeScope scope;
    if (state) wk_beginDecode(self, state, &scope);
    BOOL failed = NO;
    @try {
        if (array)
            ((void (*)(id, SEL, const char *, NSUInteger, void *))wk_original_decodeArray)(self, selector, type, count, output);
        else
            ((void (*)(id, SEL, const char *, void *))wk_original_decodeValue)(self, selector, type, output);
        if (state && wk_coderError(self)) {
            failed = YES;
            memset(output, 0, size);
        }
    } @catch (NSException *exception) {
        failed = YES;
        if (!state || [self decodingFailurePolicy] != NSDecodingFailurePolicySetErrorAndReturn || !wk_isCodingException(exception))
            @throw;
        wk_setCoderError(self, wk_codingExceptionError(exception));
        memset(output, 0, size);
    } @finally {
        if (state) wk_endDecode(self, &scope, failed);
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
static id wk_topLevelDecode(NSCoder *coder, NSSet *classes, NSString *key, NSError **error, BOOL unkeyed, BOOL typed)
{
    wk_coderState(coder, YES);
    NSError *failure = wk_coderError(coder);
    id result = nil;
    @try {
        if (!failure) {
            result = unkeyed ? [coder decodeObject] : typed ? [coder decodeObjectOfClasses:classes forKey:key] : [coder decodeObjectForKey:key];
            if (result && typed && coder.requiresSecureCoding) {
                BOOL allowed = NO;
                for (Class cls in classes) {
                    if ([result isKindOfClass:cls]) { allowed = YES; break; }
                }
                if (!allowed)
                    [coder failWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
                        userInfo:@{NSLocalizedDescriptionKey:@"Decoded root is outside the allowed classes"}]];
            }
            failure = wk_coderError(coder);
        }
    } @catch (NSException *exception) {
        if (!wk_isCodingException(exception))
            @throw;
        failure = wk_codingExceptionError(exception);
    }
    if (error)
        *error = [[failure retain] autorelease];
    wk_setCoderError(coder, nil);
    return failure ? nil : result;
}
static id wk_decodeTopLevelObject(id self, SEL selector, NSError **error)
{
    (void)selector;
    return wk_topLevelDecode(self, nil, nil, error, YES, NO);
}
static id wk_decodeTopLevelObjectForKey(id self, SEL selector, NSString *key, NSError **error)
{
    (void)selector;
    return wk_topLevelDecode(self, nil, key, error, NO, NO);
}
static id wk_decodeTopLevelObjectOfClass(id self, SEL selector, Class cls, NSString *key, NSError **error)
{
    (void)selector;
    return wk_topLevelDecode(self, cls ? [NSSet setWithObject:cls] : nil, key, error, NO, YES);
}
static id wk_decodeTopLevelObjectOfClasses(id self, SEL selector, NSSet *classes, NSString *key, NSError **error)
{
    (void)selector;
    return wk_topLevelDecode(self, classes, key, error, NO, YES);
}

static IMP wk_original_validateAllowedClass;
static void wk_validateAllowedClass(id self, SEL selector, Class cls, NSString *key)
{
    ((void (*)(id, SEL, Class, NSString *))wk_original_validateAllowedClass)(self, selector, cls, key);
    WKCoderState *state = wk_coderState(self, NO);
    if (state && state->strict && [self requiresSecureCoding] && ![[self allowedClasses] containsObject:cls])
        [NSException raise:NSInvalidUnarchiveOperationException format:@"Strict secure decoding rejects class %@ for %@", cls, key];
}
static void wk_enableStrictSecureDecodingMode(id self, SEL selector)
{
    (void)selector;
    if (!self)
        return;
    [self setRequiresSecureCoding:YES];
    wk_coderState(self, YES)->strict = YES;
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

static id wk_initForReadingFromData(id self, SEL selector, NSData *data, NSError **error)
{
    (void)selector;
    self = wk_initializeUnarchiver(self, data, error);
    [self setRequiresSecureCoding:YES];
    wk_setDecodingPolicy(self, NULL, NSDecodingFailurePolicySetErrorAndReturn);
    return self;
}

static id wk_unarchive(id cls, NSSet *classes, NSData *data, NSError **error, BOOL secure, BOOL strict)
{
    NSKeyedUnarchiver *coder = nil;
    id result = nil;
    if (error) *error = nil;
    @try {
        coder = wk_initializeUnarchiver([cls alloc], data, error);
        if (!coder)
            return nil;
        coder.requiresSecureCoding = secure;
        wk_setDecodingPolicy(coder, NULL, NSDecodingFailurePolicySetErrorAndReturn);
        if (strict) wk_enableStrictSecureDecodingMode(coder, NULL);
        result = [wk_topLevelDecode(coder, classes, NSKeyedArchiveRootObjectKey, error, NO, secure) retain];
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
static id wk_unarchivedObjectOfClasses(id self, SEL selector, NSSet *classes, NSData *data, NSError **error)
{
    (void)selector;
    return wk_unarchive(self, classes, data, error, YES, NO);
}
static id wk_unarchivedObjectOfClass(id self, SEL selector, Class cls, NSData *data, NSError **error)
{
    (void)selector;
    return wk_unarchive(self, cls ? [NSSet setWithObject:cls] : nil, data, error, YES, NO);
}
static id wk_strictlyUnarchivedObjectOfClasses(id self, SEL selector, NSSet *classes, NSData *data, NSError **error)
{
    (void)selector;
    return wk_unarchive(self, classes, data, error, YES, YES);
}
static id wk_unarchiveTopLevelObjectWithData(id self, SEL selector, NSData *data, NSError **error)
{
    (void)selector;
    return wk_unarchive(self, nil, data, error, NO, NO);
}

static id wk_initRequiringSecureCoding(id self, SEL selector, BOOL secure)
{
    (void)selector;
    self = [self initForWritingWithMutableData:[NSMutableData data]];
    [self setRequiresSecureCoding:secure];
    return self;
}
static NSData *wk_encodedData(id self, SEL selector)
{
    (void)selector;
    [self finishEncoding];
    CFTypeRef stream = wk_pointerIvar(self, wk_archiveStream);
    return stream && CFGetTypeID(stream) == CFDataGetTypeID() ? (NSData *)stream : nil;
}
static NSData *wk_archivedDataWithRootObject(id self, SEL selector, id root, BOOL secure, NSError **error)
{
    (void)selector;
    if (error) *error = nil;
    NSKeyedArchiver *coder = nil;
    NSData *result = nil;
    @try {
        coder = wk_initRequiringSecureCoding([self alloc], NULL, secure);
        [coder encodeObject:root forKey:NSKeyedArchiveRootObjectKey];
        result = [wk_encodedData(coder, NULL) retain];
    } @catch (NSException *exception) {
        if (![exception.name isEqual:NSInvalidArchiveOperationException] && !wk_isCodingException(exception))
            @throw;
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderInvalidValueError
            userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Invalid object for keyed archive"}];
    } @finally {
        [coder release];
    }
    return [result autorelease];
}

static Ivar wk_codingIvar(Class cls, const char *name, NSUInteger expectedSize)
{
    Ivar ivar = class_getInstanceVariable(cls, name);
    NSUInteger size = 0;
    if (ivar) NSGetSizeAndAlignment(ivar_getTypeEncoding(ivar), &size, NULL);
    if (!ivar || size != expectedSize)
        wk_patch_fail("NSKeyedUnarchiver", "native coding field layout differs");
    return ivar;
}
static void wk_wrapDecoder(Class cls, SEL selector, IMP replacement, IMP *original)
{
    Method method = class_getInstanceMethod(cls, selector);
    if (!method)
        wk_patch_fail(sel_getName(selector), "native decoding method is absent");
    *original = method_getImplementation(method);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static void wk_writeCodingImport(void **slot, void *replacement)
{
    mach_vm_address_t address = (mach_vm_address_t)(uintptr_t)slot;
    mach_vm_address_t region;
    mach_vm_size_t regionSize;
    vm_region_submap_info_data_64_t info;
    natural_t depth = 0;
    for (;;) {
        region = address;
        regionSize = 0;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t result = mach_vm_region_recurse(mach_task_self(), &region, &regionSize, &depth,
            (vm_region_recurse_info_t)&info, &count);
        if (result != KERN_SUCCESS || address < region || address - region >= regionSize)
            wk_patch_fail("Foundation coding imports", "native import page did not resolve");
        if (!info.is_submap) break;
        ++depth;
    }
    mach_vm_size_t pageSize = (mach_vm_size_t)getpagesize();
    mach_vm_address_t page = address & ~(pageSize - 1);
    BOOL changeProtection = !(info.protection & VM_PROT_WRITE);
    if (changeProtection && mach_vm_protect(mach_task_self(), page, pageSize, false, info.protection | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        wk_patch_fail("Foundation coding imports", "native import page is not writable");
    __atomic_store_n(slot, replacement, __ATOMIC_RELEASE);
    if (changeProtection && mach_vm_protect(mach_task_self(), page, pageSize, false, info.protection) != KERN_SUCCESS)
        wk_patch_fail("Foundation coding imports", "native import page protections did not restore");
}

static void wk_bindCodingCacheImports(void)
{
    wk_image image;
    if (!wk_find_image("/Foundation.framework/Versions/C/Foundation", &image))
        wk_patch_fail("Foundation coding imports", "native Foundation image is absent");
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(image.index);
    const struct symtab_command *symbols = NULL;
    const struct dysymtab_command *dynamicSymbols = NULL;
    uintptr_t linkedit = 0;
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SYMTAB) symbols = (const void *)command;
        if (command->cmd == LC_DYSYMTAB) dynamicSymbols = (const void *)command;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (!strcmp(segment->segname, SEG_LINKEDIT))
                linkedit = image.slide + segment->vmaddr - segment->fileoff;
        }
    }
    if (!symbols || !dynamicSymbols || !linkedit)
        wk_patch_fail("Foundation coding imports", "native indirect symbol table is absent");
    const struct nlist_64 *table = (const void *)(linkedit + symbols->symoff);
    const char *strings = (const void *)(linkedit + symbols->stroff);
    const uint32_t *indirect = (const void *)(linkedit + dynamicSymbols->indirectsymoff);
    BOOL foundSet = NO, foundRemove = NO;
    command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; ++i, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)command;
        const struct section_64 *sections = (const void *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; ++s) {
            const struct section_64 *section = &sections[s];
            uint32_t kind = section->flags & SECTION_TYPE;
            if (kind != S_LAZY_SYMBOL_POINTERS && kind != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)(image.slide + section->addr);
            for (uint64_t slot = 0; slot < section->size / sizeof(void *); ++slot) {
                uint32_t index = indirect[section->reserved1 + slot];
                if (index & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                if (index >= symbols->nsyms || table[index].n_un.n_strx >= symbols->strsize)
                    wk_patch_fail("Foundation coding imports", "native indirect symbol index differs");
                const char *name = strings + table[index].n_un.n_strx;
                if (!strcmp(name, "_CFDictionarySetValue")) {
                    wk_writeCodingImport(slots + slot, (void *)wk_foundationCacheSetValue);
                    foundSet = YES;
                } else if (!strcmp(name, "_CFDictionaryRemoveValue")) {
                    wk_writeCodingImport(slots + slot, (void *)wk_foundationCacheRemoveValue);
                    foundRemove = YES;

                }
            }
        }
    }
    if (!foundSet || !foundRemove)
        wk_patch_fail("Foundation coding imports", "native cache mutation imports are absent");
}

void wk_initializeFoundationCoding(void)
{
    Class coder = NSKeyedUnarchiver.class;
    const void *installed = wk_coderKey("wk_keyedCodingInstalled");
    @synchronized (coder) {
        if (objc_getAssociatedObject(coder, installed))
            return;
        Class helper = objc_getClass("_NSKeyedUnarchiverHelper");
        wk_genericKey = wk_codingIvar(coder, "_genericKey", 4);
        wk_flags = wk_codingIvar(coder, "_flags", 4);
        wk_offsetData = wk_codingIvar(coder, "_offsetData", sizeof(void *));
        wk_containers = wk_codingIvar(coder, "_containers", sizeof(id));
        wk_helper = wk_codingIvar(coder, "_helper", sizeof(id));
        wk_temporaryObjects = wk_codingIvar(coder, "_tmpRefObjMap", sizeof(id));
        wk_objectReferences = wk_codingIvar(coder, "_objRefMap", sizeof(id));
        wk_referenceObjects = wk_codingIvar(coder, "_refObjMap", sizeof(id));
        wk_replacements = wk_codingIvar(coder, "_replacementMap", sizeof(id));
        wk_allowedClasses = wk_codingIvar(helper, "_allowedClasses", sizeof(id));
        wk_lastRef = wk_codingIvar(helper, "_lastRef", 4);
        wk_archiveStream = wk_codingIvar(NSKeyedArchiver.class, "_stream", sizeof(void *));
        wk_image foundation, coreFoundation;
        if (!wk_find_image("/Foundation.framework/Versions/C/Foundation", &foundation)
            || !wk_find_image("/CoreFoundation.framework/Versions/A/CoreFoundation", &coreFoundation))
            wk_patch_fail("Foundation coding", "native framework images are absent");
        wk_nativeDecodeBinary = wk_symbol_in_image(&foundation, "__decodeObjectBinary");
        wk_nativeDecodeXML = wk_symbol_in_image(&foundation, "__decodeObjectXML");
        wk_uidTypeID = wk_symbol_in_image(&coreFoundation, "__CFKeyedArchiverUIDGetTypeID");
        wk_uidValue = wk_symbol_in_image(&coreFoundation, "__CFKeyedArchiverUIDGetValue");
        Method propertyList = class_getInstanceMethod(coder, sel_registerName("_decodePropertyListForKey:"));
        wk_nativePropertyList = propertyList ? method_getImplementation(propertyList) : NULL;
        if (!wk_nativeDecodeBinary || !wk_nativeDecodeXML || !wk_uidTypeID || !wk_uidValue || !wk_nativePropertyList)
            wk_patch_fail("Foundation coding", "native archive array backend is absent");
        wk_bindCodingCacheImports();
#define WRAP(name, methodName) wk_wrapDecoder(coder, @selector(methodName), (IMP)wk_##name, &wk_original_##name)
        WRAP(decodeArrayOfObjects, _decodeArrayOfObjectsForKey:);
        WRAP(decodeObjectForKey, decodeObjectForKey:);
        WRAP(decodeBoolForKey, decodeBoolForKey:);
        WRAP(decodeIntForKey, decodeIntForKey:);
        WRAP(decodeInt32ForKey, decodeInt32ForKey:);
        WRAP(decodeInt64ForKey, decodeInt64ForKey:);
        WRAP(decodeIntegerForKey, decodeIntegerForKey:);
        WRAP(decodeFloatForKey, decodeFloatForKey:);
        WRAP(decodeDoubleForKey, decodeDoubleForKey:);
        WRAP(decodePropertyListForKey, decodePropertyListForKey:);
        WRAP(decodePointForKey, decodePointForKey:);
        WRAP(decodeSizeForKey, decodeSizeForKey:);
        WRAP(decodeRectForKey, decodeRectForKey:);
        WRAP(decodeObject, decodeObject);
        WRAP(decodeDataObject, decodeDataObject);
        WRAP(decodePropertyList, decodePropertyList);
        WRAP(decodePoint, decodePoint);
        WRAP(decodeSize, decodeSize);
        WRAP(decodeRect, decodeRect);
        WRAP(decodeObjectOfClass, decodeObjectOfClass:forKey:);
        WRAP(decodeObjectOfClasses, decodeObjectOfClasses:forKey:);
        WRAP(decodeBytesForKey, decodeBytesForKey:returnedLength:);
        WRAP(decodeBytesWithReturnedLength, decodeBytesWithReturnedLength:);
        WRAP(decodeValue, decodeValueOfObjCType:at:);
        WRAP(decodeArray, decodeArrayOfObjCType:count:at:);
        WRAP(validateAllowedClass, validateAllowedClass:forKey:);
#undef WRAP
#define ADD(cls, selector, function, types) class_addMethod(cls, sel_registerName(selector), (IMP)function, types)
        ADD(NSCoder.class, "decodingFailurePolicy", wk_getDecodingPolicy, "q@:");
        ADD(NSCoder.class, "error", wk_getDecodingError, "@@:");
        ADD(NSCoder.class, "failWithError:", wk_failWithError, "v@:@");
        ADD(NSCoder.class, "decodeTopLevelObjectAndReturnError:", wk_decodeTopLevelObject, "@@:^@");
        ADD(NSCoder.class, "decodeTopLevelObjectForKey:error:", wk_decodeTopLevelObjectForKey, "@@:@^@");
        ADD(NSCoder.class, "decodeTopLevelObjectOfClass:forKey:error:", wk_decodeTopLevelObjectOfClass, "@@:#@^@");
        ADD(NSCoder.class, "decodeTopLevelObjectOfClasses:forKey:error:", wk_decodeTopLevelObjectOfClasses, "@@:@@^@");
        ADD(coder, "setDecodingFailurePolicy:", wk_setDecodingPolicy, "v@:q");
        ADD(coder, "initForReadingFromData:error:", wk_initForReadingFromData, "@@:@^@");
        ADD(coder, "_enableStrictSecureDecodingMode", wk_enableStrictSecureDecodingMode, "v@:");
        Class meta = object_getClass(coder);
        ADD(meta, "unarchivedObjectOfClasses:fromData:error:", wk_unarchivedObjectOfClasses, "@@:@@^@");
        ADD(meta, "unarchivedObjectOfClass:fromData:error:", wk_unarchivedObjectOfClass, "@@:#@^@");
        ADD(meta, "_strictlyUnarchivedObjectOfClasses:fromData:error:", wk_strictlyUnarchivedObjectOfClasses, "@@:@@^@");
        ADD(meta, "unarchiveTopLevelObjectWithData:error:", wk_unarchiveTopLevelObjectWithData, "@@:@^@");
        ADD(NSKeyedArchiver.class, "initRequiringSecureCoding:", wk_initRequiringSecureCoding, "@@:c");
        ADD(NSKeyedArchiver.class, "encodedData", wk_encodedData, "@@:");
        ADD(object_getClass(NSKeyedArchiver.class), "archivedDataWithRootObject:requiringSecureCoding:error:", wk_archivedDataWithRootObject, "@@:@c^@");
#undef ADD
        objc_setAssociatedObject(coder, installed, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

__attribute__((constructor)) static void wk_initializeKeyedCodingCompatibility(void)
{
    wk_initializeFoundationCoding();
}
