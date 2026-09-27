// The plug-in's principal class. Dashboard's WebView instantiates the Web Clip plug-in through
// +plugInViewWithArguments:, and the widget's WebClip.js drives it through the `webClip` object
// this class publishes into the widget page.

#import <Cocoa/Cocoa.h>

@class WCClipperView;
@class WebPreferences;
@class WebScriptObject;
@class WebView;

@interface WebClipper : NSObject

+ (NSString *)bundleIdentifier;
+ (Class)defaultThemeClass;
+ (float)backsideWidth;
+ (float)backsideHeight;
+ (NSString *)webClipVersion;
+ (NSString *)safariVersion;
+ (NSString *)userAgent;
+ (NSView *)plugInViewWithArguments:(NSDictionary *)arguments;

@property (nonatomic, strong) WebPreferences *webPreferences;
@property (nonatomic, strong) NSDictionary *clipSignature;
@property (nonatomic) NSRect clipRect;
@property (nonatomic) NSSize pageSize;

- (NSView *)view;
- (WebView *)dashboardWebView;
- (void)setDashboardWebView:(WebView *)webView;
- (WCClipperView *)webClipperView;
- (void)setWebClipperView:(WCClipperView *)view;
- (WebScriptObject *)windowScriptObject;

- (BOOL)hasSettings;
- (void)readSettings;
- (void)savePreferencesToDisk;
- (void)exitEditingCameraPosition;
- (void)setThumbnailAndFlipToBack:(NSImage *)thumbnail;

- (BOOL)playAudioOutOfDashboard;
- (void)setPlayAudioOutOfDashboard:(BOOL)play;
- (NSString *)URLString;
- (void)setURLString:(NSString *)URLString;
- (NSArray *)cookies;

- (NSString *)standardFont;
- (int)standardFontSize;
- (NSString *)fixedWidthFont;
- (int)fixedWidthFontSize;
- (int)minimumFontSize;
- (NSString *)defaultTextEncodingName;
- (NSString *)customTextEncodingName;
- (NSString *)userStyleSheetPath;
- (float)textSizeMultiplier;

- (void)draggableControlRegions:(void (^)(NSArray *rects))completionHandler;

@end
