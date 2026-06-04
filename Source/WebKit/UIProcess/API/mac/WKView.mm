// WKView implementation for macOS 10.9 backport
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
}

// Per-WKView state. RefPtr<WebPageProxy> keeps the page alive for the
// lifetime of the view; std::unique_ptr<PageClient> owns the page client.
struct WKViewState {
    RefPtr<WebKit::WebPageProxy> page;
    std::unique_ptr<WebKit::PageClient> pageClient;
};

@interface WKView () {
    WKViewState *_wkState;
}
@end

@implementation WKView

- (instancetype)initWithFrame:(NSRect)frame processPool:(std::reference_wrapper<WebKit::WebProcessPool>)processPool configuration:(Ref<API::PageConfiguration>&&)configuration
{
    FILE *earlyLog = ((FILE*)0);
    if (earlyLog) { fprintf(earlyLog, "[PID %d] >>> WKView initWithFrame:processPool: ENTERED! frame=%gx%g\n",
                            getpid(), frame.size.width, frame.size.height); fclose(earlyLog); }

    self = [super initWithFrame:frame];
    if (!self)
        return nil;

    [self setWantsLayer:YES];
    self.layer.backgroundColor = CGColorGetConstantColor(kCGColorWhite);

    [WKView installEventMonitorOnce];

    WebKit::InitializeWebKit2();

    FILE *f = ((FILE*)0);
    if (f) { fprintf(f, "[PID %d] WKView initWithFrame:processPool:configuration: frame=%gx%g\n",
                     getpid(), frame.size.width, frame.size.height); fclose(f); }

    _wkState = new WKViewState;
    _wkState->pageClient = createMinimalPageClient(self);
    _wkState->page = processPool.get().createWebPage(*_wkState->pageClient, WTF::move(configuration));
    setMinimalPageClientPage(*_wkState->pageClient, _wkState->page.get());

    f = ((FILE*)0);
    if (f) { fprintf(f, "[PID %d] WebPageProxy created! pageID=%" PRIu64 "\n",
                     getpid(), _wkState->page->identifier().toUInt64()); fclose(f); }

    _wkState->page->initializeWebPage(WebCore::Site(WTF::HashTableEmptyValue), WebCore::SandboxFlags {}, WebCore::ReferrerPolicy::Default);

    f = ((FILE*)0);
    if (f) { fprintf(f, "[PID %d] initializeWebPage called!\n", getpid()); fclose(f); }

    return self;
}

- (void)dealloc
{
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
    FILE *f2 = ((FILE*)0);
    if (f2) { fprintf(f2, "[PID %d] >>> WKView initWithFrame:contextRef: ctx=%p pg=%p\n", getpid(), contextRef, pageGroupRef); fclose(f2); }

    auto configuration = API::PageConfiguration::create();
    configuration->setProcessPool(WebKit::toImpl(contextRef));
    // FIXME: page group setup disabled — setPageGroup not yet wired up.
    // if (pageGroupRef)
    //     configuration->setPageGroup(WebKit::toImpl(pageGroupRef));

    return [self initWithFrame:frame processPool:*WebKit::toImpl(contextRef) configuration:WTF::move(configuration)];
}

- (id)initWithFrame:(NSRect)frame configurationRef:(WKPageConfigurationRef)configurationRef { return nil; }
- (WKPageRef)pageRef { return _wkState ? WebKit::toAPI(_wkState->page.get()) : nullptr; }

// 10.9 backport: WKView's normal setFrameSize: propagates the new viewport size to
// WebContent via WebPageProxy::setSize. Without this override, WebContent renders at
// 0x0 — Safari creates WKViews with zero frame and resizes them later.
- (void)setFrameSize:(NSSize)newSize
{
    FILE *f=((FILE*)0); if(f){fprintf(f,"[WKView setFrameSize PID %d] %gx%g _wkState=%p hasProcess=%d\n",getpid(),newSize.width,newSize.height,_wkState,_wkState && _wkState->page ? _wkState->page->hasRunningProcess() : -1);fclose(f);}
    [super setFrameSize:newSize];
    if (_wkState && _wkState->page) {
        // 10.9 backport: if drawingArea is null, the WKView was created before WebContent
        // was running. Re-attempt initializeWebPage now that the process should be alive.
        if (!_wkState->page->drawingArea()) {
            f=((FILE*)0); if(f){fprintf(f,"[WKView setFrameSize PID %d] no drawingArea, calling initializeWebPage. hasProcess=%d\n",getpid(),_wkState->page->hasRunningProcess());fclose(f);}
            _wkState->page->initializeWebPage(WebCore::Site(WTF::HashTableEmptyValue), WebCore::SandboxFlags {}, WebCore::ReferrerPolicy::Default);
        }
        if (RefPtr drawingArea = _wkState->page->drawingArea()) {
            f=((FILE*)0); if(f){fprintf(f,"[WKView setFrameSize PID %d] calling drawingArea->setSize\n",getpid());fclose(f);}
            drawingArea->setSize(WebCore::IntSize(newSize.width, newSize.height));
        } else {
            f=((FILE*)0); if(f){fprintf(f,"[WKView setFrameSize PID %d] no drawingArea after retry! hasProcess=%d\n",getpid(),_wkState->page->hasRunningProcess());fclose(f);}
        }
    }
}

