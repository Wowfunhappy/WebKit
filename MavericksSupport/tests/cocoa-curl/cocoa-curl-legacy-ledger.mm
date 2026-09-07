// Run the raw HTTP ledger through WebView's real XHR/Fetch clients before Safari integration.
#import <Cocoa/Cocoa.h>
#import <WebKitLegacy/WebView.h>
#import <WebKitLegacy/WebFrame.h>
#import <WebKitLegacy/WebPreferences.h>
#import <WebKitLegacy/WebResourceLoadDelegate.h>
#import <WebKitLegacy/WebFrameLoadDelegate.h>
#include <cstdio>
static bool completed;
@interface Ledger : NSObject <WebResourceLoadDelegate, WebFrameLoadDelegate> {
@public
    WebView* view;
    NSString* output;
}
- (void)deadline;
@end
@implementation Ledger
- (id)webView:(WebView*)sender identifierForInitialRequest:(NSURLRequest*)request fromDataSource:(WebDataSource*)source { return request.URL; }
- (void)webView:(WebView*)sender resource:(id)identifier didFinishLoadingFromDataSource:(WebDataSource*)source
{
    if (![[identifier path] isEqualToString:@"/complete"]) return;
    NSString* result = [sender stringByEvaluatingJavaScriptFromString:@"JSON.stringify(window.R)"];
    completed = [result length] && [result writeToFile:output atomically:YES encoding:NSUTF8StringEncoding error:nil];
    printf("WebView raw HTTP ledger completed=%d output=%s\n", completed, output.fileSystemRepresentation);
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)webView:(WebView*)sender didFailProvisionalLoadWithError:(NSError*)error forFrame:(WebFrame*)frame { NSLog(@"Ledger page failure: %@", error); CFRunLoopStop(CFRunLoopGetMain()); }
- (void)deadline { puts("FAIL WebView ledger deadline"); CFRunLoopStop(CFRunLoopGetMain()); }
@end
int main(int argc, char** argv)
{
    @autoreleasepool {
        if (argc != 3) return 2;
        setvbuf(stdout, nullptr, _IONBF, 0);
        [NSApplication sharedApplication];
        Ledger* ledger = [Ledger new];
        ledger->output = [[NSString stringWithUTF8String:argv[2]] retain];
        ledger->view = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) frameName:nil groupName:nil];
        WebPreferences* preferences = [[WebPreferences alloc] initWithIdentifier:@"CocoaCurlLedger"];
        preferences.autosaves = NO;
        preferences.privateBrowsingEnabled = YES;
        ledger->view.preferences = preferences;
        ledger->view.resourceLoadDelegate = ledger;
        ledger->view.frameLoadDelegate = ledger;
        [ledger->view.mainFrame loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]]]];
        NSTimer* deadline = [NSTimer scheduledTimerWithTimeInterval:90 target:ledger selector:@selector(deadline) userInfo:nil repeats:NO];
        CFRunLoopRun();
        [deadline invalidate];
        [ledger->view close];
    }
    return completed ? 0 : 1;
}
