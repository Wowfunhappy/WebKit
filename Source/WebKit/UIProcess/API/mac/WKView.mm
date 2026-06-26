// WKView implementation for macOS 10.9 backport
#import <objc/runtime.h>
// Creates a WebPageProxy when Safari's BrowserWKView initializes

#import "config.h"
#import "WKView.h"

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
#import "WebUserContentControllerProxy.h"
#import "WebKit2Initialize.h"
#import "DrawingAreaProxy.h"
#import "WKPrintingView.h"
#import "WebFrameProxy.h"
// 10.9 backport: legacy ObjC group/controller classes that QuickLook's
// Web2.qldisplay drives through WKView.
#import "WKBrowsingContextControllerInternal.h"
#import "WKProcessGroupInternal.h"
#import "WKBrowsingContextGroupInternal.h"
#import <WebCore/ActivityState.h>
#import <WebCore/ColorCocoa.h>
#import <WebCore/IntSize.h>
#import <WebCore/KeypressCommand.h>
#import <QuartzCore/QuartzCore.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>
#if ENABLE(DRAG_SUPPORT)
#import "PasteboardTypes.h"
#import "SandboxExtension.h"
#import <WebCore/DragData.h>
#import <WebCore/DragActions.h>
#import <WebCore/PlatformEventFactoryMac.h>
#import <wtf/Compiler.h>
#endif

using namespace WebKit;

// 10.9 backport: NSViewNoIntrinsicMetric is an APPKIT_EXTERN const symbol available
// only on macOS 10.11+ — it is NOT exported by 10.9's AppKit, so referencing it
// null-binds and dereferencing it crashes (EXC_BAD_ACCESS). Use its documented
// value (-1) directly. See [[webkit-mavericks-moved-framework-symbols]].
static const CGFloat kWKViewNoIntrinsicMetric = -1;

// Declared in PageClientImplMac.mm
namespace WebKit {
std::unique_ptr<PageClient> createMinimalPageClient(NSView *view);
void setMinimalPageClientPage(PageClient&, WebPageProxy *);
void setMinimalPageClientForceVisibleWhenWindowless(PageClient&, bool);
}

// Per-WKView state. RefPtr<WebPageProxy> keeps the page alive for the
// lifetime of the view; std::unique_ptr<PageClient> owns the page client.
struct WKViewState {
    RefPtr<WebKit::WebPageProxy> page;
    std::unique_ptr<WebKit::PageClient> pageClient;
#if ENABLE(DRAG_SUPPORT)
    // 10.9 backport: the originating mouse-down event, needed by the classic
    // -[NSView dragImage:...event:...] API to start an HTML5 drag session.
    RetainPtr<NSEvent> lastMouseDownEvent;
#endif
};

@interface WKView () {
    WKViewState *_wkState;
    WKBrowsingContextController *_browsingContextController;
    // 10.9 backport: cached intrinsic content size for the auto-layout SPI Mail's
    // MUIWKView drives (the web process reports the laid-out content size back via
    // MinimalPageClient::intrinsicContentSizeDidChange -> -_setIntrinsicContentSize:).
    NSSize _intrinsicContentSize;
}
@end

@implementation WKView

- (instancetype)initWithFrame:(NSRect)frame processPool:(std::reference_wrapper<WebKit::WebProcessPool>)processPool configuration:(Ref<API::PageConfiguration>&&)configuration
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    [self setWantsLayer:YES];
    self.layer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);

    _intrinsicContentSize = NSMakeSize(kWKViewNoIntrinsicMetric, kWKViewNoIntrinsicMetric);

    WebKit::InitializeWebKit2();

    _wkState = new WKViewState;
    _wkState->pageClient = createMinimalPageClient(self);
    _wkState->page = processPool.get().createWebPage(*_wkState->pageClient, WTF::move(configuration));
    setMinimalPageClientPage(*_wkState->pageClient, _wkState->page.get());
    // 10.9 backport: a WKView born with a real (non-zero) frame is an offscreen render
    // view — Safari's Top Sites snapshot fetcher allocs a WKView at the snapshot size,
    // loads a URL into it, and snapshots it WITHOUT ever adding it to a window or
    // resizing it. Normal browser tab WKViews are created at 0x0 and later attached to
    // a window + resized, which is what drives visibility and drawing-area sizing. Mark
    // this windowless view as force-visible so its WebContent takes a foreground
    // assertion and actually loads/lays-out/paints; without this the page is treated as
    // an offscreen hidden tab and never renders, so the snapshot stays a dark placeholder.
    if (frame.size.width > 0 && frame.size.height > 0)
        setMinimalPageClientForceVisibleWhenWindowless(*_wkState->pageClient, true);

    _wkState->page->initializeWebPage(WebCore::Site(WTF::HashTableEmptyValue), WebCore::SandboxFlags {}, WebCore::ReferrerPolicy::Default);

