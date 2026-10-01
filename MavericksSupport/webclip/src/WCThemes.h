// Chrome drawn around a Web Clip: the six themes, the edit-mode border and its Done button,
// and the small views the clipper view composes them with.

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(int, WCThemeID) {
    WCThemeGlass = 0,
    WCThemeBlackEdge = 1,
    WCThemeVintageCorners = 2,
    WCThemeDeckled = 3,
    WCThemePegboard = 4,
    WCThemeTornEdge = 5,
};

// The widget-side object DashboardClient hands out as -[DBCWebView widget].
@protocol WCDashboardWidget <NSObject>
- (NSWindow *)createAttachedWindow:(NSRect)frame options:(unsigned int)options;
- (void)releaseAttachedWindow:(NSWindow *)window;
- (void)orderAttachedWindow:(NSWindow *)window place:(NSWindowOrderingMode)place relativeTo:(int)relativeTo delayed:(BOOL)delayed;
- (void)setEventRegionWithRects:(const NSRect *)rects count:(int)count;
- (mach_port_t)serverPort;
- (void)bringToFront;
- (void)receivedMouseOrKeyDown;
- (BOOL)isFocused;
- (void)hasKeyFocus:(BOOL)hasKeyFocus updateWindowState:(BOOL)updateWindowState;
@end

// The widget's own WebView (a WebKit 1 WebView extended by DashboardClient).
@protocol WCDashboardWebView <NSObject>
- (id<WCDashboardWidget>)widget;
@end

// Looks up a key in the plug-in bundle's Localizable.strings.
NSString *WCLocalizedString(const char *key);

@interface NSImage (WCExtras)
+ (NSImage *)wc_PNGNamed:(NSString *)name;
+ (NSImage *)wc_flippedPNGNamed:(NSString *)name;
- (void)wc_drawAtPoint:(NSPoint)point dirtyRect:(NSRect)dirtyRect;
- (void)wc_drawAtPoint:(NSPoint)point dirtyRect:(NSRect)dirtyRect fraction:(float)fraction;
- (void)wc_drawInRect:(NSRect)rect dirtyRect:(NSRect)dirtyRect;
- (void)wc_drawInRect:(NSRect)rect dirtyRect:(NSRect)dirtyRect fraction:(float)fraction;
- (NSImage *)wc_tintedImageWithColor:(NSColor *)color;
- (NSImage *)wc_tintedImageWithColor:(NSColor *)color operation:(NSCompositingOperation)operation;
@end

@interface NSView (WCExtras)
- (void)wc_drawLeftImage:(NSImage *)left middleImage:(NSImage *)middle rightImage:(NSImage *)right inRect:(NSRect)rect dirtRect:(NSRect)dirtyRect operation:(NSCompositingOperation)operation middlePinning:(int)middlePinning;
@end

@class WCRolloverTrackingView;

@protocol WCRolloverTrackingViewDelegate <NSObject>
@optional
- (void)rolloverTrackingView:(WCRolloverTrackingView *)view mouseEnteredOrExited:(BOOL)entered;
@end

@interface WCRolloverTrackingView : NSImageView
@property (nonatomic, unsafe_unretained) id delegate;
@property (nonatomic) BOOL redrawOnMouseEnteredAndExited;
- (void)initTrackingRect;
- (BOOL)mouseIsOver;
- (void)mouseEnteredOrExited:(BOOL)entered;
- (void)updateMouseIsOver:(int)state;
- (void)removeTrackingRect;
- (void)updateTrackingRect;
- (void)_updateTrackingRectSoon;
@end

@interface WCDoneButton : WCRolloverTrackingView
- (void)setAction:(SEL)action;
- (void)setTarget:(id)target;
- (void)setIsPressed:(BOOL)pressed;
- (NSImage *)doneButtonImage;
- (NSImage *)pressedDoneButtonImage;
- (NSImage *)buttonImage;
@end

@interface WCErrorView : NSView
- (void)setMessage:(NSString *)message;
@end

