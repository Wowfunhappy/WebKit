// WKView implementation for MAVERICKS_BACKPORT
#import <objc/runtime.h>
// Creates a WebPageProxy when Safari's BrowserWKView initializes

#import "config.h"
// MAVERICKS_BACKPORT: include the public WKView.h (not WKViewInternal.h) — this is a standalone reimplementation, not the upstream PLATFORM(MAC) WebViewImpl wrapper.
#import "WKView.h"
// MAVERICKS_BACKPORT: WKViewPrivate.h carries the restored Safari-7 WKView SPI declarations
// implemented below (the WKContentAnchor enum, the view-in-window deferral family, the async
// drawing-area size-update pair, and the automatic-substitution flags).
#import "WKViewPrivate.h"

#import "APIPageConfiguration.h"
// MAVERICKS_BACKPORT: includes for the hand-written NSEvent→WebPageProxy input forwarding and page wiring below.
#import "NativeWebKeyboardEvent.h"
#import "NativeWebMouseEvent.h"
#import "NativeWebWheelEvent.h"
#import "PageClient.h"
#import "WKAPICast.h"
#import "WebPageGroup.h"
#import "WebPageProxy.h"
#import "WebPreferences.h"
#import "WebProcessPool.h"
// MAVERICKS_BACKPORT: process-global TextChecker state + the process proxy that pushes it to
// WebContent, for the restored automatic quote/dash substitution SPI below.
#import "TextChecker.h"
#import "TextCheckerState.h"
#import "WebProcessProxy.h"
#import "WebUserContentControllerProxy.h"
#import "WebKit2Initialize.h"
#import "DrawingAreaProxy.h"
#import "WKPrintingView.h"
#import "WebFrameProxy.h"
// MAVERICKS_BACKPORT: legacy ObjC group/controller classes that QuickLook's
// Web2.qldisplay drives through WKView.
#import "WKBrowsingContextControllerInternal.h"
#import "WKProcessGroupInternal.h"
#import "WKBrowsingContextGroupInternal.h"
#import <WebCore/ActivityState.h>
#import <WebCore/ColorCocoa.h>
#import <WebCore/FloatPoint.h>
#import <WebCore/FloatRect.h>
#import <WebCore/IntSize.h>
#import <WebCore/KeypressCommand.h>
// MAVERICKS_BACKPORT: WebCoreFullScreenWindow backs the restored -createFullScreenWindow SPI.
#import <WebCore/WebCoreFullScreenWindow.h>
#import <QuartzCore/QuartzCore.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
// MAVERICKS_BACKPORT: Services support — advertise the web selection to AppKit's Services
// machinery (the app-menu Services submenu and the context-menu services). The standalone
// WKView talks to WebPageProxy directly (no WebViewImpl), so these are wired here.
#import "EditorState.h"
#import "PasteboardTypes.h"
#import <WebCore/LegacyNSPasteboardTypes.h>
#import <WebCore/SharedBuffer.h>
#if ENABLE(DRAG_SUPPORT)
// MAVERICKS_BACKPORT: extra includes for the hand-written WKView HTML5 drag source/destination.
#import "PasteboardTypes.h"
#import "SandboxExtension.h"
#import <WebCore/DragData.h>
#import <WebCore/DragActions.h>
#import <WebCore/PlatformEventFactoryMac.h>
// MAVERICKS_BACKPORT: _NSRecommendedScrollerStyle(), used to pick the mouse-tracking-area options.
#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <wtf/Compiler.h>
#endif

// MAVERICKS_BACKPORT: this WKView reimplementation uses WebKit:: types unqualified throughout.
using namespace WebKit;

// MAVERICKS_BACKPORT: minimal page-client factory/accessors declared in PageClientImplMac.mm.
namespace WebKit {
std::unique_ptr<PageClient> createMinimalPageClient(NSView *view);
void setMinimalPageClientPage(PageClient&, WebPageProxy *);
void setMinimalPageClientForceVisibleWhenWindowless(PageClient&, bool);
void minimalPageClientViewDidMoveToWindow(PageClient&);
}

// Per-WKView state. RefPtr<WebPageProxy> keeps the page alive for the
// lifetime of the view; std::unique_ptr<PageClient> owns the page client.
struct WKViewState {
    RefPtr<WebKit::WebPageProxy> page;
    std::unique_ptr<WebKit::PageClient> pageClient;
#if ENABLE(DRAG_SUPPORT)
    // MAVERICKS_BACKPORT: the originating mouse-down event, needed by the classic
    // -[NSView dragImage:...event:...] API to start an HTML5 drag session.
    RetainPtr<NSEvent> lastMouseDownEvent;
#endif
    // MAVERICKS_BACKPORT: the unhandled key-down currently being re-dispatched to AppKit
    // (mirrors WebViewImpl::m_keyDownEventBeingResent); performKeyEquivalent:/keyDown:
    // pass it to super instead of re-entering the page.
    RetainPtr<NSEvent> keyDownEventBeingResent;
    // MAVERICKS_BACKPORT: Safari 7's content-anchor SPI — the corner painted content stays
    // pinned to while frame-size updates are disabled (see -setContentAnchor:).
    WKContentAnchor contentAnchor { WKContentAnchorTopLeft };
    // MAVERICKS_BACKPORT: accumulated content-anchor shift of the hosted layer, and the
    // -disableFrameSizeUpdates nesting count that gates the drawing-area size push (both
    // mirror the 537 WKView's _frameOrigin / _frameSizeUpdatesDisabledCount).
    NSPoint frameOrigin { 0, 0 };
    unsigned frameSizeUpdatesDisabledCount { 0 };
    // MAVERICKS_BACKPORT: view-in-window-change deferral state (mirrors WebViewImpl's
    // m_shouldDeferViewInWindowChanges / m_viewInWindowChangeWasDeferred). While deferring,
    // -viewDidMoveToWindow records the IsInWindow change here instead of pushing it;
    // -endDeferringViewInWindowChanges[Sync] pushes the coalesced change.
    bool shouldDeferViewInWindowChanges { false };
    bool viewInWindowChangeWasDeferred { false };
    // MAVERICKS_BACKPORT: Safari-7 -[WKView setShouldClipToVisibleRect:] state (mirrors
    // WebViewImpl::m_clipsToVisibleRect). When set, the page's view-exposed-rect is pinned to
    // the view's visible rect so the tiled drawing area only backs visible content. iBooks'
    // BKWKViewTiling sends -setShouldClipToVisibleRect:YES right after creating the view.
    bool shouldClipToVisibleRect { false };
};

// MAVERICKS_BACKPORT: WKContentAnchor corner tests, restored from the Safari-537-era WKView.mm.
static inline bool isWKContentAnchorRight(WKContentAnchor x)
{
    return x == WKContentAnchorTopRight || x == WKContentAnchorBottomRight;
}

static inline bool isWKContentAnchorBottom(WKContentAnchor x)
{
    return x == WKContentAnchorBottomLeft || x == WKContentAnchorBottomRight;
}

// MAVERICKS_BACKPORT: NSApplication SPI WebViewImpl::doneWithKeyEvent uses when re-dispatching
// an unhandled key-down back to AppKit, so [NSApp currentEvent] matches during menu dispatch.
@interface NSApplication (WKMavericksKeyResend)
- (void)_setCurrentEvent:(NSEvent *)event;
@end

@interface WKView () {
    WKViewState *_wkState;
    WKBrowsingContextController *_browsingContextController;
    // MAVERICKS_BACKPORT: cached intrinsic content size for the auto-layout SPI Mail's
    // MUIWKView drives (the web process reports the laid-out content size back via
    // MinimalPageClient::intrinsicContentSizeDidChange -> -_setIntrinsicContentSize:).
    NSSize _intrinsicContentSize;
}
// MAVERICKS_BACKPORT: private helper backing the clip-to-visible-rect SPI (see -setShouldClipToVisibleRect:).
- (void)_updateViewExposedRect;
@end // MAVERICKS_BACKPORT: WKView class extension holding the backported per-view state ivars

// MAVERICKS_BACKPORT: WKView is reimplemented for the 10.9 backport (the upstream WebViewImpl-backed body is stubbed).
@implementation WKView

