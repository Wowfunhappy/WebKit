/*
 * Minimal WK1 browser for macOS 10.9. Uses WebKitLegacy.framework directly.
 */
#import <Cocoa/Cocoa.h>

/* Forward declare to avoid pulling in WebKitLegacy/WebKit.h which has a
   complex include chain with 10.9-incompatible availability macros. */
@class WebFrame;
@interface WebView : NSView
- (id)initWithFrame:(NSRect)frame frameName:(NSString *)frameName groupName:(NSString *)groupName;
- (WebFrame *)mainFrame;
- (void)goBack;
- (void)goForward;
@end
@interface WebFrame : NSObject
- (void)loadRequest:(NSURLRequest *)request;
- (void)reload;
@end

@interface BrowserDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) WebView *webView;
@property (strong) NSTextField *urlField;
@property (strong) NSButton *backButton;
@property (strong) NSButton *forwardButton;
@property (strong) NSButton *reloadButton;
@end

@implementation BrowserDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    NSRect frame = NSMakeRect(100, 100, 1024, 768);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask)
        backing:NSBackingStoreBuffered defer:NO];
    [self.window setTitle:@"WebKit MiniBrowser (WK1)"];
    [self.window setDelegate:self];

    NSView *content = [self.window contentView];

    // Toolbar area
    CGFloat toolbarH = 32;
    NSRect tbRect = NSMakeRect(0, NSMaxY([content bounds]) - toolbarH, NSWidth([content bounds]), toolbarH);
    NSView *toolbar = [[NSView alloc] initWithFrame:tbRect];
    [toolbar setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];

    self.backButton = [[NSButton alloc] initWithFrame:NSMakeRect(5, 5, 40, 22)];
    [self.backButton setTitle:@"<"];
    [self.backButton setBezelStyle:NSRoundedBezelStyle];
    [self.backButton setTarget:self];
    [self.backButton setAction:@selector(goBack:)];
    [toolbar addSubview:self.backButton];

    self.forwardButton = [[NSButton alloc] initWithFrame:NSMakeRect(50, 5, 40, 22)];
    [self.forwardButton setTitle:@">"];
    [self.forwardButton setBezelStyle:NSRoundedBezelStyle];
    [self.forwardButton setTarget:self];
    [self.forwardButton setAction:@selector(goForward:)];
    [toolbar addSubview:self.forwardButton];

    self.reloadButton = [[NSButton alloc] initWithFrame:NSMakeRect(95, 5, 60, 22)];
    [self.reloadButton setTitle:@"Reload"];
    [self.reloadButton setBezelStyle:NSRoundedBezelStyle];
    [self.reloadButton setTarget:self];
    [self.reloadButton setAction:@selector(reload:)];
    [toolbar addSubview:self.reloadButton];

    self.urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(160, 5, NSWidth([content bounds]) - 170, 22)];
    [self.urlField setAutoresizingMask:NSViewWidthSizable];
    [[self.urlField cell] setWraps:NO];
    [[self.urlField cell] setScrollable:YES];
    [self.urlField setDelegate:self];
    [self.urlField setStringValue:@"https://example.com/"];
    [toolbar addSubview:self.urlField];

    [content addSubview:toolbar];

    // WebView area
    NSRect wvRect = NSMakeRect(0, 0, NSWidth([content bounds]), NSHeight([content bounds]) - toolbarH);
    self.webView = [[WebView alloc] initWithFrame:wvRect frameName:nil groupName:nil];
    [self.webView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    [content addSubview:self.webView];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Start with about:blank to avoid crash in network loading code path.
    NSURL *url = [NSURL URLWithString:@"about:blank"];
    [[self.webView mainFrame] loadRequest:[NSURLRequest requestWithURL:url]];
}

- (BOOL)control:(NSControl *)control textShouldEndEditing:(NSText *)fieldEditor
{
    NSString *str = [fieldEditor string];
    if ([str length] == 0) return YES;
    if (![str hasPrefix:@"http://"] && ![str hasPrefix:@"https://"] && ![str hasPrefix:@"file://"])
        str = [@"http://" stringByAppendingString:str];
    NSURL *url = [NSURL URLWithString:str];
    if (url)
        [[self.webView mainFrame] loadRequest:[NSURLRequest requestWithURL:url]];
    return YES;
}

- (void)goBack:(id)sender { [self.webView goBack]; }
- (void)goForward:(id)sender { [self.webView goForward]; }
- (void)reload:(id)sender { [[self.webView mainFrame] reload]; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

@end

int main(int argc, const char * argv[])
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        BrowserDelegate *d = [[BrowserDelegate alloc] init];
        [NSApp setDelegate:d];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp run];
    }
    return 0;
}
