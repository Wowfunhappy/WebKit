#import "WCClipperView.h"
#import <dlfcn.h>

#import <QuartzCore/QuartzCore.h>

#import "WCSnapper.h"
#import "WebClipper.h"
#import "WCWebKitSPI.h"

// AppKit posts this for every mouse-moved event it dispatches.
extern NSString * const NSMouseMovedNotification;

@interface NSURL (WCWebKitExtras)
+ (NSURL *)_web_URLWithUserTypedString:(NSString *)string;
@end

@interface NSError (WCFoundationExtras)
- (BOOL)_web_errorIsInDomain:(NSString *)domain;
@end

@interface NSString (WCFoundationExtras)
- (NSString *)_web_domainFromHost;
@end

// A Web Clip error page's message.
static NSString *messageForError(NSError *error, NSString *URLString)
{
    if ([error code] == NSURLErrorNotConnectedToInternet)
        return WCLocalizedString("Please connect to the Internet");
    NSURL *URL = [[NSURL alloc] initWithString:URLString];
    if ([URL isFileURL])
        return [NSString stringWithFormat:WCLocalizedString("Cannot access %@"), [URLString lastPathComponent]];
    NSString *domain = [[URL host] _web_domainFromHost];
    if (![domain rangeOfString:@"."].location)
        domain = [domain substringFromIndex:1];
    return [NSString stringWithFormat:WCLocalizedString("Cannot load page on %@"), domain];
}

// The page's script-message handler, holding the view weakly so the web view's configuration does
// not keep the plug-in view alive.
@interface WCScriptMessageProxy : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WCClipperView *view;
@end

@interface WCClipperView () <WKNavigationDelegate, WKUIDelegate, _WKFullscreenDelegate>
- (void)pageDidPostMessage:(NSDictionary *)message;
- (void)pageWindowWillSendEvent:(NSEvent *)event;
- (NSPoint)themeWindowOrigin;
@end

// The event AppKit delivers when the key focus passes between processes.
static const NSEventType WCProcessNotificationEventType = 21;

// CoreGraphics: places a window among the windows of its level, whoever owns the others.
extern int CGSMainConnectionID(void);
extern CGError CGSOrderWindow(int connection, int window, int place, int relativeToWindow);
extern CGError CGSSetWindowListAlpha(int connection, const int *windows, int count, float alpha, float duration);

// DashboardClient: the Dock lets a widget in Dashboard's layer put a window of its own on screen
// from the moment Dashboard starts to show its widgets until the moment it starts to take them
// away.
typedef kern_return_t (*WCDockCanShowMenuFunction)(mach_port_t serverPort, int *canShowMenu);

// The Dock keeps a widget dragged out of Dashboard on the desktop, in a window at this level below
// Dashboard's own windows. Dashboard covers such a widget and never animates it, and nothing tells
// its process when Dashboard comes and goes.
static const NSInteger WCDesktopWidgetWindowLevel = 98;

@implementation WCScriptMessageProxy

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    if ([message.body isKindOfClass:[NSDictionary class]])
        [self.view pageDidPostMessage:message.body];
}

@end

// The page window holds the clip: the page, the controls over it and a theme that draws with it.
// It is DashboardClient's own window, placed over the part of the plug-in's view that lies inside
// the widget window. The clipper view keeps the plug-in view's full size within it.
@interface WCPageWindow : NSPanel
@property (nonatomic, weak) WCClipperView *clipperView;
@end

// AppKit: orders a window, and looks for the next key window among the application's windows
// when asked to.
@interface NSWindow (WCAppKitSPI)
- (void)_doOrderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWindow findKey:(BOOL)findKey forCounter:(BOOL)forCounter force:(BOOL)force isModal:(BOOL)isModal;
@end

// AppKit: the same event, located in another window.
@interface NSEvent (WCAppKitSPI)
- (NSEvent *)_eventRelativeToWindow:(NSWindow *)window;
@end

@implementation WCPageWindow

- (BOOL)canBecomeKeyWindow
{
    return YES;
}

- (void)sendEvent:(NSEvent *)event
{
    [_clipperView pageWindowWillSendEvent:event];
    [super sendEvent:event];
}

@end

// The page window lies over the theme's window, and the overlay shows the theme over the page. The
// overlay is a subview of the clipper view.
@interface WCThemeOverlayView : NSView
@property (nonatomic, weak) WCTheme *theme;
- (void)drawTheme;
@end

@implementation WCThemeOverlayView

- (NSView *)hitTest:(NSPoint)point
{
    return nil;
}

- (void)drawRect:(NSRect)rect
{
    [self drawTheme];
}

// Draws the theme as it lies over the overlay, in the overlay's coordinates.
- (void)drawTheme
{
    WCTheme *theme = _theme;
    if (![theme window] || ![self window])
        return;
    NSRect frame = [[self window] convertRectToScreen:[self convertRect:[self bounds] toView:nil]];
    NSPoint origin = [(WCClipperView *)[self superview] themeWindowOrigin];
    NSRect themeFrame = NSOffsetRect([theme convertRect:[theme bounds] toView:nil], origin.x, origin.y);
    // The theme draws into a bitmap of its own, which takes the offset between the two windows.
    NSRect bounds = [self bounds];
    NSBitmapImageRep *bitmap = [self bitmapImageRepForCachingDisplayInRect:bounds];
    [bitmap setSize:bounds.size];
    memset([bitmap bitmapData], 0, [bitmap bytesPerRow] * [bitmap pixelsHigh]);
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    CGContextTranslateCTM([context graphicsPort], NSMinX(themeFrame) - NSMinX(frame), NSMinY(themeFrame) - NSMinY(frame));
    [theme drawIncludingPageAreaIntoContext:context];
    [bitmap drawInRect:bounds fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1 respectFlipped:YES hints:nil];
}

@end

@implementation WCPlaceholderView

