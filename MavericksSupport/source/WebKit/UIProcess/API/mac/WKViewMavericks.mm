// The 10.9 WKView implementation.
//
// WKView is Safari 7's WebKit2 view. Upstream's UIProcess/API/mac/WKView.mm is a thin shell over
// WebViewImpl, which this port cannot use: WebViewImpl drives text input through the ASYNCHRONOUS
// NSTextInputClient protocol (10.11+) and WebKit's text-input IPC is async-only, while 10.9's AppKit
// speaks the SYNCHRONOUS protocol -- bridging the two by spinning the run loop reenters AppKit and
// corrupts input (verified on device; see [[webkit-mavericks-wkview-textinput]]). So WKView is
// reimplemented here against WebPageProxy directly, with MavericksPageClient as its PageClient.
//
// This lives in its own file so that UIProcess/API/mac/WKView.mm stays BYTE-UPSTREAM: a whole-file
// reimplementation written over the upstream file would be a ~900-line divergence that every upstream
// merge has to re-resolve. Only the build lists differ -- WebKitPlatformMavericks.cmake withholds
// WKView.mm from SourcesCocoa.txt and appends this file to WebKit_SOURCES. Same shape as
// platform/cocoa/MavericksBackportWebCoreGlue.mm.

#import <objc/runtime.h>

#import "config.h"
// include the public WKView.h (not WKViewInternal.h) — this is a standalone reimplementation, not the upstream PLATFORM(MAC) WebViewImpl wrapper.
#import "WKView.h"
// WKViewPrivate.h carries the Safari-7 WKView SPI declarations implemented
// below (the WKContentAnchor enum, the view-in-window deferral family, the async drawing-area
// size-update pair, and the automatic-substitution flags).
#import "WKViewPrivate.h"

#import "APIPageConfiguration.h"
#import "NativeWebKeyboardEvent.h"
#import "NativeWebMouseEvent.h"
#import "NativeWebWheelEvent.h"
#import "PageClient.h"
#import "WKAPICast.h"
#import "WebPageGroup.h"
#import "WebPageProxy.h"
#import "WebPreferences.h"
#import "WebProcessPool.h"
// LOG_ERROR, used by the spelling/substitutions panel actions below.
#import "Logging.h"
// process-global TextChecker state, which the automatic quote/dash
// substitution SPI below reads and writes.
#import "TextChecker.h"
// pinch/smart magnify and swipe navigation (see the magnification section below).
#import "ViewGestureController.h"
// promised-file drag support (see the promised-data section below).
#import "PasteboardTypes.h"
#import <WebCore/LegacyNSPasteboardTypes.h>
#import <wtf/FileSystem.h>
#import "TextCheckerState.h"
#import "WebProcessProxy.h"
#import "WebUserContentControllerProxy.h"
#import "WebKit2Initialize.h"
#import "DrawingAreaProxy.h"
#import "WKPrintingView.h"
#import "WebFrameProxy.h"
// legacy ObjC group/controller classes that QuickLook's
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
// needed so the WKView NSTextInputClient implementation can insert text, drive
// inline-IME composition, and answer the synchronous text-input queries 10.9 AppKit makes (#63).
#import "EditingRange.h"
#import "EditorState.h"
#import "InsertTextOptions.h"
#import <WebCore/CompositionUnderline.h>
#import <wtf/text/MakeString.h>
// WebCoreFullScreenWindow backs the restored -createFullScreenWindow SPI.
#import <WebCore/WebCoreFullScreenWindow.h>
#import <QuartzCore/QuartzCore.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
// Services support — advertise the web selection to AppKit's Services
// machinery (the app-menu Services submenu and the context-menu services). The standalone
// WKView talks to WebPageProxy directly (no WebViewImpl), so these are wired here.
#import "EditorState.h"
#import "PasteboardTypes.h"
#import <WebCore/LegacyNSPasteboardTypes.h>
#import <WebCore/SharedBuffer.h>
#if ENABLE(DRAG_SUPPORT)
#import "PasteboardTypes.h"
#import "SandboxExtension.h"
#import <WebCore/DragData.h>
#import <WebCore/DragActions.h>
#import <WebCore/PlatformEventFactoryMac.h>
// _NSRecommendedScrollerStyle(), used to pick the mouse-tracking-area options.
#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <pal/spi/mac/NSWindowSPI.h> // NSWindowDidOrderOn/OffScreenNotification for the visibility observers.
// the WK2 remote-accessibility bridge below — NSAccessibilityRemoteUIElement,
// the AXObjectCache enable-on-demand gate, and makeVector for the token payloads.
#import <pal/spi/cocoa/NSAccessibilitySPI.h>
#import <WebCore/AXObjectCache.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/Compiler.h>
#endif

// this WKView reimplementation uses WebKit:: types unqualified throughout.
using namespace WebKit;

// the page-client factory and accessors defined in MavericksPageClient.mm.
namespace WebKit {
std::unique_ptr<PageClient> createMavericksPageClient(NSView *view);
void setMavericksPageClientPage(PageClient&, WebPageProxy *);
void mavericksPageClientViewDidChangeBackingProperties(PageClient&);
void setMavericksPageClientWindowOcclusionDetectionEnabled(PageClient&, bool);
bool mavericksPageClientWindowOcclusionDetectionEnabled(PageClient&);
#if ENABLE(FULLSCREEN_API)
NSView *mavericksPageClientFullScreenPlaceholderView(PageClient&);
#endif
}

// per-WKView instance state. Upstream keeps view state in WKViewData/
// WebViewImpl; this port owns the WebPageProxy and its PageClient here and threads them through the
// input/geometry paths below. The RefPtr keeps the page alive for the view's lifetime; the
// unique_ptr owns the page client.
struct WKViewState {
    RefPtr<WebKit::WebPageProxy> page;
    std::unique_ptr<WebKit::PageClient> pageClient;
    // pinch-to-zoom / smart-magnify / swipe-navigation state, mirroring
    // WebViewImpl's m_allowsMagnification, m_allowsBackForwardNavigationGestures and
    // m_gestureController. The controller is created lazily, exactly as
    // WebViewImpl::ensureGestureController does.
    bool allowsMagnification { false };
    bool allowsBackForwardNavigationGestures { false };
    RefPtr<WebKit::ViewGestureController> gestureController;
    // promised-file drag state (drag an image out of the page to the Finder).
    // Mirrors WebViewImpl's m_promisedImage / m_promisedFilename / m_promisedURL. The image bytes are
    // kept as NSData rather than a WebCore::Image because that is all the PageClient hands us and all
    // -namesOfPromisedFilesDroppedAtDestination: needs to write the file.
    RetainPtr<NSData> promisedImageData;
    RetainPtr<NSData> promisedArchiveData;
    RetainPtr<NSString> promisedImageUTI;
    RetainPtr<NSString> promisedFilename;
    RetainPtr<NSString> promisedURL;
#if ENABLE(DRAG_SUPPORT)
    // the originating mouse-down event, needed by the classic
    // -[NSView dragImage:...event:...] API to start an HTML5 drag session.
    RetainPtr<NSEvent> lastMouseDownEvent;
#endif
    // the unhandled key-down currently being re-dispatched to AppKit
    // (mirrors WebViewImpl::m_keyDownEventBeingResent); performKeyEquivalent:/keyDown:
    // pass it to super instead of re-entering the page.
    RetainPtr<NSEvent> keyDownEventBeingResent;
    // the WK2 remote-accessibility bridge, mirroring WebViewImpl's
    // m_remoteAccessibilityChild / m_remoteAccessibilityChildToken / m_registeredRemoteAccessibilityPids.
    // remoteAccessibilityChild is the WebContent process's AX tree seen from here; the view vends it
    // as its one accessibility child, which is what puts an AXWebArea under Safari's window.
    RetainPtr<NSAccessibilityRemoteUIElement> remoteAccessibilityChild;
    RetainPtr<NSData> remoteAccessibilityChildToken;
    // Safari 7's content-anchor SPI — the corner painted content stays
    // pinned to while frame-size updates are disabled (see -setContentAnchor:).
    WKContentAnchor contentAnchor { WKContentAnchorTopLeft };
    // accumulated content-anchor shift of the hosted layer, and the
    // -disableFrameSizeUpdates nesting count that gates the drawing-area size push (both
    // mirror the 537 WKView's _frameOrigin / _frameSizeUpdatesDisabledCount).
    NSPoint frameOrigin { 0, 0 };
    unsigned frameSizeUpdatesDisabledCount { 0 };
    // pending scroll compensation from -setFrame:andScrollBy:, mirroring
    // WebViewImpl::m_scrollOffsetAdjustment. Consumed by the next drawing-area size push.
    NSSize scrollOffsetAdjustment { 0, 0 };
    // view-in-window-change deferral state (mirrors WebViewImpl's
    // m_shouldDeferViewInWindowChanges / m_viewInWindowChangeWasDeferred). While deferring,
    // -viewDidMoveToWindow records the IsInWindow change here instead of pushing it;
    // -endDeferringViewInWindowChanges[Sync] pushes the coalesced change.
    bool shouldDeferViewInWindowChanges { false };
    bool viewInWindowChangeWasDeferred { false };
    // Safari-7 -[WKView setShouldClipToVisibleRect:] state (mirrors
    // WebViewImpl::m_clipsToVisibleRect). When set, the page's view-exposed-rect is pinned to
    // the view's visible rect so the tiled drawing area only backs visible content. iBooks'
    // BKWKViewTiling sends -setShouldClipToVisibleRect:YES right after creating the view.
    bool shouldClipToVisibleRect { false };
};

// consume the pending -setFrame:andScrollBy: delta on a geometry push, mirroring
// WebViewImpl::setDrawingAreaSize (mac/WebViewImpl.mm:1900-1903), which passes the accumulated
// adjustment to DrawingAreaProxy::setSize and then clears it.
static WebCore::IntSize wkTakeScrollOffsetAdjustment(WKViewState* state)
{
    if (!state)
        return { };
    WebCore::IntSize offset(state->scrollOffsetAdjustment.width, state->scrollOffsetAdjustment.height);
    state->scrollOffsetAdjustment = NSZeroSize;
    return offset;
}

// WKContentAnchor corner tests, restored from the Safari-537-era WKView.mm.
static inline bool isWKContentAnchorRight(WKContentAnchor x)
{
    return x == WKContentAnchorTopRight || x == WKContentAnchorBottomRight;
}

static inline bool isWKContentAnchorBottom(WKContentAnchor x)
{
    return x == WKContentAnchorBottomLeft || x == WKContentAnchorBottomRight;
}

// NSApplication SPI WebViewImpl::doneWithKeyEvent uses when re-dispatching
// an unhandled key-down back to AppKit, so [NSApp currentEvent] matches during menu dispatch.
@interface NSApplication (WKMavericksKeyResend)
- (void)_setCurrentEvent:(NSEvent *)event;
@end

// the speech SPI -startSpeaking:/-stopSpeaking: below forward to, declared the
// same way WebViewImpl.mm and WebHTMLView.mm declare it -- AppKit has never exposed these two in a
// public header, so the calls ported from WebViewImpl need the declaration to come along with them.
@interface NSApplication (WKMavericksSpeech)
- (void)speakString:(NSString *)string;
- (void)stopSpeaking:(id)sender;
@end

