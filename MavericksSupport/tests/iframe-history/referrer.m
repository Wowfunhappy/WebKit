#import <Cocoa/Cocoa.h>
#include <stdio.h>

@interface WebFrame : NSObject
- (void)loadRequest:(NSURLRequest *)request;
@end
@interface WebPreferences : NSObject
- (void)setJavaScriptCanOpenWindowsAutomatically:(BOOL)flag;
- (void)_setBoolValue:(BOOL)value forKey:(NSString *)key;
@end
@interface WebView : NSView
- (instancetype)initWithFrame:(NSRect)frame frameName:(NSString *)frameName groupName:(NSString *)groupName;
- (WebFrame *)mainFrame;
- (WebPreferences *)preferences;
- (void)setUIDelegate:(id)delegate;
- (void)setMaintainsBackForwardList:(BOOL)flag;
- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script;
- (void)close;
@end

@interface PopupDelegate : NSObject {
    NSMutableArray *_views;
}
- (WebView *)createView;
- (void)closeViews;
@end
@implementation PopupDelegate
- (id)init
{
    if ((self = [super init]))
        _views = [[NSMutableArray alloc] init];
    return self;
}
- (void)dealloc
{
    [_views release];
    [super dealloc];
}
- (WebView *)createView
{
    WebView *view = [[[WebView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480) frameName:nil groupName:@"ReferrerProbe"] autorelease];
    [view setUIDelegate:self];
    [view setMaintainsBackForwardList:YES];
    [view.preferences setJavaScriptCanOpenWindowsAutomatically:YES];
    [view.preferences _setBoolValue:YES forKey:@"WebKitBroadcastChannelEnabled"];
    [_views addObject:view];
    return view;
}
- (WebView *)webView:(WebView *)sender createWebViewWithRequest:(NSURLRequest *)request
{
    WebView *view = [self createView];
    if (request)
        [view.mainFrame loadRequest:request];
    return view;
}
- (void)webViewShow:(WebView *)sender { }
- (void)webViewClose:(WebView *)sender { [sender close]; }
- (void)closeViews
{
    for (WebView *view in _views)
        [view close];
    [_views removeAllObjects];
}
@end

int main(int argc, const char **argv)
{
    if (argc != 2)
        return 2;
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSArray *tests = @[
            @"about-blank-inherits-opener-referrer-policy.html",
            @"cross-origin-navigation-does-not-inherit-referrer-policy.html",
            @"cross-origin-navigation-does-not-inherit-referrer-policy-back-navigation.html"
        ];
        BOOL success = YES;
        for (NSString *test in tests) {
            PopupDelegate *delegate = [[PopupDelegate alloc] init];
            WebView *view = [delegate createView];
            NSString *url = [[NSString stringWithUTF8String:argv[1]] stringByAppendingString:test];
            [view.mainFrame loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
            NSString *result = nil;
            do {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
                result = [view stringByEvaluatingJavaScriptFromString:@"document.getElementById('console') ? document.getElementById('console').innerText : ''"];
            } while ([result rangeOfString:@"TEST COMPLETE"].location == NSNotFound && deadline.timeIntervalSinceNow > 0);
            BOOL passed = result.length && [result rangeOfString:@"TEST COMPLETE"].location != NSNotFound && [result rangeOfString:@"FAIL"].location == NSNotFound;
            printf("%s %s:\n%s\n", passed ? "PASS" : "FAIL", test.UTF8String, result.UTF8String);
            success &= passed;
            [delegate closeViews];
            [delegate release];
        }
        return success ? 0 : 1;
    }
}
