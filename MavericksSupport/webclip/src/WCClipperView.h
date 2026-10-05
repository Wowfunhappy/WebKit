// The Web Clip view: the clipped page (an out-of-process WKWebView scrolled inside a clip view),
// the theme drawn around it, the flip ("i") button, and the edit-mode controls. It is the content
// of the page window.

#import "WCThemes.h"

@class WebScriptObject;
@class WebView;
@class WebClipper;

@class WCClipperView;

// The plug-in's view in the widget window. The clip is in the page window over it; this view draws
// what the page window last showed.
@interface WCPlaceholderView : NSView
@property (nonatomic, weak) WCClipperView *clipperView;
@property (nonatomic, strong) NSImage *image;
@end

@interface WCClipperView : WCRolloverTrackingView

- (instancetype)initWithFrame:(NSRect)frame dashboardWebView:(WebView *)dashboardWebView;

- (WCPlaceholderView *)placeholderView;
- (void)placeholderDidChange;
- (BOOL)widgetWindowDidReceiveEvent:(NSEvent *)event;
- (BOOL)showsPageWindow;
- (void)webPlugInDestroy;
// The clip's extensions stop, as the clip goes away.
- (void)stopExtensions;
- (void)widgetDidStartMoving;
- (void)widgetDidStopMoving;

- (WebClipper *)controller;
- (WebScriptObject *)widgetScriptObject;

- (void)displayLoadingText;
- (void)loadURLString:(NSString *)URLString clipRect:(NSRect)clipRect clipSignature:(NSDictionary *)clipSignature pageSize:(NSSize)pageSize displayLoadingText:(BOOL)displayLoadingText resizeWidget:(BOOL)resizeWidget;
- (void)setTheme:(int)themeID;
- (void)switchToThemeAtIndex:(unsigned)index;
- (int)currentThemeID;
- (void)editCameraPosition;
- (void)didShowWidget;
- (void)didHideWidget;
- (void)didFlipWidget:(BOOL)toFront;
- (void)notifyTransitionIsComplete;
- (void)setTransitionInProgress;
- (void)fadeButtonWithOpacity:(float)opacity;
- (void)prepareWidgetForSnapshot;

- (NSRect)convertDOMRectToDashboardControlRegion:(NSRect)rect;
- (void)pageDraggableRects:(void (^)(NSArray *documentRects))completionHandler;

@end