@interface WKView () {
    WKViewState *_wkState;
    WKBrowsingContextController *_browsingContextController;
    // cached intrinsic content size for the auto-layout SPI Mail's
    // MUIWKView drives (the web process reports the laid-out content size back via
    // MavericksPageClient::intrinsicContentSizeDidChange -> -_setIntrinsicContentSize:).
    NSSize _intrinsicContentSize;
}
// private helper backing the clip-to-visible-rect SPI (see -setShouldClipToVisibleRect:).
- (void)_updateViewExposedRect;
// runs AppKit's key-binding translation for one event (see the definition).
- (void)_mavericksCollectKeypressCommands:(NSEvent *)event into:(WTF::Vector<WebCore::KeypressCommand>&)commands;
@end

@implementation WKView

// designated initializer — creates a WebPageProxy and page client for this view.
- (instancetype)initWithFrame:(NSRect)frame processPool:(std::reference_wrapper<WebKit::WebProcessPool>)processPool configuration:(Ref<API::PageConfiguration>&&)configuration
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    // layer-back the view and paint a white base so empty/loading pages aren't black.
    [self setWantsLayer:YES];
    self.layer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);

    // start with a flexible intrinsic size until the web process reports a laid-out one.
    _intrinsicContentSize = NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);

    // ensure WebKit2 globals are initialized before creating the page proxy.
    WebKit::InitializeWebKit2();

    // allocate the per-view state holding the page proxy and page client.
    _wkState = new WKViewState;
    _wkState->pageClient = createMavericksPageClient(self);
    _wkState->page = processPool.get().createWebPage(*_wkState->pageClient, WTF::move(configuration));
    setMavericksPageClientPage(*_wkState->pageClient, _wkState->page.get());

    // bring up the WebPage now that the page proxy + client are wired (no Site/sandbox yet).
    _wkState->page->initializeWebPage(WebCore::Site(WTF::HashTableEmptyValue), WebCore::SandboxFlags {}, WebCore::ReferrerPolicy::Default);

    // legacy WebKit2 launched the context's web process as soon as a page
    // existed, and embedders sequence on the resulting connection callback — WKProcessGroup's
    // -processGroup:didCreateConnectionToWebProcessPlugIn: fires at web-process launch, and
    // iBooks won't load anything into a fresh document worker's view until that callback hands
    // it the connection. Modern WebKit defers the launch to the first load, which deadlocks that
    // pattern (no load -> no launch -> no callback -> iBooks' 60s watchdog). Launch eagerly, as
    // 537 did via ensureSharedWebProcess at page creation (no-op if a real process already runs;
    // launchProcess re-runs initializeWebPage against the launched process via
    // finishAttachingToWebProcess, replacing the drawing area created above).
    _wkState->page->launchInitialProcessIfNecessary();

    // tell AppKit which pasteboard types this view can supply from / accept into the
    // selection, so the Services machinery offers services for the web selection (app-menu Services submenu
    // and context-menu services). Ported from WebViewImpl's constructor (which this WKView does not use).
    [NSApp registerServicesMenuSendTypes:WebKit::PasteboardTypes::forSelectionSingleton() returnTypes:WebKit::PasteboardTypes::forEditingSingleton()];

    // mouse-tracking area so this view receives mouseMoved:/mouseEntered:/
    // mouseExited: regardless of first-responder status — AppKit routes plain NSMouseMoved window
    // events to the first responder alone, which an embedder can keep elsewhere (Mail's message
    // list stays first responder while the body WKView shows a message), and cursor changes and
    // CSS :hover depend on those events. Options match Safari 7 WebKit2's
    // -[WKView initWithFrame:contextRef:pageGroupRef:relatedToPage:]: legacy scrollbars have
    // design details that rely on tracking the mouse all the time, overlay scrollbars only need
    // tracking while the window is key. (WebViewImpl::trackingAreaOptions() additionally sets
    // NSTrackingCursorUpdate, which is for a cursorUpdate: handler this view does not have.)
    NSTrackingAreaOptions trackingOptions = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingInVisibleRect;
    trackingOptions |= _NSRecommendedScrollerStyle() == NSScrollerStyleLegacy ? NSTrackingActiveAlways : NSTrackingActiveInKeyWindow;
    RetainPtr<NSTrackingArea> trackingArea = adoptNS([[NSTrackingArea alloc] initWithRect:frame options:trackingOptions owner:self userInfo:nil]);
    [self addTrackingArea:trackingArea.get()];

#if ENABLE(DRAG_SUPPORT)
    // become an NSDraggingDestination so drops route into the page.
    auto dragTypes = adoptNS([[NSMutableSet alloc] initWithArray:WebKit::PasteboardTypes::forEditingSingleton()]);
    [dragTypes addObjectsFromArray:WebKit::PasteboardTypes::forURLSingleton()];
    [dragTypes addObject:WebKit::PasteboardTypes::WebDummyPboardType];
    [self registerForDraggedTypes:[dragTypes allObjects]];
#endif

    return self;
}

// tear down the backported per-view state (page proxy, page client, cached controller).
- (void)dealloc
{
    // stop observing backing-scale changes (registered in -viewDidMoveToWindow for the Retina fix).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeBackingPropertiesNotification object:nil];
    // stop observing screen changes (registered in -viewDidMoveToWindow for the display-link wiring).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeScreenNotification object:nil];
    // stop observing window visibility/key-state changes (registered in -viewDidMoveToWindow).
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidOrderOnScreenNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidOrderOffScreenNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidMiniaturizeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidDeminiaturizeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    // give the WebContent pid's remote-UI registration back before the view
    // that owned it goes away (the matching half of the registration made when its token arrived).
    [self _mavericksUpdateRemoteAccessibilityRegistration:NO];
    // release the lazily-created browsing-context controller and delete the WKViewState.
    [_browsingContextController release];
    _browsingContextController = nil;
    delete _wkState;
    _wkState = nullptr;
    [super dealloc];
}

// WKView auto-layout / intrinsic-content-size SPI, ported from WebViewImpl.
// Mail's message viewer (MUIWKView) drives the message view through this: it enables auto-sizing
// with -setMinimumSizeForAutoLayout:, and the web process reports the laid-out content height back
// so the view sizes to fit the message inside Mail's scroll view.
- (NSSize)intrinsicContentSize
{
    return _intrinsicContentSize;
}

// Safari-7 auto-layout SPI -setMinimumSizeForAutoLayout: (declared in WKViewPrivate.h), ported from WebViewImpl.
- (void)setMinimumSizeForAutoLayout:(NSSize)minimumSizeForAutoLayout
{
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

// auto-layout SPI getter for the configured minimum layout size (ported from WebViewImpl).
- (NSSize)minimumSizeForAutoLayout
{
    if (!_wkState || !_wkState->page)
        return NSZeroSize;
    auto size = _wkState->page->minimumSizeForAutoLayout();
    return NSMakeSize(size.width(), size.height());
}

// auto-layout SPI — let auto-sizing expand to fill the view height (ported from WebViewImpl for Mail).
- (void)setShouldExpandToViewHeightForAutoLayout:(BOOL)shouldExpand
{
    if (_wkState && _wkState->page)
        _wkState->page->setAutoSizingShouldExpandToViewHeight(shouldExpand);
}

// auto-layout SPI getter mirroring WebViewImpl::shouldExpandToViewHeightForAutoLayout.
- (BOOL)shouldExpandToViewHeightForAutoLayout
{
    return _wkState && _wkState->page ? _wkState->page->autoSizingShouldExpandToViewHeight() : NO;
}

// called by MavericksPageClient::intrinsicContentSizeDidChange when the web
// process reports a new laid-out content size.
- (void)_setIntrinsicContentSize:(NSSize)intrinsicContentSize
{
    // A content width below the minimum layout width means the content flowed to fit, so report the
    // width as flexible; otherwise report it so auto-layout reserves space. Matches WebViewImpl.
    NSSize size = intrinsicContentSize;
    if (_wkState && _wkState->page && intrinsicContentSize.width < _wkState->page->minimumSizeForAutoLayout().width())
        size.width = NSViewNoIntrinsicMetric;
    _intrinsicContentSize = size;
    [self invalidateIntrinsicContentSize];
}

// C-ref WKView initializer Safari/QuickLook use; forwards to the relatedToPage: variant.
- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef
{
    return [self initWithFrame:frame contextRef:contextRef pageGroupRef:pageGroupRef relatedToPage:nil];
}

// build an API::PageConfiguration from the C refs and route through the designated initializer.
- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef relatedToPage:(WKPageRef)relatedPage
{
    auto configuration = API::PageConfiguration::create();
    configuration->setProcessPool(WebKit::toImpl(contextRef));
    // honor the page group Safari passes — its identifier is
    // how the injected bundle scopes extension content scripts
    // (WKBundleAddUserScript), and its preferences carry Safari's settings.
    if (pageGroupRef) {
        RefPtr<WebKit::WebPageGroup> pageGroup = WebKit::toImpl(pageGroupRef);
        configuration->setPreferences(&pageGroup->preferences());
        // share the page group's user content controller so user
        // scripts/style sheets installed on the group (WKPageGroupAddUserScript /
        // AddUserStyleSheet, e.g. via Mail's WKBrowsingContextGroup) are injected
        // into this page.
        configuration->setUserContentController(&pageGroup->userContentController());
        configuration->setPageGroup(WTF::move(pageGroup));
    }

    // honor relatedToPage — the related page pins this page into the same
    // WebProcess (WebProcessPool::createWebPage uses relatedPage->ensureRunningProcess()).
    // Safari's SearchableWKView passes the current tab's page here; Safari Reader depends on it:
    // the reader page's injected-bundle controller resolves the browser page's article finder
    // in-process (ReaderWebProcessController::originalArticleFinder walks a same-process
    // WKBundlePage link), and the extracted article DOM node is adopted across the two pages.
    if (relatedPage)
        configuration->setRelatedPage(protect(WebKit::toImpl(relatedPage)));

    return [self initWithFrame:frame processPool:*WebKit::toImpl(contextRef) configuration:WTF::move(configuration)];
}

- (id)initWithFrame:(NSRect)frame configurationRef:(WKPageConfigurationRef)configurationRef { [self release]; return nil; }
- (WKPageRef)pageRef { return _wkState ? WebKit::toAPI(_wkState->page.get()) : nullptr; }

// legacy initializer used by QuickLook's Web2.qldisplay. It hands
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

// vend a controller bound to this view's page so Web2.qldisplay
// can load/observe via the controller (or pull its pageRef for the C SPI).
- (WKBrowsingContextController *)browsingContextController
{
    if (!_browsingContextController && _wkState && _wkState->page)
        _browsingContextController = [[WKBrowsingContextController alloc] _initWithPageRef:WebKit::toAPI(_wkState->page.get())];
    return _browsingContextController;
}

// propagate the new viewport size to WebContent via WebPageProxy::setSize.
// Safari creates WKViews with a zero frame and resizes them later, so this is what gives the web
// process a real viewport.
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
    // compute the anchor-shifted content origin against the OLD frame size,
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
            drawingArea->setSize(WebCore::IntSize(newSize.width, newSize.height), wkTakeScrollOffsetAdjustment(_wkState));
        // keep the clipped view-exposed-rect matched to the new visible rect.
        if (_wkState->shouldClipToVisibleRect)
            [self _updateViewExposedRect];
    }
    // the WebContent's render layer lives in MavericksPageClient's dedicated
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
    // honor the frame-size-updates gate here too — while Safari has called
    // -disableFrameSizeUpdates, no frame change reaches the drawing area until
    // -enableFrameSizeUpdates pushes the settled size.
    if (![self frameSizeUpdatesDisabled] && _wkState && _wkState->page) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(frame.size.width, frame.size.height), wkTakeScrollOffsetAdjustment(_wkState));
    }
    [self _updateViewExposedRect];
}

