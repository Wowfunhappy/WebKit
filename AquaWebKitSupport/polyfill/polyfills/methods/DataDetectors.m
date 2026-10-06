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

#pragma clang diagnostic pop
