// DDMacAction (polyfills/classes/DataDetectors.m), found by name the way PAL soft-links it: the
// framework is opened first, then objc_getClass is answered out of __wk_clsmap. This program links
// libpolyfill.a for that objc_getClass and libpolyfill_classes.dylib for the class entry.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>

@interface NSObject (DDActionsManagerTest)
+ (id)sharedManager;
- (NSArray *)menuItemsForValue:(NSString *)value type:(CFStringRef)type service:(id)service context:(id)context;
- (id)representedObject;
@end

static int failures;
static void check(BOOL ok, const char *name)
{
    printf("  %s: %s\n", name, ok ? "ok" : "FAIL");
    failures += !ok;
}

int main(void)
{
    @autoreleasepool {
        void *framework = dlopen("/System/Library/PrivateFrameworks/DataDetectors.framework/DataDetectors", RTLD_LAZY);
        void *core = dlopen("/System/Library/PrivateFrameworks/DataDetectorsCore.framework/DataDetectorsCore", RTLD_LAZY);
        check(framework && core, "load native frameworks");
        Class action = NSClassFromString(@"DDAction");
        Class macAction = objc_getClass("DDMacAction");
        check(action && macAction == action, "DDMacAction is DDAction");
        check(!NSClassFromString(@"DDMacAction"), "system name stays free outside WebKit's lookup");

        CFStringRef const *phoneType = dlsym(core, "DDBinderPhoneNumberKey");
        NSArray *items = phoneType ? [[NSClassFromString(@"DDActionsManager") sharedManager] menuItemsForValue:@"408-555-0123" type:*phoneType service:nil context:nil] : nil;
        NSUInteger actions = 0, matching = 0;
        for (id item in items) {
            id represented = [item representedObject];
            id itemAction = [represented isKindOfClass:[NSDictionary class]] ? [represented objectForKey:@"DDAction"] : nil;
            if (!itemAction)
                continue;
            ++actions;
            matching += [itemAction isKindOfClass:macAction];
        }
        check(actions && matching == actions, "every menu item's action is a DDMacAction");
    }
    return failures ? 1 : 0;
}