// moving this view within its superview changes which part of it is visible
// but fires no other geometry hook (layer-backed views rarely get -renewGState). iBooks' reader
// turns pages by SLIDING its wide paginated strip view via frame-origin changes, so the clipped
// view-exposed rect must follow here or the newly exposed page region is never painted.
- (void)setFrameOrigin:(NSPoint)origin
{
    [super setFrameOrigin:origin];
    [self _updateViewExposedRect];
}

// the display pass that follows any layout/attach reaches -viewWillDraw with
// FINAL geometry, so the clipped view-exposed rect is refreshed here. A view swapped into a window
// at its final position (iBooks installs each chapter's strip view this way) gets no
// frame/origin/gstate hook afterwards, and its -visibleRect at -viewDidMoveToWindow time is empty.
- (void)viewWillDraw
{
    [self _updateViewExposedRect];
    [super viewWillDraw];
}

// Safari-7 clip-to-visible-rect SPI, declared in WKViewPrivate.h and ported
// from WebViewImpl::{setClipsToVisibleRect,clipsToVisibleRect,updateViewExposedRect}. iBooks'
// BKWKViewTiling sends -setShouldClipToVisibleRect:YES unguarded when wiring up its page.
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

// pin the page's view-exposed-rect to the view's visible rect while clipping
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

// content-anchor SPI, declared in WKViewPrivate.h (with the restored
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

// content-anchor getter; pageless WKViews (no _wkState) report the default top-left anchor.
- (WKContentAnchor)contentAnchor
{
    return _wkState ? _wkState->contentAnchor : WKContentAnchorTopLeft;
}

// async drawing-area size-update SPI, declared in WKViewPrivate.h and sent
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
        drawingArea->setSize(WebCore::IntSize(size.width, size.height), wkTakeScrollOffsetAdjustment(_wkState));
        drawingArea->waitForDidUpdateGeometry(WTF::Seconds { });
    }
}

// blocking counterpart, ported from the Safari-537-era
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

// the underlayColor property declared in WKViewPrivate.h, mirroring
// WebViewImpl::setUnderlayColor / underlayColor by delegating straight to the page proxy. Safari 7's
// ContinuousReadingListViewController sends -setUnderlayColor: unguarded to BrowserWKView when it
// opens a Reading List item.
- (void)setUnderlayColor:(NSColor *)underlayColor
{
    if (_wkState && _wkState->page)
        _wkState->page->setUnderlayColor(WebCore::colorFromCocoaColor(underlayColor));
}

- (NSColor *)underlayColor
{
    if (_wkState && _wkState->page)
        return WebCore::cocoaColorOrNil(_wkState->page->underlayColor()).autorelease();
    return nil;
}
// the NSTextInputClient surface AppKit sends to BrowserWKView once it is in a
// window. insertText: + doCommandBySelector: capture commands during interpretKeyEvents: so the
// keyDown handler can forward them to WebPage as KeypressCommands.
static __thread WTF::Vector<WebCore::KeypressCommand> *tlsCollectingCommands = nullptr;
- (NSArray *)validAttributesForMarkedText { return @[]; }
// the NSTextInputClient queries.
// 10.9 AppKit uses the SYNCHRONOUS NSTextInputClient protocol (the async -...:completionHandler:
// variants WKWebView/WebViewImpl use are 10.11+), and the WebProcess text-input IPC is async-only.
// Bridging the round-trip queries by spinning the run loop reenters AppKit's event handling and
// corrupts input, so the IME-critical answers are served
// synchronously from the live editor state (which the WebProcess already pushes on every selection /
// composition change), and the queries that genuinely require a synchronous round-trip fall back to
// the same values upstream's synchronous WebViewImpl path returns (WebViewImpl.mm:6011-6045).
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
    // Reconversion substring needs a synchronous round-trip the async-only IPC can't answer without
    // reentrancy; upstream's synchronous path returns nil here too.
    if (actualRange)
        *actualRange = NSMakeRange(NSNotFound, 0);
    return nil;
}
// WKView NSTextInputClient queries (github #63). 10.9 AppKit calls these
// synchronously, but WebKit2's editor IPC is async-only; -characterIndexForPoint: needs a
// synchronous hit-test it cannot answer without reentrancy, so — as upstream's synchronous path —
// it returns NSNotFound, while -firstRectForCharacterRange: below positions the IME candidate
// window from the editor state's last-reported caret rect instead.
- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
    // Needs a synchronous hit-test the async-only IPC can't answer without reentrancy; upstream's
    // synchronous path returns NSNotFound.
    return NSNotFound;
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange
{
    if (actualRange)
        *actualRange = range;
    if (!(_wkState && _wkState->page))
        return NSZeroRect;
    const WebKit::EditorState& state = _wkState->page->editorState();
    if (!state.hasVisualData())
        return NSZeroRect;
    // Position the IME candidate window at the caret — the live layout rect the WebProcess last
    // reported for the selection/composition start (the marked-text-specific caret rects are iOS-only).
    WebCore::IntRect caretRect = state.visualData->caretRectAtStart;
    NSRect rectInView = NSMakeRect(caretRect.x(), caretRect.y(), caretRect.width(), caretRect.height());
    NSRect rectInWindow = [self convertRect:rectInView toView:nil];
    if (NSWindow *window = [self window])
        return [window convertRectToScreen:rectInWindow];
    return rectInView;
}
// WKView NSTextInputClient -hasMarkedText (github #63) — served from the editor state.
- (BOOL)hasMarkedText
{
    // The composition state is carried synchronously in the editor state, so no round-trip is needed.
    return _wkState && _wkState->page && _wkState->page->editorState().hasComposition;
}
// WKView NSTextInputClient deprecated single-argument -insertText: (github #63).
- (void)insertText:(id)string
{
    // forward the deprecated single-argument NSTextInput -insertText: (which some
    // legacy callers still use) to the NSTextInputClient two-argument form.
    [self insertText:string replacementRange:NSMakeRange(NSNotFound, 0)];
}
// WKView NSTextInputClient -insertText:replacementRange: (github #63) — the real text-insertion path.
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    // capture inserted text as a KeypressCommand during interpretKeyEvents so keyDown can forward it to WebPage.
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
        return;
    }
    // insertText: sent OUTSIDE interpretKeyEvents — the Character Viewer / emoji
    // picker, an input method confirming a candidate, dictation, etc. (github #63). There is no
    // keyDown to forward it through, so insert it now (mirroring the non-keypress branch of
    // WebViewImpl::insertText).
    if (_wkState && _wkState->page) {
        // Same NSBackTabCharacter->NSTabCharacter normalization WebViewImpl::insertText applies.
        String eventText = makeStringByReplacingAll(String(s), NSBackTabCharacter, NSTabCharacter);
        _wkState->page->insertTextAsync(eventText, replacementRange, InsertTextOptions { });
    }
}
// WKView NSTextInputClient -markedRange (github #63) — see the sync-IPC note in the body.
- (NSRange)markedRange
{
    // The absolute character offsets of the marked range require a synchronous round-trip the
    // async-only IPC can't answer without reentrancy; upstream's synchronous path returns NSNotFound.
    // hasMarkedText (served from the editor state) still tells the input method a composition exists.
    return NSMakeRange(NSNotFound, 0);
}
// WKView NSTextInputClient -selectedRange (github #63) — see the sync-IPC note in the body.
- (NSRange)selectedRange
{
    // As markedRange: needs a synchronous round-trip; upstream's synchronous path also returns
    // NSNotFound (WebViewImpl.mm:6011).
    return NSMakeRange(NSNotFound, 0);
}
// WKView NSTextInputClient -setMarkedText:selectedRange:replacementRange: (github #63) — drives inline-IME composition.
- (void)setMarkedText:(id)string selectedRange:(NSRange)newSelectedRange replacementRange:(NSRange)replacementRange
{
    if (!(_wkState && _wkState->page))
        return;
    BOOL isAttributed = [string isKindOfClass:[NSAttributedString class]];
    NSString *text = isAttributed ? [(NSAttributedString *)string string] : (NSString *)string;
    if (!text)
        text = @"";
    // Underline the whole composition (WebViewImpl's plain-string default). Per-attribute styling from
    // the input method is not mirrored — a feature gap, not a correctness issue.
    Vector<WebCore::CompositionUnderline> underlines;
    underlines.append(WebCore::CompositionUnderline(0, [text length], WebCore::CompositionUnderlineColor::TextColor, WebCore::Color::black, false));
    _wkState->page->setCompositionAsync(String(text), underlines, { }, { }, newSelectedRange, replacementRange);
}
// WKView NSTextInputClient -unmarkText (github #63) — confirms the active composition.
- (void)unmarkText
{
    if (_wkState && _wkState->page)
        _wkState->page->confirmCompositionAsync();
}
// WKView NSTextInputClient -doCommandBySelector: (github #63) — collects command selectors during interpretKeyEvents.
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
// the UI-process half of the WK2 remote-accessibility bridge. WebKit2 renders
// the page in another process, so the AX tree Safari's window exposes has to be stitched across
// the process boundary: the WebContent process hands up a token for its root object, the UI
// process turns it into an NSAccessibilityRemoteUIElement and vends it as this view's only
// accessibility child, and the UI process hands *down* tokens for this view and its window so the
// remote tree knows its parent. Upstream does all of this in WebViewImpl
// (setAccessibilityWebProcessToken / updateRemoteAccessibilityRegistration /
// accessibilityRegisterUIProcessTokens / accessibilityAttributeValue:), which the WKView path does
// not use, so it is wired here. Every entry point used is present on 10.9 (class + all four
// selectors verified against this host's AppKit), so nothing here is a polyfill.
- (void)_mavericksSetAccessibilityWebProcessToken:(NSData *)token processIdentifier:(pid_t)pid
{
    if (!_wkState || !_wkState->page)
        return;
    if (pid != _wkState->page->legacyMainFrameProcess().processID())
        return;

    _wkState->remoteAccessibilityChild = [token length] ? adoptNS([[NSAccessibilityRemoteUIElement alloc] initWithRemoteToken:token]) : nil;
    _wkState->remoteAccessibilityChildToken = token;
    [self _mavericksUpdateRemoteAccessibilityRegistration:YES];
}

// Registering the WebContent pid is what lets the WindowServer resolve the remote element's
// tree; unregistering on teardown is the matching half (upstream's updateRemoteAccessibilityRegistration).
- (void)_mavericksUpdateRemoteAccessibilityRegistration:(BOOL)registerProcess
{
    if (!_wkState)
        return;

    // When the tree is connected/disconnected the registration has to be updated with the remote
    // process's pid. On the way out that pid comes from the remote element itself, because by then the
    // process may be gone and the page can no longer name it (upstream does exactly this).
    pid_t pid = 0;
    if (registerProcess) {
        if (_wkState->page)
            pid = _wkState->page->legacyMainFrameProcess().processID();
    } else {
        pid = [_wkState->remoteAccessibilityChild processIdentifier];
        _wkState->remoteAccessibilityChild = nil;
        _wkState->remoteAccessibilityChildToken = nil;
    }
    if (!pid)
        return;

    if (registerProcess)
        [NSAccessibilityRemoteUIElement registerRemoteUIProcessIdentifier:pid];
    else
        [NSAccessibilityRemoteUIElement unregisterRemoteUIProcessIdentifier:pid];
}