@interface WCVoidView : NSView
- (void)setIsBlack:(BOOL)isBlack;
@end

@interface WCTheme : NSView {
@protected
    __unsafe_unretained NSWindow *_attachedWindow;
    __unsafe_unretained WCDoneButton *_doneButton;
    BOOL _drawsInnerBezel;
    float _editModeBorderOpacity;
    NSAnimation *_editModeBorderFade;
    __unsafe_unretained id _widgetObject;
    NSImage *_topLeftEditCorner;
    NSImage *_topRightEditCorner;
    NSImage *_bottomLeftEditCorner;
    NSImage *_underDoneButton;
    NSImage *_bottomRightEditCorner;
    NSImage *_bottomEditStretch;
    NSImage *_topEditStretch;
    NSImage *_leftEditStretch;
    NSImage *_rightEditStretch;
    NSImage *_resizer;
}
+ (int)borderLeft;
+ (int)borderRight;
+ (int)borderTop;
+ (int)borderBottom;
// A view that shows the theme where the clip's own window covers the theme's. The theme's own
// window leaves that area, in the theme's coordinates, to it.
@property (nonatomic, weak) NSView *overlay;
@property (nonatomic) NSRect pageArea;
// Draws the page area too, for the overlay and the stand-in.
- (void)drawIncludingPageAreaIntoContext:(NSGraphicsContext *)context;
// Hears of a click in the theme's window, which the Dock has brought to the front with its widget.
@property (nonatomic, weak) id clickTarget;
@property (nonatomic) SEL clickAction;
- (void)setDashboardWebView:(id)dashboardWebView;
- (void)setDoneButton:(WCDoneButton *)doneButton;
- (void)buttonStateChanged;
- (NSRect)innerBezelFrame;
- (NSRect)innerBezelRect;
- (NSPoint)flipperButtonOriginInFrame:(NSRect)frame;
- (NSPoint)doneButtonOriginInFrame:(NSRect)frame;
- (NSPoint)resizerOrigin:(NSRect)frame;
- (int)resizerImageInsetX;
- (int)resizerImageInsetY;
- (int)resizerInsetX;
- (int)resizerInsetY;
- (NSSize)resizerFrameSize;
- (void)drawInnerBezelInRect:(NSRect)rect;
- (void)loadBezelImages;
- (void)deallocBezelImages;
- (NSImage *)doneButtonImage;
- (NSImage *)resizerImage;
- (void)orderAttachedWindow:(NSWindowOrderingMode)place relativeTo:(int)relativeTo delayed:(BOOL)delayed;
- (void)releaseAttachedWindow;
- (BOOL)drawsInAttachedWindow;
- (void)setEventRegion:(NSRect)rect;
- (NSRect)controlRegion;
- (NSRect)displacementRect;
- (int)themeID;
- (int)clipInsetLeft;
- (int)clipInsetTop;
- (int)clipInsetBottom;
- (NSSize)minSize;
- (void)shouldLoadImages:(BOOL)shouldLoad;
- (void)setDrawsInnerBezel:(BOOL)drawsInnerBezel;
- (void)showEditModeBorder;
- (void)hideEditModeBorder;
- (int)doneButtonInsetY;
- (int)innerBezelInsetX;
- (int)innerBezelInsetY;
- (int)innerBezelWidth;
- (int)innerBezelHeight;
- (float)innerBezelOpacity;
@end

// Implemented by each concrete theme; WCTheme itself has no frame artwork.
@interface WCTheme (WCThemeArtwork)
- (void)drawThemeInRect:(NSRect)rect;
@end

@interface WCGlassTheme : WCTheme
@end

@interface WCBlackEdgeTheme : WCTheme
@end

@interface WCVintageCornersTheme : WCTheme
@end

// "Deckled Edge" in the UI.
@interface WCScallopedTheme : WCTheme
@end

@interface WCPegboardTheme : WCTheme
@end

@interface WCTornEdgeTheme : WCTheme
@end
