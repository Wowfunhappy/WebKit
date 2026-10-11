// DataDetectors: DDSecureActionContext, the NSSecureCoding subclass of DDActionContext that WebKit
// soft-links (HAVE(SECURE_ACTION_CONTEXT)) and sends across IPC. 10.9's DDActionContext implements only
// NSCoding, and its secure-coding counterpart does not exist.
//
// DataDetectors is not linked into this dylib, so the class is built at first ask over the runtime's
// DDActionContext (WK_POLYFILL_CLASS_RESOLVED; PAL soft-links the framework before the class). It adds
// no instance variables: its archive is the native one, written by the inherited -encodeWithCoder:.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <string.h>
#include "wk_priv_class.h"

@interface NSDictionary (WKDDResultCoding)
- (CFTypeRef)dd_createResult CF_RETURNS_RETAINED;
@end

static void wk_invalidDDArchive(void)
{
    [NSException raise:NSInvalidUnarchiveOperationException format:@"Invalid Data Detectors result graph"];
}

// The native scanner's contextual-data decoder admits dictionaries and string/number/data scalars.
static void wk_validateDDContext(id root)
{
    if (!root)
        return;
    if (![root isKindOfClass:NSDictionary.class])
        wk_invalidDDArchive();
    CFMutableSetRef visited = CFSetCreateMutable(NULL, 0, NULL);
    @try {
        NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
        while (pending.count) {
            id object = [[[pending lastObject] retain] autorelease];
            [pending removeLastObject];
            if ([object isKindOfClass:NSDictionary.class]) {
                if (CFSetContainsValue(visited, object))
                    continue;
                CFSetAddValue(visited, object);
                for (id key in object) {
                    [pending addObject:key];
                    [pending addObject:[object objectForKey:key]];
                }
            } else if (![object isKindOfClass:NSString.class] && ![object isKindOfClass:NSNumber.class]
                && ![object isKindOfClass:NSData.class])
                wk_invalidDDArchive();
        }
    } @finally {
        CFRelease(visited);
    }
}

// Validate the entire SR tree before the native recursive dictionary-to-result converter runs.
static void wk_validateDDResult(id root)
{
    if (!root)
        return;
    CFMutableSetRef active = CFSetCreateMutable(NULL, 0, NULL);
    @try {
        NSMutableArray *pending = [NSMutableArray arrayWithObject:@[root, @NO]];
        while (pending.count) {
            NSArray *frame = [[[pending lastObject] retain] autorelease];
            [pending removeLastObject];
            id object = frame[0];
            if ([frame[1] boolValue]) {
                CFSetRemoveValue(active, object);
                continue;
            }
            if (![object isKindOfClass:NSDictionary.class] || CFSetContainsValue(active, object))
                wk_invalidDDArchive();
            CFSetAddValue(active, object);
            [pending addObject:@[object, @YES]];
            for (NSString *key in @[@"AR", @"T", @"MS", @"V"]) {
                id value = object[key];
                if (value && ![value isKindOfClass:NSString.class])
                    wk_invalidDDArchive();
            }
            wk_validateDDContext(object[@"C"]);
            id children = object[@"SR"];
            if (children && ![children isKindOfClass:NSArray.class])
                wk_invalidDDArchive();
            for (id child in children)
                [pending addObject:@[child, @NO]];
        }
    } @finally {
        CFRelease(active);
    }
}

static Class wk_DDActionContext;
static struct {
    const char *key;
    const char *ivarName;
    const char *className;
    Ivar ivar;
} wk_DDObjectFields[] = {
    { "eventTitle", "_eventTitle", "NSString", NULL },
    { "referenceDate", "_referenceDate", "NSDate", NULL },
    { "authorABUUID", "_authorABUUID", "NSString", NULL },
    { "authorEmailAddress", "_authorEmailAddress", "NSString", NULL },
    { "authorName", "_authorName", "NSString", NULL },
    { "matchedString", "_matchedString", "NSString", NULL },
    { "selectionString", "_selectionString", "NSString", NULL },
    { "url", "_url", "NSURL", NULL },
};
static Ivar wk_DDHighlightFrame, wk_DDAimFrame, wk_DDImmediate, wk_DDRightClick, wk_DDAllResults, wk_DDMainResult;

static void wk_DDSetValue(id object, Ivar ivar, const void *value, size_t size)
{
    memcpy((char *)object + ivar_getOffset(ivar), value, size);
}

static void wk_DDRetainObject(id object, Ivar ivar, id value)
{
    id retained = [value retain];
    id old = object_getIvar(object, ivar);
    object_setIvar(object, ivar, retained);
    [old release];
}