// The other direction: hand the WebContent process tokens for this view and its window, so the
// remote tree's root reports the right parent and window. Sent whenever the window connection is
// (re)established, exactly as upstream does from viewDidMoveToWindow and didRelaunchProcess.
- (void)_mavericksRegisterUIProcessAccessibilityTokens
{
    if (!_wkState || !_wkState->page)
        return;
    RetainPtr<NSData> elementToken = [NSAccessibilityRemoteUIElement remoteTokenForLocalUIElement:self];
    RetainPtr<NSData> windowToken = [NSAccessibilityRemoteUIElement remoteTokenForLocalUIElement:[self window]];
    _wkState->page->registerUIProcessAccessibilityTokens({ makeVector(elementToken.get()) }, { makeVector(windowToken.get()) });
}

// AX is off until something asks for it. Turning it on has to reach WebCore, and the view's
// position has to be resent afterwards, because while AX is off that position is never computed
// (upstream's enableAccessibilityIfNecessary -> updateWindowAndViewFrames, same reason).
- (void)_mavericksEnableAccessibilityIfNecessary:(NSString *)attribute
{
#if ENABLE(INITIALIZE_ACCESSIBILITY_ON_DEMAND)
    // This is the half that starts accessibility in the WEB CONTENT process. With accessibility
    // on demand (on by default on Mac), WebPage::platformInitialize deliberately skips
    // -[NSApplication _accessibilityInitialize] there and waits to be asked; the UI process asking
    // here is what starts it, and until then the WebContent process has no AX server for the remote
    // element this view vends to resolve against.
    // NSAccessibilityParentAttribute and NSAccessibilityPositionAttribute are answered locally and
    // do not need the web process, so they do not trigger initialization (upstream excludes them
    // for the same reason).
    if (![attribute isEqualToString:NSAccessibilityParentAttribute] && ![attribute isEqualToString:NSAccessibilityPositionAttribute]) {
        if (_wkState && _wkState->page)
            Ref { _wkState->page->configuration().processPool() }->initializeAccessibilityIfNecessary();
    }
#endif // closes the INITIALIZE_ACCESSIBILITY_ON_DEMAND guard (see above).

    if (WebCore::AXObjectCache::accessibilityEnabled())
        return;
    WebCore::AXObjectCache::enableAccessibility();

    if (!_wkState || !_wkState->page)
        return;
    NSRect viewFrameInWindowCoordinates = [self convertRect:[self frame] toView:nil];
    NSPoint accessibilityPosition = [[self accessibilityAttributeValue:NSAccessibilityPositionAttribute] pointValue];
    _wkState->page->windowAndViewFramesChanged(WebCore::FloatRect(viewFrameInWindowCoordinates), WebCore::FloatPoint(accessibilityPosition));
}

- (id)accessibilityAttributeValue:(NSString *)attribute
{
    [self _mavericksEnableAccessibilityIfNecessary:attribute];

    if ([attribute isEqualToString:NSAccessibilityChildrenAttribute]) {
        id child = _wkState ? _wkState->remoteAccessibilityChild.get() : nil;
        return child ? @[child] : nil;
    }
    if ([attribute isEqualToString:NSAccessibilityRoleAttribute])
        return NSAccessibilityGroupRole;
    if ([attribute isEqualToString:NSAccessibilityRoleDescriptionAttribute])
        return NSAccessibilityRoleDescription(NSAccessibilityGroupRole, nil);
    if ([attribute isEqualToString:NSAccessibilityParentAttribute])
        return NSAccessibilityUnignoredAncestor([self superview]);
    if ([attribute isEqualToString:NSAccessibilityEnabledAttribute])
        return @YES;

    return [super accessibilityAttributeValue:attribute];
}

- (BOOL)accessibilityIsIgnored { return NO; }

- (id)accessibilityFocusedUIElement
{
    [self _mavericksEnableAccessibilityIfNecessary:nil];
    return _wkState ? _wkState->remoteAccessibilityChild.get() : nil;
}

- (id)accessibilityHitTest:(NSPoint)point
{
    return [self accessibilityFocusedUIElement];
}

- (BOOL)wantsUpdateLayer { return NO; }
// fullscreen SPI declared in WKViewPrivate.h and sent by Safari 7. Upstream's
// WKView answers with its full-screen controller's placeholder view; this port's element-fullscreen
// path keeps the equivalent placeholder in the page client (MavericksPageClient.mm), so hand that
// one over. nil outside a fullscreen session, which is also what upstream answers.
- (NSView *)fullScreenPlaceholderView
{
#if ENABLE(FULLSCREEN_API)
    if (_wkState && _wkState->pageClient)
        return mavericksPageClientFullScreenPlaceholderView(*_wkState->pageClient);
#endif // closes the FULLSCREEN_API guard on -fullScreenPlaceholderView (see above).
    return nil;
}

// legacy fullscreen SPI, declared in WKViewPrivate.h and sent unguarded by
// Safari 7's fullscreen controller, which asks its WKView for a window to host fullscreen content
// in. It hands back the same window this port's own element-fullscreen path uses, so both paths
// share one factory.
- (NSWindow *)createFullScreenWindow
{
#if ENABLE(FULLSCREEN_API)
    // The same window WebViewImpl::fullScreenWindow() builds for the WKWebView path, so both paths hand
    // WKFullScreenWindowController the same thing. NSWindowStyleMaskFullSizeContentView is what lets
    // the page fill the screen rather than sit below a title bar; this port implements it for real
    // (the full-size-content adapter in MavericksSupport polyfills/methods/AppKit.m).
    return adoptNS([[WebCoreFullScreenWindow alloc] initWithContentRect:[[NSScreen mainScreen] frame] styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskUnifiedTitleAndToolbar | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO]).autorelease();
#endif // closes the FULLSCREEN_API guard; -createFullScreenWindow returns nil when fullscreen is compiled out.
    return nil;
}

- (void)updateLayer {}
// Basic init methods for non-page WKView instances (e.g. title bar button)
- (id)init { return [super init]; }
- (id)initWithFrame:(NSRect)frame { return [super initWithFrame:frame]; }
- (BOOL)isFlipped { return YES; }
- (BOOL)canChangeFrameLayout:(WKFrameRef)f { return NO; }
// printing, mirroring WebViewImpl::printOperationWithPrintInfo — build a
// WKPrintingView over the frame and wrap it in an NSPrintOperation that Safari drives.
// WKPrintingView paginates via the WebProcess print IPC.
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
// applies the frame and stashes the scroll delta. Safari sends this to its
// WKView (treated as "viewBelowBanner") during Banner._moveBannerIntoPlace: to shrink the web view
// by banner.height so the banner can occupy that vacated area.
//
// The scroll delta rides the geometry update, exactly as WebViewImpl does it
// (WebViewImpl::setFrameAndScrollBy at mac/WebViewImpl.mm:1811 stashes it in
// m_scrollOffsetAdjustment; setDrawingAreaSize passes it as DrawingAreaProxy::setSize's second
// argument and clears it). DrawingAreaProxy::setSize(size, scrollOffset) still takes that argument
// (DrawingAreaProxy.h:102), so the web process scroll-compensates the resize itself.
- (void)setFrame:(NSRect)r andScrollBy:(NSSize)o
{
    if (_wkState && !NSEqualSizes(o, NSZeroSize))
        _wkState->scrollOffsetAdjustment = o;

    [super setFrame:r];
}

// frame-size-updates gate, ported from the Safari-537-era WKView
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
    if (_wkState)
        _wkState->frameSizeUpdatesDisabledCount++;
}

// decrement the gate; on reaching zero push the settled frame size and clear the anchor shift (see -disableFrameSizeUpdates).
- (void)enableFrameSizeUpdates
{
    if (!_wkState || !_wkState->frameSizeUpdatesDisabledCount)
        return;

    // Only the outermost enable resumes frame-size updates.
    if (--_wkState->frameSizeUpdatesDisabledCount)
        return;

    if (_wkState->page) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize([self frame].size.width, [self frame].size.height), wkTakeScrollOffsetAdjustment(_wkState));
    }
    _wkState->frameOrigin = NSZeroPoint;
    if (CALayer *renderLayer = _wkState->pageClient ? _wkState->pageClient->acceleratedCompositingRootLayer() : nil) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [renderLayer setPosition:CGPointZero];
        [CATransaction commit];
    }
}

// gate query (537-verbatim semantics); pageless WKViews report the default enabled state.
- (BOOL)frameSizeUpdatesDisabled
{
    return _wkState && _wkState->frameSizeUpdatesDisabledCount > 0;
}
// +hideWordDefinitionWindow stub; Safari 7 sends it unguarded to dismiss the dictionary definition panel.
+ (void)hideWordDefinitionWindow {}

// NSServicesRequests responder hooks. AppKit walks the responder chain calling
// -validRequestorForSendType:returnType: to decide which services apply to the current selection, then
// -writeSelectionToPasteboard:types: to hand the selection to the chosen service (and
// -readSelectionFromPasteboard: for services that return a replacement). The standalone WKView talks
// to WebPageProxy directly (no WebViewImpl), so these are what offer the web selection to Services in
// both the app menu and the context menu. Ported from
// WebViewImpl::validRequestorForSendAndReturnTypes / writeSelectionToPasteboard / readSelectionFromPasteboard.
- (id)validRequestorForSendType:(NSString *)sendType returnType:(NSString *)returnType
{
    if (!_wkState || !_wkState->page)
        return [[self nextResponder] validRequestorForSendType:sendType returnType:returnType];

    // consult the page's EditorState to decide which send types the current selection offers to Services.
    const WebKit::EditorState& editorState = _wkState->page->editorState();
    bool isValidSendType = !sendType;
    if (sendType && editorState.selectionType != WebCore::SelectionType::None) {
        if (editorState.isInPlugin)
            isValidSendType = [sendType isEqualToString:WebCore::legacyStringPasteboardTypeSingleton()];
        else
            isValidSendType = [WebKit::PasteboardTypes::forSelectionSingleton() containsObject:sendType];
    }

    // a Service returning a replacement is valid only over editable content (rich or plain text).
    bool isValidReturnType = false;
    if (!returnType)
        isValidReturnType = true;
    else if ([WebKit::PasteboardTypes::forEditingSingleton() containsObject:returnType] && editorState.isContentEditable)
        isValidReturnType = editorState.isContentRichlyEditable || [returnType isEqualToString:WebCore::legacyStringPasteboardTypeSingleton()];

    // offer this view as the Services requestor when send/return types match, else fall through the responder chain.
    if (isValidSendType && isValidReturnType)
        return self;
    return [[self nextResponder] validRequestorForSendType:sendType returnType:returnType];
}