- (void)setImage:(NSImage *)image
{
    _image = image;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)rect
{
    if (![_clipperView showsPageWindow])
        [_image drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [_clipperView placeholderDidChange];
}

- (void)mouseDown:(NSEvent *)event
{
    if (![_clipperView widgetWindowDidReceiveEvent:event])
        [super mouseDown:event];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (![_clipperView widgetWindowDidReceiveEvent:event])
        [super mouseDragged:event];
}

- (void)mouseUp:(NSEvent *)event
{
    if (![_clipperView widgetWindowDidReceiveEvent:event])
        [super mouseUp:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
    if (![_clipperView widgetWindowDidReceiveEvent:event])
        [super rightMouseDown:event];
}

- (void)rightMouseUp:(NSEvent *)event
{
    if (![_clipperView widgetWindowDidReceiveEvent:event])
        [super rightMouseUp:event];
}

- (void)scrollWheel:(NSEvent *)event
{
    if (![_clipperView widgetWindowDidReceiveEvent:event])
        [super scrollWheel:event];
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    [_clipperView placeholderDidChange];
}

- (void)setFrameOrigin:(NSPoint)origin
{
    [super setFrameOrigin:origin];
    [_clipperView placeholderDidChange];
}

- (void)viewDidHide
{
    [super viewDidHide];
    [_clipperView placeholderDidChange];
}

- (void)viewDidUnhide
{
    [super viewDidUnhide];
    [_clipperView placeholderDidChange];
}

- (void)webPlugInDestroy
{
    [_clipperView webPlugInDestroy];
}

@end

static NSImage *flipperImage;

// The clipped page is remote layers, so the views of the page window are layer-backed.
static void addLayerBackedSubview(NSView *parent, NSView *view)
{
    [view setWantsLayer:YES];
    [parent addSubview:view];
}

static NSRect rectFromPageRect(id value)
{
    if (![value isKindOfClass:[NSDictionary class]])
        return NSZeroRect;
    NSDictionary *rect = value;
    return NSMakeRect([rect[@"x"] doubleValue], [rect[@"y"] doubleValue], [rect[@"width"] doubleValue], [rect[@"height"] doubleValue]);
}

@implementation WCClipperView {
    WCPlaceholderView *_placeholder;
    WCPageWindow *_pageWindow;
    BOOL _hasScreenshot;
    BOOL _isWidgetMoving;
    BOOL _dockAllowsPageWindow;
    NSClipView *_clipView;
    WebClipper *_controller;
    WCTheme *_currentTheme;
    WCErrorView *_errorView;
    NSButton *_flipButton;
    NSImageView *_flipperImageView;
    WCThemeOverlayView *_themeOverlay;
    WCDoneButton *_lockCameraButton;
    NSTimer *_progressTimer;
    NSView *_resizer;
    NSImageView *_pageSnapshotView;
    WCSnapper *_snapper;
    NSTextField *_statusTextField;
    WCVoidView *_voidView;
    WCVoidView *_pageCover;
    WKWebView *_webView;
    WKContentWorld *_pageWorld;
    NSPoint _mouseDownPoint;
    NSSize _mouseDownWindowSize;
    NSRect _mouseDownClipViewBounds;
    BOOL _shouldClearScreenshotOnRentry;
    BOOL _isHidden;
    BOOL _didFlipToFront;
    BOOL _disableAutoRefresh;
    BOOL _isEditingCameraPosition;
    BOOL _isResizing;
    BOOL _isMouseDown;
    BOOL _hasBeenMovedToWindow;
    BOOL _isLoading;
    BOOL _loadError;
    BOOL _hasBeenShown;
    BOOL _transitionInProgress;
    NSRect _clipRectAfterTransition;
    NSPoint _pageScroll;
    NSPoint _pageScrollTarget;
    BOOL _hasPageScrollTarget;
    NSPoint _clipViewportOrigin;
    NSSize _documentSize;
    unsigned _progressPeriodCount;
}

+ (NSImage *)flipperImage
{
    if (!flipperImage)
        flipperImage = [NSImage wc_PNGNamed:@"flipper"];
    return flipperImage;
}

- (WebClipper *)controller
{
    return _controller;
}

- (WebScriptObject *)windowScriptObject
{
    return [[self controller] windowScriptObject];
}

- (WebScriptObject *)widgetScriptObject
{
    return [[self windowScriptObject] valueForKey:@"widget"];
}

- (WebScriptObject *)documentScriptObject
{
    return [[self windowScriptObject] valueForKey:@"document"];
}

- (WebScriptObject *)clipperScriptObject
{
    return [[self documentScriptObject] callWebScriptMethod:@"getElementById" withArguments:[NSArray arrayWithObject:@"clipper"]];
}

- (void)setClipperStyle:(NSString *)style
{
    [[self clipperScriptObject] callWebScriptMethod:@"setAttribute" withArguments:[NSArray arrayWithObjects:@"style", style, nil]];
}

- (void)setDashboardRegion:(NSString *)region
{
    [self setClipperStyle:[@"-apple-dashboard-region:" stringByAppendingString:region]];
}

- (NSString *)stringForClickableRect:(NSRect)rect
{
    NSRect bounds = [self bounds];
    int bottom = (int)roundf((float)(bounds.size.height - (rect.origin.y + rect.size.height)));
    float right = roundf((float)(bounds.size.width - (rect.origin.x + rect.size.width)));
    float top = roundf((float)rect.origin.y);
    float left = roundf((float)rect.origin.x);
    return [NSString stringWithFormat:@"dashboard-region(control rectangle %dpx %dpx %dpx %dpx)", bottom, (int)right, (int)top, (int)left];
}

- (BOOL)isBacksideShowing
{
    return !_didFlipToFront && _hasBeenShown;
}

- (void)updateEventRegion
{
    NSRect region;
    if ([self isBacksideShowing])
        region = NSMakeRect(0, 0, [WebClipper backsideWidth], [WebClipper backsideHeight]);
    else
        region = [self frame];
    [_currentTheme setEventRegion:region];
}

- (WCPlaceholderView *)placeholderView
{
    return _placeholder;
}

// DashboardClient keeps a theme's attached window on the widget's window, frame for frame. When the Dock
// moves the widget, DashboardClient updates the widget window's frame in this process and leaves the
// attached window's, so the attached window lies on screen at the widget window's origin.
- (NSPoint)themeWindowOrigin
{
    return [[_placeholder window] frame].origin;
}

- (NSRect)placeholderFrameOnScreen
{
    return [[_placeholder window] convertRectToScreen:[_placeholder convertRect:[_placeholder bounds] toView:nil]];
}

// The plug-in's view can overhang the widget window, which clips it, and the page window shows the
// same part of the clip.
- (void)placePageWindow
{
    NSRect placeholderFrame = [self placeholderFrameOnScreen];
    NSRect frame = NSIntersectionRect(placeholderFrame, [[_placeholder window] frame]);
    if (!NSEqualRects(frame, [_pageWindow frame]))
        [_pageWindow setFrame:frame display:YES];
    NSRect clipperFrame = NSOffsetRect(placeholderFrame, -NSMinX(frame), -NSMinY(frame));
    if (!NSEqualRects(clipperFrame, [self frame]))
        [self setFrame:clipperFrame];
}

// The page window shows while Dashboard shows the widget's front, still and live.
- (BOOL)showsPageWindow
{
    return [_placeholder window] && ![_placeholder isHiddenOrHasHiddenAncestor] && _hasBeenShown && !_isHidden
        && _dockAllowsPageWindow && !_hasScreenshot && !_isWidgetMoving && ![self isBacksideShowing];
}

- (void)updatePageWindow
{
    BOOL shows = [self showsPageWindow];
    if (shows != [_pageWindow isVisible])
        [_placeholder setNeedsDisplay:YES];
    if (!shows) {
        [self orderPageWindowOut];
        return;
    }
    [self placePageWindow];
    [self updateThemeOverlay];
    // The page window is the front one of the widget's windows.
    if (![_pageWindow isVisible])
        [_pageWindow orderFront:nil];
    int connection = CGSMainConnectionID();
    int pageWindowNumber = (int)[_pageWindow windowNumber];
    CGSOrderWindow(connection, pageWindowNumber, NSWindowAbove, (int)[[_placeholder window] windowNumber]);
    NSWindow *themeWindow = [_currentTheme drawsInAttachedWindow] ? [_currentTheme window] : nil;
    if ([themeWindow windowNumber] > 0)
        CGSOrderWindow(connection, pageWindowNumber, NSWindowAbove, (int)[themeWindow windowNumber]);
    if ([[_placeholder window] isKeyWindow])
        [self makePageWindowKey];
}

// The key window goes back to the widget's own window, which the Dock orders.
- (void)orderPageWindowOut
{
    if ([_pageWindow isKeyWindow])
        [[_placeholder window] makeKeyWindow];
    if ([_pageWindow isVisible])
        [_pageWindow _doOrderWindow:NSWindowOut relativeTo:0 findKey:NO forCounter:NO force:NO isModal:NO];
    int pageWindowNumber = (int)[_pageWindow windowNumber];
    CGSSetWindowListAlpha(CGSMainConnectionID(), &pageWindowNumber, 1, 1, 0);
}

- (void)updateThemeOverlay
{
    BOOL drawsInAttachedWindow = [_currentTheme drawsInAttachedWindow];
    [_themeOverlay setTheme:drawsInAttachedWindow ? _currentTheme : nil];
    [_currentTheme setOverlay:drawsInAttachedWindow ? _themeOverlay : nil];
    [_currentTheme setClickTarget:self];
    [_currentTheme setClickAction:@selector(widgetWindowDidReceiveMouseDown)];
    [_themeOverlay setHidden:!drawsInAttachedWindow || [_clipView isHidden]];
    [_themeOverlay setFrame:[_clipView frame]];
    [_themeOverlay setNeedsDisplay:YES];
    NSRect pageArea = NSZeroRect;
    if (drawsInAttachedWindow && [_currentTheme window] && [self window]) {
        NSRect onScreen = [[self window] convertRectToScreen:[self convertRect:[_clipView frame] toView:nil]];
        NSPoint origin = [self themeWindowOrigin];
        pageArea = [_currentTheme convertRect:NSOffsetRect(onScreen, -origin.x, -origin.y) fromView:nil];
    }
    [_currentTheme setPageArea:pageArea];
}

- (void)placeholderDidChange
{
    if ([_placeholder window] && !_pageWindow) {
        // Dashboard's clients stay in the background, and their windows are panels that take the key
        // focus with the key window.
        _pageWindow = [[WCPageWindow alloc] initWithContentRect:[self placeholderFrameOnScreen] styleMask:NSBorderlessWindowMask | NSNonactivatingPanelMask backing:NSBackingStoreBuffered defer:NO];
        [_pageWindow setFloatingPanel:NO];
        [_pageWindow setHidesOnDeactivate:NO];
        [_pageWindow setReleasedWhenClosed:NO];
        [_pageWindow setOpaque:NO];
        [_pageWindow setBackgroundColor:[NSColor clearColor]];
        [_pageWindow setHasShadow:NO];
        // Clicks and scrolling over the widget reach the widget window, where the Dock drags the
        // widget from points outside its control regions and delivers the rest to the widget.
        [_pageWindow setIgnoresMouseEvents:YES];
        [_pageWindow setLevel:[[_placeholder window] level]];
        [_pageWindow setContentView:[[NSView alloc] init]];
        [_pageWindow setClipperView:self];
        [self placePageWindow];
        [[_pageWindow contentView] addSubview:self];
        // The window is one layer tree, frame view included.
        [[[_pageWindow contentView] superview] setWantsLayer:YES];
        [WCClipperView observeDashboardForWidgetWindow:[_placeholder window]];
        [clipperViews addObject:self];
        [WCClipperView askDock];
    }
    [self updatePageWindow];
}

// The widget window shows the clip while the page window is out: while Dashboard shows and hides
// its widgets, and while the widget moves. The page renders the stand-in when it has finished
// loading and when it has painted, when the pointer leaves it and when it gives up the key window.
static NSImage *imageOfView(NSView *view, NSRect rect)
{
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:rect];
    [view cacheDisplayInRect:rect toBitmapImageRep:bitmap];
    NSImage *image = [[NSImage alloc] initWithSize:rect.size];
    [image addRepresentation:bitmap];
    return image;
}

// The stand-in is what the page window shows: the clip view's content where the content mask keeps
// it, the status text, and the theme over them. The clip view's content is the cover while it shows,
// and otherwise the void with the page's snapshot over it in the given rect.
- (void)setStandInWithPageSnapshot:(NSImage *)snapshot inRect:(NSRect)snapshotRect
{
    NSRect clipFrame = [_clipView frame];
    NSRect clipRect = NSMakeRect(0, 0, NSWidth(clipFrame), NSHeight(clipFrame));
    NSImage *content = [[NSImage alloc] initWithSize:clipRect.size];
    [content lockFocus];
    [[([_pageCover isHidden] ? _voidView : _pageCover) color] set];
    NSRectFill(clipRect);
    [snapshot drawInRect:snapshotRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    CGImageRef mask = (__bridge CGImageRef)[[[_clipView layer] mask] contents];
    if (mask) {
        CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
        CGContextSetBlendMode(context, kCGBlendModeDestinationIn);
        CGContextDrawImage(context, NSRectToCGRect(clipRect), mask);
    }
    [content unlockFocus];

    NSImage *standIn = [[NSImage alloc] initWithSize:[self bounds].size];
    [standIn lockFocus];
    [content drawInRect:clipFrame fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    if (![_statusTextField isHidden])
        [imageOfView(_statusTextField, [_statusTextField bounds]) drawInRect:[_statusTextField frame] fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    if ([_currentTheme superview] == self)
        [_currentTheme displayRectIgnoringOpacity:[_currentTheme bounds] inContext:[NSGraphicsContext currentContext]];
    else if (![_themeOverlay isHidden]) {
        NSAffineTransform *transform = [NSAffineTransform transform];
        [transform translateXBy:NSMinX([_themeOverlay frame]) yBy:NSMinY([_themeOverlay frame])];
        [transform concat];
        [_themeOverlay drawTheme];
    }
    [standIn unlockFocus];
    [_placeholder setImage:standIn];
}

- (void)updateStandIn
{
    WKWebView *webView = _webView;
    if (!webView || _hasScreenshot || NSIsEmptyRect([_clipView bounds]))
        return;
    if (![_pageCover isHidden]) {
        [self setStandInWithPageSnapshot:nil inRect:NSZeroRect];
        return;
    }
    NSRect pageRect = NSIntersectionRect([_clipView bounds], [webView frame]);
    if (NSIsEmptyRect(pageRect))
        return;
    WKSnapshotConfiguration *configuration = [[WKSnapshotConfiguration alloc] init];
    configuration.rect = [webView convertRect:pageRect fromView:_voidView];
    NSRect clipFrame = [_clipView frame];
    NSRect frame = [self convertRect:pageRect fromView:_voidView];
    NSRect snapshotRect = NSOffsetRect(frame, -NSMinX(clipFrame), -NSMinY(clipFrame));
    [webView takeSnapshotWithConfiguration:configuration completionHandler:^(NSImage *image, NSError *error) {
        if (!image || webView != _webView || _hasScreenshot || ![_pageCover isHidden])
            return;
        [self setStandInWithPageSnapshot:image inRect:snapshotRect];
    }];
}

- (id<WCDashboardWidget>)dashboardWidget
{
    return [(id<WCDashboardWebView>)[[self controller] dashboardWebView] widget];
}

- (BOOL)dockAllowsPageWindow
{
    if ([[_placeholder window] level] == WCDesktopWidgetWindowLevel)
        return YES;
    static WCDockCanShowMenuFunction canShowMenuFunction;
    if (!canShowMenuFunction)
        canShowMenuFunction = (WCDockCanShowMenuFunction)dlsym(RTLD_DEFAULT, "_DBCanIShowMenu");
    int canShowMenu = 0;
    if (canShowMenuFunction([[self dashboardWidget] serverPort], &canShowMenu))
        return NO;
    return canShowMenu;
}

// The Dock changes its mind as Dashboard starts to show its widgets and to take them away. The
// plug-in asks it when the key focus passes between processes, when a widget's window takes or
// resigns the key window, and when Dashboard reports a widget shown or hidden. Every page window
// that leaves has its stand-in on screen before the first of them is ordered out.
static NSHashTable *clipperViews;

+ (void)observeDashboardForWidgetWindow:(NSWindow *)widgetWindow
{
    if (clipperViews)
        return;
    clipperViews = [NSHashTable weakObjectsHashTable];
    Class widgetWindowClass = [widgetWindow class];
    void (^keyWindowDidChange)(NSNotification *) = ^(NSNotification *notification) {
        if ([[notification object] isKindOfClass:widgetWindowClass])
            [WCClipperView askDock];
    };
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:keyWindowDidChange];
    [center addObserverForName:NSWindowDidResignKeyNotification object:nil queue:nil usingBlock:keyWindowDidChange];
    // The Dock stacks a widget's windows afresh as the widget takes the key focus.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFromType(WCProcessNotificationEventType) handler:^NSEvent *(NSEvent *event) {
        [WCClipperView askDock];
        for (WCClipperView *view in [clipperViews allObjects])
            [view updatePageWindow];
        return event;
    }];
}

+ (void)askDock
{
    static BOOL isAsking;
    if (isAsking)
        return;
    isAsking = YES;
    NSMutableArray *changedViews = nil;
    NSMutableData *leavingWindows = [NSMutableData dataWithLength:[clipperViews count] * sizeof(int)];
    int leavingCount = 0;
    for (WCClipperView *view in [clipperViews allObjects]) {
        if (!view->_pageWindow || [view dockAllowsPageWindow] == view->_dockAllowsPageWindow)
            continue;
        if (!changedViews)
            changedViews = [NSMutableArray array];
        [changedViews addObject:view];
        if (view->_dockAllowsPageWindow) {
            [view showStandIn];
            if ([view->_pageWindow isVisible])
                ((int *)[leavingWindows mutableBytes])[leavingCount++] = (int)[view->_pageWindow windowNumber];
        } else
            view->_dockAllowsPageWindow = YES;
    }
    // Every call on the window server waits for Dashboard's animation: one call takes all the
    // leaving windows off screen, and each is ordered out behind it.
    if (leavingCount)
        CGSSetWindowListAlpha(CGSMainConnectionID(), [leavingWindows bytes], leavingCount, 0, 0);
    for (WCClipperView *view in changedViews)
        [view updatePageWindow];
    isAsking = NO;
}

- (void)showStandIn
{
    _dockAllowsPageWindow = NO;
    if (![_pageWindow isVisible])
        return;
    [self updateStandIn];
    [_placeholder display];
}

// The page window holds the key window for its widget, which keeps its focus meanwhile.
- (void)makePageWindowKey
{
    id<WCDashboardWidget> widget = [self dashboardWidget];
    BOOL isFocused = [widget isFocused];
    [_pageWindow makeKeyWindow];
    if (isFocused && ![widget isFocused])
        [widget hasKeyFocus:YES updateWindowState:NO];
}

// The widget window passes these events to its widget.
- (void)pageWindowWillSendEvent:(NSEvent *)event
{
    NSEventType type = [event type];
    if (type == NSMouseEntered || type == NSKeyDown)
        [[self dashboardWidget] receivedMouseOrKeyDown];
}

// The page window lies over the placeholder and takes the clicks and scrolling the Dock delivers to it.
- (BOOL)widgetWindowDidReceiveEvent:(NSEvent *)event
{
    NSEventType type = [event type];
    BOOL isMouseDown = type == NSLeftMouseDown || type == NSRightMouseDown || type == NSOtherMouseDown;
    if (isMouseDown)
        [self widgetWindowDidReceiveMouseDown];
    if (![_pageWindow isVisible])
        return NO;
    // A widget acts on the click that brings it to the front.
    if (isMouseDown && ![_pageWindow isKeyWindow])
        [self makePageWindowKey];
    [_pageWindow sendEvent:[event _eventRelativeToWindow:_pageWindow]];
    return YES;
}

// A widget that gives up its focus resigns its window and clears the application's key window.
- (void)widgetWindowDidResignKey:(NSNotification *)notification
{
    if ([notification object] == [_placeholder window] && [_pageWindow isKeyWindow] && ![[self dashboardWidget] isFocused])
        [_pageWindow resignKeyWindow];
    if ([notification object] == _pageWindow)
        [self updateStandIn];
}

// The Dock brings a widget's windows to the front when a click lands in them.
- (void)widgetWindowDidReceiveMouseDown
{
    [self updatePageWindow];
}

- (void)widgetWindowDidMove:(NSNotification *)notification
{
    if ([notification object] == [_placeholder window])
        [self updatePageWindow];
}

// The Dock orders the widget's windows when the widget takes the key window.
- (void)windowDidBecomeKey:(NSNotification *)notification
{
    if ([notification object] == [_placeholder window])
        [self updatePageWindow];
}

- (void)widgetDidStartMoving
{
    [self updateStandIn];
    _isWidgetMoving = YES;
    [self updatePageWindow];
}

- (void)widgetDidStopMoving
{
    _isWidgetMoving = NO;
    [self updatePageWindow];
}

// A screenshot of the widget stands in for it in the widget window, over white where the clip is.
- (void)setScreenshot:(NSImage *)screenshot
{
    _hasScreenshot = screenshot != nil;
    if (screenshot) {
        NSImage *image = [[NSImage alloc] initWithSize:[screenshot size]];
        [image lockFocus];
        [[NSColor whiteColor] set];
        NSRectFillUsingOperation([_clipView frame], NSCompositeCopy);
        [screenshot drawAtPoint:NSZeroPoint fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
        [image unlockFocus];
        [_placeholder setImage:image];
    } else
        [self updateStandIn];
    [self updatePageWindow];
}

- (void)setTransitionInProgress
{
    _transitionInProgress = YES;
}

- (void)updateFlipperVisibility
{
    BOOL hidden = YES;
    if ([[self controller] hasSettings] && !_isLoading && !_loadError && !_isEditingCameraPosition)
        hidden = _hasScreenshot || _pageSnapshotView;
    [_flipButton setHidden:hidden];
    [_flipperImageView setHidden:hidden];
    [_themeOverlay setNeedsDisplay:YES];
}

- (void)clearScreenshot
{
    [self setScreenshot:nil];
    [_pageSnapshotView removeFromSuperview];
    _pageSnapshotView = nil;
    [_clipView setHidden:NO];
    [self updateFlipperVisibility];
}

- (void)clearScreenshotIfNeeded
{
    if (_isHidden) {
        _shouldClearScreenshotOnRentry = YES;
        return;
    }
    if (_shouldClearScreenshotOnRentry) {
        if (!_isLoading) {
            [self clearScreenshot];
            _shouldClearScreenshotOnRentry = NO;
        }
        return;
    }
    if (_isLoading || _transitionInProgress)
        return;
    [self clearScreenshot];
}

- (void)setDraggableRects:(NSArray *)rects
{
    int count = (int)[rects count];
    if (!count) {
        [self setDashboardRegion:@"none"];
        return;
    }
    NSMutableString *region = [NSMutableString string];
    for (int i = 0; i < count; ++i) {
        if (i)
            [region appendString:@" "];
        NSValue *value = [rects objectAtIndex:i];
        NSRect rect = value ? [value rectValue] : NSZeroRect;
        [region appendString:[self stringForClickableRect:rect]];
    }
    [self setDashboardRegion:region];
}

- (void)setClickableRect:(NSRect)rect
{
    [self setDashboardRegion:[self stringForClickableRect:rect]];
}

- (void)setClipperSize:(NSSize)size
{
    WebScriptObject *clipper = [self clipperScriptObject];
    [clipper callWebScriptMethod:@"setAttribute" withArguments:[NSArray arrayWithObjects:@"width", [[NSNumber numberWithFloat:size.width] stringValue], nil]];
    [clipper callWebScriptMethod:@"setAttribute" withArguments:[NSArray arrayWithObjects:@"height", [[NSNumber numberWithFloat:size.height] stringValue], nil]];
}

- (NSSize)minClipperSize
{
    return [_currentTheme minSize];
}

// A clip is at most 20000 points on a side, as in stock.
static const CGFloat WCMaximumClipperLength = 20000;

- (NSSize)constrainedSizeFromSize:(NSSize)size
{
    NSSize minimum = [self minClipperSize];
    return NSMakeSize(MAX(minimum.width, MIN(size.width, WCMaximumClipperLength)), MAX(minimum.height, MIN(size.height, WCMaximumClipperLength)));
}

- (void)setConstrainedClipperSize:(NSSize)size
{
    [self setClipperSize:[self constrainedSizeFromSize:size]];
}

- (void)setWidgetWindowSize:(NSSize)size keepClipperCentered:(BOOL)keepClipperCentered
{
    NSSize constrained = [self constrainedSizeFromSize:size];
    [self setClipperSize:constrained];
    WebScriptObject *window = [self windowScriptObject];
    if (keepClipperCentered) {
        float screenX = [[window valueForKey:@"screenX"] floatValue];
        float screenY = [[window valueForKey:@"screenY"] floatValue];
        [window callWebScriptMethod:@"resizeAndMoveTo" withArguments:[NSArray arrayWithObjects:
            [NSNumber numberWithFloat:screenX],
            [NSNumber numberWithFloat:screenY],
            [NSNumber numberWithFloat:(float)(constrained.width + -1.0)],
            [NSNumber numberWithFloat:(float)constrained.height],
            nil]];
    } else {
        [window callWebScriptMethod:@"resizeTo" withArguments:[NSArray arrayWithObjects:
            [NSNumber numberWithFloat:(float)constrained.width],
            [NSNumber numberWithFloat:(float)constrained.height],
            nil]];
    }
}

- (int)selectedTheme
{
    return [_currentTheme themeID];
}

- (void)updateStatusTextViewFrame:(BOOL)center
{
    [self setNeedsDisplayInRect:[_statusTextField frame]];
    [_statusTextField sizeToFit];
    NSSize size = [self frame].size;
    NSRect textFrame = [_statusTextField frame];
    if (center) {
        float y = floorf((float)((size.height - textFrame.size.height) * 0.5));
        float x = floorf((float)((size.width - textFrame.size.width) * 0.5));
        [_statusTextField setFrameOrigin:NSMakePoint(x, y)];
    }
    [self setNeedsDisplayInRect:[_statusTextField frame]];
}

- (NSRect)convertDOMRectToDashboardControlRegion:(NSRect)rect
{
    NSRect region = [self convertRect:rect fromView:_clipView];
    NSRect themeRegion;
    if ([_currentTheme drawsInAttachedWindow] && [_currentTheme window] && [self window]) {
        NSPoint origin = [self themeWindowOrigin];
        NSRect onScreen = NSOffsetRect([_currentTheme convertRect:[_currentTheme controlRegion] toView:nil], origin.x, origin.y);
        themeRegion = [self convertRect:[[self window] convertRectFromScreen:onScreen] fromView:nil];
    } else
        themeRegion = [self convertRect:[_currentTheme controlRegion] fromView:_currentTheme];
    return NSIntersectionRect(region, themeRegion);
}

- (void)updateDashboardControlRegions
{
    if (_isEditingCameraPosition) {
        NSRect resizer = [self convertRect:[_resizer bounds] fromView:_resizer];
        NSRect bezel = [self convertRect:[_currentTheme innerBezelFrame] fromView:_currentTheme];
        NSRect lockButton = [self convertRect:[_lockCameraButton bounds] fromView:_lockCameraButton];
        [self setDraggableRects:[NSArray arrayWithObjects:[NSValue valueWithRect:resizer], [NSValue valueWithRect:bezel], [NSValue valueWithRect:lockButton], nil]];
        return;
    }
    if ([self isBacksideShowing])
        return;
    [[self controller] draggableControlRegions:^(NSArray *rects) {
        if (_isEditingCameraPosition || [self isBacksideShowing])
            return;
        [self setDraggableRects:rects];
    }];
}

- (void)repositionOverlayButtons
{
    [self updateStatusTextViewFrame:YES];
    NSRect clipFrame = [self convertRect:[_clipView bounds] fromView:_clipView];
    [_lockCameraButton setFrameOrigin:[_currentTheme doneButtonOriginInFrame:clipFrame]];
    CGFloat flipButtonHeight = [_flipButton frame].size.height;
    NSPoint flipperOrigin = [_currentTheme flipperButtonOriginInFrame:clipFrame];
    NSPoint flipperOriginInTheme = [self convertPoint:flipperOrigin toView:_currentTheme];
    [_flipButton setFrameOrigin:flipperOrigin];
    [_flipperImageView setFrameOrigin:NSMakePoint(flipperOriginInTheme.x, flipperOriginInTheme.y - flipButtonHeight)];
    [_resizer setFrameOrigin:[_currentTheme resizerOrigin:clipFrame]];
    [self updateDashboardControlRegions];
}

// Renders the theme over the clip view's area, onto a transparent canvas or over opaque page
// stand-in of the given gray, returning premultiplied RGBA rows top first.
- (NSMutableData *)themePixelsOverPageGray:(CGFloat)gray page:(BOOL)page width:(size_t)width height:(size_t)height scale:(CGFloat)scale
{
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate([pixels mutableBytes], width, height, 8, width * 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    CGContextScaleCTM(context, scale, scale);
    NSRect clipFrame = [_clipView frame];
    if (page) {
        CGContextSetGrayFillColor(context, gray, 1);
        CGContextFillRect(context, CGRectMake(0, 0, clipFrame.size.width, clipFrame.size.height));
    }
    CGContextTranslateCTM(context, -clipFrame.origin.x, -clipFrame.origin.y);
    NSGraphicsContext *graphicsContext = [NSGraphicsContext graphicsContextWithGraphicsPort:context flipped:NO];
    [_currentTheme displayRectIgnoringOpacity:[_currentTheme convertRect:clipFrame fromView:self] inContext:graphicsContext];
    CGContextRelease(context);
    return pixels;
}

// A theme drawn in the widget window (Torn Edge) composites parts of its artwork with
// NSCompositeCopy, which in a single backing store replaces the page pixels beneath it. The page
// is its own layer here, so that coverage becomes a mask on the clip view: rendering the theme
// over black and over white page stand-ins measures how much of the page each pixel keeps.
- (void)updateContentMask
{
    CALayer *clipLayer = [_clipView layer];
    if (!clipLayer)
        return;
    if (!_currentTheme || [_currentTheme superview] != self) {
        clipLayer.mask = nil;
        return;
    }
    CGFloat scale = [[self window] backingScaleFactor] ?: 1;
    NSSize size = [_clipView frame].size;
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (!width || !height) {
        clipLayer.mask = nil;
        return;
    }
    const uint8_t *theme = [[self themePixelsOverPageGray:0 page:NO width:width height:height scale:scale] bytes];
    const uint8_t *overBlack = [[self themePixelsOverPageGray:0 page:YES width:width height:height scale:scale] bytes];
    const uint8_t *overWhite = [[self themePixelsOverPageGray:1 page:YES width:width height:height scale:scale] bytes];
    NSMutableData *mask = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *maskBytes = [mask mutableBytes];
    for (size_t i = 0; i < width * height; ++i) {
        int themeAlpha = theme[i * 4 + 3];
        if (themeAlpha == 255)
            continue;
        int transmitted = overWhite[i * 4] - overBlack[i * 4];
        double kept = (double)transmitted / (255 - themeAlpha);
        memset(maskBytes + i * 4, (int)lround(255 * MAX(0.0, MIN(1.0, kept))), 4);
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)mask);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef maskImage = CGImageCreate(width, height, 8, 32, width * 4, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    CALayer *maskLayer = [CALayer layer];
    maskLayer.frame = clipLayer.bounds;
    maskLayer.contents = (__bridge id)maskImage;
    CGImageRelease(maskImage);
    clipLayer.mask = maskLayer;
}

- (void)updateFrame
{
    [_clipView setFrame:[self clipViewFrame]];
    [self repositionOverlayButtons];
    [self updateEventRegion];
    [self updateContentMask];
    [self layoutPageViewport];
}

- (void)setTheme:(int)themeID
{
    WCTheme *oldTheme = _currentTheme;
    if (oldTheme) {
        if ([oldTheme themeID] == themeID)
            return;
    }
    if ([_currentTheme drawsInAttachedWindow])
        [_currentTheme releaseAttachedWindow];
    else
        [_currentTheme removeFromSuperview];

    Class themeClass;
    switch (themeID) {
    case WCThemeGlass:
        themeClass = [WCGlassTheme class];
        break;
    case WCThemeBlackEdge:
        themeClass = [WCBlackEdgeTheme class];
        break;
    case WCThemeVintageCorners:
        themeClass = [WCVintageCornersTheme class];
        break;
    case WCThemeDeckled:
        themeClass = [WCScallopedTheme class];
        break;
    case WCThemePegboard:
        themeClass = [WCPegboardTheme class];
        break;
    case WCThemeTornEdge:
        themeClass = [WCTornEdgeTheme class];
        break;
    default:
        themeClass = [WebClipper defaultThemeClass];
        break;
    }
    if (oldTheme)
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewFrameDidChangeNotification object:oldTheme];
    _currentTheme = [[themeClass alloc] init];
    // The overlay buttons are placed by converting between the widget window and the theme's
    // attached window, so they follow the theme whenever Dashboard resizes that window.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeFrameDidChange:) name:NSViewFrameDidChangeNotification object:_currentTheme];

    BOOL orderAttachedWindow = !oldTheme && [_currentTheme drawsInAttachedWindow];
    [_currentTheme setDoneButton:_lockCameraButton];
    [_currentTheme setDashboardWebView:[[self controller] dashboardWebView]];
    // A theme's attached window holds no page, and its views draw into the window.
    if ([_currentTheme drawsInAttachedWindow]) {
        [_flipperImageView setWantsLayer:NO];
        [_currentTheme addSubview:_flipperImageView];
    } else
        addLayerBackedSubview(_currentTheme, _flipperImageView);
    [_resizer setFrameSize:[_currentTheme resizerFrameSize]];
    if (![_currentTheme drawsInAttachedWindow]) {
        [_currentTheme setFrameSize:[self frame].size];
        addLayerBackedSubview(self, _currentTheme);
    }
    if (orderAttachedWindow) {
        [self updateFrame];
        [_currentTheme orderAttachedWindow:NSWindowAbove relativeTo:0 delayed:YES];
        [_currentTheme display];
    }
    [self updateContentMask];
    [self updatePageWindow];
}

// The overlay shows the theme at its present size.
- (void)themeFrameDidChange:(NSNotification *)notification
{
    [self repositionOverlayButtons];
    [_themeOverlay setNeedsDisplay:YES];
}

- (NSImage *)themeSnapshot
{
    NSRect frame = [_currentTheme frame];
    NSImage *image = [[NSImage alloc] initWithSize:frame.size];
    NSBitmapImageRep *representation = [_currentTheme bitmapImageRepForCachingDisplayInRect:frame];
    [representation setSize:frame.size];
    memset([representation bitmapData], 0, [representation bytesPerRow] * [representation pixelsHigh]);
    [_currentTheme drawIncludingPageAreaIntoContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:representation]];
    [image addRepresentation:representation];
    return image;
}

// Copies a screen region of the window's current on-screen contents, including the composited layers
// the clipped page is drawn with.
static void copyWindowRegion(NSWindow *window, NSRect screenRect, NSRect destination)
{
    if (!window)
        return;
    CGFloat primaryHeight = NSMaxY([[[NSScreen screens] objectAtIndex:0] frame]);
    CGRect captureRect = CGRectMake(screenRect.origin.x, primaryHeight - NSMaxY(screenRect), screenRect.size.width, screenRect.size.height);
    CGImageRef image = CGWindowListCreateImage(captureRect, kCGWindowListOptionIncludingWindow, (CGWindowID)[window windowNumber], kCGWindowImageBoundsIgnoreFraming);
    if (!image)
        return;
    CGContextDrawImage((CGContextRef)[[NSGraphicsContext currentContext] graphicsPort], NSRectToCGRect(destination), image);
    CGImageRelease(image);
}

- (NSImage *)snapshotOfRegion:(NSRect)region includeTheme:(BOOL)includeTheme
{
    NSRect destination = NSMakeRect(0, 0, region.size.width, region.size.height);
    NSImage *image = [[NSImage alloc] initWithSize:region.size];
    [image lockFocus];
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context setCompositingOperation:NSCompositeCopy];
    copyWindowRegion([self window], [[self window] convertRectToScreen:[self convertRect:region toView:nil]], destination);
    if (includeTheme) {
        [context setCompositingOperation:NSCompositeSourceOver];
        NSPoint origin = [self themeWindowOrigin];
        copyWindowRegion([_currentTheme window], NSOffsetRect(region, origin.x, origin.y), destination);
    }
    [image unlockFocus];
    return image;
}