// MAVERICKS_BACKPORT: designated initializer — creates a WebPageProxy + minimal page client for this view.
- (instancetype)initWithFrame:(NSRect)frame processPool:(std::reference_wrapper<WebKit::WebProcessPool>)processPool configuration:(Ref<API::PageConfiguration>&&)configuration
{
    // MAVERICKS_BACKPORT: chain to NSView's initializer before wiring up the page.
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    // MAVERICKS_BACKPORT: layer-back the view and paint a white base so empty/loading pages aren't black.
    [self setWantsLayer:YES];
    self.layer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);

    // MAVERICKS_BACKPORT: start with a flexible intrinsic size until the web process reports a laid-out one.
    _intrinsicContentSize = NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);

    // MAVERICKS_BACKPORT: ensure WebKit2 globals are initialized before creating the page proxy.
    WebKit::InitializeWebKit2();

    // MAVERICKS_BACKPORT: allocate the backported per-view state holding the page proxy + minimal page client.
    _wkState = new WKViewState;
    _wkState->pageClient = createMinimalPageClient(self);
    _wkState->page = processPool.get().createWebPage(*_wkState->pageClient, WTF::move(configuration));
    setMinimalPageClientPage(*_wkState->pageClient, _wkState->page.get());
    // MAVERICKS_BACKPORT: a WKView born with a real (non-zero) frame is an offscreen render
    // view — Safari's Top Sites snapshot fetcher allocs a WKView at the snapshot size,
    // loads a URL into it, and snapshots it WITHOUT ever adding it to a window or
    // resizing it. Normal browser tab WKViews are created at 0x0 and later attached to
    // a window + resized, which is what drives visibility and drawing-area sizing. Mark
    // this windowless view as force-visible so its WebContent takes a foreground
    // assertion and actually loads/lays-out/paints; without this the page is treated as
    // an offscreen hidden tab and never renders, so the snapshot stays a dark placeholder.
    if (frame.size.width > 0 && frame.size.height > 0)
        setMinimalPageClientForceVisibleWhenWindowless(*_wkState->pageClient, true);

    // MAVERICKS_BACKPORT: bring up the WebPage now that the page proxy + client are wired (no Site/sandbox yet).
    _wkState->page->initializeWebPage(WebCore::Site(WTF::HashTableEmptyValue), WebCore::SandboxFlags {}, WebCore::ReferrerPolicy::Default);

    // MAVERICKS_BACKPORT: legacy WebKit2 launched the context's web process as soon as a page
    // existed, and embedders sequence on the resulting connection callback — WKProcessGroup's
    // -processGroup:didCreateConnectionToWebProcessPlugIn: fires at web-process launch, and
    // iBooks won't load anything into a fresh document worker's view until that callback hands
    // it the connection. Modern WebKit defers the launch to the first load, which deadlocks that
    // pattern (no load -> no launch -> no callback -> iBooks' 60s watchdog). Launch eagerly, as
    // 537 did via ensureSharedWebProcess at page creation (no-op if a real process already runs;
    // launchProcess re-runs initializeWebPage against the launched process via
    // finishAttachingToWebProcess, replacing the drawing area created above).
    _wkState->page->launchInitialProcessIfNecessary();

    // MAVERICKS_BACKPORT: tell AppKit which pasteboard types this view can supply from / accept into the
    // selection, so the Services machinery offers services for the web selection (app-menu Services submenu
    // and context-menu services). Ported from WebViewImpl's constructor (which this WKView does not use).
    [NSApp registerServicesMenuSendTypes:WebKit::PasteboardTypes::forSelectionSingleton() returnTypes:WebKit::PasteboardTypes::forEditingSingleton()];

    // MAVERICKS_BACKPORT: mouse-tracking area so this view receives mouseMoved:/mouseEntered:/
    // mouseExited: even when it is not the window's first responder. AppKit routes plain
    // NSMouseMoved window events to the first responder only, so an embedder that keeps focus
    // elsewhere (Mail's message list stays first responder while the body WKView shows a message)
    // would otherwise deliver no mouseMoved: to this view until it is first clicked — leaving the
    // cursor a plain arrow over text/links and CSS :hover dead. A tracking area delivers these
    // events to its owner regardless of first-responder status. Options match Safari 7 WebKit2's
    // -[WKView initWithFrame:contextRef:pageGroupRef:relatedToPage:]: legacy scrollbars have
    // design details that rely on tracking the mouse all the time, overlay scrollbars only need
    // tracking while the window is key. (WebViewImpl::trackingAreaOptions() additionally sets
    // NSTrackingCursorUpdate, which is for a cursorUpdate: handler this view does not have.)
    NSTrackingAreaOptions trackingOptions = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect;
    trackingOptions |= _NSRecommendedScrollerStyle() == NSScrollerStyleLegacy ? NSTrackingActiveAlways : NSTrackingActiveInKeyWindow;
    RetainPtr<NSTrackingArea> trackingArea = adoptNS([[NSTrackingArea alloc] initWithRect:frame options:trackingOptions owner:self userInfo:nil]);
    [self addTrackingArea:trackingArea.get()];

#if ENABLE(DRAG_SUPPORT)
    // MAVERICKS_BACKPORT: become an NSDraggingDestination so drops route into the page.
    auto dragTypes = adoptNS([[NSMutableSet alloc] initWithArray:WebKit::PasteboardTypes::forEditingSingleton()]);
    [dragTypes addObjectsFromArray:WebKit::PasteboardTypes::forURLSingleton()];
    [dragTypes addObject:WebKit::PasteboardTypes::WebDummyPboardType];
    [self registerForDraggedTypes:[dragTypes allObjects]];
#endif

    // MAVERICKS_BACKPORT: designated initializer returns the fully wired-up WKView.
    return self;
}

// MAVERICKS_BACKPORT: tear down the backported per-view state (page proxy, page client, cached controller).
- (void)dealloc
{
    // MAVERICKS_BACKPORT: stop observing backing-scale changes (registered in -viewDidMoveToWindow for the Retina fix).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeBackingPropertiesNotification object:nil];
    // MAVERICKS_BACKPORT: stop observing screen changes (registered in -viewDidMoveToWindow for the display-link wiring).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeScreenNotification object:nil];
    // MAVERICKS_BACKPORT: release the lazily-created browsing-context controller and delete the WKViewState.
    [_browsingContextController release];
    _browsingContextController = nil;
    delete _wkState;
    _wkState = nullptr;
    [super dealloc];
}

// MAVERICKS_BACKPORT: WKView auto-layout / intrinsic-content-size SPI. Mail's message
// viewer (MUIWKView) drives the message view through this: it enables auto-sizing
// with -setMinimumSizeForAutoLayout:, and the web process reports the laid-out
// content height back so the view sizes to fit the message inside Mail's scroll
// view. Without it the message body renders blank. Ported from WebViewImpl.
- (NSSize)intrinsicContentSize
{
    // MAVERICKS_BACKPORT: return the cached auto-layout content size so Mail can size message bodies.
    return _intrinsicContentSize;
}

- (void)setMinimumSizeForAutoLayout:(NSSize)minimumSizeForAutoLayout
{
// MAVERICKS_BACKPORT: auto-layout SPI — a positive min width enables web-process auto-sizing (ported from WebViewImpl).
    if (!_wkState || !_wkState->page)
        return;
    // Matches WebViewImpl::setMinimumSizeForAutoLayout: a positive minimum width enables
    // auto-sizing (the web process lays out at >= this width and reports the content height
    // back via intrinsicContentSizeDidChange), and the main frame becomes non-scrollable so
    // it grows to fit instead of clipping. Mail relies on this to size each message body.
    BOOL expandsToFit = minimumSizeForAutoLayout.width > 0;
    _wkState->page->setMinimumSizeForAutoLayout(WebCore::IntSize(minimumSizeForAutoLayout.width, minimumSizeForAutoLayout.height));
    _wkState->page->setMainFrameIsScrollable(!expandsToFit);
}

// MAVERICKS_BACKPORT: auto-layout SPI getter for the configured minimum layout size (ported from WebViewImpl).
- (NSSize)minimumSizeForAutoLayout
{
    if (!_wkState || !_wkState->page)
        return NSZeroSize;
    auto size = _wkState->page->minimumSizeForAutoLayout();
    return NSMakeSize(size.width(), size.height());
}

// MAVERICKS_BACKPORT: auto-layout SPI — let auto-sizing expand to fill the view height (ported from WebViewImpl for Mail).
- (void)setShouldExpandToViewHeightForAutoLayout:(BOOL)shouldExpand
{
    // MAVERICKS_BACKPORT: forward the auto-size-expands-to-view-height flag to the page proxy.
    if (_wkState && _wkState->page)
        _wkState->page->setAutoSizingShouldExpandToViewHeight(shouldExpand);
}

- (BOOL)shouldExpandToViewHeightForAutoLayout
{
// MAVERICKS_BACKPORT: auto-layout SPI getter mirroring WebViewImpl::shouldExpandToViewHeightForAutoLayout.
    return _wkState && _wkState->page ? _wkState->page->autoSizingShouldExpandToViewHeight() : NO;
}

// MAVERICKS_BACKPORT: Called by MinimalPageClient::intrinsicContentSizeDidChange when the web process
// reports a new laid-out content size.
- (void)_setIntrinsicContentSize:(NSSize)intrinsicContentSize
{
    // MAVERICKS_BACKPORT: clamp the reported width to a flexible metric when it flowed below the min layout width (matches WebViewImpl).
    // If the content's intrinsic width is less than the minimum layout width, the
    // content flowed to fit, so report the width as flexible (no intrinsic metric);
    // otherwise report it so auto-layout reserves space. Matches WebViewImpl.
    NSSize size = intrinsicContentSize;
    if (_wkState && _wkState->page && intrinsicContentSize.width < _wkState->page->minimumSizeForAutoLayout().width())
        size.width = NSViewNoIntrinsicMetric;
    _intrinsicContentSize = size;
    [self invalidateIntrinsicContentSize];
}

// MAVERICKS_BACKPORT: C-ref WKView initializer Safari/QuickLook use; forwards to the relatedToPage: variant.
- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef
{
    return [self initWithFrame:frame contextRef:contextRef pageGroupRef:pageGroupRef relatedToPage:nil];
}

// MAVERICKS_BACKPORT: build an API::PageConfiguration from the C refs and route through the designated initializer.
- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef relatedToPage:(WKPageRef)relatedPage
{
    auto configuration = API::PageConfiguration::create();
    configuration->setProcessPool(WebKit::toImpl(contextRef));
    // MAVERICKS_BACKPORT: honor the page group Safari passes — its identifier is
    // how the injected bundle scopes extension content scripts
    // (WKBundleAddUserScript), and its preferences carry Safari's settings.
    if (pageGroupRef) {
        RefPtr<WebKit::WebPageGroup> pageGroup = WebKit::toImpl(pageGroupRef);
        configuration->setPreferences(&pageGroup->preferences());
        // MAVERICKS_BACKPORT: share the page group's user content controller so user
        // scripts/style sheets installed on the group (WKPageGroupAddUserScript /
        // AddUserStyleSheet, e.g. via Mail's WKBrowsingContextGroup) are injected
        // into this page. Without this the page would get a fresh empty controller.
        configuration->setUserContentController(&pageGroup->userContentController());
        configuration->setPageGroup(WTF::move(pageGroup));
    }

    // MAVERICKS_BACKPORT: honor relatedToPage — the related page pins this page into the same
    // WebProcess (WebProcessPool::createWebPage uses relatedPage->ensureRunningProcess()).
    // Safari's SearchableWKView passes the current tab's page here; Safari Reader depends on it:
    // the reader page's injected-bundle controller resolves the browser page's article finder
    // in-process (ReaderWebProcessController::originalArticleFinder walks a same-process
    // WKBundlePage link), and the extracted article DOM node is adopted across the two pages.
    if (relatedPage)
        configuration->setRelatedPage(protect(WebKit::toImpl(relatedPage)));

    return [self initWithFrame:frame processPool:*WebKit::toImpl(contextRef) configuration:WTF::move(configuration)];
}