// -writeSelectionToPasteboard: hands the web selection to the chosen Service (ported from WebViewImpl::writeSelectionToPasteboard).
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard types:(NSArray *)types
{
    if (!_wkState || !_wkState->page)
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

// -readSelectionFromPasteboard: lets a Service replace the web selection (ported from WebViewImpl::readSelectionFromPasteboard).
- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pasteboard
{
    if (!_wkState || !_wkState->page)
        return NO;
    return _wkState->page->readSelectionFromPasteboard([pasteboard name]);
}

// NSEvent forwarding into WebPageProxy — mouseDown/Up/Moved/Dragged,
// scrollWheel and keyDown/Up — since this WKView does not use WebViewImpl's input pipeline.
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// #138: notify the page when this view gains/loses first-responder status so the
// WebContent's ActivityState::IsFocused flag tracks focus, which is what FrameSelection::
// isFocusedAndActive() reads to show the text-insertion caret and active selection highlight.
// Matches WebViewImpl, which fires activityStateDidChange(IsFocused) on become/resignFirstResponder.
// activityStateDidChange defers the recompute, so by the time it re-queries -isViewFocused the
// window firstResponder has settled.
- (BOOL)becomeFirstResponder
{
    BOOL result = [super becomeFirstResponder];
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return result;
}

// clear ActivityState::IsFocused on resign so the page's FocusController matches first-responder state (#138).
- (BOOL)resignFirstResponder
{
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return [super resignFirstResponder];
}

// ported from the Safari-537 WKView, which refreshed its window/view frames
// here. AppKit invalidates the gstate whenever this view's geometry RELATIVE TO THE WINDOW changes
// — window resize, ancestor moves, scrolling — none of which touch the view's own frame, so they
// reach no other geometry hook. iBooks attaches its reader views while the reader window is still
// animating open at a tiny size, so their -visibleRect is empty at -viewDidMoveToWindow time and
// this signal is what re-clips the exposed rect once the window reaches full size.
- (void)renewGState
{
    if ([self window])
        [self _updateViewExposedRect];
    [super renewGState];
}

// (re)register the window observers and push this view's activity state to the
// page. Safari's tab swap removes the inactive tab's WKView from the window and re-adds it on
// switch-back; the activityStateDidChange below is the WebPage::SetActivityState IPC that makes
// WebContent send a fresh layer-tree commit for the re-attached view.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!_wkState || !_wkState->page) return;

    // propagate the window's backing scale to the page so it renders at the
    // display's device pixel ratio (Retina = 2x). The MavericksPageClient/WKView path replaces
    // WebViewImpl, so its setIntrinsicDeviceScaleFactor wiring is mirrored here: set the factor on
    // (re)entering a window and observe NSWindowDidChangeBackingPropertiesNotification (display /
    // scale change).
    NSNotificationCenter *backingCenter = [NSNotificationCenter defaultCenter];
    [backingCenter removeObserver:self name:NSWindowDidChangeBackingPropertiesNotification object:nil];
    if (NSWindow *window = [self window])
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeBackingProperties:) name:NSWindowDidChangeBackingPropertiesNotification object:window];
    [self _wk_updateIntrinsicDeviceScaleFactor];

    // report the hosting window's screen to the page, mirroring upstream
    // WebViewImpl::windowDidChangeScreen. WebPageProxy::windowScreenDidChange sets m_displayID,
    // which updateDisplayLinkFrequency() needs to request full-speed DisplayLink updates for
    // wheel/animated-scroll activity, and tells the WebContent side (WebPage::WindowScreenDidChange
    // + EventDispatcher::PageScreenDidChange) which display the ThreadedScrollingTree belongs to —
    // its displayDidRefresh() only services callbacks whose displayID matches. Safari 7's WKView
    // predates all of this wiring.
    [backingCenter removeObserver:self name:NSWindowDidChangeScreenNotification object:nil];
    if (NSWindow *window = [self window]) {
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeScreen:) name:NSWindowDidChangeScreenNotification object:window];
        [self _wk_windowDidChangeScreen:nil];
    }

    // window visibility / key-state observers, mirroring upstream
    // WebViewImpl's WKWindowVisibilityObserver registrations. They are what recomputes visibility
    // for a view attached to a not-yet-shown window (Safari attaches restored windows' views before
    // ordering the window front at launch) once that window orders on screen; a WebCore page left
    // "hidden" suspends rAF, alignment-throttles DOM timers and runs no rendering updates.
    // The order-on/off-screen notifications are the private-SPI pair upstream observes
    // (NSWindowSPI.h; posted on 10.9 — runtime-verified via a symbol-registered observer on
    // orderFront:/makeKeyAndOrderFront:/deminiaturize: and orderOut:/miniaturize:). Observed with
    // _wk_-prefixed selectors because NSView itself observes these notifications (upstream's
    // WKWindowVisibilityObserver exists for the same reason).
    [backingCenter removeObserver:self name:NSWindowDidOrderOnScreenNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidOrderOffScreenNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidMiniaturizeNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidDeminiaturizeNotification object:nil];
    // the WindowServer computes occlusion asynchronously, so the Visible bit
    // arrives after the window orders in; this notification is how that transition is delivered
    // (upstream observes it at WebViewImpl::registerViewObservers). MavericksPageClient::isActiveViewVisible
    // reads window.occlusionState under this recompute.
    [backingCenter removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    if (NSWindow *window = [self window]) {
        [backingCenter addObserver:self selector:@selector(_wk_windowDidOrderOnScreen:) name:NSWindowDidOrderOnScreenNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidOrderOffScreen:) name:NSWindowDidOrderOffScreenNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeMiniaturization:) name:NSWindowDidMiniaturizeNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeMiniaturization:) name:NSWindowDidDeminiaturizeNotification object:window];
        [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeOcclusionState:) name:NSWindowDidChangeOcclusionStateNotification object:window];
    }
    // Key notifications are observed with object:nil like upstream (the key window may be this
    // window's attached sheet); remove-then-add so re-entering a window never double-registers.
    [backingCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [backingCenter removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeKeyState:) name:NSWindowDidBecomeKeyNotification object:nil];
    [backingCenter addObserver:self selector:@selector(_wk_windowDidChangeKeyState:) name:NSWindowDidResignKeyNotification object:nil];

    // recompute IsVisible when the active Space changes, mirroring upstream
    // WKWindowVisibilityObserver's NSWorkspaceActiveSpaceDidChangeNotification registration. A
    // window on another Space carries the change in its occlusion state, which is what
    // MavericksPageClient::isActiveViewVisible reads under this recompute.
    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    [workspaceCenter removeObserver:self name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [workspaceCenter addObserver:self selector:@selector(_wk_activeSpaceDidChange:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];

    OptionSet<WebCore::ActivityState> flags;
    // while Safari is deferring view-in-window changes
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

    // refresh the clipped view-exposed-rect now that the view is in a window
    // (its visible rect only becomes meaningful once attached), mirroring WebViewImpl's
    // updateWindowAndViewFrames -> updateViewExposedRect trigger.
    if (_wkState->shouldClipToVisibleRect)
        [self _updateViewExposedRect];

    // the remote accessibility tokens describe this view and the window it is
    // in, so they are (re)sent once the window connection exists, as upstream does from the same
    // place. Sending them from -initWithFrame: would name a window the view does not have yet.
    if ([self window])
        [self _mavericksRegisterUIProcessAccessibilityTokens];
}

// view-in-window-change deferral SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7 when it moves a WKView between windows (tab drag-out/merge). Ported from
// WebViewImpl::beginDeferringViewInWindowChanges / endDeferringViewInWindowChanges /
// endDeferringViewInWindowChangesSync onto this WKView's activityStateDidChange machinery:
// while deferring, -viewDidMoveToWindow suppresses the ActivityState::IsInWindow push and records
// it; ending the deferral pushes the coalesced in-window change so the page sees one transition
// instead of an out-of-window/in-window flicker.
- (void)beginDeferringViewInWindowChanges
{
    if (!_wkState)
        return;
    if (_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"beginDeferringViewInWindowChanges was called while already deferring view-in-window changes!");
        return;
    }

    _wkState->shouldDeferViewInWindowChanges = true;
}

// end the deferral and push the coalesced IsInWindow change (ported from WebViewImpl::endDeferringViewInWindowChanges).
- (void)endDeferringViewInWindowChanges
{
    if (!_wkState)
        return;
    if (!_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"endDeferringViewInWindowChanges was called without beginDeferringViewInWindowChanges!");
        return;
    }

    _wkState->shouldDeferViewInWindowChanges = false;

    if (_wkState->viewInWindowChangeWasDeferred) {
        if (_wkState->page)
            _wkState->page->activityStateDidChange(WebCore::ActivityState::IsInWindow);
        _wkState->viewInWindowChangeWasDeferred = false;
    }
}

// Sync variant, ported from WebViewImpl::endDeferringViewInWindowChangesSync,
// whose body upstream is identical to the non-Sync variant — the historical synchronous
// waitForDidUpdateInWindowState is gone from modern WebKit, so "Sync" carries no extra wait.
// (WebViewImpl also flushes its pending obscured-content-inset changes here; this WKView has no
// content-inset machinery, so there is nothing to flush.)
- (void)endDeferringViewInWindowChangesSync
{
    if (!_wkState)
        return;
    if (!_wkState->shouldDeferViewInWindowChanges) {
        NSLog(@"endDeferringViewInWindowChangesSync was called without beginDeferringViewInWindowChanges!");
        return;
    }

    _wkState->shouldDeferViewInWindowChanges = false;

    if (_wkState->viewInWindowChangeWasDeferred) {
        if (_wkState->page)
            _wkState->page->activityStateDidChange(WebCore::ActivityState::IsInWindow);
        _wkState->viewInWindowChangeWasDeferred = false;
    }
}

// deferral-state getter (ported from WebViewImpl::isDeferringViewInWindowChanges; declared in WKViewPrivate.h).
- (BOOL)isDeferringViewInWindowChanges
{
    return _wkState && _wkState->shouldDeferViewInWindowChanges;
}
// upstream closes its #if ENABLE(MAC_GESTURE_EVENTS) guard (which wraps
// -rotateWithEvent:) with this #endif here. MAC_GESTURE_EVENTS is unavailable on 10.9, so the guard
// is disabled and its closing #endif is kept commented out for upstream merges.
//#endif

// recompute visibility when this view (or an ancestor) hides/unhides, mirroring
// upstream WebViewImpl's viewDidHide/viewDidUnhide forwarding — the unhide is the only signal that
// clears an IsVisible=0 latched while the view was hidden.
- (void)viewDidHide
{
    [super viewDidHide];
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::IsVisibleOrOccluded });
}

// mirror -viewDidHide: recompute visibility when this view (or an ancestor) unhides.
- (void)viewDidUnhide
{
    [super viewDidUnhide];
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::IsVisibleOrOccluded });
}

// read the current window's (or main screen's) backing scale and push it to the page.
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

// the window changed backing scale (e.g. moved to a Retina display) — re-propagate it.
- (void)_wk_windowDidChangeBackingProperties:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    [self _wk_updateIntrinsicDeviceScaleFactor];
}

// push the hosting window's display ID to WebPageProxy (see -viewDidMoveToWindow). Also called
// when a process launch builds a new drawing area, whose m_displayID starts empty
// (MavericksPageClient::didRelaunchProcess).
- (void)_mavericksPushWindowScreen
{
    [self _wk_windowDidChangeScreen:nil];
}

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

// the hosting window's occlusion state changed — recompute visibility,
// mirroring WebViewImpl::windowDidChangeOcclusionState.
- (void)_wk_windowDidChangeOcclusionState:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsVisible);
}

// the hosting window ordered on screen — push IsVisible/WindowIsActive to the
// page, mirroring WebViewImpl::windowDidOrderOnScreen.
- (void)_wk_windowDidOrderOnScreen:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::WindowIsActive });
}

// the hosting window ordered off screen — recompute visibility, mirroring
// WebViewImpl::windowDidOrderOffScreen.
- (void)_wk_windowDidOrderOffScreen:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->activityStateDidChange({ WebCore::ActivityState::IsVisible, WebCore::ActivityState::WindowIsActive });
}

// the hosting window miniaturized or deminiaturized — recompute visibility,
// mirroring WebViewImpl::windowDidMiniaturize/windowDidDeminiaturize.
- (void)_wk_windowDidChangeMiniaturization:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsVisible);
}

// the active Space changed — recompute IsVisible, mirroring
// WebViewImpl::activeSpaceDidChange.
- (void)_wk_activeSpaceDidChange:(NSNotification *)notification
{
    UNUSED_PARAM(notification);
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->activityStateDidChange(WebCore::ActivityState::IsVisible);
}