#if ENABLE(DRAG_SUPPORT)
    // 10.9 backport: become an NSDraggingDestination so drops route into the page.
    auto dragTypes = adoptNS([[NSMutableSet alloc] initWithArray:WebKit::PasteboardTypes::forEditingSingleton()]);
    [dragTypes addObjectsFromArray:WebKit::PasteboardTypes::forURLSingleton()];
    [dragTypes addObject:WebKit::PasteboardTypes::WebDummyPboardType];
    [self registerForDraggedTypes:[dragTypes allObjects]];
#endif

    return self;
}

- (void)dealloc
{
    [_browsingContextController release];
    _browsingContextController = nil;
    delete _wkState;
    _wkState = nullptr;
    [super dealloc];
}

// 10.9 backport: WKView auto-layout / intrinsic-content-size SPI. Mail's message
// viewer (MUIWKView) drives the message view through this: it enables auto-sizing
// with -setMinimumSizeForAutoLayout:, and the web process reports the laid-out
// content height back so the view sizes to fit the message inside Mail's scroll
// view. Without it the message body renders blank. Ported from WebViewImpl.
- (NSSize)intrinsicContentSize
{
    return _intrinsicContentSize;
}

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

- (NSSize)minimumSizeForAutoLayout
{
    if (!_wkState || !_wkState->page)
        return NSZeroSize;
    auto size = _wkState->page->minimumSizeForAutoLayout();
    return NSMakeSize(size.width(), size.height());
}

- (void)setShouldExpandToViewHeightForAutoLayout:(BOOL)shouldExpand
{
    if (_wkState && _wkState->page)
        _wkState->page->setAutoSizingShouldExpandToViewHeight(shouldExpand);
}

- (BOOL)shouldExpandToViewHeightForAutoLayout
{
    return _wkState && _wkState->page ? _wkState->page->autoSizingShouldExpandToViewHeight() : NO;
}

// Called by MinimalPageClient::intrinsicContentSizeDidChange when the web process
// reports a new laid-out content size.
- (void)_setIntrinsicContentSize:(NSSize)intrinsicContentSize
{
    // If the content's intrinsic width is less than the minimum layout width, the
    // content flowed to fit, so report the width as flexible (no intrinsic metric);
    // otherwise report it so auto-layout reserves space. Matches WebViewImpl.
    NSSize size = intrinsicContentSize;
    if (_wkState && _wkState->page && intrinsicContentSize.width < _wkState->page->minimumSizeForAutoLayout().width())
        size.width = kWKViewNoIntrinsicMetric;
    _intrinsicContentSize = size;
    [self invalidateIntrinsicContentSize];
}

- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef
{
    return [self initWithFrame:frame contextRef:contextRef pageGroupRef:pageGroupRef relatedToPage:nil];
}

- (id)initWithFrame:(NSRect)frame contextRef:(WKContextRef)contextRef pageGroupRef:(WKPageGroupRef)pageGroupRef relatedToPage:(WKPageRef)relatedPage
{
    auto configuration = API::PageConfiguration::create();
    configuration->setProcessPool(WebKit::toImpl(contextRef));
    // 10.9 backport: honor the page group Safari passes — its identifier is
    // how the injected bundle scopes extension content scripts
    // (WKBundleAddUserScript), and its preferences carry Safari's settings.
    if (pageGroupRef) {
        RefPtr<WebKit::WebPageGroup> pageGroup = WebKit::toImpl(pageGroupRef);
        configuration->setPreferences(&pageGroup->preferences());
        // 10.9 backport: share the page group's user content controller so user
        // scripts/style sheets installed on the group (WKPageGroupAddUserScript /
        // AddUserStyleSheet, e.g. via Mail's WKBrowsingContextGroup) are injected
        // into this page. Without this the page would get a fresh empty controller.
        configuration->setUserContentController(&pageGroup->userContentController());
        configuration->setPageGroup(WTF::move(pageGroup));
    }

    return [self initWithFrame:frame processPool:*WebKit::toImpl(contextRef) configuration:WTF::move(configuration)];
}

- (id)initWithFrame:(NSRect)frame configurationRef:(WKPageConfigurationRef)configurationRef { return nil; }
- (WKPageRef)pageRef { return _wkState ? WebKit::toAPI(_wkState->page.get()) : nullptr; }

// 10.9 backport: legacy initializer used by QuickLook's Web2.qldisplay. It hands
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