- (void)setFrame:(NSRect)frame
{
    FILE *f=((FILE*)0); if(f){fprintf(f,"[WKView setFrame PID %d] %gx%g+%g+%g _wkState=%p\n",getpid(),frame.size.width,frame.size.height,frame.origin.x,frame.origin.y,_wkState);fclose(f);}
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

// 10.9 backport: layer-tree mirror subviews intercept mouseDown without forwarding.
// Force hit-testing to land on WKView so our mouseDown/Up/etc. always fire.
- (NSView *)hitTest:(NSPoint)point
{
    NSView *result = [super hitTest:point];
    if (!result)
        return nil;
    if (result == self || [result isDescendantOf:self])
        return self;
    return result;
}

// 10.9 backport: Safari's BrowserWindowContentView/NSTabView hierarchy may absorb
// mouseDown via hitTest before it ever reaches WKView. Install a global NSEvent
// monitor that catches mouseDown/Up/scrollWheel within WKView bounds and dispatches
// directly to the appropriate WKView instance. This bypasses hitTest entirely.
+ (void)installEventMonitorOnce
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSEventMask mask =
            NSLeftMouseDownMask | NSLeftMouseUpMask |
            NSRightMouseDownMask | NSRightMouseUpMask |
            NSOtherMouseDownMask | NSOtherMouseUpMask |
            NSLeftMouseDraggedMask | NSRightMouseDraggedMask | NSOtherMouseDraggedMask |
            NSMouseMovedMask | NSScrollWheelMask;
        [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
            NSWindow *win = [event window];
            if (!win)
                win = [NSApp keyWindow];
            if (!win)
                win = [[NSApp orderedWindows] firstObject];
            if (!win)
                return event;
            NSView *cv = [win contentView];
            if (!cv)
                return event;
            // 10.9 backport: Safari multi-tab can mount several WKViews in the
            // same window (one per tab); only the active tab's WKView is
            // visible. Walk depth-first but skip hidden views (and their
            // subtrees) so events go to the currently-displayed tab, not a
            // background tab's WKView found earlier in subview order.
            __block WKView *wkView = nil;
            void (^walk)(NSView *) = ^(NSView *v) {};
            // MRC: __block block vars are not retained by the capturing block, so __block alone
            // breaks the recursive-block retain cycle (__weak is unavailable under manual ref counting).
            __block void (^weakWalk)(NSView *) = nil;
            walk = ^(NSView *v) {
                if (wkView) return;
                if ([v isHidden]) return;
                if ([v isKindOfClass:[WKView class]]) { wkView = (WKView *)v; return; }
                for (NSView *sub in [v subviews]) { if (wkView) return; weakWalk(sub); }
            };
            weakWalk = walk;
            walk(cv);
            if (!wkView)
                return event;
            // Convert event location to wkView coords; ignore if outside.
            NSPoint pInWin = [event locationInWindow];
            if (![event window]) {
                // Event has no associated window — locationInWindow is screen coords.
                NSRect r = NSMakeRect(pInWin.x, pInWin.y, 0, 0);
                pInWin = [win convertRectFromScreen:r].origin;
            }
            NSPoint pInWK = [wkView convertPoint:pInWin fromView:nil];
            if (![wkView mouse:pInWK inRect:[wkView bounds]])
                return event;
            NSEventType t = [event type];
            switch (t) {
            case NSLeftMouseDown:    [wkView mouseDown:event];    return (NSEvent *)nil;
            case NSLeftMouseUp:      [wkView mouseUp:event];      return (NSEvent *)nil;
            case NSRightMouseDown:   [wkView rightMouseDown:event]; return (NSEvent *)nil;
            case NSRightMouseUp:     [wkView rightMouseUp:event]; return (NSEvent *)nil;
            case NSOtherMouseDown:   [wkView otherMouseDown:event]; return (NSEvent *)nil;
            case NSOtherMouseUp:     [wkView otherMouseUp:event]; return (NSEvent *)nil;
            case NSLeftMouseDragged: [wkView mouseDragged:event]; return (NSEvent *)nil;
            case NSRightMouseDragged:[wkView rightMouseDragged:event]; return (NSEvent *)nil;
            case NSOtherMouseDragged:[wkView otherMouseDragged:event]; return (NSEvent *)nil;
            case NSMouseMoved:       [wkView mouseMoved:event];   return (NSEvent *)nil;
            case NSScrollWheel:      [wkView scrollWheel:event];  return (NSEvent *)nil;
            default: return event;
            }
        }];
    });
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