- (NSImage *)clipViewImage
{
    return [self snapshotOfRegion:[self clipViewFrame] includeTheme:NO];
}

- (NSImage *)snapshotIncludingTheme:(BOOL)includeTheme
{
    return [self snapshotOfRegion:[_currentTheme frame] includeTheme:includeTheme];
}

- (NSPoint)mouseLocationInView
{
    return [self convertPoint:[[self window] convertScreenToBase:[NSEvent mouseLocation]] fromView:nil];
}

- (void)updateCursor
{
    BOOL editing = _isEditingCameraPosition;
    NSWindow *window = [self window];
    if (!editing) {
        [window enableCursorRects];
        return;
    }
    [window disableCursorRects];
    NSPoint mouse = [self mouseLocationInView];
    NSRect lockButton = [self convertRect:[_lockCameraButton bounds] fromView:_lockCameraButton];
    NSRect bezel = [self convertRect:[_currentTheme innerBezelFrame] fromView:_currentTheme];
    NSRect resizer = [self convertRect:[_resizer bounds] fromView:_resizer];
    BOOL inBezel = NSMouseInRect(mouse, bezel, [self isFlipped]);
    BOOL inLockButton = NSMouseInRect(mouse, lockButton, [self isFlipped]);
    BOOL inResizer = NSMouseInRect(mouse, resizer, [self isFlipped]);
    NSCursor *cursor;
    if (inBezel && _isEditingCameraPosition && !inLockButton && !inResizer)
        cursor = _isMouseDown ? [NSCursor closedHandCursor] : [NSCursor openHandCursor];
    else
        cursor = [NSCursor arrowCursor];
    [cursor set];
}