// a window became or resigned key — recompute WindowIsActive, mirroring
// WebViewImpl::windowDidBecomeKey/windowDidResignKey.
- (void)_wk_windowDidChangeKeyState:(NSNotification *)notification
{
    if (!_wkState || !_wkState->page)
        return;
    NSWindow *window = [self window];
    if (!window)
        return;
    id changedWindow = [notification object];
    if (changedWindow != window && changedWindow != [window attachedSheet])
        return;
    _wkState->page->activityStateDidChange(WebCore::ActivityState::WindowIsActive);
}

// AppKit delivers this directly to the view when its backing properties change —
// the backing scale factor and the colour space of the display it is on.
- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self _wk_updateIntrinsicDeviceScaleFactor];
    if (_wkState && _wkState->pageClient)
        mavericksPageClientViewDidChangeBackingProperties(*_wkState->pageClient);
}

// WKViewPrivate.h's occlusion-detection switch, carried through to the page
// client that reads window.occlusionState.
- (void)setWindowOcclusionDetectionEnabled:(BOOL)flag
{
    if (_wkState && _wkState->pageClient)
        setMavericksPageClientWindowOcclusionDetectionEnabled(*_wkState->pageClient, flag);
}

- (BOOL)windowOcclusionDetectionEnabled
{
    return (_wkState && _wkState->pageClient) ? mavericksPageClientWindowOcclusionDetectionEnabled(*_wkState->pageClient) : YES;
}

// the WebContent layer tree is hosted on a dedicated layer-hosting subview
// (MavericksPageClient's WKMavericksLayerHostingView — the 537 _layerHostingView arrangement). That
// subview's -hitTest: returns nil, so AppKit's hit-testing lands on the WKView itself and the
// mouse/scroll/key NSResponder overrides below fire naturally via -[NSWindow sendEvent:]. The
// redirect here is the upstream-equivalent insurance (WebViewImpl::hitTest): a hit on self or
// any descendant resolves to self so the responder-chain forwarding stays correct.
- (NSView *)hitTest:(NSPoint)point
{
    NSView *result = [super hitTest:point];
    if (!result)
        return nil;
    if (result == self || [result isDescendantOf:self])
        return self;
    return result;
}

// macro that forwards each NSResponder mouse selector into the page proxy.
#define WKV_FORWARD_MOUSE(SEL_NAME) \
- (void)SEL_NAME:(NSEvent *)event \
{ \
    if (!_wkState || !_wkState->page) { [super SEL_NAME:event]; return; } \
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebMouseEventInputSource::UserDriven); \
    _wkState->page->handleMouseEvent(webEvent); \
}

// mouseDown is explicit (not via the macro) so it can retain the
// originating event for the classic drag-image API used to start HTML5 drags.
- (void)mouseDown:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super mouseDown:event]; return; }
#if ENABLE(DRAG_SUPPORT)
    _wkState->lastMouseDownEvent = event;
#endif
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebMouseEventInputSource::UserDriven);
    _wkState->page->handleMouseEvent(webEvent);
}
WKV_FORWARD_MOUSE(mouseUp)
// mouseMoved is explicit (not via the macro) because it needs a filter the
// other forwards don't: while this view is first responder, the window routes mouseMoved events
// to it from anywhere in the window (not just over the tracking area installed in the designated
// initializer), so moves outside the visible rect are dropped rather than hit-tested at bogus
// coordinates. Matches Safari 7 WebKit2's -[WKView mouseMoved:] and WebViewImpl::mouseMoved().
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

// three-finger-tap "Look Up" trackpad gesture. AppKit delivers the gesture as
// quickLookWithEvent: down the responder chain; upstream handles it in WebViewImpl::quickLookWithEvent,
// which this WKView doesn't use. There is no immediate-action gesture recognizer on 10.9
// (NSImmediateActionGestureRecognizer is 10.10.3+), so this is upstream's non-recognizer path:
// a dictionary lookup at the tap location.
- (void)quickLookWithEvent:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super quickLookWithEvent:event]; return; }
    NSPoint locationInViewCoordinates = [self convertPoint:[event locationInWindow] fromView:nil];
    _wkState->page->performDictionaryLookupAtLocation(WebCore::FloatPoint(locationInViewCoordinates));
}

#if ENABLE(DRAG_SUPPORT)
// HTML5 drag-and-drop for WKView. Safari 7 drives WebKit2 through WKView,
// whose input pipeline is written here rather than in WebViewImpl, so the drag source and
// destination are wired directly to WebPageProxy. Mirrors WebViewImpl, using the classic
// -[NSView dragImage:...] API (NSFilePromiseProvider / beginDraggingSession are 10.12+, already
// gated out of WebViewImpl::startDrag).

// map an NSDragOperation to a WebCore::DragOperation mask for the hand-written WKView drag pipeline (mirrors WebViewImpl).
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

// map a WebCore::DragOperation back to an NSDragOperation for the hand-written WKView drag pipeline.
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

// derive WebCore::DragApplicationFlags from AppKit state for the hand-written WKView drag destination.
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

// assemble a WebCore::DragData from an NSDraggingInfo for the hand-written WKView drag destination.
static WebCore::DragData wkDragDataFromInfo(NSView *view, id<NSDraggingInfo> info, WebKit::WebPageProxy& page)
{
    WebCore::IntPoint client([view convertPoint:info.draggingLocation fromView:nil]);
    NSPoint global = WebCore::globalPoint(info.draggingLocation, [view window]);
    return WebCore::DragData(info, client, WebCore::IntPoint(global), wkCoreDragOperationMask(info.draggingSourceOperationMask), wkDragApplicationFlags(view, info), WebCore::anyDragDestinationAction(), page.webPageIDInMainFrameProcess());
}

// NSDraggingDestination for WKView — drops route directly into WebPageProxy.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
    if (!_wkState || !_wkState->page)
        return NSDragOperationNone;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->resetCurrentDragInformation();
    _wkState->page->dragEntered(dragData, info.draggingPasteboard.name);
    return NSDragOperationCopy;
}

// NSDraggingDestination -draggingUpdated: for WKView — routes into WebPageProxy (drag op resolved in the body).
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info
{
    if (!_wkState || !_wkState->page)
        return NSDragOperationNone;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->dragUpdated(dragData, info.draggingPasteboard.name);
    // mirror WebViewImpl::draggingUpdated — report the page's current drag
    // operation, None while the async PerformDragControllerAction reply is still pending.
    return wkKitDragOperation(_wkState->page->currentDragOperation());
}

// NSDraggingDestination -draggingExited: for WKView — routes into WebPageProxy.
- (void)draggingExited:(id<NSDraggingInfo>)info
{
    if (!_wkState || !_wkState->page)
        return;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->dragExited(dragData);
    _wkState->page->resetCurrentDragInformation();
}

// NSDraggingDestination — always accept so AppKit proceeds to performDragOperation.
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
    return YES;
}

// NSDraggingDestination drop handler — route the drop into the page proxy.
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
    if (!_wkState || !_wkState->page)
        return NO;
    auto dragData = wkDragDataFromInfo(self, info, *_wkState->page);
    _wkState->page->performDragOperation(dragData, info.draggingPasteboard.name, { }, { });
    return YES;
}

// NSDraggingSource (classic informal protocol, paired with -dragImage:...).
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    // file-input drags advertise Copy only; otherwise allow the generic source operations.
    if (!isLocal || (_wkState && _wkState->page && _wkState->page->currentDragIsOverFileInput()))
        return NSDragOperationCopy;
    return NSDragOperationGeneric | NSDragOperationMove | NSDragOperationCopy;
}

// classic NSDraggingSource drag-ended callback that pairs with -dragImage:... (the 10.12+ session API is unused here).
- (void)draggedImage:(NSImage *)image endedAt:(NSPoint)screenPoint operation:(NSDragOperation)operation
{
    if (!_wkState || !_wkState->page)
        return;
    NSWindow *window = [self window];
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    NSPoint windowPoint = window ? [window convertScreenToBase:screenPoint] : screenPoint;
ALLOW_DEPRECATED_DECLARATIONS_END
    _wkState->page->dragEnded(WebCore::IntPoint(windowPoint), WebCore::IntPoint(WebCore::globalPoint(windowPoint, window)), wkCoreDragOperationMask(operation));
}

// Called by MavericksPageClient::startDrag once the drag image is ready.
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
    // dragLocationInContentCoordinates.)
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
    // start the OS drag via the classic -dragImage:... API (beginDraggingSession is 10.12+).
    [self dragImage:image at:windowPoint offset:NSZeroSize event:event pasteboard:pasteboard source:self slideBack:YES];
ALLOW_DEPRECATED_DECLARATIONS_END
}
#endif // ENABLE(DRAG_SUPPORT) — HTML5 drag source/destination wired up here for the WKView input path

// forward scroll-wheel NSEvents into the page.
- (void)scrollWheel:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super scrollWheel:event]; return; }
    WebKit::NativeWebWheelEvent webEvent(event, self);

    // give the two-finger back/forward swipe first refusal, exactly as
    // WebViewImpl::scrollWheel does — these are the wheel events that drive the swipe.
    if (_wkState->allowsBackForwardNavigationGestures) {
        if (auto *gestureController = [self _wkEnsureGestureController]) {
            if (gestureController->handleScrollWheelEvent(webEvent))
                return;
        }
    }

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
    [self _mavericksCollectKeypressCommands:event into:commands];
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

// run AppKit's key-binding translation for an event and collect what it
// produces, mirroring WebViewImpl::interpretKeyEvent on the WKWebView path (github #90).
//
// This runs for Cmd-modified events too. AppKit's StandardKeyBinding.dict deliberately contains no
// Cmd+X/C/V/Z — those are menu key equivalents, not key bindings — while it DOES bind Cmd+Delete to
// deleteToBeginningOfLine:, Cmd+Up/Down to moveToBeginningOfDocument:/moveToEndOfDocument:,
// Cmd+Left/Right to moveToLeftEndOfLine:/moveToRightEndOfLine: and their AndModifySelection:
// variants, alongside any user binding from ~/Library/KeyBindings/DefaultKeyBinding.dict.
- (void)_mavericksCollectKeypressCommands:(NSEvent *)event into:(WTF::Vector<WebCore::KeypressCommand>&)commands
{
    tlsCollectingCommands = &commands;
    [self interpretKeyEvents:@[event]];
    tlsCollectingCommands = nullptr;
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
    // WebViewImpl::eventKeyCodeIsZeroOrNumLockOrFn). A keyCode-0 flagsChanged — which virtual
    // keyboards (VMware) emit for bare modifier presses — maps to windows keyCode 65 ('A'), so a
    // bare Cmd press would reach the page as Cmd+A.
    unsigned short keyCode = [event keyCode];
    if (!keyCode || keyCode == 10 || keyCode == 63) { [super flagsChanged:event]; return; }
    WTF::Vector<WebCore::KeypressCommand> commands;
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

// give the page first crack at Cmd-modified key-downs before AppKit's menus
// (mirrors WebViewImpl::performKeyEquivalent; the Safari-7-era WKView has the same), so pages that
// implement their own shortcuts (Google Docs Cmd+Z undo/redo, etc.) see the key-down. Events the
// page leaves unhandled come back through MavericksPageClient::doneWithKeyEvent and are
// re-dispatched to AppKit (-_mavericksResendUnhandledKeyDownEvent:), so Safari's menu shortcuts
// still fire.
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
        // collect the event's key-binding commands here too (github #90).
        // AppKit sends performKeyEquivalent: before keyDown:, and this returns YES, so this is the
        // ONLY chance a Cmd-modified event gets to be translated — Cmd+Delete
        // (deleteToBeginningOfLine:) and the Cmd+arrow document/line movers are real key bindings.
        // Upstream's WebViewImpl::performKeyEquivalent likewise goes through interpretKeyEvent.
        WTF::Vector<WebCore::KeypressCommand> commands;
        [self _mavericksCollectKeypressCommands:event into:commands];
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        _wkState->page->handleKeyboardEvent(webEvent);
        return YES;
    }

    return [super performKeyEquivalent:event];
}

