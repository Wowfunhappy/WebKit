#import <Cocoa/Cocoa.h>
#include <stdio.h>

@interface WebFrame : NSObject
- (void)loadHTMLString:(NSString *)string baseURL:(NSURL *)url;
@end
@interface WebView : NSView
- (instancetype)initWithFrame:(NSRect)frame frameName:(NSString *)frameName groupName:(NSString *)groupName;
- (WebFrame *)mainFrame;
- (void)setFrameLoadDelegate:(id)delegate;
- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script;
- (NSDictionary *)_dashboardRegions;
@end
@interface NSObject (Region)
- (NSRect)dashboardRegionRect;
- (NSRect)dashboardRegionClip;
@end

static BOOL loaded;
@interface LoadDelegate : NSObject @end
@implementation LoadDelegate
- (void)webView:(WebView *)view didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame == view.mainFrame) loaded = YES;
}
@end

static BOOL near(CGFloat a, CGFloat b) { return fabs(a - b) <= 1; }
static BOOL sameRect(NSRect a, NSRect b)
{
    return near(a.origin.x, b.origin.x) && near(a.origin.y, b.origin.y)
        && near(a.size.width, b.size.width) && near(a.size.height, b.size.height);
}

int main(int argc, const char **argv)
{
    if (argc != 2) return 2;
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 300)
            styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        WebView *view = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 500, 300) frameName:nil groupName:nil];
        LoadDelegate *delegate = [LoadDelegate new];
        [view setFrameLoadDelegate:delegate];
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        NSString *html = @"<!doctype html><style>"
            "body{margin:0} #clip{position:absolute;left:80px;top:40px;width:60px;height:25px;padding:10px;overflow:hidden;font:10px/10px monospace}"
            "#containing{position:relative;left:7px;top:4px;width:60px}"
            "#inline{-apple-dashboard-region:dashboard-region(inline rectangle 2px 3px 4px 5px)}"
            "#box{position:absolute;left:200px;top:40px;width:70px;height:30px;-apple-dashboard-region:dashboard-region(box rectangle 1px 2px 3px 4px)}"
            "</style><div id=clip><div id=containing>xx<span id=inline>abc def ghi jkl mno pqr stu vwx yz</span></div></div><div id=box></div>";
        [view.mainFrame loadHTMLString:html baseURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!loaded && deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        NSString *json = [view stringByEvaluatingJavaScriptFromString:@"JSON.stringify((function(){let r=document.getElementById('inline').getBoundingClientRect(),c=document.getElementById('clip').getBoundingClientRect();return {x:r.x+5,y:r.y+2,w:r.width-8,h:r.height-6,cx:c.x,cy:c.y,cw:c.width,ch:c.height}})())"];
        NSDictionary *geometry = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
        NSDictionary *regions = [view _dashboardRegions];
        id inlineRegion = [regions[@"inline"] firstObject], boxRegion = [regions[@"box"] firstObject];
        NSRect expected = NSMakeRect([geometry[@"x"] doubleValue], [geometry[@"y"] doubleValue], [geometry[@"w"] doubleValue], [geometry[@"h"] doubleValue]);
        NSRect clip = NSMakeRect([geometry[@"cx"] doubleValue], [geometry[@"cy"] doubleValue], [geometry[@"cw"] doubleValue], [geometry[@"ch"] doubleValue]);
        NSRect expectedClip = NSIntersectionRect(expected, clip);
        BOOL ok = loaded && geometry && inlineRegion && boxRegion && expected.size.height > 20
            && sameRect([inlineRegion dashboardRegionRect], expected)
            && sameRect([inlineRegion dashboardRegionClip], expectedClip)
            && sameRect([boxRegion dashboardRegionRect], NSMakeRect(204, 41, 64, 26));
        NSLog(@"inline=%@ expected=%@ clip=%@ expectedClip=%@ box=%@", NSStringFromRect([inlineRegion dashboardRegionRect]),
            NSStringFromRect(expected), NSStringFromRect([inlineRegion dashboardRegionClip]), NSStringFromRect(expectedClip),
            NSStringFromRect([boxRegion dashboardRegionRect]));
        printf("%s Dashboard multiline inline bounds, offsets, ancestor clipping and box bounds\n", ok ? "PASS" : "FAIL");
        [view setFrameLoadDelegate:nil];
        [delegate release];
        [view release];
        [window release];
        return ok ? 0 : 1;
    }
}
