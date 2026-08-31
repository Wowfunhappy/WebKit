// A one-window WKWebView host that drives the organization variant of the Storage Access consent
// sheet -- the branch with the disclosure triangle and the related-websites table, which no site can
// reach without WebPrivacy.framework's quirk list.
//
//     clang -fobjc-arc -framework Cocoa -o sso-quirk-host sso-quirk-host.m
//     ./sso-quirk-host
//
// WebKit2.framework -- where this port keeps the modern WK2 classes, WebKit.framework being the
// WebKitLegacy surface Safari 7 links against -- is dlopened rather than linked, because 10.9's ld
// cannot parse a dylib this toolchain produces.
//
// It plants a quirk pairing four domains (the threshold above which the sheet builds the table),
// records the first-party interaction ITP wants for the embedded origin, and loads
// storage-access-top.html. Click the button in the frame; the sheet should carry the disclosure
// triangle, and opening it should list the four domains. Safari cannot host this: it carries
// entitlements, so dyld prunes DYLD_INSERT_LIBRARIES and the quirk cannot be planted from outside.

#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <objc/message.h>

static NSString * const kTopPage = @"http://127.0.0.1:8899/privacy-preferences/storage-access-top.html";

// WKWebsiteDataStoreSetStatisticsIsRunningTest answers through a C function pointer, so the
// continuation is held here rather than captured.
static dispatch_block_t gAfterTestStore;

static void afterTestStore(void *context)
{
    NSLog(@"sso-quirk-host: store marked as a test store");
    if (gAfterTestStore)
        gAfterTestStore();
}

@interface Host : NSObject <NSApplicationDelegate>
@end

@implementation Host {
    NSWindow *_window;
    id _webView;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    if (!dlopen("/System/Library/PrivateFrameworks/WebKit2.framework/WebKit2", RTLD_NOW)) {
        NSLog(@"sso-quirk-host: %s", dlerror());
        [NSApp terminate:nil];
        return;
    }

    Class configurationClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    Class dataStoreClass = NSClassFromString(@"WKWebsiteDataStore");
    if (!configurationClass || !webViewClass || !dataStoreClass) {
        NSLog(@"sso-quirk-host: WebKit did not load");
        [NSApp terminate:nil];
        return;
    }

    id store = ((id (*)(id, SEL))objc_msgSend)(dataStoreClass, sel_registerName("defaultDataStore"));
    ((void (*)(id, SEL, BOOL))objc_msgSend)(store, sel_registerName("_setResourceLoadStatisticsEnabled:"), YES);

    id configuration = [[configurationClass alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(configuration, sel_registerName("setWebsiteDataStore:"), store);

    NSRect frame = NSMakeRect(0, 0, 900, 600);
    _webView = ((id (*)(id, SEL, NSRect, id))objc_msgSend)([webViewClass alloc], sel_registerName("initWithFrame:configuration:"), frame, configuration);

    // Without a UI delegate the page proxy keeps the base API::UIClient, whose storage-access default
    // grants without asking anyone; the delegate is what routes the request to WebKit's own sheet.
    ((void (*)(id, SEL, id))objc_msgSend)(_webView, sel_registerName("setUIDelegate:"), self);

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"SSO storage-access quirk"];
    [_window setContentView:_webView];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    void (^loadTopPage)(void) = ^{
        id request = [NSURLRequest requestWithURL:[NSURL URLWithString:kTopPage]];
        ((id (*)(id, SEL, id))objc_msgSend)(self->_webView, sel_registerName("loadRequest:"), request);
        NSLog(@"sso-quirk-host: loaded %@ -- click the button in the frame", kTopPage);
    };

    // ResourceLoadStatisticsStore::shouldSkip() drops the literal domain "localhost" from every
    // skip-guarded setter unless the store is a test store, and the Storage Access API refuses a
    // non-secure context, which leaves loopback as the only usable pair -- so mark the store a test
    // store rather than renaming the hosts.
    void (^markTestStore)(dispatch_block_t) = ^(dispatch_block_t next) {
        void *handle = dlopen("/System/Library/PrivateFrameworks/WebKit2.framework/WebKit2", RTLD_NOW);
        void *(*defaultStoreRef)(void) = dlsym(handle, "WKWebsiteDataStoreGetDefaultDataStore");
        void (*setIsRunningTest)(void *, bool, void *, void (*)(void *)) = dlsym(handle, "WKWebsiteDataStoreSetStatisticsIsRunningTest");
        if (!defaultStoreRef || !setIsRunningTest) {
            NSLog(@"sso-quirk-host: the isRunningTest C entry point is missing");
            next();
            return;
        }
        gAfterTestStore = [next copy];
        setIsRunningTest(defaultStoreRef(), true, NULL, afterTestStore);
    };

    // Prevalence is what makes the network process put the request to the user rather than answer it
    // from the cookie policy; poll for it, because the setter's completion handler fires either way.
    __block int prevalenceAttempts = 0;
    __block __weak dispatch_block_t weakEnsurePrevalent;
    dispatch_block_t ensurePrevalent = ^{
        ((void (*)(id, SEL, id, void (^)(void)))objc_msgSend)(store, sel_registerName("_setPrevalentDomain:completionHandler:"),
            [NSURL URLWithString:@"http://localhost:8899/"], ^{
            ((void (*)(id, SEL, id, void (^)(BOOL)))objc_msgSend)(store, sel_registerName("_getIsPrevalentDomain:completionHandler:"),
                [NSURL URLWithString:@"http://localhost:8899/"], ^(BOOL prevalent) {
                NSLog(@"sso-quirk-host: localhost prevalent=%d (attempt %d)", prevalent, ++prevalenceAttempts);
                if (prevalent) {
                    ((id (*)(id, SEL))objc_msgSend)(self->_webView, sel_registerName("reload"));
                    NSLog(@"sso-quirk-host: reloaded -- click the button in the frame");
                } else if (prevalenceAttempts < 8) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), weakEnsurePrevalent);
                } else
                    NSLog(@"sso-quirk-host: prevalence never took");
            });
        });
    };
    weakEnsurePrevalent = ensurePrevalent;

    SEL quirkSelector = sel_registerName("_setStorageAccessPromptQuirkForTesting:withSubFrameDomains:withTriggerPages:completionHandler:");
    if (![store respondsToSelector:quirkSelector]) {
        NSLog(@"sso-quirk-host: %@ does not answer the quirk SPI", store);
        [NSApp terminate:nil];
        return;
    }

    ((void (*)(id, SEL, id, id, id, void (^)(void)))objc_msgSend)(store, quirkSelector,
        @"127.0.0.1", @[@"localhost", @"sso-second.test", @"sso-third.test"], @[], ^{
        NSLog(@"sso-quirk-host: planted 127.0.0.1 -> localhost, sso-second.test, sso-third.test");
        loadTopPage();
        // The statistics store only exists once a page has loaded; a setter issued before that is
        // discarded without an error.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            markTestStore(^{
                ((void (*)(id, SEL, id, void (^)(void)))objc_msgSend)(store, sel_registerName("_logUserInteraction:completionHandler:"),
                    [NSURL URLWithString:@"http://localhost:8899/"], ^{
                    NSLog(@"sso-quirk-host: logged first-party interaction for localhost");
                    ensurePrevalent();
                });
            });
        });
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        Host *host = [Host new];
        [NSApp setDelegate:host];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp run];
    }
    return 0;
}
