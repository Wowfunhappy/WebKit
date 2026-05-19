/*
 * Headless WK1 smoke test for macOS 10.9 modern WebKit backport.
 * Allocates a WebView, loads a URL, runs the runloop briefly, dumps the DOM.
 * No NSWindow / no AppKit window machinery — just enough to exercise the
 * init path so we can hunt down dyld bind errors fast.
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class DOMDocument, DOMElement, DOMNode, WebFrame, WebView;

@interface WebView : NSView
- (id)initWithFrame:(NSRect)frame frameName:(NSString *)frameName groupName:(NSString *)groupName;
- (WebFrame *)mainFrame;
@end

@interface WebFrame : NSObject
- (void)loadRequest:(NSURLRequest *)request;
- (DOMDocument *)DOMDocument;
@end

@interface DOMNode : NSObject
- (NSString *)nodeName;
- (NSString *)nodeValue;
@end

@interface DOMDocument : DOMNode
- (DOMElement *)documentElement;
- (NSString *)title;
@end

@interface DOMElement : DOMNode
- (NSString *)outerHTML;
- (NSString *)textContent;
@end

@interface WebView (JS)
- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script;
@end

@interface Probe : NSObject
@property (nonatomic, assign) BOOL didFinish;
@property (nonatomic, strong) WebView *webView;
@end

@implementation Probe
- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    NSLog(@"[probe] didFinishLoadForFrame");
    self.didFinish = YES;
}
- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    NSLog(@"[probe] didFailLoadWithError: %@", error);
    self.didFinish = YES;
}
- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    NSLog(@"[probe] didFailProvisionalLoadWithError: %@", error);
    self.didFinish = YES;
}
@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSString *urlString = (argc > 1) ? @(argv[1]) : @"data:text/html,<html><head><title>Hi</title></head><body><h1>Hello WebKit!</h1></body></html>";

        // No NSApplication / no window — just NSRunLoop driving CFRunLoop.
        // Some Cocoa code paths still need [NSApplication sharedApplication]
        // for stuff like NSScreen, but let's see how far we get without it.
        [NSApplication sharedApplication];

        NSLog(@"[main] alloc WebView");
        WebView *webView = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) frameName:nil groupName:nil];
        NSLog(@"[main] WebView allocated: %p", webView);

        Probe *probe = [[Probe alloc] init];
        probe.webView = webView;
        // Use the real -setFrameLoadDelegate: setter (KVC was unreliable).
        if ([webView respondsToSelector:@selector(setFrameLoadDelegate:)])
            [webView performSelector:@selector(setFrameLoadDelegate:) withObject:probe];
        else
            NSLog(@"[main] WARNING: WebView doesn't respond to setFrameLoadDelegate:");

        NSLog(@"[main] loadRequest %@", urlString);
        NSURL *url = [NSURL URLWithString:urlString];
        [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:url]];

        // Run the runloop until the page finishes or 5 sec passes
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (!probe.didFinish && [deadline compare:[NSDate date]] == NSOrderedDescending) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }

        NSLog(@"[main] runloop done, didFinish=%d", probe.didFinish);

        DOMDocument *doc = [[webView mainFrame] DOMDocument];
        if (doc) {
            NSLog(@"[main] DOMDocument: title=%@", [doc title]);
            DOMElement *root = [doc documentElement];
            if (root) {
                NSString *html = [root outerHTML];
                NSLog(@"[main] outerHTML (first 500 chars):\n%@", [html length] > 500 ? [html substringToIndex:500] : html);
            } else {
                NSLog(@"[main] no documentElement");
            }
        } else {
            NSLog(@"[main] no DOMDocument");
        }

        // Test JS execution. This should prove that JSC is wired up properly.
        NSLog(@"[main] testing JS evaluation...");
        NSString *jsResult = [webView stringByEvaluatingJavaScriptFromString:
            @"document.body.innerHTML = '<h1>JS injected!</h1><p>2+2=' + (2+2) + '</p>'; "
            @"document.title = 'Set by JS'; "
            @"'js says hi: ' + (1+1) + ' ua=' + navigator.userAgent.substring(0, 30)"];
        NSLog(@"[main] JS result: %@", jsResult);
        NSLog(@"[main] document.title after JS: %@", [doc title]);
        if ([doc documentElement])
            NSLog(@"[main] outerHTML after JS:\n%@", [[doc documentElement] outerHTML]);
    }
    return 0;
}