// called by MavericksPageClient::doneWithKeyEvent when the page leaves a
// key-down unhandled — re-dispatch it to AppKit so menu key equivalents (Cmd+T, Cmd+Z when the
// page doesn't intercept it, etc.) still fire after the page had first crack. Mirrors the
// m_keyDownEventBeingResent re-send in WebViewImpl::doneWithKeyEvent.
- (void)_mavericksResendUnhandledKeyDownEvent:(NSEvent *)event
{
    if (!_wkState || _wkState->keyDownEventBeingResent)
        return;
    RetainPtr<WKView> protector = self; // re-sending the event may destroy this view
    _wkState->keyDownEventBeingResent = event;
    [NSApp _setCurrentEvent:event];
    [NSApp sendEvent:event];
    _wkState->keyDownEventBeingResent = nil;
}

// Edit menu items dispatch action selectors to the first responder.
// Forward them to WebPageProxy::executeEditCommand, mirroring WebViewImpl's
// WEBCORE_COMMAND forwarding for the same selectors.
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
WKV_EDIT_ACTION(copy,            "Copy")
WKV_EDIT_ACTION(cut,             "Cut")
WKV_EDIT_ACTION(paste,           "Paste")
WKV_EDIT_ACTION(pasteAsPlainText,"PasteAsPlainText")
WKV_EDIT_ACTION(undo,            "Undo")
WKV_EDIT_ACTION(redo,            "Redo")
// Edit > Transformations. Upstream routes these through WebViewImpl's
// WEBCORE_COMMAND list; same executeEditCommand names.
WKV_EDIT_ACTION(uppercaseWord,   "UppercaseWord")
WKV_EDIT_ACTION(lowercaseWord,   "LowercaseWord")
WKV_EDIT_ACTION(capitalizeWord,  "CapitalizeWord")
#undef WKV_EDIT_ACTION

// automatic quote/dash substitution SPI, declared in WKViewPrivate.h and sent
// unguarded by Safari 7's substitutions plumbing. Ported from
// WebViewImpl::isAutomaticQuoteSubstitutionEnabled / setAutomaticQuoteSubstitutionEnabled /
// isAutomaticDashSubstitutionEnabled / setAutomaticDashSubstitutionEnabled: the flags live in the
// process-global TextChecker state (persisted to user defaults by TextCheckerMac), and a change is
// pushed to the WebContent process via WebProcessProxy::updateTextCheckerState.
- (BOOL)isAutomaticQuoteSubstitutionEnabled
{
    return TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled);
}

// see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::setAutomaticQuoteSubstitutionEnabled).
- (void)setAutomaticQuoteSubstitutionEnabled:(BOOL)flag
{
    if (static_cast<bool>(flag) == TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled))
        return;

    TextChecker::setAutomaticQuoteSubstitutionEnabled(flag);
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::isAutomaticDashSubstitutionEnabled).
- (BOOL)isAutomaticDashSubstitutionEnabled
{
    return TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled);
}

