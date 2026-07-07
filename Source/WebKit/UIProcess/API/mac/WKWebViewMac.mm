// MAVERICKS_BACKPORT: add mouse/keyboard event forwarders missing from upstream
// WKWebView (modern API) — the inspector uses WKInspectorWKWebView which extends
// WKWebView and without these methods AppKit's mouseDown: hits NSResponder's no-op,
// so the inspector window swallowed every click.
#include "config.h"

#if PLATFORM(MAC)

// MAVERICKS_BACKPORT: includes for the event-forwarding category that backfills WKWebView's input handling.
#import "WKWebViewInternal.h"
#import "WebViewImpl.h"
// MAVERICKS_BACKPORT: native event + keypress types used to marshal NSEvents to the page proxy.
#import "NativeWebMouseEvent.h"
#import "NativeWebWheelEvent.h"
#import "NativeWebKeyboardEvent.h"
#import "WebPageProxy.h"
#import <WebCore/CGWindowUtilities.h>
#import <WebCore/KeypressCommand.h>
#import <pal/spi/cg/CoreGraphicsSPI.h>

// MAVERICKS_BACKPORT: category adding the NSEvent forwarders/NSTextInputClient stubs absent from upstream WKWebView on Mac.
@implementation WKWebView (Mac10_9EventForwarding)

// MAVERICKS_BACKPORT: WKView returns YES; WKWebView's upstream Mac impl also returns YES (set elsewhere). On this
// backport WKWebView inherits NSView's default NO, so window→view convertPoint never flips Y
// and clicks land in the wrong DOM element. Override to YES so positions arrive top-left.
- (BOOL)isFlipped { return YES; }

// MAVERICKS_BACKPORT: forward mouse-down into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)mouseDown:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super mouseDown:event]; return; }
    @try { self._impl->mouseDown(event, WebKit::WebMouseEventInputSource::UserDriven); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward mouse-up into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)mouseUp:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super mouseUp:event]; return; }
    @try { self._impl->mouseUp(event, WebKit::WebMouseEventInputSource::UserDriven); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward mouse-moved into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)mouseMoved:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super mouseMoved:event]; return; }
    @try { self._impl->mouseMoved(event); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward mouse-dragged into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)mouseDragged:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super mouseDragged:event]; return; }
    @try { self._impl->mouseDragged(event, WebKit::WebMouseEventInputSource::UserDriven); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward right-mouse-down into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)rightMouseDown:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super rightMouseDown:event]; return; }
    @try { self._impl->rightMouseDown(event); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward right-mouse-up into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)rightMouseUp:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super rightMouseUp:event]; return; }
    @try { self._impl->rightMouseUp(event); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward other-mouse-down into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)otherMouseDown:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super otherMouseDown:event]; return; }
    @try { self._impl->otherMouseDown(event); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward other-mouse-up into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)otherMouseUp:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super otherMouseUp:event]; return; }
    @try { self._impl->otherMouseUp(event); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward mouse-entered into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)mouseEntered:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super mouseEntered:event]; return; }
    @try { self._impl->mouseEntered(event); } @catch (NSException *e) {}
}
// MAVERICKS_BACKPORT: forward mouse-exited into WebViewImpl (missing from upstream WKWebView Mac impl here).
- (void)mouseExited:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: hand the event to WebViewImpl.
    if (!self._impl) { [super mouseExited:event]; return; }
    @try { self._impl->mouseExited(event); } @catch (NSException *e) {}
}

// MAVERICKS_BACKPORT: forward scroll-wheel into the page (missing from upstream WKWebView Mac impl here).
- (void)scrollWheel:(NSEvent *)event
{
    WebKit::WebViewImpl *impl = self._impl;
    if (!impl) { [super scrollWheel:event]; return; }
    @try {
        WebKit::NativeWebWheelEvent webEvent(event, self);
        impl->page().handleNativeWheelEvent(webEvent);
    } @catch (NSException *) { }
}