- (void)updateOverlayButtons
{
    [_currentTheme setDrawsInnerBezel:_isEditingCameraPosition];
    [_lockCameraButton setHidden:!_isEditingCameraPosition];
    [_resizer setHidden:!_isEditingCameraPosition];
    [self updateFlipper];
    [self updateCursor];
    [self updateDashboardControlRegions];
}

- (BOOL)isEditingCameraPosition
{
    return _isEditingCameraPosition;
}

- (void)setIsEditingCameraPosition:(BOOL)editing
{
    if (_isEditingCameraPosition == editing)
        return;
    _isEditingCameraPosition = editing;
    if (editing) {
        _clipRectAfterTransition = NSZeroRect;
        [self callPageFunction:@"snapNodes" argument:nil completionHandler:^(id nodes) {
            if (_isEditingCameraPosition && [nodes isKindOfClass:[NSArray class]])
                _snapper = [[WCSnapper alloc] initWithNodes:nodes];
        }];
    } else
        _snapper = nil;
    [self updateOverlayButtons];
    [_currentTheme display];
    [self updateFrame];
    [self layoutPageViewport];
}

- (void)setStatusText:(NSString *)text updateOrigin:(BOOL)updateOrigin
{
    [_voidView setIsBlack:NO];
    [_pageCover setIsBlack:NO];
    [_pageCover setHidden:NO];
    [_statusTextField setStringValue:text];
    [self updateStatusTextViewFrame:updateOrigin];
    // The stand-in follows the text while it is on screen.
    if (_isWidgetMoving || !_dockAllowsPageWindow)
        [self updateStandIn];
}