- (id)initWithFrame:(NSRect)frame configurationRef:(WKPageConfigurationRef)configurationRef { return nil; }
- (WKPageRef)pageRef { return _wkState ? WebKit::toAPI(_wkState->page.get()) : nullptr; }

// MAVERICKS_BACKPORT: legacy initializer used by QuickLook's Web2.qldisplay. It hands
// us a WKProcessGroup + WKBrowsingContextGroup; unwrap them to the underlying
// WKContextRef/WKPageGroupRef and route through the existing C-ref init path.
- (id)initWithFrame:(NSRect)frame processGroup:(WKProcessGroup *)processGroup browsingContextGroup:(WKBrowsingContextGroup *)browsingContextGroup
{
    WKContextRef contextRef = processGroup ? [processGroup _contextRef] : nullptr;
    if (!contextRef) {
        [self release];
        return nil;
    }
    WKPageGroupRef pageGroupRef = browsingContextGroup ? [browsingContextGroup _pageGroupRef] : nullptr;
    return [self initWithFrame:frame contextRef:contextRef pageGroupRef:pageGroupRef];
}

// MAVERICKS_BACKPORT: vend a controller bound to this view's page so Web2.qldisplay
// can load/observe via the controller (or pull its pageRef for the C SPI).
- (WKBrowsingContextController *)browsingContextController
{
    if (!_browsingContextController && _wkState && _wkState->page)
        _browsingContextController = [[WKBrowsingContextController alloc] _initWithPageRef:WebKit::toAPI(_wkState->page.get())];
    return _browsingContextController;
}

// MAVERICKS_BACKPORT: WKView's normal setFrameSize: propagates the new viewport size to
// WebContent via WebPageProxy::setSize. Without this override, WebContent renders at
// 0x0 — Safari creates WKViews with zero frame and resizes them later.
//
// The Safari-537-era frame-size-updates gate and content-anchor shift are ported in here:
// Safari 7's resize animations run disableFrameSizeUpdates → -setFrameSize: (repeatedly) →
// forceAsyncDrawingAreaSizeUpdate: → waitForAsyncDrawingAreaSizeUpdate →
// enableFrameSizeUpdates. While updates are disabled, the drawing-area push is skipped and
// the hosted layer is shifted so the already-painted content stays pinned to the corner
// Safari chose with -setContentAnchor: (the 537 setFrameSize: _frameOrigin/rootLayer.position
// mechanism); -enableFrameSizeUpdates then pushes the settled frame size and clears the shift.
- (void)setFrameSize:(NSSize)newSize
{
    // MAVERICKS_BACKPORT: compute the anchor-shifted content origin against the OLD frame size,
    // before super updates it (mirrors the 537 setFrameSize: ordering).
    bool frameSizeUpdatesEnabled = ![self frameSizeUpdatesDisabled];
    NSPoint newFrameOrigin = NSZeroPoint;
    if (!frameSizeUpdatesEnabled && _wkState) {
        newFrameOrigin = _wkState->frameOrigin;
        if (isWKContentAnchorRight(_wkState->contentAnchor))
            newFrameOrigin.x += [self frame].size.width - newSize.width;
        if (isWKContentAnchorBottom(_wkState->contentAnchor))
            newFrameOrigin.y += [self frame].size.height - newSize.height;
    }

    [super setFrameSize:newSize];

    if (frameSizeUpdatesEnabled && _wkState && _wkState->page) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(newSize.width, newSize.height));
        // MAVERICKS_BACKPORT: keep the clipped view-exposed-rect matched to the new visible rect.
        if (_wkState->shouldClipToVisibleRect)
            [self _updateViewExposedRect];
    }
    // MAVERICKS_BACKPORT: the WebContent's render layer lives in MinimalPageClient's dedicated
    // layer-hosting subview (autoresized with us), unframed — so plain resizes need no layer
    // fix-up. Only the 537 content-anchor shift is applied here: while frame-size updates are
    // disabled the render layer's position moves by the accumulated size delta so the painted
    // content stays pinned to the anchored corner, and the outermost re-enable (or the next
    // enabled-state resize) puts it back. This view is flipped, so the top-left-origin math of
    // the 537 shift (rootLayer.position = -newFrameOrigin) carries over directly.
    CALayer *renderLayer = (_wkState && _wkState->pageClient) ? _wkState->pageClient->acceleratedCompositingRootLayer() : nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (frameSizeUpdatesEnabled) {
        if (_wkState && !NSEqualPoints(_wkState->frameOrigin, NSZeroPoint)) {
            _wkState->frameOrigin = NSZeroPoint;
            [renderLayer setPosition:CGPointZero];
        }
    } else {
        if (_wkState)
            _wkState->frameOrigin = newFrameOrigin;
        [renderLayer setPosition:CGPointMake(-newFrameOrigin.x, -newFrameOrigin.y)];
    }
    [CATransaction commit];
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    // MAVERICKS_BACKPORT: honor the frame-size-updates gate here too — while Safari has called
    // -disableFrameSizeUpdates, no frame change reaches the drawing area until
    // -enableFrameSizeUpdates pushes the settled size.
    if (![self frameSizeUpdatesDisabled] && _wkState && _wkState->page) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(frame.size.width, frame.size.height));
    }
    [self _updateViewExposedRect];
}

// MAVERICKS_BACKPORT: moving this view within its superview changes which part of it is visible
// but fires no other geometry hook (layer-backed views rarely get -renewGState). iBooks' reader
// turns pages by SLIDING its wide paginated strip view via frame-origin changes, so the clipped
// view-exposed rect must follow here or the newly exposed page region is never painted.
- (void)setFrameOrigin:(NSPoint)origin
{
    [super setFrameOrigin:origin];
    [self _updateViewExposedRect];
}

// MAVERICKS_BACKPORT: the display pass that follows any layout/attach reaches -viewWillDraw with
// FINAL geometry. Refresh the clipped view-exposed rect here: a view swapped into a window at
// its final position (iBooks installs each chapter's strip view this way) gets no
// frame/origin/gstate hook afterwards, and the empty visibleRect latched at -viewDidMoveToWindow
// time would otherwise persist — the web process then paints nothing for the visible page.
- (void)viewWillDraw
{
    [self _updateViewExposedRect];
    [super viewWillDraw];
}

// MAVERICKS_BACKPORT: Safari-7 clip-to-visible-rect SPI, declared in WKViewPrivate.h.
// Ported from WebViewImpl::{setClipsToVisibleRect,clipsToVisibleRect,updateViewExposedRect}
// (which this WKView reimplementation does not use). iBooks' BKWKViewTiling sends
// -setShouldClipToVisibleRect:YES unguarded when wiring up its page; without the method the
// send hit ObjC forwarding -> uncaught NSInvalidArgumentException -> the app terminated.
- (BOOL)shouldClipToVisibleRect
{
    return _wkState ? _wkState->shouldClipToVisibleRect : NO;
}

- (void)setShouldClipToVisibleRect:(BOOL)clipsToVisibleRect
{
    if (!_wkState)
        return;
    _wkState->shouldClipToVisibleRect = clipsToVisibleRect;
    [self _updateViewExposedRect];
}

// MAVERICKS_BACKPORT: pin the page's view-exposed-rect to the view's visible rect while clipping
// is on (nullopt = no restriction). Mirrors WebViewImpl::updateViewExposedRect; refreshed from the
// geometry hooks below so a view that turned clipping on while zero-sized/out-of-window (iBooks
// enables it before attaching the view to a window) does not stay clipped to an empty rect.
- (void)_updateViewExposedRect
{
    if (!_wkState || !_wkState->page)
        return;
    CGRect exposedRect = NSRectToCGRect([self visibleRect]);
    _wkState->page->setViewExposedRect(_wkState->shouldClipToVisibleRect ? std::optional<WebCore::FloatRect>(exposedRect) : std::nullopt);
}

// MAVERICKS_BACKPORT: content-anchor SPI, declared in WKViewPrivate.h (with the restored
// WKContentAnchor enum) and sent unguarded by Safari 7 around its gated resize animations
// (-disableFrameSizeUpdates … -enableFrameSizeUpdates). The Safari-537-era anchoring had two
// halves, and this port restores the UI-process half: while frame-size updates are disabled,
// -setFrameSize: shifts the hosted layer by the accumulated size delta so the already-painted
// content stays pinned to the anchored corner (537's rootLayer.position = -_frameOrigin shift).
// The web-process half is gone from modern WebKit: 537's geometry update carried a layer offset
// (DrawingAreaProxy::setSize(size, layerOffset, scrollOffset) → TiledCoreAnimationDrawingArea::
// updateGeometry) that kept the FRESHLY painted new-size layout anchored too, whereas the modern
// UpdateGeometry message is only (viewSize, flushSynchronously, fencePort) with no offset for
// the web process to apply. So when -enableFrameSizeUpdates pushes the settled size, the anchor
// shift is cleared in the same transaction and the fenced new-size layout swaps in
// top-left-aligned — the anchor holds throughout the animation, not across the final repaint.
- (void)setContentAnchor:(WKContentAnchor)contentAnchor
{
    if (_wkState)
        _wkState->contentAnchor = contentAnchor;
}

// MAVERICKS_BACKPORT: content-anchor getter; pageless WKViews (no _wkState) report the default top-left anchor.
- (WKContentAnchor)contentAnchor
{
    return _wkState ? _wkState->contentAnchor : WKContentAnchorTopLeft;
}

// MAVERICKS_BACKPORT: async drawing-area size-update SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7, typically while frame-size updates are disabled (the force bypasses
// the -disableFrameSizeUpdates gate, which is its entire point). Ported from the Safari-537-era
// -[WKView forceAsyncDrawingAreaSizeUpdate:] against the current drawing-area API: push the
// given size to the drawing area without waiting (the drawn area need not match the view frame),
// then poll with a zero timeout so an already-answered UpdateGeometry dispatches and the fresh
// size can go out immediately — the modern shape of the old zero-timeout
// waitForPossibleGeometryUpdate poll. Like the 537 version, this leaves any content-anchor shift
// in place; -enableFrameSizeUpdates clears it. (The 537 version also refreshed the exposed rect
// when clipping to the visible rect; this WKView has no clips-to-visible-rect machinery, so
// there is no exposed rect to refresh.)
- (void)forceAsyncDrawingAreaSizeUpdate:(NSSize)size
{
    if (!_wkState || !_wkState->page)
        return;
    if (RefPtr drawingArea = _wkState->page->drawingArea()) {
        drawingArea->setSize(WebCore::IntSize(size.width, size.height));
        drawingArea->waitForDidUpdateGeometry(WTF::Seconds { });
    }
}