// MAVERICKS_BACKPORT: WKWebView ships no NSTextInputClient implementation, so AppKit's
// interpretKeyEvents: had no client to translate keystrokes into insertText:/command
// callbacks — typing into the inspector (console, filter fields) produced nothing.
// Mirror the proven WKView path: a thread-local command collector + minimal
// NSTextInputClient stubs that append to it, and a keyDown: that runs interpretKeyEvents:
// then forwards the collected KeypressCommands to WebContent. This avoids the 10.10+
// -[NSTextInputContext handleEventByInputMethod:completionHandler:] used by
// WebViewImpl::interpretKeyEvent (which is unavailable on 10.9).
static __thread WTF::Vector<WebCore::KeypressCommand> *tlsWKWVCommands = nullptr;

- (NSArray *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange { return nil; }
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange { return NSZeroRect; }
- (BOOL)hasMarkedText { return NO; }
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
    // MAVERICKS_BACKPORT: capture inserted text into the thread-local KeypressCommand collector for keyDown: to forward.
    NSString *s = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
    if (!s)
        return;
    if (tlsWKWVCommands)
        tlsWKWVCommands->append(WebCore::KeypressCommand("insertText:"_s, String(s)));
}
// MAVERICKS_BACKPORT: remaining minimal NSTextInputClient stubs so AppKit vends an input context for interpretKeyEvents:.
- (NSRange)markedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {}
- (void)unmarkText {}
- (void)doCommandBySelector:(SEL)selector
{
    if (!tlsWKWVCommands)
        return;
    tlsWKWVCommands->append(WebCore::KeypressCommand(String::fromLatin1(sel_getName(selector))));
}
// NSView only vends an NSTextInputContext (needed by interpretKeyEvents:) when the view
// conforms to NSTextInputClient. Without this, -inputContext is nil and typing collects no
// commands. WKView does the same (WKView.mm).
- (BOOL)conformsToProtocol:(Protocol *)protocol
{
    if (protocol == @protocol(NSTextInputClient)) return YES;
    return [super conformsToProtocol:protocol];
}