- (void)setStatusText:(NSString *)text
{
    [self setStatusText:text updateOrigin:YES];
}

- (BOOL)isShowingLoadingText
{
    return ![_statusTextField isHidden];
}

- (void)dismissLoadingText
{
    [_statusTextField setStringValue:@""];
    [_statusTextField setHidden:YES];
    [_pageCover setHidden:YES];
    [_voidView setIsBlack:YES];
}

- (void)displayLoadingText
{
    [self stopProgressTimer];
    [self setStatusText:WCLocalizedString("Loading Clip")];
    [_statusTextField setHidden:NO];
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(updateProgress) userInfo:nil repeats:YES];
}

- (void)reflectScrolledClipView:(NSClipView *)clipView
{
    [self repositionOverlayButtons];
}

// The content mask lives in the clip layer's bounds, which follow the clip view's as it scrolls.
- (void)clipViewBoundsDidChange:(NSNotification *)notification
{
    CALayer *mask = [[_clipView layer] mask];
    if (!mask)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = NSRectToCGRect([_clipView bounds]);
    [CATransaction commit];
}

- (void)stopProgressTimer
{
    [_progressTimer invalidate];
    _progressTimer = nil;
}

- (void)prepareWidgetForSnapshot
{
    if (![_currentTheme drawsInAttachedWindow])
        return;
    [self setScreenshot:[self snapshotIncludingTheme:YES]];
    [_currentTheme orderAttachedWindow:NSWindowOut relativeTo:0 delayed:YES];
    [self stopProgressTimer];
    [_clipView setHidden:YES];
    [_statusTextField setHidden:YES];
    [self updateFlipperVisibility];
    [self display];
}

- (NSImage *)thumbnail
{
    NSImage *image = [self clipViewImage];
    NSSize size = [image size];
    if (size.width / size.height >= 1.0) {
        [image setSize:NSMakeSize((float)size.height, size.height)];
        size = [image size];
    }
    NSImage *thumbnail = [[NSImage alloc] initWithSize:NSMakeSize(87, 61)];
    [thumbnail lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [image setScalesWhenResized:YES];
    double scale = (float)(87.0 / size.width);
    double scaledHeight = size.height * scale;
    [image setSize:NSMakeSize(size.width * scale, scaledHeight)];
    [image compositeToPoint:NSZeroPoint fromRect:NSMakeRect(0, scaledHeight + -61.0, 87, 61) operation:NSCompositeCopy];
    [thumbnail unlockFocus];
    return thumbnail;
}

- (void)flipToBack
{
    [self setIsEditingCameraPosition:NO];
    [[self controller] setThumbnailAndFlipToBack:[self thumbnail]];
    _didFlipToFront = NO;
    [self updatePageWindow];
}

- (NSRect)clipViewBounds
{
    return _clipView ? [_clipView bounds] : NSZeroRect;
}

- (NSRect)webViewFrame
{
    return _webView ? [_webView bounds] : NSZeroRect;
}

- (WKWebView *)webview
{
    return _webView;
}

- (NSPoint)visibleWebViewOrigin
{
    NSRect bounds = [_voidView superview] ? [[_voidView superview] bounds] : NSZeroRect;
    return NSMakePoint(bounds.origin.x - [_currentTheme clipInsetLeft], bounds.origin.y - [_currentTheme clipInsetBottom]);
}

- (void)reload:(id)sender
{
    NSURLRequest *request = [[NSURLRequest alloc] initWithURL:[NSURL _web_URLWithUserTypedString:[[self controller] URLString]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:31536000];
    _isLoading = _webView != nil;
    [_webView loadRequest:request];
}

- (NSSize)convertDOMBorderSizeToWindowSize:(NSSize)size
{
    int insetLeft = [_currentTheme clipInsetLeft];
    int insetBottom = [_currentTheme clipInsetBottom];
    double width = (double)(insetLeft + insetLeft) + size.width;
    int insetTop = [_currentTheme clipInsetTop];
    return NSMakeSize(width, (double)(insetTop + insetBottom) + size.height);
}

// Moves the clip to the rect of the element its signature describes, and sizes the widget to it. The
// page scrolls the rect to where the clip lies in the viewport, as far as it scrolls. The widget's
// window is the front's size only while the front shows: during a flip the rect waits for the flip to
// complete, and behind the back side the clipper element alone takes the size, which is the size the
// widget flips to the front with. The clip is signed again where it lands.
- (void)adjustClipToRect:(NSRect)rect
{
    if (_transitionInProgress) {
        _clipRectAfterTransition = rect;
        return;
    }
    if (!NSEqualRects(rect, NSZeroRect)) {
        NSRect bounds = [_clipView bounds];
        if (fabs(rect.origin.x - bounds.origin.x) >= 0.5 || fabs(rect.origin.y - bounds.origin.y) >= 0.5) {
            _clipViewportOrigin = [self viewportOriginInViewport:_clipViewportOrigin];
            NSPoint target = NSMakePoint(MAX(0, rect.origin.x - _clipViewportOrigin.x), MAX(0, rect.origin.y - _clipViewportOrigin.y));
            _clipViewportOrigin = NSMakePoint(rect.origin.x - target.x, rect.origin.y - target.y);
            [self scrollPageTo:target];
        }
        NSSize widgetSize = [self frame].size;
        if (fabs(rect.size.width - bounds.size.width) >= 0.5 || fabs(rect.size.height - bounds.size.height) >= 0.5) {
            widgetSize = [self convertDOMBorderSizeToWindowSize:rect.size];
            if ([self isBacksideShowing]) {
                widgetSize = [self constrainedSizeFromSize:widgetSize];
                [self setClipperSize:widgetSize];
                [_clipView setFrame:[self clipViewFrame]];
            } else
                [self setWidgetWindowSize:widgetSize keepClipperCentered:NO];
        }
        [self recordClipRectWithWidgetSize:widgetSize];
    }
    [self signClip];
}

// The signature describes the element the clip shows, so that the next load finds the element
// wherever the page has moved it.
- (void)signClip
{
    WebClipper *controller = [self controller];
    WKWebView *webView = _webView;
    [self callPageFunction:@"signRect" argument:[self clipPageRect] completionHandler:^(id signature) {
        if (webView != _webView || _isEditingCameraPosition || ![signature isKindOfClass:[NSDictionary class]])
            return;
        [controller setClipSignature:signature];
        [controller savePreferencesToDisk];
    }];
}

// After a load, the page builds the element the clip shows; the clip stays once the element is back
// where it was, and otherwise follows the page agent's match at the deadline. A clip just made from
// Safari shows the selection, and is signed once the element Safari signed lies there.
static const double WCSignatureDeadlineMilliseconds = 10000;

- (void)followSignature
{
    WebClipper *controller = [self controller];
    NSDictionary *signature = [controller clipSignature];
    WKWebView *webView = _webView;
    if ([signature objectForKey:@"ClipSignatureScore"]) {
        [self callPageFunction:@"placeBySignature" argument:@{ @"signature": signature, @"deadline": @(WCSignatureDeadlineMilliseconds) } completionHandler:^(id result) {
            if (webView != _webView || _isEditingCameraPosition || ![result isKindOfClass:[NSDictionary class]])
                return;
            [self adjustClipToRect:rectFromPageRect(result[@"rect"])];
        }];
        return;
    }
    [self callPageFunction:@"signRectWhenPresent" argument:@{ @"signature": signature ?: [NSNull null], @"rect": [self clipPageRect], @"deadline": @(WCSignatureDeadlineMilliseconds) } completionHandler:^(id result) {
        if (webView != _webView || _isEditingCameraPosition || ![result isKindOfClass:[NSDictionary class]])
            return;
        id newSignature = result[@"signature"];
        if (![newSignature isKindOfClass:[NSDictionary class]])
            return;
        [controller setClipSignature:newSignature];
        [controller savePreferencesToDisk];
    }];
}

// The saved ClipRect is where the clip is: its origin in the page and the widget's size. The saved
// PageScroll is where the page is scrolled to show it.
- (void)recordClipRectWithWidgetSize:(NSSize)widgetSize
{
    NSPoint scroll = _hasPageScrollTarget ? _pageScrollTarget : _pageScroll;
    [[self controller] setClipRect:NSMakeRect(_clipViewportOrigin.x + scroll.x, _clipViewportOrigin.y + scroll.y, widgetSize.width, widgetSize.height)];
    [[self controller] setPageScroll:scroll];
}

- (void)exitEditingCameraPosition:(id)sender
{
    [self setIsEditingCameraPosition:NO];
    [self recordClipRectWithWidgetSize:[self frame].size];
    [self signClip];
    [[self controller] exitEditingCameraPosition];
}

- (void)showControls:(id)sender
{
    [self flipToBack];
}

- (void)updateProgress
{
    _progressPeriodCount = _progressPeriodCount == 3 ? 0 : _progressPeriodCount + 1;
    const char *key;
    switch (_progressPeriodCount) {
    case 3:
        key = "Loading Clip...";
        break;
    case 2:
        key = "Loading Clip..";
        break;
    case 1:
        key = "Loading Clip.";
        break;
    default:
        key = "Loading Clip";
        break;
    }
    [self setStatusText:WCLocalizedString(key) updateOrigin:NO];
}

- (void)dismissError
{
    if (!_errorView)
        return;
    [_errorView removeFromSuperview];
    _errorView = nil;
    [self displayLoadingText];
}

- (void)setError:(NSError *)error
{
    if ([[error domain] isEqualToString:NSURLErrorDomain] && [error code] == NSURLErrorCancelled)
        return;
    NSRect frame = [self clipViewFrame];
    if (!_errorView)
        _errorView = [[WCErrorView alloc] initWithFrame:frame];
    [_errorView setFrame:frame];
    [_errorView setMessage:messageForError(error, [[self controller] URLString])];
    addLayerBackedSubview(self, _errorView);
    _loadError = YES;
    _isLoading = NO;
    [self clearScreenshotIfNeeded];
    [self dismissLoadingText];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    WebClipper *controller = [self controller];
    if (![self window])
        return;
    if (!_hasBeenMovedToWindow) {
        [self setUpContents];
        [controller readSettings];
        // Dashboard tells the widget's page when the user starts and stops dragging the widget.
        [[self windowScriptObject] evaluateWebScript:@"widget.ondragstart = function () { webClip.widgetDidStartMoving(); }; widget.ondragend = function () { webClip.widgetDidStopMoving(); };"];
    }
    [self updateDashboardControlRegions];
    [self updateEventRegion];
    [[self window] disableCursorRects];
    _hasBeenMovedToWindow = YES;
}

- (NSRect)clipViewFrame
{
    NSRect frame = [self bounds];
    int insetLeft = [_currentTheme clipInsetLeft];
    int insetBottom = [_currentTheme clipInsetBottom];
    double left = insetLeft;
    frame.origin.x += left;
    frame.origin.y += insetBottom;
    NSRect displacement = _currentTheme ? [_currentTheme displacementRect] : NSZeroRect;
    if (NSIsEmptyRect(displacement))
        frame.size.width -= insetLeft + insetLeft;
    else
        frame.size.width -= left + displacement.size.width + displacement.origin.x;
    frame.size.height -= [_currentTheme clipInsetTop] + insetBottom;
    return frame;
}

- (void)setFrameSize:(NSSize)size
{
    NSSize oldSize = [self frame].size;
    [super setFrameSize:size];
    if (!NSEqualSizes(oldSize, size))
        [self updateFrame];
}

// The clips' web content processes load the plug-in's injected bundle.
static WKProcessPool *clipProcessPool(void)
{
    static WKProcessPool *processPool;
    if (!processPool) {
        _WKProcessPoolConfiguration *configuration = [[_WKProcessPoolConfiguration alloc] init];
        configuration.injectedBundleURL = [[NSBundle bundleForClass:[WCClipperView class]] URLForResource:@"WebClipPageBundle" withExtension:@"bundle"];
        processPool = [[WKProcessPool alloc] _initWithConfiguration:configuration];
    }
    return processPool;
}

- (WKWebViewConfiguration *)webViewConfiguration
{
    WebClipper *controller = [self controller];
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.processPool = clipProcessPool();
    configuration.applicationNameForUserAgent = [WebClipper userAgent];

    WKPreferences *preferences = configuration.preferences;
    preferences._standardFontFamily = [controller standardFont];
    preferences._fixedPitchFontFamily = [controller fixedWidthFont];
    preferences._defaultFontSize = [controller standardFontSize];
    preferences._defaultFixedPitchFontSize = [controller fixedWidthFontSize];
    preferences.minimumFontSize = [controller minimumFontSize];
    preferences._defaultTextEncodingName = [controller defaultTextEncodingName];
    // Pages see the element fullscreen API Safari offers them.
    preferences.elementFullscreenEnabled = YES;

    WKUserContentController *userContentController = configuration.userContentController;
    _pageWorld = [WKContentWorld worldWithName:@"WebClip"];
    NSString *agentPath = [[NSBundle bundleForClass:[WCClipperView class]] pathForResource:@"WCPageAgent" ofType:@"js"];
    NSString *agentSource = [NSString stringWithContentsOfFile:agentPath encoding:NSUTF8StringEncoding error:nil];
    [userContentController addUserScript:[[WKUserScript alloc] initWithSource:agentSource injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:_pageWorld]];
    WCScriptMessageProxy *proxy = [[WCScriptMessageProxy alloc] init];
    proxy.view = self;
    [userContentController addScriptMessageHandler:proxy contentWorld:_pageWorld name:@"webClip"];

    // The main frame shows no scroll bars; the web view takes the size Safari's left to the page. The clip
    // is a rect of the document, as stock's document-sized WebView showed it, so the main frame's scroll
    // position does not anchor to content.
    [userContentController _addUserStyleSheet:[[_WKUserStyleSheet alloc] initWithSource:@":root { scrollbar-width: none !important; overflow-anchor: none !important; }" forMainFrameOnly:YES]];

    NSString *userStyleSheetPath = [controller userStyleSheetPath];
    if (userStyleSheetPath) {
        NSString *userStyleSheet = [NSString stringWithContentsOfFile:userStyleSheetPath encoding:NSUTF8StringEncoding error:nil];
        if (userStyleSheet)
            [userContentController _addUserStyleSheet:[[_WKUserStyleSheet alloc] initWithSource:userStyleSheet forMainFrameOnly:NO]];
    }
    return configuration;
}

- (void)applyCustomTextEncodingName
{
    NSString *name = [[self controller] customTextEncodingName];
    if (!name)
        return;
    WKStringRef encoding = WKStringCreateWithCFString((__bridge CFStringRef)name);
    WKPageSetCustomTextEncodingName([_webView _pageRefForTransitionToWKWebView], encoding);
    WKRelease(encoding);
}

- (void)createWebViewWithSize:(NSSize)size
{
    _webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height) configuration:[self webViewConfiguration]];
    [_webView _setObservedRenderingProgressEvents:_WKRenderingProgressEventFirstPaintWithSignificantArea | _WKRenderingProgressEventFirstMeaningfulPaint];
    [_webView setUIDelegate:self];
    [_webView setNavigationDelegate:self];
    [_webView _setFullscreenDelegate:self];
    [_webView _setClipsToVisibleRect:YES];
    [self applyCustomTextEncodingName];
}

