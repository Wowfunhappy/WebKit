// Exercise application plug-in admission in a WebKit1 host without Mail's signature quirk.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface Host : NSObject {
@public
    NSMutableDictionary *views;
    BOOL loaded;
}
@end

@implementation Host
- (NSView *)webView:(WebView *)sender plugInViewWithArguments:(NSDictionary *)arguments
{
    NSDictionary *attributes = [arguments objectForKey:WebPlugInAttributesKey];
    NSString *identifier = [attributes objectForKey:@"id"];
    NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 40, 40)] autorelease];
    [views setObject:view forKey:identifier];
    return view;
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame == [sender mainFrame])
        loaded = YES;
}
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        Host *host = [[Host alloc] init];
        host->views = [[NSMutableDictionary alloc] init];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 480)
            styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        WebView *webView = [[WebView alloc] initWithFrame:[[window contentView] bounds]];
        WebPreferences *preferences = [[WebPreferences alloc] initWithIdentifier:@"AttachmentPluginTest"];
        [preferences setAutosaves:NO];
        [preferences setPlugInsEnabled:NO];
        [webView setPreferences:preferences];
        [webView setUIDelegate:host];
        [webView setFrameLoadDelegate:host];
        [window setContentView:webView];
        [window orderFront:nil];

        [[webView mainFrame] loadHTMLString:
            @"<object id='attachment' type='application/x-apple-msg-attachment' data='cid:attachment@test'></object>"
             "<object id='uppercase' type='APPLICATION/X-APPLE-MSG-ATTACHMENT' data='cid:uppercase@test'></object>"
             "<object id='webclip' type='application/x-apple-webclip-plug-in'></object>"
             "<object id='flash' type='application/x-shockwave-flash'></object>"
             "<object id='unknown' type='application/x-test-unknown'></object>"
             "<object id='suffix' type='application/x-apple-msg-attachment-other'></object>"
            baseURL:nil];

        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        while ((!host->loaded || [host->views count] < 3) && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            [webView displayIfNeeded];
        }

        BOOL passed = host->loaded;
        for (NSString *identifier in @[@"attachment", @"uppercase", @"webclip", @"flash", @"unknown", @"suffix"]) {
            BOOL expected = [@[@"attachment", @"uppercase", @"webclip"] containsObject:identifier];
            NSView *view = [host->views objectForKey:identifier];
            BOOL correct = expected ? view && [view superview] : !view;
            printf("%s %s\n", correct ? "PASS" : "FAIL", [identifier UTF8String]);
            passed &= correct;
        }
        [webView close];
        [window orderOut:nil];
        return passed ? 0 : 1;
    }
}
