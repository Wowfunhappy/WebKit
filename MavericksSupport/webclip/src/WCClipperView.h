// The Web Clip plug-in view: the clipped page (an out-of-process WKWebView scrolled inside a clip
// view), the theme drawn around it, the flip ("i") button, and the edit-mode controls.

#import "WCThemes.h"

@class WebScriptObject;
@class WebView;
@class WebClipper;

@interface WCClipperView : WCRolloverTrackingView

- (instancetype)initWithFrame:(NSRect)frame dashboardWebView:(WebView *)dashboardWebView;

- (WebClipper *)controller;
- (WebScriptObject *)widgetScriptObject;

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