// MAVERICKS_BACKPORT: blocking counterpart, ported from the Safari-537-era
// -[WKView waitForAsyncDrawingAreaSizeUpdate]. If a geometry update is still pending then
// receiving its reply may schedule another update (the drawing area resends when the size
// changed while waiting) — wait for that one too, matching the 537 implementation's split of
// the 500ms didUpdateBackingStoreStateTimeout into two half-timeout waits.
- (void)waitForAsyncDrawingAreaSizeUpdate
{
    if (!_wkState || !_wkState->page)
        return;
    if (RefPtr drawingArea = _wkState->page->drawingArea()) {
        drawingArea->waitForDidUpdateGeometry(WTF::Seconds::fromMilliseconds(250));
        drawingArea->waitForDidUpdateGeometry(WTF::Seconds::fromMilliseconds(250));
    }
}

// MAVERICKS_BACKPORT: implement the underlayColor property. It is declared in WKViewPrivate.h
// but was never implemented here, so when Safari 7's ContinuousReadingListViewController opens a
// Reading List item it sends -setUnderlayColor: to BrowserWKView, the message falls through to
// the forwarding path, and the resulting unrecognized-selector NSInvalidArgumentException is
// uncaught — terminating the whole Safari UI process. Mirror WebViewImpl::setUnderlayColor /
// underlayColor, delegating straight to the page proxy.
- (void)setUnderlayColor:(NSColor *)underlayColor
{
    // MAVERICKS_BACKPORT: implement -setUnderlayColor: (was unimplemented → unrecognized-selector crash from Reading List).
    if (_wkState && _wkState->page)
        _wkState->page->setUnderlayColor(WebCore::colorFromCocoaColor(underlayColor));
}

// MAVERICKS_BACKPORT: underlayColor getter mirroring WebViewImpl::underlayColor (the property was declared but never implemented).
- (NSColor *)underlayColor
{
    if (_wkState && _wkState->page)
        return WebCore::cocoaColorOrNil(_wkState->page->underlayColor()).autorelease();
    return nil;
}
// MAVERICKS_BACKPORT: NSTextInputClient minimal stubs — Safari crashes with validAttributesForMarkedText
// unrecognized selector when BrowserWKView is added to a window without these.
// insertText: + doCommandBySelector: capture commands during interpretKeyEvents:
// so the keyDown handler can forward them to WebPage as KeypressCommands.
static __thread WTF::Vector<WebCore::KeypressCommand> *tlsCollectingCommands = nullptr;
- (NSArray *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange { return NSZeroRect; }
- (BOOL)hasMarkedText { return NO; }
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    // MAVERICKS_BACKPORT: capture inserted text as a KeypressCommand during interpretKeyEvents so keyDown can forward it to WebPage.
    NSString *s = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
    if (!s)
        return;
    if (tlsCollectingCommands) {
        WebCore::KeypressCommand command("insertText:"_s, String(s));
        tlsCollectingCommands->append(command);
        // Register the collected selector so WebPageProxy::executeSavedCommandBySelector's
        // MESSAGE_CHECK(isValidKeypressCommandName) accepts the WebContent reply for it,
        // mirroring WebViewImpl's WKWebView path.
        if (_wkState && _wkState->page)
            _wkState->page->registerKeypressCommandName(command.commandName);
    }
}
- (NSRange)markedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {}
- (void)unmarkText {}
- (void)doCommandBySelector:(SEL)selector
{
    if (!tlsCollectingCommands)
        return;
    WebCore::KeypressCommand command(String::fromLatin1(sel_getName(selector)));
    tlsCollectingCommands->append(command);
    // Register the collected selector so WebPageProxy::executeSavedCommandBySelector's
    // MESSAGE_CHECK(isValidKeypressCommandName) accepts the WebContent reply for it,
    // mirroring WebViewImpl's WKWebView path.
    if (_wkState && _wkState->page)
        _wkState->page->registerKeypressCommandName(command.commandName);
}
- (BOOL)conformsToProtocol:(Protocol *)protocol
{
    if (protocol == @protocol(NSTextInputClient)) return YES;
    return [super conformsToProtocol:protocol];
}
- (BOOL)wantsUpdateLayer { return NO; }
- (NSView *)fullScreenPlaceholderView { return nil; }

// MAVERICKS_BACKPORT: legacy fullscreen SPI, declared in WKViewPrivate.h and sent unguarded by
// Safari 7's fullscreen controller, which asks its WKView for the window that hosts fullscreen
// content. Ported verbatim from the Safari-537-era -[WKView createFullScreenWindow]: a borderless
// WebCoreFullScreenWindow sized to the main screen. WebCoreFullScreenWindow is alive in this tree
// (WebKitLegacy's WebFullScreenController builds the same window) and answers YES to
// canBecomeKeyWindow, matching the borderless key-window arrangement this backport's own
// element-fullscreen path uses (WKMinimalFullScreenWindow in MinimalPageClient.mm).
- (NSWindow *)createFullScreenWindow
{
// MAVERICKS_BACKPORT: -createFullScreenWindow returns a borderless WebCoreFullScreenWindow sized to the main screen for Safari 7's fullscreen controller.
#if ENABLE(FULLSCREEN_API)
    return [[[WebCoreFullScreenWindow alloc] initWithContentRect:[[NSScreen mainScreen] frame] styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO] autorelease];
#else
    return nil;
// MAVERICKS_BACKPORT: closes the FULLSCREEN_API guard above; -createFullScreenWindow returns nil when fullscreen is compiled out.
#endif
}

- (void)updateLayer {}
// Basic init methods for non-page WKView instances (e.g. title bar button)
- (id)init { return [super init]; }
- (id)initWithFrame:(NSRect)frame { return [super initWithFrame:frame]; }
- (BOOL)isFlipped { return YES; }
- (BOOL)canChangeFrameLayout:(WKFrameRef)f { return NO; }
// MAVERICKS_BACKPORT: implement printing (was a return-nil stub, so Cmd+P / File > Print did nothing).
// Mirrors WebViewImpl::printOperationWithPrintInfo: build a WKPrintingView over the frame and wrap it in
// an NSPrintOperation that Safari drives. WKPrintingView paginates via the WebProcess print IPC.
- (NSPrintOperation *)printOperationWithPrintInfo:(NSPrintInfo *)pi forFrame:(WKFrameRef)f
{
    WebFrameProxy* frame = toImpl(f);
    if (!frame)
        return nil;
    RetainPtr<WKPrintingView> printingView = adoptNS([[WKPrintingView alloc] initWithFrameProxy:*frame view:self]);
    RetainPtr<NSPrintOperation> printOperation = [NSPrintOperation printOperationWithView:printingView.get() printInfo:pi];
    [printOperation setCanSpawnSeparateThread:YES];
    [printOperation setJobTitle:frame->title().createNSString().get()];
    printingView->_printOperation = printOperation.get();
    return printOperation.autorelease();
}
// MAVERICKS_BACKPORT: actually apply the frame. Safari calls this on its WKView
// (treated as "viewBelowBanner") during Banner._moveBannerIntoPlace: to shrink
// the web view by banner.height so that the banner can occupy that vacated
// area. The empty stub left WKView at full container height, and Safari then
// positioned the banner ABOVE the unchanged WKView — outside the container's
// clipping bounds, making the banner invisible.
// The scroll offset is dropped: 537 stashed it in _resizeScrollOffset and passed it as the
// scrollOffset argument of DrawingAreaProxy::setSize so the web process scroll-compensated a
// bottom-anchored resize in the same geometry update, but the modern drawing area no longer
// consumes it (DrawingAreaProxy::setSize accumulates m_scrollOffset and nothing reads it; the
// TCA UpdateGeometry message carries no scroll delta). Recorded in the hack audit
// ([[webkit-mavericks-hack-audit]]) as a known behavior gap: banner show/hide can jump the
// scroll position by the banner height.
- (void)setFrame:(NSRect)r andScrollBy:(NSSize)o
{
    [super setFrame:r];
    (void)o;
}
// MAVERICKS_BACKPORT: frame-size-updates gate, ported from the Safari-537-era WKView
// (disableFrameSizeUpdates / enableFrameSizeUpdates / frameSizeUpdatesDisabled). Safari 7 nests
// disable/enable around its resize animations so the web process sees one settled size instead
// of every animation frame; while disabled, -setFrameSize: also applies the content-anchor
// shift (see there). -enableFrameSizeUpdates pushes the current frame size on reaching zero,
// exactly as the 537 implementation pushed _setDrawingAreaSize:[self frame].size — and, because
// the modern geometry update carries no layer offset for the web process to compensate with
// (see -setContentAnchor:), it also clears the anchor shift in the same transaction so the
// fenced new-size layout swaps in aligned to the view.
- (void)disableFrameSizeUpdates
{
    // MAVERICKS_BACKPORT: nest-count the frame-size-updates gate; a pageless WKView has no state to bump.
    if (_wkState)
        _wkState->frameSizeUpdatesDisabledCount++;
}

// MAVERICKS_BACKPORT: decrement the gate; on reaching zero push the settled frame size and clear the anchor shift (see -disableFrameSizeUpdates).
- (void)enableFrameSizeUpdates
{
    if (!_wkState || !_wkState->frameSizeUpdatesDisabledCount)
        return;

    // MAVERICKS_BACKPORT: only the outermost enable (count reaching zero) resumes frame-size updates.
    if (--_wkState->frameSizeUpdatesDisabledCount)
        return;

    // MAVERICKS_BACKPORT: on the last enable, push the settled frame size to the drawing area and clear the content-anchor shift.
    if (_wkState->page) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize([self frame].size.width, [self frame].size.height));
    }
    _wkState->frameOrigin = NSZeroPoint;
    if (CALayer *renderLayer = _wkState->pageClient ? _wkState->pageClient->acceleratedCompositingRootLayer() : nil) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [renderLayer setPosition:CGPointZero];
        [CATransaction commit];
    }
}

