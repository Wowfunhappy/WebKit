// MAVERICKS_BACKPORT: add mouse/keyboard event forwarders missing from upstream
// WKWebView (modern API) — the inspector uses WKInspectorWKWebView which extends
// WKWebView and without these methods AppKit's mouseDown: hits NSResponder's no-op,
// so the inspector window swallowed every click.
#include "config.h"

#if PLATFORM(MAC)

#import "WKWebViewInternal.h"
#import "WebViewImpl.h"
#import "NativeWebMouseEvent.h"
#import "NativeWebWheelEvent.h"
#import "NativeWebKeyboardEvent.h"
#import "WebPageProxy.h"
#import <WebCore/KeypressCommand.h>

@implementation WKWebView (Mac10_9EventForwarding)

// WKView returns YES; WKWebView's upstream Mac impl also returns YES (set elsewhere). On this
// backport WKWebView inherits NSView's default NO, so window→view convertPoint never flips Y
// and clicks land in the wrong DOM element. Override to YES so positions arrive top-left.
- (BOOL)isFlipped { return YES; }

- (void)mouseDown:(NSEvent *)event
{
    if (!self._impl) { [super mouseDown:event]; return; }
    @try { self._impl->mouseDown(event, WebKit::WebMouseEventInputSource::UserDriven); } @catch (NSException *e) {}
}
- (void)mouseUp:(NSEvent *)event
{
    if (!self._impl) { [super mouseUp:event]; return; }
    @try { self._impl->mouseUp(event, WebKit::WebMouseEventInputSource::UserDriven); } @catch (NSException *e) {}
}
- (void)mouseMoved:(NSEvent *)event
{
    if (!self._impl) { [super mouseMoved:event]; return; }
    @try { self._impl->mouseMoved(event); } @catch (NSException *e) {}
}
- (void)mouseDragged:(NSEvent *)event
{
    if (!self._impl) { [super mouseDragged:event]; return; }
    @try { self._impl->mouseDragged(event, WebKit::WebMouseEventInputSource::UserDriven); } @catch (NSException *e) {}
}
- (void)rightMouseDown:(NSEvent *)event
{
    if (!self._impl) { [super rightMouseDown:event]; return; }
    @try { self._impl->rightMouseDown(event); } @catch (NSException *e) {}
}
- (void)rightMouseUp:(NSEvent *)event
{
    if (!self._impl) { [super rightMouseUp:event]; return; }
    @try { self._impl->rightMouseUp(event); } @catch (NSException *e) {}
}
- (void)otherMouseDown:(NSEvent *)event
{
    if (!self._impl) { [super otherMouseDown:event]; return; }
    @try { self._impl->otherMouseDown(event); } @catch (NSException *e) {}
}
- (void)otherMouseUp:(NSEvent *)event
{
    if (!self._impl) { [super otherMouseUp:event]; return; }
    @try { self._impl->otherMouseUp(event); } @catch (NSException *e) {}
}
- (void)mouseEntered:(NSEvent *)event
{
    if (!self._impl) { [super mouseEntered:event]; return; }
    @try { self._impl->mouseEntered(event); } @catch (NSException *e) {}
}
- (void)mouseExited:(NSEvent *)event
{
    if (!self._impl) { [super mouseExited:event]; return; }
    @try { self._impl->mouseExited(event); } @catch (NSException *e) {}
}

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
    NSString *s = [string isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString *)string string] : (NSString *)string;
    if (!s)
        return;
    if (tlsWKWVCommands)
        tlsWKWVCommands->append(WebCore::KeypressCommand("insertText:"_s, String(s)));
}
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
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        impl->page().handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

- (void)keyUp:(NSEvent *)event
{
    WebKit::WebViewImpl *impl = self._impl;
    if (!impl) { [super keyUp:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        impl->page().handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

- (void)flagsChanged:(NSEvent *)event
{
    WebKit::WebViewImpl *impl = self._impl;
    if (!impl) { [super flagsChanged:event]; return; }
    @try {
        WTF::Vector<WebCore::KeypressCommand> commands;
        WebKit::NativeWebKeyboardEvent webEvent(event, false, false, commands);
        impl->page().handleKeyboardEvent(webEvent);
    } @catch (NSException *) { }
}

// Declared in WKWebViewMac.h and called from -[WKWebView dealloc]; upstream's
// Mac WKWebView category (not built here) implemented it. Without it, EVERY
// Mac WKWebView teardown raised unrecognized-selector and terminated Safari —
// the Web Inspector frontend (WKInspectorWKWebView) crashed Safari on
// open/close because of this.
- (void)_resetSecureInputState
{
    if (WebKit::WebViewImpl *impl = self._impl)
        impl->resetSecureInputState();
}

// Declared in WKWebViewMac.h, called from -[WKWebView _takeFindStringFromSelection:]
// (Edit ▸ Find ▸ Use Selection for Find). Same unrecognized-selector hazard as
// _resetSecureInputState. The WebCore edit command writes the find pasteboard.
- (void)_takeFindStringFromSelectionInternal:(id)sender
{
    if (WebKit::WebViewImpl *impl = self._impl)
        impl->page().executeEditCommand("TakeFindStringFromSelection"_s);
}

// Declared in WKWebViewMac.h, called from WebViewImpl's drag handling.
- (Vector<String>)_promisedFileMIMETypes:(id<NSDraggingInfo>)info
{
    return { };
}

@end

#endif // PLATFORM(MAC)