// The page is laid out in the viewport Safari laid it out in when the clip was made, and the clip shows
// the part of the viewport Safari showed. The web view is the viewport, placed in the void at the page's
// scroll offset, and the clip view's bounds follow it: whatever scrolls the page, the clip reaching where
// Safari had it or the page anchoring its content as content above loads, moves the clip with the viewport.
// The void is the clip view's document: it reaches past the page, the web view and the clip.
- (void)sizeVoidToContainClipAt:(NSPoint)clipOrigin
{
    NSRect webViewFrame = _webView ? [_webView frame] : NSZeroRect;
    NSSize clipSize = [_clipView bounds].size;
    NSSize size = NSMakeSize(MAX(MAX(_documentSize.width, NSMaxX(webViewFrame)), clipOrigin.x + clipSize.width),
        MAX(MAX(_documentSize.height, NSMaxY(webViewFrame)), clipOrigin.y + clipSize.height));
    if (!NSEqualSizes([_voidView frame].size, size))
        [_voidView setFrameSize:size];
}

- (void)placeWebViewAtPageScroll:(NSPoint)scroll
{
    _pageScroll = scroll;
    if (!NSEqualPoints([_webView frame].origin, scroll))
        [_webView setFrameOrigin:scroll];
    if (_hasPageScrollTarget && NSEqualPoints(scroll, _pageScrollTarget))
        _hasPageScrollTarget = NO;
    NSPoint clipOrigin = [self clipPageOrigin];
    [self sizeVoidToContainClipAt:clipOrigin];
    if (!NSEqualPoints([_clipView bounds].origin, clipOrigin)) {
        [_clipView scrollToPoint:clipOrigin];
        [self updateDashboardControlRegions];
    }
}

// Where the clip is in the page. Until the page reaches the scroll target, the clip shows the content
// it will show there.
- (NSPoint)clipPageOrigin
{
    NSPoint anchor = _hasPageScrollTarget ? _pageScrollTarget : _pageScroll;
    return NSMakePoint(_clipViewportOrigin.x + anchor.x, _clipViewportOrigin.y + anchor.y);
}

- (NSDictionary *)clipPageRect
{
    NSPoint origin = [self clipPageOrigin];
    NSSize size = [_clipView bounds].size;
    return @{ @"x": @(origin.x), @"y": @(origin.y), @"width": @(size.width), @"height": @(size.height) };
}

// The clip lies in the viewport, which is all the web view shows.
- (NSPoint)viewportOriginInViewport:(NSPoint)origin
{
    NSSize viewport = [_webView frame].size;
    NSSize clipSize = [_clipView bounds].size;
    return NSMakePoint(MAX(0, MIN(origin.x, viewport.width - clipSize.width)), MAX(0, MIN(origin.y, viewport.height - clipSize.height)));
}

static NSPoint pageScrollFromResult(id result)
{
    if (![result isKindOfClass:[NSDictionary class]])
        return NSMakePoint(NAN, NAN);
    return NSMakePoint([result[@"x"] doubleValue], [result[@"y"] doubleValue]);
}

// The page scrolls to the target as far as it can while it loads. Once loaded, it stays where it can scroll
// to, and the clip moves within the viewport by what the page could not scroll, onto the same content.
- (void)scrollPageTo:(NSPoint)target
{
    _pageScrollTarget = NSMakePoint(MAX(0, target.x), MAX(0, target.y));
    _hasPageScrollTarget = YES;
    [self layoutPageViewport];
}

- (void)sizeWebView
{
    NSSize visibleContentSize = [[self controller] visibleContentSize];
    NSSize clipSize = [_clipView bounds].size;
    NSSize size = NSMakeSize(MAX(visibleContentSize.width, clipSize.width), MAX(visibleContentSize.height, clipSize.height));
    if (!NSEqualSizes([_webView frame].size, size))
        [_webView setFrameSize:size];
    [self sizeVoidToContainClipAt:[_clipView bounds].origin];
    // Viewport units resolve against Safari's viewport, scroll bars included.
    NSSize viewport = [[self controller] viewportSize];
    if (viewport.width > 0 && viewport.height > 0 && !NSEqualSizes(NSSizeFromCGSize([_webView _viewportSizeForCSSViewportUnits]), viewport))
        [_webView _setViewportSizeForCSSViewportUnits:viewport];
}

- (void)layoutPageViewport
{
    if (!_webView)
        return;
    [self sizeWebView];
    if (!_hasPageScrollTarget)
        return;
    if (NSEqualPoints(_pageScroll, _pageScrollTarget)) {
        _hasPageScrollTarget = NO;
        return;
    }
    NSPoint target = _pageScrollTarget;
    [self callPageFunction:@"scrollToPoint" argument:@{ @"x": @(target.x), @"y": @(target.y) } completionHandler:^(id result) {
        NSPoint actual = pageScrollFromResult(result);
        if (isnan(actual.x))
            return;
        [self placeWebViewAtPageScroll:actual];
    }];
}

// Moves the clip within the web view; a clip moved past its edges scrolls the page by as much.
- (void)scrollClipViewToPoint:(NSPoint)point
{
    NSSize viewport = [_webView frame].size;
    NSSize clipSize = [_clipView bounds].size;
    NSPoint scroll = _hasPageScrollTarget ? _pageScrollTarget : _pageScroll;
    NSPoint origin = NSMakePoint(point.x - scroll.x, point.y - scroll.y);
    NSPoint overflow = NSMakePoint(origin.x < 0 ? origin.x : MAX(0, origin.x + clipSize.width - viewport.width),
        origin.y < 0 ? origin.y : MAX(0, origin.y + clipSize.height - viewport.height));
    _clipViewportOrigin = NSMakePoint(origin.x - overflow.x, origin.y - overflow.y);
    [self placeWebViewAtPageScroll:_pageScroll];
    if (!NSEqualPoints(overflow, NSZeroPoint))
        [self scrollPageTo:NSMakePoint(scroll.x + overflow.x, scroll.y + overflow.y)];
}

