// DataDetectors: Objective-C methods on DataDetectors classes. The classes are private and not linked,
// so each block names its classes by string.

#import "wk_polyfill.h"
#import "wk_selref_scope.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------------------------------------------
// DDActionsManager's action-flow methods, sent unguarded by WebKit.
//
// -requestBubbleClosureUnanchorOnFailure: is sent from both view stacks' dismissal paths
// (WebViewImpl::dismissContentRelativeChildWindowsFromViewOnly, WK1's WebImmediateActionController
// _clearImmediateActionState). 10.9 has its two halves as separate primitives, -requestBubbleClosure and
// -unanchorBubbles, with no closure-failure signal to sequence them by, so the body requests closure and,
// when asked to unanchor on failure, also unanchors.
//
// +didUseActions / +shouldUseActionsWithContext: / -hasActionsForResult:actionContext: sit on the
// immediate-action flows. 10.9's flow has no use notification and no should-use gate, so the notification
// is empty and the gate answers YES; -hasActionsForResult:actionContext: answers through -actionsForResult:.
@interface DDActionsManager : NSObject
- (void)requestBubbleClosure;
- (void)unanchorBubbles;
- (NSArray *)actionsForResult:(id)result;
@end

WK_POLYFILL_ADD_METHODS_ON(NSObject, "DDActionsManager")
- (void)requestBubbleClosureUnanchorOnFailure:(BOOL)unanchorOnFailure
{
    DDActionsManager *manager = (DDActionsManager *)self;
    [manager requestBubbleClosure];
    if (unanchorOnFailure)
        [manager unanchorBubbles];
}
+ (void)didUseActions
{
}
+ (BOOL)shouldUseActionsWithContext:(id)context
{
    (void)context;
    return YES;
}
- (BOOL)hasActionsForResult:(id)result actionContext:(id)actionContext
{
    (void)actionContext;
    return [[(DDActionsManager *)self actionsForResult:result] count] > 0;
}
@end

// ---------------------------------------------------------------------------------------------------
// The allowed-action filter of a DDActionContext, and -[DDActionsManager menuItemsForValue:type:service:
// context:] taking one. 10.9's method reads its context as a dictionary, which +[DDActionContext
// contextFromDictionary:] turns back into a context, and its DDActionContext has no allowed-action list.
// Given a DDActionContext, the method passes the context's fields under the keys contextFromDictionary:
// reads (the author as the ABPerson its UUID names), then keeps the items whose action's UTI the context
// allows. 10.9 has no dictionary key for immediate, isRightClick, aimFrame, mainResult or highlightFrame.
// An item's action is the DDAction under "DDAction" in its represented dictionary, as
// DDMenuItemGetActionUTI reads it.
@interface DDAction : NSObject
- (NSString *)actionUTI;
@end

@interface DDActionContext : NSObject
- (NSString *)eventTitle;
- (NSDate *)referenceDate;
- (NSString *)authorUUID;
- (NSString *)authorName;
- (NSString *)authorEmailAddress;
- (NSURL *)URL;
- (NSString *)matchedString;
- (NSArray *)allResults;
- (NSString *)selectionString;
- (NSRect)highlightFrame;
- (NSRect)aimFrame;
- (CFTypeRef)mainResult;
- (BOOL)immediate;
- (BOOL)isRightClick;
- (void)setHighlightFrame:(NSRect)frame;
- (void)setAimFrame:(NSRect)frame;
- (void)setEventTitle:(NSString *)eventTitle;
- (void)setReferenceDate:(NSDate *)referenceDate;
- (void)setAuthorUUID:(NSString *)authorUUID;
- (void)setAuthorName:(NSString *)authorName;
- (void)setAuthorEmailAddress:(NSString *)authorEmailAddress;
- (void)setURL:(NSURL *)url;
- (void)setMatchedString:(NSString *)matchedString;
- (void)setAllResults:(NSArray *)allResults;
- (void)setSelectionString:(NSString *)selectionString;
- (void)setMainResult:(CFTypeRef)mainResult;
- (void)setImmediate:(BOOL)immediate;
- (void)setIsRightClick:(BOOL)isRightClick;
@end

