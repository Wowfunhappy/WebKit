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
#import "WebKit2Initialize.h"
#import "DrawingAreaProxy.h"
// 10.9 backport: legacy ObjC group/controller classes that QuickLook's
// Web2.qldisplay drives through WKView.
#import "WKBrowsingContextControllerInternal.h"
#import "WKProcessGroupInternal.h"
#import "WKBrowsingContextGroupInternal.h"
#import <WebCore/ActivityState.h>
#import <WebCore/IntSize.h>
#import <WebCore/KeypressCommand.h>
#import <QuartzCore/QuartzCore.h>
#import <wtf/RetainPtr.h>
#import <wtf/Vector.h>

using namespace WebKit;

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
};

@interface WKView () {
    WKViewState *_wkState;
    WKBrowsingContextController *_browsingContextController;
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
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    if (_wkState && _wkState->page) {
        if (RefPtr drawingArea = _wkState->page->drawingArea())
            drawingArea->setSize(WebCore::IntSize(frame.size.width, frame.size.height));
    }
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
- (NSPrintOperation *)printOperationWithPrintInfo:(NSPrintInfo *)pi forFrame:(WKFrameRef)f { return nil; }
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
- (BOOL)becomeFirstResponder { return [super becomeFirstResponder]; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

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
    @try {
        _wkState->page->activityStateDidChange(flags);
    } @catch (NSException *) { }
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
    @try { \
        WebKit::NativeWebMouseEvent webEvent(event, nil, self, WebKit::WebMouseEventInputSource::UserDriven); \
        _wkState->page->handleMouseEvent(webEvent); \
    } @catch (NSException *) { } \
}

WKV_FORWARD_MOUSE(mouseDown)
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

- (void)scrollWheel:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super scrollWheel:event]; return; }
    @try {
        WebKit::NativeWebWheelEvent webEvent(event, self);
        _wkState->page->handleNativeWheelEvent(webEvent);
    } @catch (NSException *) { }
}

- (void)keyDown:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super keyDown:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        // Run AppKit's interpretKeyEvents to translate the NSEvent into NSTextInputClient
        // calls (insertText:/doCommandBySelector:); collect them in a thread-local that
        // our NSTextInputClient stubs append to.
        // 10.9 backport: skip interpretKeyEvents for Cmd-modified keys. Those are
        // menu shortcuts dispatched via sendAction: (already handled by my copy:/
        // paste:/etc. action methods). Running interpretKeyEvents would double-
        // dispatch the action via doCommandBySelector → KeypressCommand path.
        BOOL hasCmd = ([event modifierFlags] & NSCommandKeyMask) != 0;
        if (!hasCmd) {
            tlsCollectingCommands = &commands;
            @try { [self interpretKeyEvents:@[event]]; } @catch (NSException *) { }
            tlsCollectingCommands = nullptr;
        }
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        _wkState->page->handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

- (void)keyUp:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super keyUp:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        _wkState->page->handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

- (void)flagsChanged:(NSEvent *)event
{
    if (!_wkState || !_wkState->page) { [super flagsChanged:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        _wkState->page->handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
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
