#import <Cocoa/Cocoa.h>
#include <stdio.h>

@interface WebFrame : NSObject
- (void)loadRequest:(NSURLRequest *)request;
@end
@interface WebView : NSView
- (instancetype)initWithFrame:(NSRect)frame frameName:(NSString *)frameName groupName:(NSString *)groupName;
- (WebFrame *)mainFrame;
- (void)setMaintainsBackForwardList:(BOOL)flag;
- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script;
- (void)close;
@end

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
        for (NSArray *test in tests) {
            WebView *view = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480) frameName:nil groupName:nil];
            [view setMaintainsBackForwardList:YES];
            NSString *path = [[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:test[0]];
            [view.mainFrame loadRequest:[NSURLRequest requestWithURL:[NSURL fileURLWithPath:path]]];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
            NSString *result = nil;
            do {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
                result = [view stringByEvaluatingJavaScriptFromString:@"document.body ? document.body.innerText.trim() : ''"];
            } while (![result isEqual:test[1]] && ![result isEqual:@"FAIL"] && deadline.timeIntervalSinceNow > 0);
            BOOL passed = [result isEqual:test[1]];
            printf("%s %s: %s\n", passed ? "PASS" : "FAIL", [test[0] UTF8String], result.UTF8String);
            success &= passed;
            [view close];
            [view release];
        }
        return success ? 0 : 1;
    }
}