@interface ABAddressBook : NSObject
+ (ABAddressBook *)sharedAddressBook;
- (id)recordForUniqueId:(NSString *)uniqueId;
@end

static void wk_setDDContextValue(NSMutableDictionary *dictionary, const char *keySymbol, id value)
{
    if (value)
        [dictionary setObject:value forKey:*(NSString *const *)dlsym(RTLD_DEFAULT, keySymbol)];
}

static NSDictionary *wk_DDContextDictionary(DDActionContext *context)
{
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    wk_setDDContextValue(dictionary, "kDataDetectorsEventTitleKey", context.eventTitle);
    wk_setDDContextValue(dictionary, "kDataDetectorsReferenceDateKey", context.referenceDate);
    NSString *authorUUID = context.authorUUID;
    if (authorUUID)
        wk_setDDContextValue(dictionary, "kDataDetectorsABPersonAuthorKey", [[objc_getClass("ABAddressBook") sharedAddressBook] recordForUniqueId:authorUUID]);
    wk_setDDContextValue(dictionary, "kDataDetectorsAuthorAsStringKey", context.authorName);
    wk_setDDContextValue(dictionary, "kDataDetectorsAuthorAsEmailAddressKey", context.authorEmailAddress);
    wk_setDDContextValue(dictionary, "kDataDetectorsSpecialURLKey", context.URL);
    wk_setDDContextValue(dictionary, "kDataDetectorsMatchedStringKey", context.matchedString);
    wk_setDDContextValue(dictionary, "kDataDetectorsAllResultsKey", context.allResults);
    wk_setDDContextValue(dictionary, "kDataDetectorsSelectionStringKey", context.selectionString);
    return dictionary;
}

static char wk_allowedActionUTIsKey;