// see -isAutomaticQuoteSubstitutionEnabled above (ported from WebViewImpl::setAutomaticDashSubstitutionEnabled).
- (void)setAutomaticDashSubstitutionEnabled:(BOOL)flag
{
    if (static_cast<bool>(flag) == TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled))
        return;

    TextChecker::setAutomaticDashSubstitutionEnabled(flag);
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// Edit ▸ Substitutions menu actions for the quote/dash pair, ported from
// WebViewImpl::toggleAutomaticQuoteSubstitution / toggleAutomaticDashSubstitution (the
// Safari-537-era WKView ships the same responder actions). AppKit dispatches these down the
// responder chain from the menu items, which is what enables those items while the web view is
// first responder.
- (void)toggleAutomaticQuoteSubstitution:(id)sender
{
    TextChecker::setAutomaticQuoteSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// see -toggleAutomaticQuoteSubstitution: above (ported from WebViewImpl::toggleAutomaticDashSubstitution).
- (void)toggleAutomaticDashSubstitution:(id)sender
{
    TextChecker::setAutomaticDashSubstitutionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// pinch-to-zoom, double-tap smart zoom and the two-finger back/forward swipe.
// WKViewPrivate.h declares allowsMagnification, magnification, -setMagnification:centeredAtPoint:
// and allowsBackForwardNavigationGestures, and Safari sets them. Each method below is ported from
// its WebViewImpl counterpart; the work itself lives in ViewGestureController
// (UIProcess/mac/ViewGestureControllerMac.mm), which needs only a WebPageProxy.

// ported from WebViewImpl::ensureGestureController.
- (WebKit::ViewGestureController *)_wkEnsureGestureController
{
    if (!_wkState || !_wkState->page)
        return nullptr;
    if (!_wkState->gestureController)
        _wkState->gestureController = WebKit::ViewGestureController::create(*_wkState->page);
    return _wkState->gestureController.get();
}

// ported from WebViewImpl::setAllowsMagnification / allowsMagnification.
- (BOOL)allowsMagnification
{
    return _wkState && _wkState->allowsMagnification;
}

- (void)setAllowsMagnification:(BOOL)allowsMagnification
{
    if (_wkState)
        _wkState->allowsMagnification = allowsMagnification;
}

// ported from WebViewImpl::magnification -- the live gesture's scale while a pinch
// is in flight, otherwise the page scale factor.
- (double)magnification
{
    if (!_wkState || !_wkState->page)
        return 1;
    if (RefPtr gestureController = _wkState->gestureController)
        return gestureController->magnification();
    return _wkState->page->pageScaleFactor();
}

// ported from WebViewImpl::setMagnification(double, CGPoint).
- (void)setMagnification:(double)magnification centeredAtPoint:(NSPoint)point
{
    if (magnification <= 0 || std::isnan(magnification) || std::isinf(magnification))
        [NSException raise:NSInvalidArgumentException format:@"Magnification should be a positive number"];

    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->scalePageInViewCoordinates(magnification, WebCore::roundedIntPoint(WebCore::FloatPoint(point)));
}

// ported from WebViewImpl::setMagnification(double) -- centres on the view.
- (void)setMagnification:(double)magnification
{
    if (magnification <= 0 || std::isnan(magnification) || std::isinf(magnification))
        [NSException raise:NSInvalidArgumentException format:@"Magnification should be a positive number"];

    if (!_wkState || !_wkState->page)
        return;
    WebCore::FloatPoint viewCenter(NSMidX([self bounds]), NSMidY([self bounds]));
    _wkState->page->scalePageInViewCoordinates(magnification, WebCore::roundedIntPoint(viewCenter));
}

// ported from WebViewImpl::setAllowsBackForwardNavigationGestures -- the swipe needs
// navigation snapshots recorded and implicit rubber-band control to detect the pinned edge.
- (BOOL)allowsBackForwardNavigationGestures
{
    return _wkState && _wkState->allowsBackForwardNavigationGestures;
}

- (void)setAllowsBackForwardNavigationGestures:(BOOL)allowsBackForwardNavigationGestures
{
    if (!_wkState || !_wkState->page)
        return;
    _wkState->allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures;
    _wkState->page->setShouldRecordNavigationSnapshots(allowsBackForwardNavigationGestures);
    _wkState->page->setShouldUseImplicitRubberBandControl(allowsBackForwardNavigationGestures);
}

// ported from WebViewImpl::magnifyWithEvent. ENABLE(MAC_GESTURE_EVENTS) is off for
// this port, so this is upstream's #else branch: hand the pinch straight to the gesture controller.
- (void)magnifyWithEvent:(NSEvent *)event
{
    if (![self allowsMagnification]) {
        [super magnifyWithEvent:event];
        return;
    }

    if (auto *gestureController = [self _wkEnsureGestureController])
        gestureController->handleMagnificationGestureEvent(event, [self convertPoint:[event locationInWindow] fromView:nil]);
}

// ported from WebViewImpl::smartMagnifyWithEvent (double-tap / two-finger
// double-tap zoom-to-element).
- (void)smartMagnifyWithEvent:(NSEvent *)event
{
    if (![self allowsMagnification]) {
        [super smartMagnifyWithEvent:event];
        return;
    }

    if (auto *gestureController = [self _wkEnsureGestureController])
        gestureController->handleSmartMagnificationGesture([self convertPoint:[event locationInWindow] fromView:nil]);
}

// promised-file drags — dragging an image out of a page onto the Finder or the
// Desktop to save it. WebCore offers the image as a "promise": the page puts a promise type on the
// drag pasteboard, and the destination asks for the actual bytes only once the drop happens.
//
// Ported from WebViewImpl::setPromisedDataForImage / provideDataForPasteboard /
// namesOfPromisedFilesDroppedAtDestination, using the classic promised-file API. NSFilePromiseProvider
// (the modern replacement, and what upstream reaches for first) is 10.12+, while its 10.9-era
// predecessor -namesOfPromisedFilesDroppedAtDestination: is present and is what the rest of this drag
// pipeline uses — the drag source here is the classic -[NSView dragImage:...] path for the same reason.

// does not overwrite an existing file; appends -1, -2, ... like WebViewImpl's
// pathWithUniqueFilenameForPath.
static RetainPtr<NSString> wkUniquePathForPath(NSString *path)
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return path;

    RetainPtr lastComponent = [path lastPathComponent];
    RetainPtr extension = [lastComponent pathExtension];
    RetainPtr stem = [retainPtr([path stringByDeletingLastPathComponent])
        stringByAppendingPathComponent:retainPtr([lastComponent stringByDeletingPathExtension]).get()];

    for (unsigned i = 1; ; ++i) {
        RetainPtr candidate = adoptNS([[NSString alloc] initWithFormat:@"%@-%u", stem.get(), i]);
        RetainPtr full = [extension length] ? [candidate stringByAppendingPathExtension:extension.get()] : candidate.get();
        if (![[NSFileManager defaultManager] fileExistsAtPath:full.get()])
            return full;
    }
}

// called from MavericksPageClient::setPromisedDataForImage. Puts the promise type on
// the drag pasteboard (with this view as owner, so -pasteboard:provideDataForType: is asked for the
// bytes lazily) and remembers what was promised.
- (void)_wkSetPromisedImageData:(NSData *)imageData
                            uti:(NSString *)uti
                       filename:(NSString *)filename
                            url:(NSString *)url
                  archiveBuffer:(NSData *)archiveData
                 pasteboardName:(NSString *)pasteboardName
{
    if (!_wkState)
        return;

    _wkState->promisedImageData = imageData;
    _wkState->promisedArchiveData = archiveData;
    _wkState->promisedImageUTI = uti;
    _wkState->promisedFilename = filename;
    _wkState->promisedURL = url;

    RetainPtr pasteboard = [NSPasteboard pasteboardWithName:pasteboardName];
    RetainPtr types = adoptNS([[NSMutableArray alloc] initWithObjects:WebCore::legacyFilesPromisePasteboardTypeSingleton(), nil]);
    if ([uti length] && [imageData length])
        [types addObject:uti];
    [types addObjectsFromArray:(archiveData ? WebKit::PasteboardTypes::forImagesWithArchiveSingleton() : WebKit::PasteboardTypes::forImagesSingleton())];

    [pasteboard clearContents];
    [pasteboard addTypes:types.get() owner:self];

    // The promise itself: the extension the destination should expect.
    [pasteboard setPropertyList:@[ retainPtr([filename pathExtension]).get() ]
                        forType:WebCore::legacyFilesPromisePasteboardTypeSingleton()];

    if (archiveData) {
        [pasteboard setData:archiveData forType:WebKit::PasteboardTypes::WebArchivePboardType];
        [pasteboard setData:archiveData forType:(__bridge NSString *)kUTTypeWebArchive];
    }
}

// NSPasteboardOwner -- supply the promised bytes when the destination asks.
// Ported from WebViewImpl::provideDataForPasteboard.
- (void)pasteboard:(NSPasteboard *)pasteboard provideDataForType:(NSString *)type
{
    if (!_wkState || !_wkState->promisedImageData)
        return;

    if (_wkState->promisedImageUTI && [type isEqualToString:_wkState->promisedImageUTI.get()]) {
        [pasteboard setData:_wkState->promisedImageData.get() forType:type];
        return;
    }

    if ([type isEqualToString:WebCore::legacyTIFFPasteboardTypeSingleton()]) {
        RetainPtr image = adoptNS([[NSImage alloc] initWithData:_wkState->promisedImageData.get()]);
        if (RetainPtr tiff = [image TIFFRepresentation])
            [pasteboard setData:tiff.get() forType:WebCore::legacyTIFFPasteboardTypeSingleton()];
    }
}

// NSPasteboardOwner -- another owner took the pasteboard; drop what we promised so
// we cannot serve stale bytes. Ported from WebViewImpl::pasteboardChangedOwner.
- (void)pasteboardChangedOwner:(NSPasteboard *)pasteboard
{
    if (!_wkState)
        return;
    _wkState->promisedImageData = nil;
    _wkState->promisedArchiveData = nil;
    _wkState->promisedImageUTI = nil;
    _wkState->promisedFilename = nil;
    _wkState->promisedURL = nil;
}

// the drop landed -- write the promised image into the destination directory and
// return the filename. Ported from WebViewImpl::namesOfPromisedFilesDroppedAtDestination.
- (NSArray *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
{
    if (!_wkState)
        return nil;

    RetainPtr<NSFileWrapper> wrapper;
    if (_wkState->promisedImageData)
        wrapper = adoptNS([[NSFileWrapper alloc] initRegularFileWithContents:_wkState->promisedImageData.get()]);
    else if ([_wkState->promisedURL length]) {
        RetainPtr url = adoptNS([[NSURL alloc] initWithString:_wkState->promisedURL.get()]);
        wrapper = adoptNS([[NSFileWrapper alloc] initWithURL:url.get() options:NSFileWrapperReadingImmediate error:nil]);
    }

    if (!wrapper) {
        LOG_ERROR("Failed to create image file.");
        return nil;
    }

    if ([_wkState->promisedFilename length])
        [wrapper setPreferredFilename:_wkState->promisedFilename.get()];

    RetainPtr path = [retainPtr([dropDestination path]) stringByAppendingPathComponent:retainPtr([wrapper preferredFilename]).get()];
    path = wkUniquePathForPath(path.get());

    if (![wrapper writeToURL:[NSURL fileURLWithPath:path.get() isDirectory:NO]
                     options:NSFileWrapperWritingWithNameUpdating
         originalContentsURL:nil
                       error:nullptr]) {
        LOG_ERROR("Failed to write the promised image file.");
        return nil;
    }

    // Tag the saved file with where it came from, matching WebViewImpl.
    if ([_wkState->promisedURL length])
        FileSystem::setMetadataURL(String(path.get()), String(_wkState->promisedURL.get()));

    return @[retainPtr([path lastPathComponent]).get()];
}

// Edit > Spelling and Grammar, and Edit > Speech. Safari 7 dispatches these
// action selectors down the responder chain to the web view, which is what enables the submenu
// while the web view is first responder; the Safari-537-era WKView implements them all. Each is
// ported from the WebViewImpl method of the same name — they depend only on the process-global
// TextChecker state and on WebPageProxy, both of which this view has.

// ported from WebViewImpl::showGuessPanel.
- (void)showGuessPanel:(id)sender
{
    RetainPtr checker = [NSSpellChecker sharedSpellChecker];
    if (!checker) {
        LOG_ERROR("No NSSpellChecker");
        return;
    }

    RetainPtr spellingPanel = [checker spellingPanel];
    if ([spellingPanel isVisible]) {
        [spellingPanel orderOut:sender];
        return;
    }

    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->advanceToNextMisspelling(true);
    [spellingPanel orderFront:sender];
}

// ported from WebViewImpl::checkSpelling.
- (void)checkSpelling:(id)sender
{
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->advanceToNextMisspelling(false);
}

// ported from WebViewImpl::changeSpelling -- the guess panel sends the chosen
// replacement as the sender's selected cell.
- (void)changeSpelling:(id)sender
{
    if (!_wkState || !_wkState->page)
        return;
    RetainPtr word = [[sender selectedCell] stringValue];
    _wkState->page->changeSpellingToWord(word.get());
}

// ported from WebViewImpl::toggleContinuousSpellChecking.
- (void)toggleContinuousSpellChecking:(id)sender
{
    TextChecker::setContinuousSpellCheckingEnabled(!TextChecker::state().contains(TextCheckerState::ContinuousSpellCheckingEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleGrammarChecking.
- (void)toggleGrammarChecking:(id)sender
{
    TextChecker::setGrammarCheckingEnabled(!TextChecker::state().contains(TextCheckerState::GrammarCheckingEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleAutomaticSpellingCorrection.
- (void)toggleAutomaticSpellingCorrection:(id)sender
{
    TextChecker::setAutomaticSpellingCorrectionEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticSpellingCorrectionEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleAutomaticTextReplacement.
- (void)toggleAutomaticTextReplacement:(id)sender
{
    TextChecker::setAutomaticTextReplacementEnabled(!TextChecker::state().contains(TextCheckerState::AutomaticTextReplacementEnabled));
    if (_wkState && _wkState->page)
        protect(_wkState->page->legacyMainFrameProcess())->updateTextCheckerState();
}

// ported from WebViewImpl::toggleSmartInsertDelete -- this one is page state,
// not TextChecker state, so it needs no updateTextCheckerState push.
- (void)toggleSmartInsertDelete:(id)sender
{
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->setSmartInsertDeleteEnabled(!_wkState->page->isSmartInsertDeleteEnabled());
}

// ported from WebViewImpl::orderFrontSubstitutionsPanel.
- (void)orderFrontSubstitutionsPanel:(id)sender
{
    RetainPtr checker = [NSSpellChecker sharedSpellChecker];
    if (!checker) {
        LOG_ERROR("No NSSpellChecker");
        return;
    }

    RetainPtr substitutionsPanel = [checker substitutionsPanel];
    if ([substitutionsPanel isVisible]) {
        [substitutionsPanel orderOut:sender];
        return;
    }
    [substitutionsPanel orderFront:sender];
}

// ported from WebViewImpl::startSpeaking -- the selection (or, with no selection,
// the whole document) is fetched asynchronously and handed to NSApplication's speech synthesis.
- (void)startSpeaking:(id)sender
{
    if (!_wkState || !_wkState->page)
        return;
    _wkState->page->getSelectionOrContentsAsString([](const WTF::String& string) {
        if (!string)
            return;
        [NSApp speakString:string.createNSString().get()];
    });
}

// ported from WebViewImpl::stopSpeaking.
- (void)stopSpeaking:(id)sender
{
    [NSApp stopSpeaking:sender];
}

// NSMenuItem downcast for -validateUserInterfaceItem: (the Safari-537-era
// WKView.mm static menuItem() helper). Toolbar items validate through the same protocol and must
// not be sent NSMenuItem messages, so anything else answers nil.
static NSMenuItem *wkMenuItem(id <NSValidatedUserInterfaceItem> item)
{
    if (![(NSObject *)item isKindOfClass:[NSMenuItem class]])
        return nil;
    return (NSMenuItem *)item;
}

// menu validation for the Substitutions toggles, ported from the
// Safari-537-era -[WKView validateUserInterfaceItem:] cases (checkbox state from the TextChecker
// flag; enabled only over editable content, matching WebViewImpl). Every other action falls
// through to YES, which is what AppKit's responds-to-selector default validation gives this
// WKView's remaining menu actions (copy:/cut:/paste:/undo:/redo:/selectAll:).
- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)item
{
    SEL action = [item action];

    // validate the Automatic Quote Substitution toggle: checkbox from the TextChecker flag, enabled only over editable content.
    if (action == @selector(toggleAutomaticQuoteSubstitution:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticQuoteSubstitutionEnabled);
        [wkMenuItem(item) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState && _wkState->page && _wkState->page->editorState().isContentEditable;
    }

    // validate the Automatic Dash Substitution toggle: checkbox from the TextChecker flag, enabled only over editable content.
    if (action == @selector(toggleAutomaticDashSubstitution:)) {
        bool checked = TextChecker::state().contains(TextCheckerState::AutomaticDashSubstitutionEnabled);
        [wkMenuItem(item) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState && _wkState->page && _wkState->page->editorState().isContentEditable;
    }

    // the Spelling and Grammar / Substitutions toggles above show a checkmark
    // for their current state. Each reads the same flag its action writes.
    struct { SEL action; TextCheckerState flag; } checkedToggles[] = {
        { @selector(toggleContinuousSpellChecking:),   TextCheckerState::ContinuousSpellCheckingEnabled },
        { @selector(toggleGrammarChecking:),           TextCheckerState::GrammarCheckingEnabled },
        { @selector(toggleAutomaticSpellingCorrection:), TextCheckerState::AutomaticSpellingCorrectionEnabled },
        { @selector(toggleAutomaticTextReplacement:),  TextCheckerState::AutomaticTextReplacementEnabled },
    };
    for (auto& toggle : checkedToggles) {
        if (action != toggle.action)
            continue;
        [wkMenuItem(item) setState:TextChecker::state().contains(toggle.flag) ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState && _wkState->page && _wkState->page->editorState().isContentEditable;
    }

    // smart insert/delete is page state rather than TextChecker state.
    if (action == @selector(toggleSmartInsertDelete:)) {
        bool checked = _wkState && _wkState->page && _wkState->page->isSmartInsertDeleteEnabled();
        [wkMenuItem(item) setState:checked ? NSControlStateValueOn : NSControlStateValueOff];
        return _wkState && _wkState->page && _wkState->page->editorState().isContentEditable;
    }

    // the spelling actions and the case transformations only apply to editable
    // content; the panels and Speech apply whenever there is a page.
    if (action == @selector(checkSpelling:) || action == @selector(changeSpelling:)
        || action == @selector(uppercaseWord:) || action == @selector(lowercaseWord:)
        || action == @selector(capitalizeWord:))
        return _wkState && _wkState->page && _wkState->page->editorState().isContentEditable;

    if (action == @selector(showGuessPanel:) || action == @selector(orderFrontSubstitutionsPanel:)
        || action == @selector(startSpeaking:) || action == @selector(stopSpeaking:))
        return _wkState && _wkState->page;

    return YES;
}

@end
// upstream WKView.mm ends with the lines below. This reimplementation opens no
// ALLOW_DEPRECATED_DECLARATIONS block and no PLATFORM(MAC) guard, so they are kept commented out
// for upstream merges.
// ALLOW_DEPRECATED_DECLARATIONS_END
//
// #endif // PLATFORM(MAC)