- (void)keyDown:(NSEvent *)event
{
    WebKit::WebViewImpl *impl = self._impl;
    if (!impl) { [super keyDown:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        // MAVERICKS_BACKPORT: skip interpretKeyEvents for Cmd-modified keys — those are menu
        // shortcuts dispatched via sendAction:; running interpretKeyEvents would double-
        // dispatch via doCommandBySelector.
        BOOL hasCmd = ([event modifierFlags] & NSCommandKeyMask) != 0;
        if (!hasCmd) {
            tlsWKWVCommands = &commands;
            @try { [self interpretKeyEvents:@[event]]; } @catch (NSException *) { }
            tlsWKWVCommands = nullptr;
        }
        // MAVERICKS_BACKPORT: register every collected command name so
        // WebPageProxy::executeSavedCommandBySelector's MESSAGE_CHECK(isValidKeypressCommandName)
        // accepts the selector WebContent echoes back when the DOM leaves it unhandled (e.g. Esc
        // -> cancelOperation:). The sibling collectors (WKView.mm, WebViewImpl) register at
        // collection time; this one previously omitted it, so the unhandled-key round-trip
        // tripped the security check and SIGTRAPed the UI process.
        for (auto& command : commands)
            impl->page().registerKeypressCommandName(command.commandName);
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        impl->page().handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

// MAVERICKS_BACKPORT: forward key-up into the page (missing from upstream WKWebView Mac impl here).
- (void)keyUp:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: build a NativeWebKeyboardEvent and hand it to the page proxy.
    WebKit::WebViewImpl *impl = self._impl;
    if (!impl) { [super keyUp:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        impl->page().handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

// MAVERICKS_BACKPORT: forward modifier-key changes into the page (missing from upstream WKWebView Mac impl here).
- (void)flagsChanged:(NSEvent *)event
{
    // MAVERICKS_BACKPORT: build a NativeWebKeyboardEvent and hand it to the page proxy.
    WebKit::WebViewImpl *impl = self._impl;
    if (!impl) { [super flagsChanged:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        impl->page().handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

// MAVERICKS_BACKPORT: Declared in WKWebViewMac.h and called from -[WKWebView dealloc]; upstream's
// Mac WKWebView category (not built here) implemented it. Without it, EVERY
// Mac WKWebView teardown raised unrecognized-selector and terminated Safari —
// the Web Inspector frontend (WKInspectorWKWebView) crashed Safari on
// open/close because of this.
- (void)_resetSecureInputState
{
    // MAVERICKS_BACKPORT: forward to WebViewImpl::resetSecureInputState.
    if (WebKit::WebViewImpl *impl = self._impl)
        impl->resetSecureInputState();
}

// MAVERICKS_BACKPORT: Declared in WKWebViewMac.h, called from -[WKWebView _takeFindStringFromSelection:]
// (Edit ▸ Find ▸ Use Selection for Find). Same unrecognized-selector hazard as
// _resetSecureInputState. The WebCore edit command writes the find pasteboard.
- (void)_takeFindStringFromSelectionInternal:(id)sender
{
    // MAVERICKS_BACKPORT: route Use-Selection-for-Find through the page proxy's edit command.
    if (WebKit::WebViewImpl *impl = self._impl)
        impl->page().executeEditCommand("TakeFindStringFromSelection"_s);
}

// MAVERICKS_BACKPORT: declared in WKWebViewMac.h, called from WebViewImpl's drag handling; upstream's unbuilt Mac category provided it.
- (Vector<String>)_promisedFileMIMETypes:(id<NSDraggingInfo>)info
{
    // MAVERICKS_BACKPORT: no promised file types on this backport; return empty.
    return { };
}

// MAVERICKS_BACKPORT: upstream's NSView geometry/window/responder plumbing (one-line WebViewImpl
// forwards from the full WKWebViewMac.mm). Without setFrameSize:, programmatic view resizes never
// reach the web process (window.open feature sizes, window-resize tests); without the
// viewWillMoveToWindow:/viewDidMoveToWindow pair, WebViewImpl never observes its window, so
// key-window / visibility / backing-scale state never updates (window focus events).
- (BOOL)acceptsFirstResponder
{
    return self._impl && self._impl->acceptsFirstResponder();
}

- (BOOL)becomeFirstResponder
{
    return self._impl && self._impl->becomeFirstResponder();
}

- (BOOL)resignFirstResponder
{
    return self._impl ? self._impl->resignFirstResponder() : [super resignFirstResponder];
}

- (void)viewWillStartLiveResize
{
    if (self._impl)
        self._impl->viewWillStartLiveResize();
}

- (void)viewDidEndLiveResize
{
    if (self._impl)
        self._impl->viewDidEndLiveResize();
}

- (void)setFrameSize:(NSSize)size
{
    [super setFrameSize:size];
    if (self._impl)
        self._impl->setFrameSize(NSSizeToCGSize(size));
}

- (void)renewGState
{
    if (self._impl)
        self._impl->renewGState();
    [super renewGState];
}

- (void)viewWillMoveToWindow:(NSWindow *)window
{
    if (self._impl)
        self._impl->viewWillMoveToWindow(window);
}

- (void)viewDidMoveToWindow
{
    if (self._impl)
        self._impl->viewDidMoveToWindow();
}

- (void)viewDidHide
{
    if (self._impl)
        self._impl->viewDidHide();
}

- (void)viewDidUnhide
{
    if (self._impl)
        self._impl->viewDidUnhide();
}

- (void)viewDidChangeBackingProperties
{
    if (self._impl)
        self._impl->viewDidChangeBackingProperties();
}

// MAVERICKS_BACKPORT: upstream WKWebViewPrivate SPI (from the full WKWebViewMac.mm).
// WebKitTestRunner turns occlusion detection off so its offscreen test windows count as
// visible; 10.9 never reports offscreen windows as occlusion-visible, so without this the
// page's activity state is pinned by the occlusion check.
- (void)_setWindowOcclusionDetectionEnabled:(BOOL)enabled
{
    if (self._impl)
        self._impl->setWindowOcclusionDetectionEnabled(enabled);
}

- (BOOL)_windowOcclusionDetectionEnabled
{
    return self._impl && self._impl->windowOcclusionDetectionEnabled();
}

// MAVERICKS_BACKPORT: upstream's WKWebView (WKInternalMac) supercall methods (from the full
// WKWebViewMac.mm). WebViewImpl invokes these on its view; without them, any WebViewImpl
// path reaching one throws unrecognized-selector. In release builds an ObjC exception
// unwinding through an IPC dispatch destroys the reply CompletionHandler uncalled —
// WebPageProxy::executeSavedCommandBySelector's reply never gets sent and WebContent hangs
// forever inside its synchronous ExecuteSavedCommandBySelector wait (every unhandled
// keypress command, e.g. Esc -> cancelOperation:).
- (NSTextInputContext *)_web_superInputContext
{
    return [super inputContext];
}

- (void)_web_superQuickLookWithEvent:(NSEvent *)event
{
    [super quickLookWithEvent:event];
}

- (void)_web_superSwipeWithEvent:(NSEvent *)event
{
    [super swipeWithEvent:event];
}

- (void)_web_superMagnifyWithEvent:(NSEvent *)event
{
    [super magnifyWithEvent:event];
}

- (void)_web_superSmartMagnifyWithEvent:(NSEvent *)event
{
    [super smartMagnifyWithEvent:event];
}

- (void)_web_superRemoveTrackingRect:(NSTrackingRectTag)tag
{
    [super removeTrackingRect:tag];
}

- (id)_web_superAccessibilityAttributeValue:(NSString *)attribute
{
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    return [super accessibilityAttributeValue:attribute];
ALLOW_DEPRECATED_DECLARATIONS_END
}

- (void)_web_superDoCommandBySelector:(SEL)selector
{
    [super doCommandBySelector:selector];
}

- (BOOL)_web_superPerformKeyEquivalent:(NSEvent *)event
{
    return [super performKeyEquivalent:event];
}

- (void)_web_superKeyDown:(NSEvent *)event
{
    [super keyDown:event];
}

- (NSView *)_web_superHitTest:(NSPoint)point
{
    return [super hitTest:point];
}

@end

// MAVERICKS_BACKPORT: upstream's mouse-simulation testing SPI, restored for WebKitTestRunner's
// EventSenderProxy (upstream keeps these in its full WKWebViewMac.mm).
@implementation WKWebView (WKMouseSimulation)
- (void)_simulateMouseMove:(NSEvent *)event
{
    if (self._impl)
        self._impl->mouseMoved(event);
}

- (void)_simulateMouseEnter:(NSEvent *)event
{
    if (self._impl)
        self._impl->mouseEntered(event);
}

- (void)_simulateMouseExit:(NSEvent *)event
{
    if (self._impl)
        self._impl->mouseExited(event);
}
@end

// MAVERICKS_BACKPORT: upstream's WKWindowSnapshot category, restored for WebKitTestRunner's
// windowSnapshotImage() pixel-dump path (upstream keeps it in its full WKWebViewMac.mm).
@implementation WKWebView (WKWindowSnapshot)
- (NSImage *)_windowSnapshotInRect:(CGRect)rect withOptions:(CGWindowImageOption)options
{
    RetainPtr snapshot = WebCore::cgWindowListCreateImage(rect, kCGWindowListOptionIncludingWindow, (CGSWindowID)[[self window] windowNumber], options);
    if (!snapshot)
        return nil;

    SUPPRESS_RETAINPTR_CTOR_ADOPT return [[NSImage alloc] initWithCGImage:snapshot.get() size:NSZeroSize];
}
@end

#endif // PLATFORM(MAC)