// MAVERICKS_BACKPORT: gate query (537-verbatim semantics); pageless WKViews report the default enabled state.
- (BOOL)frameSizeUpdatesDisabled
{
    return _wkState && _wkState->frameSizeUpdatesDisabledCount > 0;
}
// MAVERICKS_BACKPORT: +hideWordDefinitionWindow stub; Safari 7 sends it unguarded to dismiss the dictionary definition panel.
+ (void)hideWordDefinitionWindow {}

// MAVERICKS_BACKPORT: NSServicesRequests responder hooks. AppKit walks the responder chain calling
// -validRequestorForSendType:returnType: to decide which services apply to the current selection, then
// -writeSelectionToPasteboard:types: to hand the selection to the chosen service (and
// -readSelectionFromPasteboard: for services that return a replacement). The standalone WKView talks to
// WebPageProxy directly (no WebViewImpl), so without these the web selection is never offered to Services
// and the Services submenu is empty in BOTH the app menu and the context menu. Ported from
// WebViewImpl::validRequestorForSendAndReturnTypes / writeSelectionToPasteboard / readSelectionFromPasteboard.
- (id)validRequestorForSendType:(NSString *)sendType returnType:(NSString *)returnType
{
    // MAVERICKS_BACKPORT: a pageless WKView forwards Services validation up the responder chain.
    if (!_wkState->page)
        return [[self nextResponder] validRequestorForSendType:sendType returnType:returnType];

    // MAVERICKS_BACKPORT: consult the page's EditorState to decide which send types the current selection offers to Services.
    const WebKit::EditorState& editorState = _wkState->page->editorState();
    bool isValidSendType = !sendType;
    if (sendType && editorState.selectionType != WebCore::SelectionType::None) {
        if (editorState.isInPlugin)
            isValidSendType = [sendType isEqualToString:WebCore::legacyStringPasteboardTypeSingleton()];
        else
            isValidSendType = [WebKit::PasteboardTypes::forSelectionSingleton() containsObject:sendType];
    }

    // MAVERICKS_BACKPORT: a Service returning a replacement is valid only over editable content (rich or plain text).
    bool isValidReturnType = false;
    if (!returnType)
        isValidReturnType = true;
    else if ([WebKit::PasteboardTypes::forEditingSingleton() containsObject:returnType] && editorState.isContentEditable)
        isValidReturnType = editorState.isContentRichlyEditable || [returnType isEqualToString:WebCore::legacyStringPasteboardTypeSingleton()];

    // MAVERICKS_BACKPORT: offer this view as the Services requestor when send/return types match, else fall through the responder chain.
    if (isValidSendType && isValidReturnType)
        return self;
    return [[self nextResponder] validRequestorForSendType:sendType returnType:returnType];
}

// MAVERICKS_BACKPORT: -writeSelectionToPasteboard: hands the web selection to the chosen Service (ported from WebViewImpl::writeSelectionToPasteboard).
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard types:(NSArray *)types
{
    // MAVERICKS_BACKPORT: write the web selection to the Services pasteboard via WebPageProxy.
    if (!_wkState->page)
        return NO;
    [pasteboard clearContents];
    [pasteboard addTypes:types owner:nil];
    for (NSString *type in types) {
        if ([type isEqualTo:WebCore::legacyStringPasteboardTypeSingleton()])
            [pasteboard setString:_wkState->page->stringSelectionForPasteboard().createNSString().get() forType:WebCore::legacyStringPasteboardTypeSingleton()];
        else {
            RefPtr<WebCore::SharedBuffer> buffer = _wkState->page->dataSelectionForPasteboard(type);
            [pasteboard setData:buffer ? buffer->createNSData().get() : nil forType:type];
        }
    }
    return YES;
}

// MAVERICKS_BACKPORT: -readSelectionFromPasteboard: lets a Service replace the web selection (ported from WebViewImpl::readSelectionFromPasteboard).
- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pasteboard
{
    // MAVERICKS_BACKPORT: hand the Services replacement pasteboard to WebPageProxy.
    if (!_wkState->page)
        return NO;
    return _wkState->page->readSelectionFromPasteboard([pasteboard name]);
}

// MAVERICKS_BACKPORT: forward NSEvents to WebPageProxy. The full WebViewImpl.mm input
// pipeline is stubbed out in this build, so add a minimal mouseDown/Up/Moved/Dragged,
// scrollWheel, and keyDown/Up forwarding here so links/forms/scrolling become interactive.
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// MAVERICKS_BACKPORT (#138): notify the page when this view gains/loses first-responder status so the
// WebContent's ActivityState::IsFocused flag tracks focus. Without it the page's FocusController is
// never marked focused, so FrameSelection::isFocusedAndActive() stays false and WebCore suppresses the
// text-insertion caret (and active selection highlight) even though typing works. Matches WebViewImpl,
// which fires activityStateDidChange(IsFocused) on become/resignFirstResponder. activityStateDidChange
// defers the recompute, so by the time it re-queries -isViewFocused the window firstResponder has settled.
- (BOOL)becomeFirstResponder
{
    // MAVERICKS_BACKPORT: notify the page so ActivityState::IsFocused tracks focus and the text caret/selection shows (#138).
    BOOL result = [super becomeFirstResponder];
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return result;
}

// MAVERICKS_BACKPORT: clear ActivityState::IsFocused on resign so the page's FocusController matches first-responder state (#138).
- (BOOL)resignFirstResponder
{
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return [super resignFirstResponder];
}

// MAVERICKS_BACKPORT: tell WebPageProxy when this view's window membership changes.
// Without this, Safari's tab swap (which removes the inactive tab's WKView from
// the window and re-adds it on switch-back) leaves the WebPage with a stale
// activity-state and the visible content blank. Calling activityStateDidChange
// triggers a WebPage::SetActivityState IPC which kicks WebContent to send a
// fresh layer-tree commit, restoring the visible content.
// MAVERICKS_BACKPORT: ported from the Safari-537 WKView (which refreshed its window/view frames
// here). AppKit invalidates the gstate whenever this view's geometry RELATIVE TO THE WINDOW
// changes — window resize, ancestor moves, scrolling — none of which touch the view's own frame,
// so they reach no other geometry hook. The clipped view-exposed rect must be refreshed on this
// signal: iBooks attaches its reader views while the reader window is still animating open at a
// tiny size, so at -viewDidMoveToWindow time the views' -visibleRect is EMPTY, and the empty
// exposed rect latched then would otherwise persist after the window reaches full size — the
// web process then paints nothing and every page shows blank.
- (void)renewGState
{
    if ([self window])
        [self _updateViewExposedRect];
    [super renewGState];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!_wkState || !_wkState->page) return;

    // MAVERICKS_BACKPORT: a CALayerHost minted while this view was windowless never connects to
    // the remote CAContext once the view joins a window; re-mint it now (no-op when there is no
    // stored layer-tree context or no window). iBooks composites its reader views pre-window.
    if (_wkState->pageClient)
        WebKit::minimalPageClientViewDidMoveToWindow(*_wkState->pageClient);

    // MAVERICKS_BACKPORT: propagate the window's backing scale to the page so it renders at the display's
    // device pixel ratio (Retina = 2x). The MinimalPageClient/WKView path replaces WebViewImpl and dropped
    // WebViewImpl's setIntrinsicDeviceScaleFactor wiring, so WebPageProxy::m_intrinsicDeviceScaleFactor stayed
    // at its 1.0 default and the page rendered at 1x even on a Retina screen. Mirror WebViewImpl: set it on
    // (re)entering a window and observe NSWindowDidChangeBackingPropertiesNotification (display / scale change).
    NSNotificationCenter *backingCenter = [NSNotificationCenter defaultCenter];
    [backingCenter removeObserver:self name:NSWindowDidChangeBackingPropertiesNotification object:nil];
    if (NSWindow *window = [self window])
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeBackingProperties:) name:NSWindowDidChangeBackingPropertiesNotification object:window];
    [self _wk_updateIntrinsicDeviceScaleFactor];

    // MAVERICKS_BACKPORT: report the hosting window's screen to the page, mirroring upstream
    // WebViewImpl::windowDidChangeScreen. WebPageProxy::windowScreenDidChange is what sets
    // m_displayID (without it updateDisplayLinkFrequency() bails, so wheel/animated-scroll
    // activity can never request full-speed DisplayLink updates) and what tells the WebContent
    // side (WebPage::WindowScreenDidChange + EventDispatcher::PageScreenDidChange) which display
    // the ThreadedScrollingTree belongs to — its displayDidRefresh() drops callbacks whose
    // displayID doesn't match, so without this the scrolling thread never services scroll
    // animations or desynchronized layer updates. Safari 7's WKView predates all of this wiring.
    [backingCenter removeObserver:self name:NSWindowDidChangeScreenNotification object:nil];
    if (NSWindow *window = [self window]) {
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeScreen:) name:NSWindowDidChangeScreenNotification object:window];
        [self _wk_windowDidChangeScreen:nil];
    }

    OptionSet<WebCore::ActivityState> flags;
    // MAVERICKS_BACKPORT: while Safari is deferring view-in-window changes
    // (-beginDeferringViewInWindowChanges), the IsInWindow push is suppressed and recorded so
    // -endDeferringViewInWindowChanges[Sync] pushes the coalesced change. Mirrors the
    // m_shouldDeferViewInWindowChanges gate in WebViewImpl::viewDidMoveToWindow.
    if (_wkState->shouldDeferViewInWindowChanges)
        _wkState->viewInWindowChangeWasDeferred = true;
    else
        flags.add(WebCore::ActivityState::IsInWindow);
    flags.add(WebCore::ActivityState::IsVisible);
    flags.add(WebCore::ActivityState::IsVisibleOrOccluded);
    flags.add(WebCore::ActivityState::WindowIsActive);
    flags.add(WebCore::ActivityState::IsFocused);
    _wkState->page->activityStateDidChange(flags);

    // MAVERICKS_BACKPORT: refresh the clipped view-exposed-rect now that the view is in a window
    // (its visible rect only becomes meaningful once attached), mirroring WebViewImpl's
    // updateWindowAndViewFrames -> updateViewExposedRect trigger.
    if (_wkState->shouldClipToVisibleRect)
        [self _updateViewExposedRect];
}