- (void)setUpSubviews
{
    [self createWebViewWithSize:NSZeroSize];

    _statusTextField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [_statusTextField setBezeled:NO];
    [_statusTextField setEditable:NO];
    [_statusTextField setDrawsBackground:NO];
    [_statusTextField setAlignment:NSCenterTextAlignment];
    [_statusTextField setTextColor:[NSColor colorWithDeviceWhite:0 alpha:0.5]];
    [_statusTextField setFont:[NSFont fontWithName:@"Helvetica Neue Light" size:18]];
    [_statusTextField setHidden:YES];

    _voidView = [[WCVoidView alloc] initWithFrame:NSZeroRect];
    // The cover lies over the web view in the void. It hides the page from the user while it loads, and
    // leaves it visible to WebKit, which renders it as Safari renders a tab in a visible window.
    _pageCover = [[WCVoidView alloc] initWithFrame:[_voidView bounds]];
    [_pageCover setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_pageCover setHidden:YES];
    _clipView = [[NSClipView alloc] initWithFrame:[self clipViewFrame]];
    [_clipView setCopiesOnScroll:NO];
    [_clipView setDocumentView:_voidView];
    [_clipView setPostsBoundsChangedNotifications:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clipViewBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:_clipView];

    _lockCameraButton = [[WCDoneButton alloc] init];
    [_lockCameraButton setTarget:self];
    [_lockCameraButton setAction:@selector(exitEditingCameraPosition:)];

    _flipButton = [[NSButton alloc] init];
    [_flipButton setBordered:NO];
    [_flipButton setButtonType:NSMomentaryChangeButton];
    [_flipButton setTarget:self];
    [_flipButton setAction:@selector(showControls:)];
    [_flipButton setFrameSize:[[[self class] flipperImage] size]];
    [_flipButton setTitle:@""];

    _flipperImageView = [[NSImageView alloc] init];
    [_flipperImageView setFrameSize:[[[self class] flipperImage] size]];
    [_flipperImageView setAutoresizingMask:NSViewMaxYMargin];

    _resizer = [[NSView alloc] init];
    [_resizer setHidden:YES];

    [[self window] setAcceptsMouseMovedEvents:YES];
    [_voidView setWantsLayer:YES];
    [_voidView addSubview:_webView];
    [_voidView addSubview:_pageCover];
    addLayerBackedSubview(self, _clipView);
    _themeOverlay = [[WCThemeOverlayView alloc] initWithFrame:[_clipView frame]];
    addLayerBackedSubview(self, _themeOverlay);
    addLayerBackedSubview(self, _flipButton);
    addLayerBackedSubview(self, _lockCameraButton);
    addLayerBackedSubview(self, _resizer);
    addLayerBackedSubview(self, _statusTextField);
}

- (void)setUpContents
{
    [self setUpSubviews];
    [self updateCursor];
    [self updateOverlayButtons];
}

- (instancetype)initWithFrame:(NSRect)frame dashboardWebView:(WebView *)dashboardWebView
{
    self = [super initWithFrame:frame];
    [self setWantsLayer:YES];
    _placeholder = [[WCPlaceholderView alloc] initWithFrame:frame];
    [_placeholder setClipperView:self];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateCursor) name:NSMouseMovedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(widgetWindowDidMove:) name:NSWindowDidMoveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowDidBecomeKey:) name:NSWindowDidBecomeKeyNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(widgetWindowDidResignKey:) name:NSWindowDidResignKeyNotification object:nil];
    _controller = [[dashboardWebView windowScriptObject] valueForKey:@"webClip"];
    [self setPostsFrameChangedNotifications:YES];
    [self setPostsBoundsChangedNotifications:YES];
    _disableAutoRefresh = [[NSUserDefaults standardUserDefaults] boolForKey:@"DisableWebClipRefresh"];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_webView setUIDelegate:nil];
    [_webView setNavigationDelegate:nil];
}

- (NSView *)hitTest:(NSPoint)point
{
    NSView *hit = [super hitTest:point];
    NSPoint mouse = [self mouseLocationInView];
    BOOL editing = _isEditingCameraPosition;
    if (hit == _currentTheme) {
        if (!editing)
            return _webView;
    } else if (!editing) {
        NSRect flipButton = [self convertRect:[_flipButton bounds] fromView:_flipButton];
        if (![_flipButton isHiddenOrHasHiddenAncestor] && NSMouseInRect(mouse, flipButton, [self isFlipped]))
            return _flipButton;
        return hit;
    }
    NSRect lockButton = [self convertRect:[_lockCameraButton bounds] fromView:_lockCameraButton];
    BOOL inLockButton = NSMouseInRect(mouse, lockButton, [self isFlipped]);
    if (hit == _lockCameraButton || inLockButton)
        return _lockCameraButton;
    if (hit == _resizer)
        return self;
    return _clipView;
}

- (void)fadeButtonWithOpacity:(float)opacity
{
    NSColor *color = [NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:opacity];
    [_flipperImageView setImage:[[[self class] flipperImage] wc_tintedImageWithColor:color]];
    [_flipperImageView display];
    [_themeOverlay display];
}

- (void)updateFlipper
{
    [self updateFlipperVisibility];
}

- (void)mouseEnteredOrExited:(BOOL)entered
{
    NSColor *color = [NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:entered ? 0.001 : 0.5];
    [_flipperImageView setImage:[[[self class] flipperImage] wc_tintedImageWithColor:color]];
    [_themeOverlay setNeedsDisplay:YES];
    if (!entered)
        [self updateStandIn];
    [[self windowScriptObject] callWebScriptMethod:entered ? @"iFadeIn" : @"iFadeOut" withArguments:[NSArray array]];
}

- (void)runDragEventRunLoop
{
    [[NSRunLoop currentRunLoop] limitDateForMode:NSEventTrackingRunLoopMode];
    while (true) {
        // The Dock delivers the drag to the widget window.
        NSEvent *event = [[NSApp nextEventMatchingMask:NSLeftMouseDownMask | NSLeftMouseUpMask | NSMouseMovedMask | NSLeftMouseDraggedMask untilDate:[NSDate distantFuture] inMode:NSEventTrackingRunLoopMode dequeue:YES] _eventRelativeToWindow:[self window]];
        NSEventType type = [event type];
        if (type == NSLeftMouseUp)
            break;
        if (type == NSLeftMouseDragged)
            [self mouseDragged:event];
    }
}

- (void)resizeWidgetOnMouseDragged:(NSEvent *)event
{
    NSPoint location = [[self window] convertBaseToScreen:[event locationInWindow]];
    NSSize startSize = _mouseDownWindowSize;
    NSRect start = [_clipView convertRect:_mouseDownClipViewBounds toView:nil];
    NSRect proposed = start;
    proposed.size.width += location.x - _mouseDownPoint.x;
    proposed.size.height += _mouseDownPoint.y - location.y;

    NSView *documentView = _webView;
    NSRect documentRect = documentView ? [documentView convertRect:proposed fromView:nil] : NSZeroRect;
    NSRect snapped = _snapper ? [_snapper snappedRectFromProposedRect:documentRect] : documentRect;
    NSRect snappedInWindow = documentView ? [documentView convertRect:snapped toView:nil] : NSZeroRect;
    float deltaHeight = (snappedInWindow.origin.y + snappedInWindow.size.height) - (start.origin.y + start.size.height);
    float deltaWidth = (snappedInWindow.origin.x + snappedInWindow.size.width) - (start.origin.x + start.size.width);
    [self setWidgetWindowSize:NSMakeSize(startSize.width + deltaWidth, startSize.height + deltaHeight) keepClipperCentered:NO];
}

- (void)repositionClipViewOnMouseDragged:(NSEvent *)event
{
    NSRect bounds = [_clipView bounds];
    NSPoint location = [_clipView convertPoint:[event locationInWindow] fromView:nil];
    float y = roundf((float)(bounds.origin.y - (location.y - _mouseDownPoint.y)));
    float x = roundf((float)(bounds.origin.x - (location.x - _mouseDownPoint.x)));
    NSPoint constrained = [_clipView constrainScrollPoint:NSMakePoint(x, y)];
    NSSize minimum = [_currentTheme minSize];
    float maxX = _documentSize.width - minimum.width;
    float maxY = _documentSize.height - minimum.height;
    NSPoint proposed = NSMakePoint(MIN(constrained.x, (double)maxX), MIN(constrained.y, (double)maxY));
    NSPoint snapped = _snapper ? [_snapper snappedPointFromPoint:proposed proposedCropRect:bounds] : proposed;
    [self scrollClipViewToPoint:snapped];
    [self repositionOverlayButtons];
}

- (void)mouseDragged:(NSEvent *)event
{
    if (!_isEditingCameraPosition) {
        [super mouseDragged:event];
        return;
    }
    [_currentTheme hideEditModeBorder];
    if (_isResizing)
        [self resizeWidgetOnMouseDragged:event];
    else
        [self repositionClipViewOnMouseDragged:event];
}

- (BOOL)pointIsInResizeCorner:(NSPoint)point
{
    NSRect resizer = [self convertRect:(_resizer ? [_resizer bounds] : NSZeroRect) fromView:_resizer];
    return NSPointInRect(point, resizer);
}

- (void)mouseDown:(NSEvent *)event
{
    _isMouseDown = YES;
    if (!_isEditingCameraPosition) {
        [self updateCursor];
        [super mouseDown:event];
        return;
    }
    _isResizing = [self pointIsInResizeCorner:[self convertPoint:[event locationInWindow] fromView:nil]];
    if (_isResizing) {
        _mouseDownPoint = [[self window] convertBaseToScreen:[event locationInWindow]];
        _mouseDownWindowSize = [self window] ? [[self window] frame].size : NSZeroSize;
        _mouseDownClipViewBounds = _clipView ? [_clipView bounds] : NSZeroRect;
    } else
        _mouseDownPoint = [_clipView convertPoint:[event locationInWindow] fromView:nil];
    [self updateCursor];
    [self runDragEventRunLoop];
    _isMouseDown = NO;
    [_currentTheme showEditModeBorder];
    [self updateCursor];
}

- (void)mouseUp:(NSEvent *)event
{
    _isMouseDown = NO;
    _isResizing = NO;
    [self updateCursor];
    if (!_isEditingCameraPosition)
        [super mouseUp:event];
}

- (void)notifyTransitionIsComplete
{
    _transitionInProgress = NO;
    if (!NSEqualRects(_clipRectAfterTransition, NSZeroRect)) {
        NSRect rect = _clipRectAfterTransition;
        _clipRectAfterTransition = NSZeroRect;
        if (!_isEditingCameraPosition)
            [self adjustClipToRect:rect];
    }
    [self updateEventRegion];
    if (!_didFlipToFront)
        return;
    if ([_currentTheme drawsInAttachedWindow]) {
        [_currentTheme orderAttachedWindow:NSWindowAbove relativeTo:0 delayed:YES];
        [self clearScreenshotIfNeeded];
    }
    [self repositionOverlayButtons];
    [self updateCursor];
    [self updateFlipper];
    [_clipView setHidden:NO];
    [_currentTheme display];
    [_placeholder setNeedsDisplay:YES];
    [self updatePageWindow];
}

- (NSSize)adjustedFrameSizeFromOldClipSize:(NSSize)oldClipSize toSize:(NSSize)newClipSize
{
    NSSize frameSize = [self frame].size;
    return NSMakeSize(oldClipSize.width - newClipSize.width + frameSize.width, oldClipSize.height - newClipSize.height + frameSize.height);
}