// 10.9 backport: vend a controller bound to this view's page so Web2.qldisplay
// can load/observe via the controller (or pull its pageRef for the C SPI).
- (WKBrowsingContextController *)browsingContextController
{
    if (!_browsingContextController && _wkState && _wkState->page)
        _browsingContextController = [[WKBrowsingContextController alloc] _initWithPageRef:WebKit::toAPI(_wkState->page.get())];
    return _browsingContextController;
}

// 10.9 backport: WKView's normal setFrameSize: propagates the new viewport size to
// WebContent via WebPageProxy::setSize. Without this override, WebContent renders at
// 0x0 — Safari creates WKViews with zero frame and resizes them later.
- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    if (_wkState && _wkState->page) {
        // 10.9 backport: if drawingArea is null, the WKView was created before WebContent
        // was running. Re-attempt initializeWebPage now that the process should be alive.
        if (!_wkState->page->drawingArea())
            _wkState->page->initializeWebPage(WebCore::Site(WTF::HashTableEmptyValue), WebCore::SandboxFlags {}, WebCore::ReferrerPolicy::Default);
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(newSize.width, newSize.height));
    }
    // 10.9 backport: the WebContent's hosted layer is added as a sublayer of our backing
    // layer by MinimalPageClient::enterAcceleratedCompositingMode, framed to the view's
    // bounds AT THAT TIME. It is not re-framed on resize, so a view that composites while
    // small (e.g. Mail's message view before its auto-layout height arrives) stays clipped
    // to that initial size and shows blank. Keep the hosted sublayer matched to our bounds.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *sublayer in [[self layer] sublayers])
        [sublayer setFrame:[self bounds]];
    [CATransaction commit];
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    if (_wkState && _wkState->page) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(frame.size.width, frame.size.height));
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
    if (_wkState && _wkState->page)
        _wkState->page->setUnderlayColor(WebCore::colorFromCocoaColor(underlayColor));
}

- (NSColor *)underlayColor
{
    if (_wkState && _wkState->page)
        return WebCore::cocoaColorOrNil(_wkState->page->underlayColor()).autorelease();
    return nil;
}
// NSTextInputClient minimal stubs — Safari crashes with validAttributesForMarkedText
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
    NSString *s = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
    if (!s)
        return;
    if (tlsCollectingCommands)
        tlsCollectingCommands->append(WebCore::KeypressCommand("insertText:"_s, String(s)));
}
- (NSRange)markedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {}
- (void)unmarkText {}
- (void)doCommandBySelector:(SEL)selector
{
    if (!tlsCollectingCommands)
        return;
    tlsCollectingCommands->append(WebCore::KeypressCommand(String::fromLatin1(sel_getName(selector))));
}
- (BOOL)conformsToProtocol:(Protocol *)protocol
{
    if (protocol == @protocol(NSTextInputClient)) return YES;
    return [super conformsToProtocol:protocol];
}
- (BOOL)wantsUpdateLayer { return NO; }
- (NSView *)fullScreenPlaceholderView { return nil; }
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
// 10.9 backport: actually apply the frame. Safari calls this on its WKView
// (treated as "viewBelowBanner") during Banner._moveBannerIntoPlace: to shrink
// the web view by banner.height so that the banner can occupy that vacated
// area. The empty stub left WKView at full container height, and Safari then
// positioned the banner ABOVE the unchanged WKView — outside the container's
// clipping bounds, making the banner invisible.
- (void)setFrame:(NSRect)r andScrollBy:(NSSize)o
{
    [super setFrame:r];
    (void)o;
}
- (void)disableFrameSizeUpdates {}
- (void)enableFrameSizeUpdates {}
- (BOOL)frameSizeUpdatesDisabled { return NO; }
+ (void)hideWordDefinitionWindow {}

// 10.9 backport: forward NSEvents to WebPageProxy. The full WebViewImpl.mm input
// pipeline is stubbed out in this build, so add a minimal mouseDown/Up/Moved/Dragged,
// scrollWheel, and keyDown/Up forwarding here so links/forms/scrolling become interactive.
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

// 10.9 backport (#138): notify the page when this view gains/loses first-responder status so the
// WebContent's ActivityState::IsFocused flag tracks focus. Without it the page's FocusController is
// never marked focused, so FrameSelection::isFocusedAndActive() stays false and WebCore suppresses the
// text-insertion caret (and active selection highlight) even though typing works. Matches WebViewImpl,
// which fires activityStateDidChange(IsFocused) on become/resignFirstResponder. activityStateDidChange
// defers the recompute, so by the time it re-queries -isViewFocused the window firstResponder has settled.
- (BOOL)becomeFirstResponder
{
    BOOL result = [super becomeFirstResponder];
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return result;
}

