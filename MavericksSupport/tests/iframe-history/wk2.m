#import <Cocoa/Cocoa.h>
#include <stdio.h>

@interface WKPreferences : NSObject
- (void)_setAllowFileAccessFromFileURLs:(BOOL)value;
- (void)_setUniversalAccessFromFileURLsAllowed:(BOOL)value;
@end
@interface WKWebViewConfiguration : NSObject
- (WKPreferences *)preferences;
@end
@interface WKWebView : NSView
- (instancetype)initWithFrame:(NSRect)frame configuration:(WKWebViewConfiguration *)configuration;
- (id)loadFileURL:(NSURL *)URL allowingReadAccessToURL:(NSURL *)readAccessURL;
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))completionHandler;
@end

static NSString *scriptValue(WKWebView *view, NSString *script)
{
    __block BOOL done = NO;
    __block NSString *result = nil;
    [view evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        if ([value isKindOfClass:[NSString class]])
            result = [value retain];
        done = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (!done && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return [result autorelease];
}

int main(int argc, const char **argv)
{
    if (argc != 2)
        return 2;
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSArray *tests = @[
            @[ @"fast/loader/stateobjects/pushstate-in-iframe.html", @"PASS" ],
            @[ @"fast/loader/remove-iframe-during-history-navigation-same.html", @"TEST PASSED" ]
        ];
        BOOL success = YES;
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        for (NSArray *test in tests) {
            WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
            [configuration.preferences _setAllowFileAccessFromFileURLs:YES];
            [configuration.preferences _setUniversalAccessFromFileURLsAllowed:YES];
            WKWebView *view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480) configuration:configuration];
            [configuration release];
            [view loadFileURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:test[0]]]
                allowingReadAccessToURL:[NSURL fileURLWithPath:root]];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
            NSString *result = nil;
            do {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
                result = scriptValue(view, @"document.body ? document.body.innerText.trim() : ''");
            } while (![result isEqual:test[1]] && ![result isEqual:@"FAIL"] && deadline.timeIntervalSinceNow > 0);
            BOOL passed = [result isEqual:test[1]];
            printf("%s WK2 %s: %s\n", passed ? "PASS" : "FAIL", [test[0] UTF8String], result.UTF8String);
            if (!passed)
                NSLog(@"history state %@", scriptValue(view, @"JSON.stringify({url:location.href,ready:document.readyState,history:history.length,frames:Array.from(document.querySelectorAll('iframe')).map(f=>({src:f.src,url:f.contentWindow.location.href,ready:f.contentDocument.readyState,history:f.contentWindow.history.length})),resources:performance.getEntriesByType('resource').map(r=>r.name)})"));
            success &= passed;
            [view release];
        }
        return success ? 0 : 1;
    }
}