// MAVERICKS_BACKPORT: view-in-window-change deferral SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7 when it moves a WKView between windows (tab drag-out/merge). Ported from
// WebViewImpl::beginDeferringViewInWindowChanges / endDeferringViewInWindowChanges /
// endDeferringViewInWindowChangesSync onto this WKView's activityStateDidChange machinery:
// while deferring, -viewDidMoveToWindow suppresses the ActivityState::IsInWindow push and records
// it; ending the deferral pushes the coalesced in-window change so the page sees one transition
// instead of an out-of-window/in-window flicker.
- (void)beginDeferringViewInWindowChanges
{
    // MAVERICKS_BACKPORT: -beginDeferringViewInWindowChanges guards a pageless WKView (ported from WebViewImpl).
    if (!_wkState)
        return;
    if (_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"beginDeferringViewInWindowChanges was called while already deferring view-in-window changes!");
        return;
    }

    // MAVERICKS_BACKPORT: begin coalescing view-in-window changes so -viewDidMoveToWindow defers the IsInWindow push.
    _wkState->shouldDeferViewInWindowChanges = true;
}

// MAVERICKS_BACKPORT: end the deferral and push the coalesced IsInWindow change (ported from WebViewImpl::endDeferringViewInWindowChanges).
- (void)endDeferringViewInWindowChanges
{
    if (!_wkState)
        return;
    if (!_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"endDeferringViewInWindowChanges was called without beginDeferringViewInWindowChanges!");
        return;
    }

    // MAVERICKS_BACKPORT: end the in-window-change deferral (ported from WebViewImpl::endDeferringViewInWindowChanges).
    _wkState->shouldDeferViewInWindowChanges = false;

    // MAVERICKS_BACKPORT: push the coalesced IsInWindow change recorded while deferral was active.
    if (_wkState->viewInWindowChangeWasDeferred) {
        if (_wkState->page)
            _wkState->page->activityStateDidChange(WebCore::ActivityState::IsInWindow);
        _wkState->viewInWindowChangeWasDeferred = false;
    }
}

// MAVERICKS_BACKPORT: Sync variant, ported from WebViewImpl::endDeferringViewInWindowChangesSync,
// whose body upstream is identical to the non-Sync variant — the historical synchronous
// waitForDidUpdateInWindowState is gone from modern WebKit, so "Sync" carries no extra wait.
// (WebViewImpl also flushes its pending obscured-content-inset changes here; this WKView has no
// content-inset machinery, so there is nothing to flush.)
- (void)endDeferringViewInWindowChangesSync
{
    // MAVERICKS_BACKPORT: -endDeferringViewInWindowChangesSync guards a pageless WKView (ported from WebViewImpl).
    if (!_wkState)
        return;
    if (!_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"endDeferringViewInWindowChangesSync was called without beginDeferringViewInWindowChanges!");
        return;
    }

    // MAVERICKS_BACKPORT: end the deferral, sync variant (ported from WebViewImpl::endDeferringViewInWindowChangesSync).
    _wkState->shouldDeferViewInWindowChanges = false;

    // MAVERICKS_BACKPORT: push the coalesced IsInWindow change recorded while deferral was active.
    if (_wkState->viewInWindowChangeWasDeferred) {
        if (_wkState->page)
            _wkState->page->activityStateDidChange(WebCore::ActivityState::IsInWindow);
        _wkState->viewInWindowChangeWasDeferred = false;
    }
}

// MAVERICKS_BACKPORT: deferral-state getter (ported from WebViewImpl::isDeferringViewInWindowChanges; declared in WKViewPrivate.h).
- (BOOL)isDeferringViewInWindowChanges
{
    return _wkState && _wkState->shouldDeferViewInWindowChanges;
}

// MAVERICKS_BACKPORT: recompute visibility when this view (or an ancestor) hides/unhides, mirroring
// upstream WebViewImpl's viewDidHide/viewDidUnhide forwarding. Without these, a recompute that runs
// while the view is hidden latches IsVisible=0 and the unhide never triggers another recompute.
- (void)viewDidHide
{
    // MAVERICKS_BACKPORT: recompute IsVisible when this view hides, mirroring WebViewImpl's viewDidHide forwarding.
    [super viewDidHide];
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::IsVisibleOrOccluded });
}

// MAVERICKS_BACKPORT: mirror -viewDidHide: recompute visibility when this view (or an ancestor) unhides.
- (void)viewDidUnhide
{
    // MAVERICKS_BACKPORT: recompute IsVisible on unhide so a hidden-latched IsVisible=0 is cleared.
    [super viewDidUnhide];
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::IsVisibleOrOccluded });
}

// MAVERICKS_BACKPORT: read the current window's (or main screen's) backing scale and push it to the page.
- (void)_wk_updateIntrinsicDeviceScaleFactor
{
    if (!_wkState || !_wkState->page)
        return;
    NSWindow *window = [self window];
    CGFloat scale = window ? [window backingScaleFactor] : [[NSScreen mainScreen] backingScaleFactor];
    if (scale <= 0)
        scale = 1;
    _wkState->page->setIntrinsicDeviceScaleFactor(scale);
}

// MAVERICKS_BACKPORT: the window changed backing scale (e.g. moved to a Retina display) — re-propagate it.
- (void)_wk_windowDidChangeBackingProperties:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    [self _wk_updateIntrinsicDeviceScaleFactor];
}

// MAVERICKS_BACKPORT: push the hosting window's display ID to WebPageProxy (see -viewDidMoveToWindow).
- (void)_wk_windowDidChangeScreen:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    if (!_wkState || !_wkState->page)
        return;
    NSScreen *screen = [[self window] screen] ?: [NSScreen mainScreen];
    CGDirectDisplayID displayID = [[[screen deviceDescription] objectForKey:@"NSScreenNumber"] unsignedIntValue];
    if (!displayID)
        displayID = CGMainDisplayID();
    _wkState->page->windowScreenDidChange(displayID);
}

// MAVERICKS_BACKPORT: AppKit also delivers this directly to the view when its backing scale changes.
- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self _wk_updateIntrinsicDeviceScaleFactor];
}

// MAVERICKS_BACKPORT: the WebContent layer tree is hosted on a dedicated layer-hosting subview
// (MinimalPageClient's WKMinimalLayerHostingView — the 537 _layerHostingView arrangement). That
// subview's -hitTest: returns nil, so AppKit's hit-testing lands on the WKView itself and the
// mouse/scroll/key NSResponder overrides below fire naturally via -[NSWindow sendEvent:]. The
// redirect here is the upstream-equivalent insurance (WebViewImpl::hitTest): a hit on self or
// any descendant resolves to self so the responder-chain forwarding stays correct.
- (NSView *)hitTest:(NSPoint)point
{
    // MAVERICKS_BACKPORT: resolve a hit on self or any descendant back to self so responder-chain forwarding stays correct.
    NSView *result = [super hitTest:point];
    if (!result)
        return nil;
    if (result == self || [result isDescendantOf:self])
        return self;
    return result;
}

// MAVERICKS_BACKPORT: macro that forwards each NSResponder mouse selector into the page proxy (WebViewImpl's input path is stubbed here).
#define WKV_FORWARD_MOUSE(SEL_NAME) \
- (void)SEL_NAME:(NSEvent *)event \
{ \
    if (!_wkState || !_wkState->page) { [super SEL_NAME:event]; return; } \
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebMouseEventInputSource::UserDriven); \
    _wkState->page->handleMouseEvent(webEvent); \
}

// MAVERICKS_BACKPORT: mouseDown is explicit (not via the macro) so it can retain the
// originating event for the classic drag-image API used to start HTML5 drags.
- (void)mouseDown:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: forward the mouse-down into the page proxy (stash the event for drag-image start).
    if (!_wkState || !_wkState->page) { [super mouseDown:event]; return; }
#if ENABLE(DRAG_SUPPORT)
    _wkState->lastMouseDownEvent = event;
#endif
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebMouseEventInputSource::UserDriven);
    _wkState->page->handleMouseEvent(webEvent);
}
WKV_FORWARD_MOUSE(mouseUp)
// MAVERICKS_BACKPORT: mouseMoved is explicit (not via the macro) because it needs a filter the
// other forwards don't: while this view is first responder, the window routes mouseMoved events
// to it from anywhere in the window (not just over the tracking area installed in the designated
// initializer), so drop moves outside the visible rect instead of hit-testing bogus coordinates.
// Matches Safari 7 WebKit2's -[WKView mouseMoved:] and WebViewImpl::mouseMoved().
- (void)mouseMoved:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super mouseMoved:event]; return; }
    if (self == [[self window] firstResponder] && !NSPointInRect([self convertPoint:[event locationInWindow] fromView:nil], [self visibleRect]))
        return;
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebMouseEventInputSource::UserDriven);
    _wkState->page->handleMouseEvent(webEvent);
}
WKV_FORWARD_MOUSE(mouseDragged)
WKV_FORWARD_MOUSE(rightMouseDown)
WKV_FORWARD_MOUSE(rightMouseUp)
WKV_FORWARD_MOUSE(rightMouseDragged)
WKV_FORWARD_MOUSE(otherMouseDown)
WKV_FORWARD_MOUSE(otherMouseUp)
WKV_FORWARD_MOUSE(otherMouseDragged)
WKV_FORWARD_MOUSE(mouseEntered)
WKV_FORWARD_MOUSE(mouseExited)

#undef WKV_FORWARD_MOUSE

// MAVERICKS_BACKPORT: three-finger-tap "Look Up" trackpad gesture. AppKit delivers the gesture as
// quickLookWithEvent: down the responder chain; upstream handles it in WebViewImpl::quickLookWithEvent,
// which this WKView doesn't use. There is no immediate-action gesture recognizer on 10.9
// (NSImmediateActionGestureRecognizer is 10.10.3+), so this is upstream's non-recognizer path:
// a dictionary lookup at the tap location.
- (void)quickLookWithEvent:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: forward the three-finger-tap Look Up gesture to the page's dictionary lookup (WebViewImpl::quickLookWithEvent is unused here).
    if (!_wkState || !_wkState->page) { [super quickLookWithEvent:event]; return; }
    NSPoint locationInViewCoordinates = [self convertPoint:[event locationInWindow] fromView:nil];
    _wkState->page->performDictionaryLookupAtLocation(WebCore::FloatPoint(locationInViewCoordinates));
}

