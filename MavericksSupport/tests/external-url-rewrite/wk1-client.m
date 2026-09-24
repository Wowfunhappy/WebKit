// A WebKit1 client for run.sh: loads <source>/page.html in a WebView and prints its title and address,
// loads <source>/check.html and then <direct>, then downloads <source>/data.json with WebDownload into
// <directory> and prints the file. Usage: wk1-client <source> <directory> <direct>
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface Client : NSObject <NSURLDownloadDelegate> {
@public
    BOOL loaded;
    BOOL downloaded;
    NSString *downloadPath;
}
@end

@implementation Client
- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
    if (frame == [sender mainFrame])
        loaded = YES;
}
- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
    printf("LOAD FAILED %s\n", [[error description] UTF8String]);
    loaded = YES;
}
- (void)webView:(WebView *)sender addMessageToConsole:(NSDictionary *)message
{
    printf("CONSOLE %s\n", [[[message objectForKey:@"message"] description] UTF8String] ?: "-");
}
- (void)webView:(WebView *)sender addMessageToConsole:(NSDictionary *)message withSource:(NSString *)source
{
    [self webView:sender addMessageToConsole:message];
}
- (void)download:(NSURLDownload *)download decideDestinationWithSuggestedFilename:(NSString *)filename
{
    [download setDestination:downloadPath allowOverwrite:YES];
}
- (void)downloadDidFinish:(NSURLDownload *)download
{
    downloaded = YES;
}
- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error
{
    printf("DOWNLOAD FAILED %s\n", [[error description] UTF8String]);
    downloaded = YES;
}
@end

static BOOL spinUntil(BOOL (^done)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (!done()) {
        if ([deadline timeIntervalSinceNow] < 0)
            return NO;
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return YES;
}

static void load(WebView *view, Client *client, NSString *url)
{
    client->loaded = NO;
    [[view mainFrame] loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
    if (!spinUntil(^{ return client->loaded; }))
        printf("LOAD TIMED OUT %s\n", [url UTF8String]);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 4)
            return 2;
        NSString *source = @(argv[1]);
        [NSApplication sharedApplication];
        Client *client = [Client new];
        WebView *view = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600) styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
        [window setContentView:view];
        [view setFrameLoadDelegate:client];
        [view setUIDelegate:client];

        load(view, client, [source stringByAppendingString:@"/page.html"]);
        spinUntil(^{
            NSString *title = [view mainFrameTitle];
            return (BOOL)([title hasPrefix:@"PASS"] || [title hasPrefix:@"FAIL"]);
        });
        printf("TITLE %s\n", [[view mainFrameTitle] UTF8String]);
        printf("ADDRESS %s\n", [[view mainFrameURL] UTF8String]);

        load(view, client, [source stringByAppendingString:@"/check.html"]);
        // WebKit1 hands the document's title to the data source in a task after the load finishes.
        spinUntil(^{ return (BOOL)([[view mainFrameTitle] length] > 0); });
        printf("CHECK %s\n", [[view mainFrameTitle] UTF8String]);

        load(view, client, @(argv[3]));

        client->downloadPath = [@(argv[2]) stringByAppendingPathComponent:@"data.json"];
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:[source stringByAppendingString:@"/data.json?download=1"]]];
        WebDownload *download = [[WebDownload alloc] initWithRequest:request delegate:client];
        if (!spinUntil(^{ return client->downloaded; }))
            printf("DOWNLOAD TIMED OUT\n");
        NSString *body = [NSString stringWithContentsOfFile:client->downloadPath encoding:NSUTF8StringEncoding error:nil];
        printf("DOWNLOAD %s\n", [[body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] UTF8String] ?: "-");
        (void)download;
        (void)window;
    }
    return 0;
}