- (BOOL)resignFirstResponder
{
    if (_wkState && _wkState->page)
        _wkState->page->activityStateDidChange(WebCore::ActivityState::IsFocused);
    return [super resignFirstResponder];
}

// 10.9 backport: tell WebPageProxy when this view's window membership changes.
// Without this, Safari's tab swap (which removes the inactive tab's WKView from
// the window and re-adds it on switch-back) leaves the WebPage with a stale
// activity-state and the visible content blank. Calling activityStateDidChange
// triggers a WebPage::SetActivityState IPC which kicks WebContent to send a
// fresh layer-tree commit, restoring the visible content.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // 10.9 backport: the cursor only changes on hover (and CSS :hover fires) when
    // WebContent receives mouseMoved events to hit-test under the pointer. The
    // WindowServer suppresses mouseMoved unless the hosting window opts in. Stock
    // WKWebView gets them via an NSTrackingArea; here -mouseMoved: is delivered by
    // AppKit's normal responder chain (the WKView is the hit-test target), but only
    // if the window emits mouseMoved at all — so opt the window in. Without this,
    // setCursor IPC never fires and the pointer stays a plain arrow over links/text (#17).
    if (NSWindow *window = [self window])
        [window setAcceptsMouseMovedEvents:YES];
    if (!_wkState || !_wkState->page) return;
    OptionSet<WebCore::ActivityState> flags;
    flags.add(WebCore::ActivityState::IsInWindow);
    flags.add(WebCore::ActivityState::IsVisible);
    flags.add(WebCore::ActivityState::IsVisibleOrOccluded);
    flags.add(WebCore::ActivityState::WindowIsActive);
    flags.add(WebCore::ActivityState::IsFocused);
    _wkState->page->activityStateDidChange(flags);
}

// 10.9 backport: the WebContent layer tree is hosted as a plain CALayer SUBLAYER of
// WKView's own backing layer (see MinimalPageClient::enterAcceleratedCompositingMode /
// setRemoteLayerTreeRootNode — [[m_view layer] addSublayer:]). CALayers do NOT participate
// in NSView -hitTest:, and WKView mounts no NSView subviews of its own, so AppKit's normal
// hit-testing already lands directly on the WKView and the mouse/scroll/key NSResponder
// overrides below fire naturally via -[NSWindow sendEvent:]. This is the same arrangement
// upstream uses on macOS, except upstream hosts the remote layer on a dedicated WKFlippedView
// subview and so must redirect a hit on that subview back to the main view
// (WebViewImpl::hitTest). We have no such subview, but keep that redirect as cheap, upstream-
// equivalent insurance in case any descendant view is ever inserted: a hit on self or a
// descendant resolves to self so the responder-chain forwarding stays correct.
- (NSView *)hitTest:(NSPoint)point
{
    NSView *result = [super hitTest:point];
    if (!result)
        return nil;
    if (result == self || [result isDescendantOf:self])
        return self;
    return result;
}

#define WKV_FORWARD_MOUSE(SEL_NAME) \
- (void)SEL_NAME:(NSEvent *)event \
{ \
    if (!_wkState || !_wkState->page) { [super SEL_NAME:event]; return; } \
    WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebMouseEventInputSource::UserDriven); \
    _wkState->page->handleMouseEvent(webEvent); \
}

// 10.9 backport: mouseDown is explicit (not via the macro) so it can retain the
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
WKV_FORWARD_MOUSE(mouseMoved)
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

#if ENABLE(DRAG_SUPPORT)
// 10.9 backport: HTML5 drag-and-drop for WKView. Safari 7 drives WebKit2 through
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
    // 10.9 backport: currentDragOperation is set by an async IPC reply to
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

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
    return YES;
}

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
    if (!isLocal || (_wkState && _wkState->page && _wkState->page->currentDragIsOverFileInput()))
        return NSDragOperationCopy;
    return NSDragOperationGeneric | NSDragOperationMove | NSDragOperationCopy;
}

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
    [self dragImage:image at:windowPoint offset:NSZeroSize event:event pasteboard:pasteboard source:self slideBack:YES];
ALLOW_DEPRECATED_DECLARATIONS_END
}
#endif // ENABLE(DRAG_SUPPORT)

- (void)scrollWheel:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super scrollWheel:event]; return; }
    WebKit::NativeWebWheelEvent webEvent(event, self);
    _wkState->page->handleNativeWheelEvent(webEvent);
}

- (void)keyDown:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super keyDown:event]; return; }
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
    WTF::Vector<WebCore::KeypressCommand> commands;
    WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
    _wkState->page->handleKeyboardEvent(webEvent);
}

// 10.9 backport: Edit menu items dispatch action selectors to first responder.
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
// 10.9 backport: implementing copy:/cut: PROTECTS against Safari's default
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

@end
