#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld_images.h>
#include <pthread.h>
#include <string.h>
#include "wk_symbols.h"

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

static IMP wk_originalDDInitWithCoder;
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

static id wk_DDInitWithCoder(id self, SEL selector, NSCoder *coder)
{
    if (!coder.requiresSecureCoding)
        return ((id (*)(id, SEL, NSCoder *))wk_originalDDInitWithCoder)(self, selector, coder);
    self = [self init];
    if (!self)
        return nil;
    @try {
        NSRect highlight = [coder decodeRectForKey:@"highlightFrame"];
        NSRect aim = [coder decodeRectForKey:@"aimFrame"];
        wk_DDSetValue(self, wk_DDHighlightFrame, &highlight, sizeof(highlight));
        wk_DDSetValue(self, wk_DDAimFrame, &aim, sizeof(aim));
        // Native initWithCoder: retains decoded objects; the public property setters copy them.
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

static BOOL wk_DDSupportsSecureCoding(id self, SEL selector)
{
    (void)self;
    (void)selector;
    return YES;
}

static Ivar wk_DDIvar(Class cls, const char *name, const char *type, NSUInteger expectedSize)
{
    Ivar ivar = class_getInstanceVariable(cls, name);
    if (!ivar || strncmp(ivar_getTypeEncoding(ivar), type, strlen(type)))
        wk_patch_fail("DDActionContext", "native archive field layout differs");
    NSUInteger size = 0;
    NSGetSizeAndAlignment(ivar_getTypeEncoding(ivar), &size, NULL);
    if (size != expectedSize)
        wk_patch_fail("DDActionContext", "native archive field size differs");
    return ivar;
}

static void wk_installDDSecureCoding(void)
{
    Class cls = objc_getClass("DDActionContext");
    if (!cls)
        return;
    @synchronized (cls) {
        Protocol *protocol = objc_getProtocol("NSSecureCoding");
        if (!protocol)
            wk_patch_fail("DDActionContext", "Foundation secure-coding protocol is absent");
        if (class_conformsToProtocol(cls, protocol))
            return;
        Method method = class_getInstanceMethod(cls, @selector(initWithCoder:));
        if (!method || !class_getInstanceMethod(NSDictionary.class, @selector(dd_createResult)))
            wk_patch_fail("DDActionContext", "native archive schema is absent");
        for (size_t i = 0; i < sizeof(wk_DDObjectFields) / sizeof(wk_DDObjectFields[0]); ++i)
            wk_DDObjectFields[i].ivar = wk_DDIvar(cls, wk_DDObjectFields[i].ivarName, "@", sizeof(id));
        wk_DDHighlightFrame = wk_DDIvar(cls, "_highlightFrame", "{CGRect=", sizeof(NSRect));
        wk_DDAimFrame = wk_DDIvar(cls, "_aimFrame", "{CGRect=", sizeof(NSRect));
        wk_DDImmediate = wk_DDIvar(cls, "_immediate", @encode(BOOL), sizeof(BOOL));
        wk_DDRightClick = wk_DDIvar(cls, "_isRightClick", @encode(BOOL), sizeof(BOOL));
        wk_DDAllResults = wk_DDIvar(cls, "_allResults", "@", sizeof(id));
        wk_DDMainResult = wk_DDIvar(cls, "_mainResult", "^{__DDResult=", sizeof(CFTypeRef));
        wk_originalDDInitWithCoder = method_getImplementation(method);
        // Foundation sends these raw selectors, including for native copyWithZone: results.
        class_replaceMethod(cls, @selector(initWithCoder:), (IMP)wk_DDInitWithCoder, method_getTypeEncoding(method));
        class_replaceMethod(object_getClass(cls), @selector(supportsSecureCoding), (IMP)wk_DDSupportsSecureCoding, "c@:");
        if (!class_addProtocol(cls, protocol))
            wk_patch_fail("DDActionContext", "secure-coding protocol registration failed");
    }
}

static const char *wk_DDImageInitializing(uint32_t state, uint32_t count, const struct dyld_image_info *images)
{
    (void)state;
    (void)count;
    (void)images;
    wk_installDDSecureCoding();
    return NULL;
}

static void wk_watchDDImages(void)
{
    typedef void (*RegisterHandler)(uint32_t, bool, const char *(*)(uint32_t, uint32_t, const struct dyld_image_info *));
    RegisterHandler registerHandler = (RegisterHandler)dlsym(RTLD_DEFAULT, "dyld_register_image_state_change_handler");
    if (!registerHandler)
        wk_patch_fail("DDActionContext", "dyld class-initialization notification is absent");
    // State 45 follows Objective-C class registration and precedes image initializers.
    registerHandler(45, false, wk_DDImageInitializing);
    wk_installDDSecureCoding();
}

void wk_initializeDDSecureCoding(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, wk_watchDDImages);
}

__attribute__((constructor)) static void wk_initializeDataDetectorsCompatibility(void)
{
    wk_initializeDDSecureCoding();
}
