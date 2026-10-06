// A framework 10.9 does not ship AT ALL, whose classes the layer supplies: Accessibility.framework and
// its AXCustomContent, which -[WebAccessibilityObjectWrapperBase accessibilityCustomContent] builds one
// of per element carrying an extended description.
//
// SOFT_LINK_CLASS_FOR_SOURCE opens the framework and then asks objc_getClass by name, and both halves
// RELEASE_ASSERT. The open is answered by the absent-provider token (wk_polyfill_runtime.c), which is
// minted only for a framework the registry vends something for -- including, as here, a framework whose
// only registered symbols are class stubs. The name lookup is answered out of __wk_clsmap, which lives
// in libpolyfill_classes.dylib: a DIFFERENT image from the libpolyfill.a copy running the override, so
// this program links both, the topology WebCore forms.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <unistd.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

int main(void)
{
    @autoreleasepool {
        static const char frameworkPath[] = "/System/Library/Frameworks/Accessibility.framework/Accessibility";
        check(access("/System/Library/Frameworks/Accessibility.framework", F_OK) != 0,
            "this system ships no Accessibility.framework, so the premise holds");

        void *handle = dlopen(frameworkPath, RTLD_NOW);
        check(handle != NULL, "dlopen of the absent framework answers with a handle");
        check(dlsym(handle, "AXNothingTheLayerSupplies") == NULL,
            "and a name the layer does not supply still reports missing through it");
        check(dlclose(handle) == 0, "and the handle closes");

        Class customContent = objc_getClass("AXCustomContent");
        check(customContent != Nil, "objc_getClass finds the stub across images");
        if (!customContent) {
            printf("Accessibility-absent-framework: %d failure(s)\n", failures);
            return 1;
        }

        id item = ((id (*)(Class, SEL, NSString *, NSString *))objc_msgSend)(customContent,
            sel_getUid("customContentWithLabel:value:"), @"description", @"Sometimes Always");
        check(item != nil, "+customContentWithLabel:value: builds an item");
        check([[item valueForKey:@"label"] isEqualToString:@"description"], "the label is the one it was given");
        check([[item valueForKey:@"value"] isEqualToString:@"Sometimes Always"], "and so is the value");
        check([[item valueForKey:@"importance"] unsignedIntegerValue] == 0, "importance starts at the default");
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(item, sel_getUid("setImportance:"), 1);
        check([[item valueForKey:@"importance"] unsignedIntegerValue] == 1, "and holds the importance it is set to");

        // The attributed half of the class, which a caller reaches from either factory.
        check([[item valueForKey:@"attributedLabel"] isKindOfClass:[NSAttributedString class]]
            && [[[item valueForKey:@"attributedLabel"] string] isEqualToString:@"description"],
            "the attributed label carries the label it was given");
        check([[[item valueForKey:@"attributedValue"] string] isEqualToString:@"Sometimes Always"],
            "and the attributed value carries the value");
        id attributed = ((id (*)(Class, SEL, NSAttributedString *, NSAttributedString *))objc_msgSend)(customContent,
            sel_getUid("customContentWithAttributedLabel:attributedValue:"),
            [[[NSAttributedString alloc] initWithString:@"orientation"] autorelease],
            [[[NSAttributedString alloc] initWithString:@"portrait"] autorelease]);
        check([[attributed valueForKey:@"label"] isEqualToString:@"orientation"]
            && [[attributed valueForKey:@"value"] isEqualToString:@"portrait"],
            "and the attributed factory derives the plain pair");

        // NSAccessibilityCustomAction's two forms. The class is reached by classref alias, not by name.
        extern char OBJC_CLASS_$_NSAccessibilityCustomAction;
        Class customAction = (__bridge Class)(void *)&OBJC_CLASS_$_NSAccessibilityCustomAction;
        id blockAction = ((id (*)(id, SEL, NSString *, BOOL (^)(void)))objc_msgSend)([customAction alloc],
            sel_getUid("initWithName:handler:"), @"Press", ^BOOL { return YES; });
        check([[blockAction valueForKey:@"name"] isEqualToString:@"Press"], "a custom action keeps its name");
        BOOL (^storedHandler)(void) = [blockAction valueForKey:@"handler"];
        check(storedHandler && storedHandler(), "and runs the handler it was built with");
        id targetAction = ((id (*)(id, SEL, NSString *, id, SEL))objc_msgSend)([customAction alloc],
            sel_getUid("initWithName:target:selector:"), @"Activate", (id)customContent, sel_getUid("class"));
        check([targetAction valueForKey:@"target"] == (id)customContent
            && ((SEL (*)(id, SEL))objc_msgSend)(targetAction, sel_getUid("selector")) == sel_getUid("class"),
            "the target/selector form keeps both");
        check([targetAction valueForKey:@"handler"] == nil, "and leaves the handler nil, which tells the forms apart");

        // The private runtime name is what keeps the stub out of a host app's way: only the registry
        // above and WebKit's own classref alias reach it.
        check(objc_getClass("WKMavPolyfillPriv_AXCustomContent") != Nil,
            "the stub is registered under the private name");

        printf("Accessibility-absent-framework: %d failure(s)\n", failures);
        return failures ? 1 : 0;
    }
}