#if ENABLE(DRAG_SUPPORT)
// MAVERICKS_BACKPORT: HTML5 drag-and-drop for WKView. Safari 7 drives WebKit2 through
// WKView, whose input pipeline is hand-written here (the full WebViewImpl/WKWebView
// path is unused), so the drag source + destination must be wired up directly or
// dragstart fires but no OS drag session begins. Mirrors WebViewImpl, using the
// classic -[NSView dragImage:...] API (NSFilePromiseProvider / beginDraggingSession
// are 10.12+, already gated out of WebViewImpl::startDrag).

static OptionSet<WebCore::DragOperation> wkCoreDragOperationMask(NSDragOperation operation)
{
    OptionSet<WebCore::DragOperation> result;
    if (operation & NSDragOperationCopy)
        result.add(WebCore::DragOperation::Copy);
    if (operation & NSDragOperationLink)
        result.add(WebCore::DragOperation::Link);
    if (operation & NSDragOperationGeneric)
        result.add(WebCore::DragOperation::Generic);
    if (operation & NSDragOperationPrivate)
        result.add(WebCore::DragOperation::Private);
    if (operation & NSDragOperationMove)
        result.add(WebCore::DragOperation::Move);
    if (operation & NSDragOperationDelete)
        result.add(WebCore::DragOperation::Delete);
    return result;
}

static NSDragOperation wkKitDragOperation(std::optional<WebCore::DragOperation> op)
{
    if (!op)
        return NSDragOperationNone;
    switch (*op) {
    case WebCore::DragOperation::Copy: return NSDragOperationCopy;
    case WebCore::DragOperation::Link: return NSDragOperationLink;
    case WebCore::DragOperation::Generic: return NSDragOperationGeneric;
    case WebCore::DragOperation::Private: return NSDragOperationPrivate;
    case WebCore::DragOperation::Move: return NSDragOperationMove;
    case WebCore::DragOperation::Delete: return NSDragOperationDelete;
    }
    return NSDragOperationNone;
}

static OptionSet<WebCore::DragApplicationFlags> wkDragApplicationFlags(NSView *view, id<NSDraggingInfo> info)
{
    OptionSet<WebCore::DragApplicationFlags> flags;
    if ([NSApp modalWindow])
        flags.add(WebCore::DragApplicationFlags::IsModal);
    if (view.window.attachedSheet)
        flags.add(WebCore::DragApplicationFlags::HasAttachedSheet);
    if (info.draggingSource == view)
        flags.add(WebCore::DragApplicationFlags::IsSource);
    if ([NSApp currentEvent].modifierFlags & NSEventModifierFlagOption)
        flags.add(WebCore::DragApplicationFlags::IsCopyKeyDown);
    return flags;
}

static WebCore::DragData wkDragDataFromInfo(NSView *view, id<NSDraggingInfo> info, WebKit::WebPageProxy& page)
{
    WebCore::IntPoint client([view convertPoint:info.draggingLocation fromView:nil]);
    NSPoint global = WebCore::globalPoint(info.draggingLocation, [view window]);
    return WebCore::DragData(info, client, WebCore::IntPoint(global), wkCoreDragOperationMask(info.draggingSourceOperationMask), wkDragApplicationFlags(view, info), WebCore::anyDragDestinationAction(), page.webPageIDInMainFrameProcess());
}

// NSDraggingDestination — drops route into the page.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    if (!_wkState || !_wkState->page)
        return NSDragOperationNone;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->resetCurrentDragInformation();
    _wkState->page->dragEntered(dragData, info.draggingPasteboard.name);
    return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info
{
    if (!_wkState || !_wkState->page)
        return NSDragOperationNone;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->dragUpdated(dragData, info.draggingPasteboard.name);
    // MAVERICKS_BACKPORT: currentDragOperation is set by an async IPC reply to
    // PerformDragControllerAction. Returning None until it arrives makes AppKit
    // reject the drop on quick drags; fall back to Copy while it is still pending
    // so AppKit proceeds to performDragOperation, where WebCore makes the final
    // accept/reject decision (a non-drop-target there fires no DOM drop event).
    auto op = _wkState->page->currentDragOperation();
    if (!op)
        return NSDragOperationCopy;
    return wkKitDragOperation(op);
}

- (void)draggingExited:(id<NSDraggingInfo>)info
{
    if (!_wkState || !_wkState->page)
        return;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->dragExited(dragData);
    _wkState->page->resetCurrentDragInformation();
}

// MAVERICKS_BACKPORT: NSDraggingDestination — always accept so AppKit proceeds to performDragOperation.
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
    return YES;
}

// MAVERICKS_BACKPORT: NSDraggingDestination drop handler — route the drop into the page proxy.
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    // MAVERICKS_BACKPORT: hand the drop data to WebCore via the page proxy's performDragOperation.
    if (!_wkState || !_wkState->page)
        return NO;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->performDragOperation(dragData, info.draggingPasteboard.name, { }, { });
    return YES;
}

// MAVERICKS_BACKPORT: NSDraggingSource (classic informal protocol, paired with -dragImage:...).
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    // MAVERICKS_BACKPORT: file-input drags advertise Copy only; otherwise allow the generic source operations.
    if (!isLocal || (_wkState && _wkState->page && _wkState->page->currentDragIsOverFileInput()))
        return NSDragOperationCopy;
    return NSDragOperationGeneric | NSDragOperationMove | NSDragOperationCopy;
}

// MAVERICKS_BACKPORT: classic NSDraggingSource drag-ended callback that pairs with -dragImage:... (the 10.12+ session API is unused here).
- (void)draggedImage:(NSImage *)image endedAt:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
    // MAVERICKS_BACKPORT: report the drag end back to the page proxy to finish the HTML5 drag session.
    if (!_wkState || !_wkState->page)
        return;
    NSWindow *window = [self window];
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    NSPoint windowPoint = window ? [window convertScreenToBase:screenPoint] : screenPoint;
ALLOW_DEPRECATED_DECLARATIONS_END
    _wkState->page->dragEnded(WebCore::IntPoint(windowPoint), WebCore::IntPoint(WebCore::globalPoint(windowPoint, window)), wkCoreDragOperationMask(operation));
}

// Called by MinimalPageClient::startDrag once the drag image is ready.
- (void)_wk_beginDragWithImage:(NSImage *)image atWindowPoint:(NSPoint)windowPoint
{
    if (!_wkState || !_wkState->page)
        return;
    // windowPoint is item.dragLocationInWindowCoordinates: a WebCore window coordinate
    // (top-left origin, relative to this view's content — the WebProcess has no toolbar/
    // window offset). WKView is isFlipped == YES, so its own coordinate system is already
    // top-left with the same origin; the WebCore point maps to a WKView point with NO
    // conversion. -dragImage:at: takes that location directly. (Mirrors both reference
    // paths: WebViewImpl::startDrag hands dragLocationInMainFrameCoordinates straight to
    // -dragImage:at:, and WK1 WebDragClient::startDrag does the same with
    // dragLocationInContentCoordinates.) A -convertPoint:fromView: here is wrong: it
    // interprets this top-left point as an AppKit bottom-left window point and flips Y to
    // (windowHeight - y), planting the drag image at an inverted vertical position.
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSDragPboard];
    // WebCore has already written the drag data to NSDragPboard; the dummy type just
    // guarantees the source pasteboard advertises at least one registered type.
    [pasteboard setString:@"" forType:WebKit::PasteboardTypes::WebDummyPboardType];
    NSEvent *event = _wkState->lastMouseDownEvent.get();
    if (!event)
        event = [NSApp currentEvent];
    if (!event)
        return;
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    // MAVERICKS_BACKPORT: start the OS drag via the classic -dragImage:... API (beginDraggingSession is 10.12+).
    [self dragImage:image at:windowPoint offset:NSZeroSize event:event pasteboard:pasteboard source:self slideBack:YES];
ALLOW_DEPRECATED_DECLARATIONS_END
}
#endif // ENABLE(DRAG_SUPPORT) — MAVERICKS_BACKPORT: HTML5 drag source/destination wired up here for the WKView input path

// MAVERICKS_BACKPORT: forward scroll-wheel NSEvents into the page (the stubbed WebViewImpl input path is unused here).
- (void)scrollWheel:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super scrollWheel:event]; return; }
    WebKit::NativeWebWheelEvent webEvent(event, self);
    _wkState->page->handleNativeWheelEvent(webEvent);
}

- (void)keyDown:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super keyDown:event]; return; }
    // We could be receiving a key down from AppKit if we re-sent an event the page left
    // unhandled and it maps to an action that is currently unavailable (mirrors
    // WebViewImpl::keyDown); the page has already seen it, so pass it to super.
    if (_wkState->keyDownEventBeingResent.get() == event) { [super keyDown:event]; return; }
    WTF::Vector<WebCore::KeypressCommand> commands;
    // Run AppKit's interpretKeyEvents to translate the NSEvent into NSTextInputClient
    // calls (insertText:/doCommandBySelector:); collect them in a thread-local that
    // our NSTextInputClient stubs append to.
    // MAVERICKS_BACKPORT: skip interpretKeyEvents for Cmd-modified keys. Those are
    // menu shortcuts dispatched via sendAction: (already handled by my copy:/
    // paste:/etc. action methods). Running interpretKeyEvents would double-
    // dispatch the action via doCommandBySelector → KeypressCommand path.
    BOOL hasCmd = ([event modifierFlags] & NSCommandKeyMask) != 0;
    if (!hasCmd) {
        tlsCollectingCommands = &commands;
        [self interpretKeyEvents:@[event]];
        tlsCollectingCommands = nullptr;
    }
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

- (void)keyUp:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super keyUp:event]; return; }
    WTF::Vector<WebCore::KeypressCommand> commands;
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