// A coder that does not require secure coding gets DDActionContext's own decoder. A secure one gets the
// native archive's fields decoded by type, each set the way the native decoder sets it: decoded objects
// retained, results rebuilt from their dictionaries once the whole result tree is validated.
static id wk_DDInitWithCoder(id self, SEL selector, NSCoder *coder)
{
    if (!coder.requiresSecureCoding) {
        struct objc_super superclass = { self, wk_DDActionContext };
        return ((id (*)(struct objc_super *, SEL, NSCoder *))objc_msgSendSuper)(&superclass, selector, coder);
    }
    self = [self init];
    if (!self)
        return nil;
    @try {
        NSRect highlight = [coder decodeRectForKey:@"highlightFrame"];
        NSRect aim = [coder decodeRectForKey:@"aimFrame"];
        wk_DDSetValue(self, wk_DDHighlightFrame, &highlight, sizeof(highlight));
        wk_DDSetValue(self, wk_DDAimFrame, &aim, sizeof(aim));
        for (size_t i = 0; i < sizeof(wk_DDObjectFields) / sizeof(wk_DDObjectFields[0]); ++i) {
            Class cls = objc_getClass(wk_DDObjectFields[i].className);
            id value = [coder decodeObjectOfClass:cls forKey:[NSString stringWithUTF8String:wk_DDObjectFields[i].key]];
            // Mavericks' unarchiver implicitly admits string/number/data scalars for every class set.
            if (value && ![value isKindOfClass:cls])
                wk_invalidDDArchive();
            wk_DDRetainObject(self, wk_DDObjectFields[i].ivar, value);
        }
        BOOL immediate = [coder decodeBoolForKey:@"immediate"];
        BOOL rightClick = [coder decodeBoolForKey:@"isRightClick"];
        wk_DDSetValue(self, wk_DDImmediate, &immediate, sizeof(immediate));
        wk_DDSetValue(self, wk_DDRightClick, &rightClick, sizeof(rightClick));
        NSSet *classes = [NSSet setWithObjects:NSDictionary.class, NSArray.class, NSString.class,
            NSNumber.class, NSData.class, nil];
        id allResults = [coder decodeObjectOfClasses:classes forKey:@"allResults"];
        id mainResult = [coder decodeObjectOfClasses:classes forKey:@"mainResult"];
        if (allResults && ![allResults isKindOfClass:NSArray.class])
            wk_invalidDDArchive();
        for (id dictionary in allResults)
            wk_validateDDResult(dictionary);
        wk_validateDDResult(mainResult);
        NSMutableArray *results = [NSMutableArray arrayWithCapacity:[allResults count]];
        for (NSDictionary *dictionary in allResults) {
            CFTypeRef result = [dictionary dd_createResult];
            @try {
                [results addObject:(id)result];
            } @finally {
                if (result)
                    CFRelease(result);
            }
        }
        wk_DDRetainObject(self, wk_DDAllResults, results);
        CFTypeRef result = [mainResult dd_createResult];
        CFTypeRef oldResult;
        memcpy(&oldResult, (char *)self + ivar_getOffset(wk_DDMainResult), sizeof(oldResult));
        wk_DDSetValue(self, wk_DDMainResult, &result, sizeof(result));
        if (oldResult)
            CFRelease(oldResult);
        return self;
    } @catch (NSException *exception) {
        [self release];
        @throw;
    }
}

// DDActionContext's copy is allocated as a DDActionContext; a copy of this class is one of this class.
static id wk_DDCopyWithZone(id self, SEL selector, NSZone *zone)
{
    struct objc_super superclass = { self, wk_DDActionContext };
    id copy = ((id (*)(struct objc_super *, SEL, NSZone *))objc_msgSendSuper)(&superclass, selector, zone);
    if (copy && object_getClass(copy) == wk_DDActionContext)
        object_setClass(copy, [self class]);
    return copy;
}

static BOOL wk_DDSupportsSecureCoding(id self, SEL selector)
{
    (void)self;
    (void)selector;
    return YES;
}

WK_POLYFILL_CLASS_RESOLVED("DataDetectors", DDSecureActionContext, wk_resolveDDSecureActionContext);
static void *wk_resolveDDSecureActionContext(void)
{
    static Class secureContext;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class context = objc_getClass("DDActionContext");
        for (size_t i = 0; i < sizeof(wk_DDObjectFields) / sizeof(wk_DDObjectFields[0]); ++i)
            wk_DDObjectFields[i].ivar = class_getInstanceVariable(context, wk_DDObjectFields[i].ivarName);
        wk_DDHighlightFrame = class_getInstanceVariable(context, "_highlightFrame");
        wk_DDAimFrame = class_getInstanceVariable(context, "_aimFrame");
        wk_DDImmediate = class_getInstanceVariable(context, "_immediate");
        wk_DDRightClick = class_getInstanceVariable(context, "_isRightClick");
        wk_DDAllResults = class_getInstanceVariable(context, "_allResults");
        wk_DDMainResult = class_getInstanceVariable(context, "_mainResult");
        wk_DDActionContext = context;
        Class cls = objc_allocateClassPair(context, "WKPolyfillPriv_DDSecureActionContext", 0);
        // class_addMethod's prototype takes IMP, so the method implementations reach it through the
        // cast the runtime's own headers require; the diagnostic stays armed everywhere else.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-mismatch"
        class_addMethod(cls, @selector(initWithCoder:), (IMP)wk_DDInitWithCoder, "@@:@");
        class_addMethod(cls, @selector(copyWithZone:), (IMP)wk_DDCopyWithZone, "@@:^{_NSZone=}");
        class_addMethod(object_getClass(cls), @selector(supportsSecureCoding), (IMP)wk_DDSupportsSecureCoding, "c@:");
#pragma clang diagnostic pop
        class_addProtocol(cls, @protocol(NSSecureCoding));
        objc_registerClassPair(cls);
        secureContext = cls;
    });
    return secureContext;
}