WK_POLYFILL_ADD_METHODS_ON(NSObject, "DDActionContext")
- (NSArray *)allowedActionUTIs
{
    return objc_getAssociatedObject(self, &wk_allowedActionUTIsKey);
}
- (void)setAllowedActionUTIs:(NSArray *)allowedActionUTIs
{
    objc_setAssociatedObject(self, &wk_allowedActionUTIsKey, allowedActionUTIs, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
@end

WK_POLYFILL_REPLACE_METHODS_ON(NSObject, "DDActionsManager")
- (NSArray *)menuItemsForValue:(NSString *)value type:(CFStringRef)type service:(NSString *)service context:(id)context
{
    if (![context isKindOfClass:objc_getClass("DDActionContext")])
        return WK_ORIGINAL_METHOD(NSArray *, (NSString *, CFStringRef, NSString *, id), value, type, service, context);

    NSArray *items = WK_ORIGINAL_METHOD(NSArray *, (NSString *, CFStringRef, NSString *, id), value, type, service, wk_DDContextDictionary(context));
    NSArray *allowedActionUTIs = objc_getAssociatedObject(context, &wk_allowedActionUTIsKey);
    if (!allowedActionUTIs)
        return items;

    NSMutableArray *allowedItems = [NSMutableArray array];
    for (NSMenuItem *item in items) {
        id representedObject = item.representedObject;
        if (![representedObject isKindOfClass:[NSDictionary class]])
            continue;
        id action = [representedObject objectForKey:@"DDAction"];
        if ([action isKindOfClass:objc_getClass("DDAction")] && [allowedActionUTIs containsObject:[(DDAction *)action actionUTI]])
            [allowedItems addObject:item];
    }
    return allowedItems;
}
@end

// ---------------------------------------------------------------------------------------------------
// The WebKit property lists of DDScannerResult and DDSecureActionContext, which WebKit's IPC coders
// (CoreIPCDDScannerResult, CoreIPCDDSecureActionContext) read and rebuild the objects from.
//
// A result's property list holds the fields of its native archive under the archive's keys: AR (the range,
// as an NSValue), MS, T, SR (the subresults, as DDScannerResults), V and C. The native -initWithCoder:
// builds the result from those keys; a keyed decoder over the property list feeds it.
@interface DDScannerResult : NSObject <NSCoding>
+ (DDScannerResult *)resultFromCoreResult:(CFTypeRef)coreResult;
- (CFTypeRef)coreResult;
- (NSRange)range;
- (NSString *)matchedString;
- (NSString *)type;
- (NSArray *)subResults;
- (NSString *)rawValue;
- (NSDictionary *)contextualData;
@end

static void wk_DDSetPropertyListValue(NSMutableDictionary *propertyList, NSString *key, id value)
{
    if (value)
        [propertyList setObject:value forKey:key];
}

static id wk_DDPropertyListValue(NSDictionary *propertyList, NSString *key, Class cls)
{
    id value = [propertyList objectForKey:key];
    return [value isKindOfClass:cls] ? value : nil;
}

static BOOL wk_isKindOfClasses(id object, NSSet *classes)
{
    for (Class cls in classes) {
        if ([object isKindOfClass:cls])
            return YES;
    }
    return NO;
}

@interface WKDDPropertyListDecoder : NSCoder {
    NSDictionary *_propertyList;
}
- (instancetype)initWithPropertyList:(NSDictionary *)propertyList;
@end

@implementation WKDDPropertyListDecoder
- (instancetype)initWithPropertyList:(NSDictionary *)propertyList
{
    if ((self = [super init]))
        _propertyList = [propertyList retain];
    return self;
}
- (void)dealloc
{
    [_propertyList release];
    [super dealloc];
}
- (BOOL)allowsKeyedCoding
{
    return YES;
}
- (BOOL)requiresSecureCoding
{
    return YES;
}
- (BOOL)containsValueForKey:(NSString *)key
{
    return [_propertyList objectForKey:key] != nil;
}
- (id)decodeObjectForKey:(NSString *)key
{
    return [_propertyList objectForKey:key];
}
// A value of the wrong class decodes as nil; an array's elements must each be of the given classes.
- (id)decodeObjectOfClasses:(NSSet *)classes forKey:(NSString *)key
{
    id object = [_propertyList objectForKey:key];
    if (!object || !wk_isKindOfClasses(object, classes))
        return nil;
    if ([object isKindOfClass:[NSArray class]]) {
        for (id element in object) {
            if (!wk_isKindOfClasses(element, classes))
                return nil;
        }
    }
    return object;
}
- (id)decodeObjectOfClass:(Class)cls forKey:(NSString *)key
{
    return [self decodeObjectOfClasses:[NSSet setWithObject:cls] forKey:key];
}
@end

WK_POLYFILL_ADD_METHODS_ON(NSObject, "DDScannerResult")
- (NSDictionary *)_webKitPropertyListData
{
    DDScannerResult *result = (DDScannerResult *)self;
    NSMutableDictionary *propertyList = [NSMutableDictionary dictionaryWithCapacity:6];
    [propertyList setObject:[NSValue valueWithRange:result.range] forKey:@"AR"];
    wk_DDSetPropertyListValue(propertyList, @"MS", result.matchedString);
    wk_DDSetPropertyListValue(propertyList, @"T", result.type);
    wk_DDSetPropertyListValue(propertyList, @"SR", result.subResults);
    wk_DDSetPropertyListValue(propertyList, @"V", result.rawValue);
    wk_DDSetPropertyListValue(propertyList, @"C", result.contextualData);
    return propertyList;
}
- (id)_initWithWebKitPropertyListData:(NSDictionary *)propertyList
{
    WKDDPropertyListDecoder *decoder = [[WKDDPropertyListDecoder alloc] initWithPropertyList:propertyList];
    id result = [(DDScannerResult *)self initWithCoder:decoder];
    [decoder release];
    return result;
}
@end

// A context's property list holds its fields under the keys of its native archive, with its core results
// as DDScannerResults. 10.9's context has no storage for the property list's other keys (leadingText,
// hostUUID, groupAllResults, authorNameComponents, ...). The methods sit on DDActionContext so that
// DDSecureActionContext, which polyfills/classes/DataDetectors.m builds over it at first ask, inherits them.
WK_POLYFILL_ADD_METHODS_ON(NSObject, "DDActionContext")
- (NSDictionary *)_webKitPropertyListData
{
    DDActionContext *context = (DDActionContext *)self;
    Class resultClass = objc_getClass("DDScannerResult");
    NSMutableDictionary *propertyList = [NSMutableDictionary dictionaryWithCapacity:14];
    [propertyList setObject:[NSValue valueWithRect:context.highlightFrame] forKey:@"highlightFrame"];
    [propertyList setObject:[NSValue valueWithRect:context.aimFrame] forKey:@"aimFrame"];
    wk_DDSetPropertyListValue(propertyList, @"eventTitle", context.eventTitle);
    wk_DDSetPropertyListValue(propertyList, @"referenceDate", context.referenceDate);
    wk_DDSetPropertyListValue(propertyList, @"authorABUUID", context.authorUUID);
    wk_DDSetPropertyListValue(propertyList, @"authorEmailAddress", context.authorEmailAddress);
    wk_DDSetPropertyListValue(propertyList, @"authorName", context.authorName);
    wk_DDSetPropertyListValue(propertyList, @"url", context.URL);
    wk_DDSetPropertyListValue(propertyList, @"matchedString", context.matchedString);
    NSArray *coreResults = context.allResults;
    if (coreResults) {
        NSMutableArray *allResults = [NSMutableArray arrayWithCapacity:coreResults.count];
        for (id coreResult in coreResults)
            [allResults addObject:[resultClass resultFromCoreResult:(CFTypeRef)coreResult]];
        [propertyList setObject:allResults forKey:@"allResults"];
    }
    wk_DDSetPropertyListValue(propertyList, @"selectionString", context.selectionString);
    CFTypeRef mainResult = context.mainResult;
    if (mainResult)
        [propertyList setObject:[resultClass resultFromCoreResult:mainResult] forKey:@"mainResult"];
    [propertyList setObject:@(context.immediate) forKey:@"immediate"];
    [propertyList setObject:@(context.isRightClick) forKey:@"isRightClick"];
    return propertyList;
}
- (id)_initWithWebKitPropertyListData:(NSDictionary *)propertyList
{
    DDActionContext *context = [(DDActionContext *)self init];
    if (!context)
        return nil;
    Class resultClass = objc_getClass("DDScannerResult");
    NSValue *highlightFrame = wk_DDPropertyListValue(propertyList, @"highlightFrame", [NSValue class]);
    if (highlightFrame)
        context.highlightFrame = highlightFrame.rectValue;
    NSValue *aimFrame = wk_DDPropertyListValue(propertyList, @"aimFrame", [NSValue class]);
    if (aimFrame)
        context.aimFrame = aimFrame.rectValue;
    context.eventTitle = wk_DDPropertyListValue(propertyList, @"eventTitle", [NSString class]);
    context.referenceDate = wk_DDPropertyListValue(propertyList, @"referenceDate", [NSDate class]);
    context.authorUUID = wk_DDPropertyListValue(propertyList, @"authorABUUID", [NSString class]);
    context.authorEmailAddress = wk_DDPropertyListValue(propertyList, @"authorEmailAddress", [NSString class]);
    context.authorName = wk_DDPropertyListValue(propertyList, @"authorName", [NSString class]);
    context.URL = wk_DDPropertyListValue(propertyList, @"url", [NSURL class]);
    context.matchedString = wk_DDPropertyListValue(propertyList, @"matchedString", [NSString class]);
    context.selectionString = wk_DDPropertyListValue(propertyList, @"selectionString", [NSString class]);
    NSArray *allResults = wk_DDPropertyListValue(propertyList, @"allResults", [NSArray class]);
    if (allResults) {
        NSMutableArray *coreResults = [NSMutableArray arrayWithCapacity:allResults.count];
        for (id result in allResults) {
            if ([result isKindOfClass:resultClass])
                [coreResults addObject:(id)[(DDScannerResult *)result coreResult]];
        }
        context.allResults = coreResults;
    }
    DDScannerResult *mainResult = wk_DDPropertyListValue(propertyList, @"mainResult", resultClass);
    if (mainResult)
        context.mainResult = mainResult.coreResult;
    context.immediate = [wk_DDPropertyListValue(propertyList, @"immediate", [NSNumber class]) boolValue];
    context.isRightClick = [wk_DDPropertyListValue(propertyList, @"isRightClick", [NSNumber class]) boolValue];
    return (id)context;
}
@end

#pragma clang diagnostic pop