- (void)flagsChanged:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super flagsChanged:event]; return; }
    // Don't make an event from the num lock and function keys (mirrors
    // WebViewImpl::eventKeyCodeIsZeroOrNumLockOrFn). A keyCode-0 flagsChanged —
    // which virtual keyboards (VMware) emit for bare modifier presses — would
    // otherwise reach the page as a key-down with windows keyCode 65 ('A'), so a
    // bare Cmd press became a spurious Cmd+A (select all) to pages like Google Docs.
    unsigned short keyCode = [event keyCode];
    if (!keyCode || keyCode == 10 || keyCode == 63) { [super flagsChanged:event]; return; }
    WTF::Vector<WebCore::KeypressCommand> commands;
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

// MAVERICKS_BACKPORT: give the page first crack at Cmd-modified key-downs before AppKit's
// menus (mirrors WebViewImpl::performKeyEquivalent; stock Safari-7-era WKView had the same).
// Without this, every key equivalent went straight to Safari's menus, so pages that implement
// their own shortcuts (Google Docs Cmd+Z undo/redo, etc.) never saw the key-down — the menu's
// edit action then ran against WebCore's editor instead of the page's handler. Events the page
// leaves unhandled come back through MinimalPageClient::doneWithKeyEvent and are re-dispatched
// to AppKit (-_mavericksResendUnhandledKeyDownEvent:), so Safari's menu shortcuts still fire.
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if (!_wkState || !_wkState->page || [event type] != NSEventTypeKeyDown)
        return [super performKeyEquivalent:event];

    // A nested event loop during dispatch can release the current event; keep it alive.
    retainPtr(event).autorelease();

    // We get Esc here after Esc or Cmd+period gets transformed to a cancelOperation: command;
    // don't interpret it again (avoids re-entrancy / infinite loops), matching WebViewImpl.
    if ([[event charactersIgnoringModifiers] isEqualToString:@"\e"] && !([event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask))
        return [super performKeyEquivalent:event];

    // The page already saw this event; it is being re-dispatched to AppKit for the menus.
    if (_wkState->keyDownEventBeingResent)
        return [super performKeyEquivalent:event];

    // Only Cmd-modified keys are menu key equivalents on this path; anything else keeps
    // flowing through keyDown: (which also runs interpretKeyEvents command collection).
    if (!([event modifierFlags] & NSCommandKeyMask))
        return [super performKeyEquivalent:event];

    // Pass key combos through WebCore so pages can intercept key-modified keypresses, but
    // only when the web view has focus (not, e.g., while the URL bar field editor does).
    if ([[self window] firstResponder] == self) {
        WTF::Vector<WebCore::KeypressCommand> commands;
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        _wkState->page->handleKeyboardEvent(webEvent);
        return YES;
    }

    return [super performKeyEquivalent:event];
}

// MAVERICKS_BACKPORT: called by MinimalPageClient::doneWithKeyEvent when the page leaves a
// key-down unhandled — re-dispatch it to AppKit so menu key equivalents (Cmd+T, Cmd+Z when the
// page doesn't intercept it, etc.) still fire after the page had first crack. Mirrors the
// m_keyDownEventBeingResent re-send in WebViewImpl::doneWithKeyEvent.
- (void)_mavericksResendUnhandledKeyDownEvent:(NSEvent *)event
{
    if (!_wkState || _wkState->keyDownEventBeingResent)
        return;
    RetainPtr<WKView> protector = self; // re-sending the event may destroy this view
    _wkState->keyDownEventBeingResent = event;
    if ([NSApp respondsToSelector:@selector(_setCurrentEvent:)])
        [NSApp _setCurrentEvent:event];
    [NSApp sendEvent:event];
    _wkState->keyDownEventBeingResent = nil;
}

// MAVERICKS_BACKPORT: Edit menu items dispatch action selectors to first responder.
// We forward to WebPageProxy. For Copy/Cut/Paste/Undo/Redo, only forward when
// an editable element is focused (per WebPage::getPlatformEditorState now-safe
// computation via Document::focusedElement). When focus isn't on editable
// content, we don't override — Safari's URL-bar fallback handles it.
- (void)selectAll:(id)sender
{
    if (!_wkState || !_wkState->page) return;
    _wkState->page->selectAll();
}

#define WKV_EDIT_ACTION(SEL_NAME, COMMAND) \
- (void)SEL_NAME:(id)sender \
{ \
    if (!_wkState || !_wkState->page) return; \
    _wkState->page->executeEditCommand(WTF::String(COMMAND ## _s), WTF::String()); \
}
// MAVERICKS_BACKPORT: implementing copy:/cut: PROTECTS against Safari's default
// fallback navigation. Without our handlers, even bare Cmd+C (no selection)
// navigates to "Untitled" (URL goes empty). With our handlers, Cmd+C alone
// is safe; only Cmd+A→Cmd+C combo still triggers navigation (selection
// state in WebContent's Editor::copy → pasteboard write → some side effect).
WKV_EDIT_ACTION(copy,            "Copy")
WKV_EDIT_ACTION(cut,             "Cut")
WKV_EDIT_ACTION(paste,           "Paste")
WKV_EDIT_ACTION(pasteAsPlainText,"PasteAsPlainText")
WKV_EDIT_ACTION(undo,            "Undo")
WKV_EDIT_ACTION(redo,            "Redo")
#undef WKV_EDIT_ACTION

// MAVERICKS_BACKPORT: automatic quote/dash substitution SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7's substitutions plumbing. Ported from
// WebViewImpl::isAutomaticQuoteSubstitutionEnabled / setAutomaticQuoteSubstitutionEnabled /
// isAutomaticDashSubstitutionEnabled / setAutomaticDashSubstitutionEnabled: the flags live in the
// process-global TextChecker state (persisted to user defaults by TextCheckerMac), and a change is
// pushed to the WebContent process via WebProcessProxy::updateTextCheckerState.
- (BOOL)isAutomaticQuoteSubstitutionEnabled
{
    // MAVERICKS_BACKPORT: read the automatic-quote-substitution flag from the process-global TextChecker state.
    return TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled);
}

// MAVERICKS_BACKPORT: see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::setAutomaticQuoteSubstitutionEnabled).
- (void)setAutomaticQuoteSubstitutionEnabled:(BOOL)flag
{
    if (static_cast<bool>(flag) == TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled))
        return;

    // MAVERICKS_BACKPORT: store the quote-substitution flag in the process-global TextChecker state and push it to WebContent.
    TextChecker::setAutomaticQuoteSubstitutionEnabled(flag);
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// MAVERICKS_BACKPORT: see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::isAutomaticDashSubstitutionEnabled).
- (BOOL)isAutomaticDashSubstitutionEnabled
{
    return TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled);
}

// MAVERICKS_BACKPORT: see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::setAutomaticDashSubstitutionEnabled).
- (void)setAutomaticDashSubstitutionEnabled:(BOOL)flag
{
    if (static_cast<bool>(flag) == TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled))
        return;

    // MAVERICKS_BACKPORT: store the dash-substitution flag in the process-global TextChecker state and push it to WebContent.
    TextChecker::setAutomaticDashSubstitutionEnabled(flag);
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// MAVERICKS_BACKPORT: Edit ▸ Substitutions menu actions for the quote/dash pair, ported from
// WebViewImpl::toggleAutomaticQuoteSubstitution / toggleAutomaticDashSubstitution (the
// Safari-537-era WKView shipped the same responder actions). AppKit dispatches these down the
// responder chain from the menu items; without them the items are permanently disabled while
// the web view is first responder.
- (void)toggleAutomaticQuoteSubstitution:(id)sender
{
    // MAVERICKS_BACKPORT: Substitutions menu toggle flips the process-global TextChecker quote flag and pushes it to WebContent.
    TextChecker::setAutomaticQuoteSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// MAVERICKS_BACKPORT: see -toggleAutomaticQuoteSubstitution: above (ported from WebViewImpl::toggleAutomaticDashSubstitution).
- (void)toggleAutomaticDashSubstitution:(id)sender
{
    TextChecker::setAutomaticDashSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// MAVERICKS_BACKPORT: NSMenuItem downcast for -validateUserInterfaceItem: (restored from the
// Safari-537-era WKView.mm static menuItem() helper; toolbar items validate through the same
// protocol and must not be sent NSMenuItem messages).
static NSMenuItem *wkMenuItem(id <NSValidatedUserInterfaceItem> item)
{
    // MAVERICKS_BACKPORT: wkMenuItem downcasts only genuine NSMenuItems so toolbar items validating through the same protocol are not sent NSMenuItem messages.
    if (![(NSObject *)item isKindOfClass:[NSMenuItem class]])
        return nil;
    return (NSMenuItem *)item;
}

// MAVERICKS_BACKPORT: menu validation for the two restored Substitutions toggles, ported from
// the Safari-537-era -[WKView validateUserInterfaceItem:] cases (checkbox state from the
// TextChecker flag; enabled only over editable content, matching WebViewImpl). Every other
// action falls through to YES: this WKView's other menu actions (copy:/cut:/paste:/undo:/
// redo:/selectAll:) are enabled by AppKit's responds-to-selector default validation, and this
// override preserves exactly that for them.
- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)item
{
    // MAVERICKS_BACKPORT: -validateUserInterfaceItem: validates the restored Substitutions menu toggles dispatched down the responder chain.
    SEL action = [item action];

    // MAVERICKS_BACKPORT: validate the Automatic Quote Substitution toggle: checkbox from the TextChecker flag, enabled only over editable content.
    if (action == @selector(toggleAutomaticQuoteSubstitution:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled);
        [wkMenuItem(item) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState && _wkState->page && _wkState->page->editorState().isContentEditable;
    }

    // MAVERICKS_BACKPORT: validate the Automatic Dash Substitution toggle: checkbox from the TextChecker flag, enabled only over editable content.
    if (action == @selector(toggleAutomaticDashSubstitution:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled);
        [wkMenuItem(item) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState && _wkState->page && _wkState->page->editorState().isContentEditable;
    }

    // MAVERICKS_BACKPORT: every other action falls through to YES (AppKit's responds-to-selector default validation for copy:/cut:/paste:/undo:/redo:/selectAll:).
    return YES;
}

@end
// MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
// ALLOW_DEPRECATED_DECLARATIONS_END
//
// #endif // PLATFORM(MAC)
// (end MAVERICKS_BACKPORT restored block)
