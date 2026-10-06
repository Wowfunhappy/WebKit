#import <WebKit/WebKit.h>

// The clip's copy of Safari 7 extensions (WCSafariExtensions.h) at work, as Safari runs its extensions for
// its tabs: their global pages and popovers in WebKit 1 views Safari configures them with, never shown, with
// Safari 7's API for them (WCSafariExtensionPage.js); their files under safari-extension://; their content
// scripts and style sheets in the clip's pages, each extension's in a content world named after its files'
// root, which the plug-in's injected bundle gives Safari 7's content API (WCPageExtensions.h) and whose
// messages the runtime carries to and from the extensions' pages. WebKit gives the pages and content scripts
// their `browser` namespace and webRequest as it gives Safari's.
//
// One process shows every clip; each clip's copy runs on its own, its extensions keyed by Safari's keys with
// the clip's identifier.
@interface WCExtensionRuntime : NSObject

// The clips' process pool: its pages' safari-extension:// loads and its injected bundle's messages.
+ (void)serveProcessPool:(WKProcessPool *)processPool;

// Where the process's WebKit 1 pages keep their local storage and indexed databases, each clip's extensions'
// under origins of their own, and an extension's key in a clip.
+ (NSString *)localStorageDirectory;
+ (NSString *)indexedDatabaseDirectory;
+ (NSString *)extensionKey:(NSString *)key ofClip:(NSString *)clipIdentifier;

// The runtime of the clip's copy in the directory, running from its first use.
+ (instancetype)runtimeOfClip:(NSString *)clipIdentifier directory:(NSString *)directory;

// A web view of the clip, a tab of the clip's one browser window to the extensions.
- (void)addWebView:(WKWebView *)webView;

// A main-frame navigation of a web view of the clip: whether it goes ahead, and that its page has loaded.
- (BOOL)webView:(WKWebView *)webView shouldNavigateToURL:(NSURL *)url;
- (void)webViewDidNavigate:(WKWebView *)webView;

// The clip is going away: its extensions stop, and their pages and content leave the process.
- (void)invalidate;

@end
