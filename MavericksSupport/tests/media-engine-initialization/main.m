#import <Cocoa/Cocoa.h>
#include <stdio.h>
@interface WebFrameView : NSView
- (NSView *)documentView;
@end
@interface WebFrame : NSObject
- (void)loadRequest:(NSURLRequest *)request;
- (void)loadHTMLString:(NSString *)html baseURL:(NSURL *)url;
- (WebFrameView *)frameView;
@end
@interface WebPreferences : NSObject
- (void)_setBoolValue:(BOOL)value forKey:(NSString *)key;
+ (instancetype)standardPreferences;
- (void)setAutosaves:(BOOL)flag;
@end
@interface WebView : NSView
- (instancetype)initWithFrame:(NSRect)frame frameName:(NSString *)name groupName:(NSString *)group;
- (WebFrame *)mainFrame;
- (WebPreferences *)preferences;
- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script;
- (void)close;
- (void)setUIDelegate:(id)delegate;
@end
@interface StreamDelegate : NSObject
@end
@implementation StreamDelegate
- (void)webView:(WebView *)view decidePolicyForUserMediaRequestFromOrigin:(id)origin listener:(id)listener { puts("USER MEDIA ALLOWED"); fflush(stdout); [listener performSelector:@selector(allow)]; }
@end
int main(int argc, const char **argv) {
    if (argc < 2) return 2;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [[WebPreferences standardPreferences] setAutosaves:NO];
        id earlyTypes = [NSClassFromString(@"WebHTMLRepresentation") performSelector:@selector(supportedMediaMIMETypes)];
        printf("early supported media type count=%lu\n", (unsigned long)[earlyTypes count]);
        WebView *view = [[WebView alloc] initWithFrame:NSMakeRect(0,0,640,480) frameName:nil groupName:nil];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000,-10000,640,480) styleMask:0 backing:NSBackingStoreBuffered defer:NO];
        [window setReleasedWhenClosed:NO];
        [window setColorSpace:[[NSScreen screens][0] colorSpace]];
        [window setContentView:view];
        StreamDelegate *delegate = [StreamDelegate new];
        [view setUIDelegate:delegate];
        [view.preferences _setBoolValue:YES forKey:@"WebKitMediaDevicesEnabled"];
        [view.preferences _setBoolValue:NO forKey:@"WebKitGetUserMediaRequiresFocus"];
        [view.preferences _setBoolValue:YES forKey:@"WebKitCanvasUsesAcceleratedDrawing"];
        [view.preferences _setBoolValue:YES forKey:@"WebKitMockCaptureDevicesEnabled"];
        [view.preferences _setBoolValue:YES forKey:@"WebKitMediaStreamEnabled"];
        [view.preferences _setBoolValue:NO forKey:@"WebKitMockCaptureDevicesPromptEnabled"];
        [view.preferences _setBoolValue:YES forKey:@"WebKitManagedMediaSourceEnabled"];
        [view.preferences _setBoolValue:YES forKey:@"WebKitMediaSourceEnabled"];
        [view.preferences _setBoolValue:YES forKey:@"WebKitGStreamerEnabled"];
        [view.mainFrame loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]]]];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:argc > 2 ? atoi(argv[2]) : 8];
        while (deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
        NSString *script = @"JSON.stringify({body:document.body.innerText,video:((typeof video!=='undefined' && video)||document.querySelector('video')) && ((v)=>({ready:v.readyState,network:v.networkState,current:v.currentTime,paused:v.paused,error:v.error&&v.error.code,tracks:v.textTracks.length}))(typeof video!=='undefined'&&video||document.querySelector('video'))})";
        NSString *result = [view stringByEvaluatingJavaScriptFromString:script];
        puts(result.UTF8String);
        NSString *body = [view stringByEvaluatingJavaScriptFromString:@"document.body.innerText"];
        BOOL completed = [body rangeOfString:@"TEST COMPLETE"].location != NSNotFound;
        BOOL passed = completed && [body rangeOfString:@"PASS" options:NSCaseInsensitiveSearch].location != NSNotFound
            && [body rangeOfString:@"FAIL" options:NSCaseInsensitiveSearch].location == NSNotFound
            && [body rangeOfString:@"TIMEOUT" options:NSCaseInsensitiveSearch].location == NSNotFound;
        printf("RESULT: %s\n", passed ? "PASS" : "FAIL");
        [view close];
        [window close];
        [window release];
        [view release];
        return passed ? 0 : 1;
    }
}