- (void)switchToThemeAtIndex:(unsigned)index
{
    if ([_currentTheme themeID] == (int)index)
        return;
    NSSize oldClipSize = [_clipView frame].size;
    [self setTheme:index];
    [_clipView setFrame:[self clipViewFrame]];
    NSSize newClipSize = [_clipView frame].size;
    NSSize themeSize = [_currentTheme bounds].size;
    NSSize minimum = [_currentTheme minSize];
    NSSize frameSize = [self adjustedFrameSizeFromOldClipSize:oldClipSize toSize:newClipSize];
    [self setClipperSize:frameSize];
    if (minimum.width > frameSize.width || minimum.height > frameSize.height) {
        frameSize = NSMakeSize(MAX(minimum.width, frameSize.width), MAX(minimum.height, frameSize.height));
        [self setClipperSize:frameSize];
    }
    if ([_currentTheme drawsInAttachedWindow]) {
        [_currentTheme setFrameSize:frameSize];
        [self setScreenshot:[self themeSnapshot]];
        [_currentTheme setFrameSize:themeSize];
    } else
        [self clearScreenshot];
    [_currentTheme display];
    [self updateContentMask];
}

- (void)editCameraPosition
{
    [self updateCursor];
    [self setIsEditingCameraPosition:YES];
}

- (void)didShowWidget
{
    _isHidden = NO;
    _hasBeenShown = YES;
    [WCClipperView askDock];
    [self updatePageWindow];
    if (_disableAutoRefresh || [[self controller] playAudioOutOfDashboard])
        return;
    if (!_webView) {
        [self createWebViewWithSize:[[self controller] visibleContentSize]];
        [_voidView addSubview:_webView positioned:NSWindowBelow relativeTo:_pageCover];
        [_pageCover setIsBlack:YES];
        [_pageCover setHidden:NO];
        [self sizeWebView];
    }
    if (_hasBeenShown && !_isLoading && _didFlipToFront && !_isEditingCameraPosition)
        [self reload:nil];
    [self clearScreenshotIfNeeded];
}

- (void)closeWebView
{
    [_webView stopLoading:nil];
    [_webView setNavigationDelegate:nil];
    [_webView setUIDelegate:nil];
    [_webView _setFullscreenDelegate:nil];
    [_webView _close];
    [_webView removeFromSuperview];
    _webView = nil;
    _isLoading = NO;
}

// The clip's last pixels stand in for the page from a hide, which closes the web view, to the end
// of the load the next show starts. They sit where the page was in the clip view, under the same
// theme and content mask.
- (void)showPageSnapshot:(NSImage *)image inRect:(NSRect)rect
{
    [_pageSnapshotView removeFromSuperview];
    _pageSnapshotView = [[NSImageView alloc] initWithFrame:rect];
    [_pageSnapshotView setImageScaling:NSImageScaleAxesIndependently];
    [_pageSnapshotView setImage:image];
    addLayerBackedSubview(_voidView, _pageSnapshotView);
    [self updateFlipperVisibility];
}

// The page renders the clip's pixels, and the web view closes once it has.
- (void)didHideWidget
{
    _isHidden = YES;
    [WCClipperView askDock];
    [self updatePageWindow];
    if (_disableAutoRefresh || [[self controller] playAudioOutOfDashboard] || _isEditingCameraPosition || [self isShowingLoadingText] || [self isBacksideShowing] || _loadError)
        return;
    WKWebView *webView = _webView;
    NSRect pageRect = NSIntersectionRect([_clipView bounds], [webView frame]);
    if (!webView || ![_pageCover isHidden] || NSIsEmptyRect(pageRect)) {
        [self closeWebView];
        return;
    }
    WKSnapshotConfiguration *configuration = [[WKSnapshotConfiguration alloc] init];
    configuration.rect = [webView convertRect:pageRect fromView:_voidView];
    [webView takeSnapshotWithConfiguration:configuration completionHandler:^(NSImage *image, NSError *error) {
        if (webView != _webView || !_isHidden)
            return;
        if (image)
            [self showPageSnapshot:image inRect:pageRect];
        [self closeWebView];
    }];
}

- (void)didFlipWidget:(BOOL)toFront
{
    if (!toFront) {
        _didFlipToFront = NO;
        [self updatePageWindow];
        return;
    }
    _didFlipToFront = YES;
    [self updatePageWindow];
    [_currentTheme setHidden:NO];
    [self updateEventRegion];
    [self updateTrackingRect];
    [_lockCameraButton updateTrackingRect];
}

- (void)loadURLString:(NSString *)URLString clipRect:(NSRect)clipRect clipSignature:(NSDictionary *)clipSignature pageSize:(NSSize)pageSize displayLoadingText:(BOOL)displayLoadingText resizeWidget:(BOOL)resizeWidget
{
    _documentSize = pageSize;
    NSPoint pageScroll = [[self controller] pageScroll];
    _clipViewportOrigin = NSMakePoint(clipRect.origin.x - pageScroll.x, clipRect.origin.y - pageScroll.y);
    [self placeWebViewAtPageScroll:NSZeroPoint];
    [self scrollPageTo:pageScroll];
    [[self controller] setClipSignature:clipSignature];
    if (resizeWidget)
        [self setWidgetWindowSize:clipRect.size keepClipperCentered:YES];
    else {
        [self setConstrainedClipperSize:clipRect.size];
        [_clipView setFrame:[self clipViewFrame]];
    }
    if (displayLoadingText)
        [self displayLoadingText];
    if ([self isBacksideShowing]) {
        NSSize themeSize = _currentTheme ? [_currentTheme frame].size : NSZeroSize;
        [_currentTheme setFrameSize:clipRect.size];
        [_clipView setHidden:YES];
        [self setScreenshot:[self themeSnapshot]];
        [self updateFlipperVisibility];
        [self setNeedsDisplay:YES];
        [_currentTheme setFrameSize:themeSize];
    }
    NSURLRequest *request = [[NSURLRequest alloc] initWithURL:[NSURL _web_URLWithUserTypedString:URLString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:31536000];
    _isLoading = YES;
    [_webView loadRequest:request];
    _didFlipToFront = YES;
    [self updatePageWindow];
}

- (int)currentThemeID
{
    return [_currentTheme themeID];
}

- (void)webPlugInDestroy
{
    [_webView stopLoading:nil];
    [[_webView configuration].userContentController removeAllScriptMessageHandlers];
    [_webView setUIDelegate:nil];
    [_webView setNavigationDelegate:nil];
    [_webView _setFullscreenDelegate:nil];
    [_webView _close];
    [self orderPageWindowOut];
    [_pageWindow setContentView:nil];
    [_pageWindow close];
    _pageWindow = nil;
    [[self controller] setWebClipperView:nil];
    [_currentTheme setDashboardWebView:nil];
}

#pragma mark - Page agent

- (void)callPageFunction:(NSString *)name argument:(id)argument completionHandler:(void (^)(id result))completionHandler
{
    if (!_webView || !_pageWorld) {
        completionHandler(nil);
        return;
    }
    NSString *body = [NSString stringWithFormat:@"return window.__webClip ? window.__webClip.%@(argument) : null;", name];
    [_webView callAsyncJavaScript:body arguments:@{ @"argument": argument ?: [NSNull null] } inFrame:nil inContentWorld:_pageWorld completionHandler:^(id result, NSError *error) {
        completionHandler(error || [result isKindOfClass:[NSNull class]] ? nil : result);
    }];
}

- (void)pageDraggableRects:(void (^)(NSArray *documentRects))completionHandler
{
    [self callPageFunction:@"draggableRects" argument:nil completionHandler:^(id rects) {
        NSMutableArray *documentRects = [NSMutableArray array];
        if ([rects isKindOfClass:[NSArray class]]) {
            for (id rect in rects) {
                NSRect documentRect = rectFromPageRect(rect);
                if (!NSEqualSizes(documentRect.size, NSZeroSize))
                    [documentRects addObject:[NSValue valueWithRect:documentRect]];
            }
        }
        completionHandler(documentRects);
    }];
}

- (void)pageDidPostMessage:(NSDictionary *)message
{
    NSString *type = message[@"type"];
    if ([type isEqual:@"scroll"]) {
        [self placeWebViewAtPageScroll:pageScrollFromResult(message)];
        if (_hasPageScrollTarget)
            [self layoutPageViewport];
    } else if ([type isEqual:@"documentSize"]) {
        _documentSize = NSMakeSize([message[@"width"] doubleValue], [message[@"height"] doubleValue]);
        [self layoutPageViewport];
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    _isLoading = YES;
    [self clearScreenshotIfNeeded];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    _loadError = NO;
    [self dismissError];
    [self placeWebViewAtPageScroll:NSZeroPoint];
    [self scrollPageTo:[[self controller] pageScroll]];
}

- (void)_webView:(WKWebView *)webView renderingProgressDidChange:(_WKRenderingProgressEvents)progressEvents
{
    if (webView == _webView)
        [self updateStandIn];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    _isLoading = NO;
    [self dismissLoadingText];
    [self stopProgressTimer];
    [self layoutPageViewport];
    [_webView _setTextZoomFactor:[[self controller] textSizeMultiplier]];
    [self clearScreenshotIfNeeded];
    [self updateStandIn];
    [self followSignature];
}

- (void)failedNavigationWithError:(NSError *)error
{
    if ([error _web_errorIsInDomain:WebKitErrorDomain] && [error code] == 204 /* WebKitErrorPlugInWillHandleLoad */) {
        [self webView:_webView didFinishNavigation:nil];
        return;
    }
    _isLoading = NO;
    [self setError:error];
    [self stopProgressTimer];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [self failedNavigationWithError:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    [self failedNavigationWithError:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    [self reload:nil];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURLRequest *request = [navigationAction request];
    if ([[[request URL] scheme] isEqualToString:@"opensafari"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        [[_placeholder window] accessibilityPerformAction:@"AXCloseWidget"];
        [[self windowScriptObject] callWebScriptMethod:@"openSafari" withArguments:nil];
        return;
    }
    WKNavigationType type = [navigationAction navigationType];
    // A form the page's script submits is part of the page loading.
    if (type == WKNavigationTypeReload || type == WKNavigationTypeOther || (type == WKNavigationTypeFormSubmitted && ![navigationAction _isUserInitiated])) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    decisionHandler(WKNavigationActionPolicyCancel);
    if (type == WKNavigationTypeFormSubmitted) {
        if ([[request HTTPMethod] caseInsensitiveCompare:@"POST"] == NSOrderedSame)
            return;
    } else if (type != WKNavigationTypeLinkActivated)
        return;
    [[self windowScriptObject] callWebScriptMethod:@"openURL" withArguments:[NSArray arrayWithObjects:[[request URL] absoluteString], nil]];
}

#pragma mark - _WKFullscreenDelegate

// Dashboard's windows lie above every application window, so the page's full screen window takes a level
// above the widget's.
- (void)_webViewWillEnterFullscreen:(NSView *)webView
{
    [[webView window] setLevel:[[_placeholder window] level] + 1];
}

// The full screen window gives the key focus back to the page window before it leaves: ordered out as
// the key window, it would hand the focus on through the widget's windows, which the Dock owns.
- (void)_webViewWillExitFullscreen:(NSView *)webView
{
    if ([_pageWindow isVisible])
        [self makePageWindowKey];
}

#pragma mark - WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
    return nil;
}

- (void)_webView:(WKWebView *)webView getContextMenuFromProposedMenu:(NSMenu *)menu forElement:(id)element userInfo:(id)userInfo completionHandler:(void (^)(NSMenu *))completionHandler
{
    completionHandler(nil);
}

@end
