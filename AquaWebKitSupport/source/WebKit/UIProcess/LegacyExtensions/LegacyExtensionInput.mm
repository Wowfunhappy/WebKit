#import "config.h"
#import "LegacyExtensionInput.h"

#import "PageClient.h"
#import "PageLoadState.h"
#import "WebPageProxy.h"
#import <AppKit/AppKit.h>
#import <wtf/BlockPtr.h>
#import <wtf/WeakHashMap.h>
#import <wtf/text/MakeString.h>

// The web view's entry points for input an extension gives the page (WKViewAquaWebKit.mm).
@interface NSView (WKViewExtensionInput)
- (void)_aquaWebKitHandleExtensionMouseEvent:(NSEvent *)event buttons:(unsigned short)buttons completionHandler:(void (^)(void))completionHandler;
- (void)_aquaWebKitHandleExtensionKeyEvent:(NSEvent *)event completionHandler:(void (^)(void))completionHandler;
- (void)_aquaWebKitHandleExtensionWheelEvent:(NSEvent *)event;
- (void)_aquaWebKitInsertExtensionText:(NSString *)text;
- (void)_aquaWebKitValidateEditingAction:(NSMenuItem *)item completionHandler:(void (^)(BOOL))completionHandler;
@end

// NSEvent SPI WebAutomationSession's wheel events take their window by.
@interface NSEvent (WKExtensionInputWindow)
- (NSEvent *)_eventRelativeToWindow:(NSWindow *)window;
@end

namespace WebKit::LegacyExtensions {

// What each tab's input from extensions holds down, and where its pointer last was, as a pointing device has
// them: the buttons a mouse event reports, and the movement it reports from the last position.
struct PointerState {
    unsigned short buttons { 0 };
    std::optional<NSPoint> lastLocation;
};

static WeakHashMap<WebPageProxy, PointerState>& pointerStates()
{
    static NeverDestroyed<WeakHashMap<WebPageProxy, PointerState>> states;
    return states;
}

InputResult checkInputAccess(WebPageProxy& page, const String& extensionKey, const WebsiteAccess& access)
{
    auto tabID = page.identifier().toUInt64();
    if (page.isClosed())
        return makeUnexpected(makeString("No tab with id: "_s, tabID, '.'));
    if (!access.coversEverySite())
        return makeUnexpected("Missing host permission for the tab"_s);
    auto& pageLoadState = page.pageLoadState();
    if (!access.allowsForExtension(extensionKey, pageLoadState.url()) || (!pageLoadState.provisionalURL().isEmpty() && !access.allowsForExtension(extensionKey, pageLoadState.provisionalURL())))
        return makeUnexpected(makeString("Cannot access the page of the tab with id: "_s, tabID, '.'));
    return { };
}

// The tab's web view, which PageClient names as the view a reveal popover is presented from.
static NSView *viewOfPage(WebPageProxy& page)
{
    return page.pageClient()->viewForPresentingRevealPopover();
}

static NSEventModifierFlags modifierFlags(const JSON::Object& event)
{
    NSEventModifierFlags flags = 0;
    RefPtr modifiers = event.getArray("modifiers"_s);
    if (!modifiers)
        return flags;
    for (auto& value : *modifiers) {
        auto name = value->asString();
        if (name == "shift"_s)
            flags |= NSEventModifierFlagShift;
        else if (name == "control"_s)
            flags |= NSEventModifierFlagControl;
        else if (name == "option"_s)
            flags |= NSEventModifierFlagOption;
        else if (name == "command"_s)
            flags |= NSEventModifierFlagCommand;
        else if (name == "capsLock"_s)
            flags |= NSEventModifierFlagCapsLock;
    }
    return flags;
}

// A point of the tab's viewport in CSS pixels, in the base coordinates of the view's window, which is the
// view's own root when the view has none.
static NSPoint basePoint(WebPageProxy& page, NSView *view, const JSON::Object& event)
{
    double scale = page.pageZoomFactor() * page.pageScaleFactor();
    NSPoint viewPoint = NSMakePoint(event.getDouble("x"_s).value_or(0) * scale, event.getDouble("y"_s).value_or(0) * scale);
    return [view convertPoint:viewPoint toView:nil];
}

static NSTimeInterval eventTimestamp()
{
    return [[NSProcessInfo processInfo] systemUptime];
}

// The buttons mask of a mouse button, as MouseEvent.buttons spells it.
static unsigned short buttonMask(const String& button)
{
    if (button == "left"_s)
        return 1;
    if (button == "right"_s)
        return 2;
    if (button == "middle"_s)
        return 4;
    return 0;
}

// A wheel event at the base point: in the view's window, positioned on the screen as the window is, as
// WebAutomationSession makes its wheel events; with no window, the event's screen location is its location
// in the window, which is the base point.
static RetainPtr<NSEvent> wheelEvent(NSView *view, NSPoint location, NSEventModifierFlags flags, const JSON::Object& event)
{
    RetainPtr cgEvent = adoptCF(CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitPixel, 2, static_cast<int32_t>(-event.getDouble("deltaY"_s).value_or(0)), static_cast<int32_t>(-event.getDouble("deltaX"_s).value_or(0))));
    CGFloat screenHeight = NSMaxY([[NSScreen screens].firstObject frame]);
    NSWindow *window = view.window;
    NSPoint screenPoint = window ? [window convertRectToScreen:NSMakeRect(location.x, location.y, 0, 0)].origin : location;
    CGEventSetLocation(cgEvent.get(), CGPointMake(screenPoint.x, screenHeight - screenPoint.y));
    CGEventSetFlags(cgEvent.get(), static_cast<CGEventFlags>(flags));
    NSEvent *nsEvent = [NSEvent eventWithCGEvent:cgEvent.get()];
    return window ? [nsEvent _eventRelativeToWindow:window] : nsEvent;
}

void dispatchMouseEvent(WebPageProxy& page, const String& extensionKey, const WebsiteAccess& access, const JSON::Object& event, CompletionHandler<void(InputResult&&)>&& completionHandler)
{
    if (auto result = checkInputAccess(page, extensionKey, access); !result)
        return completionHandler(WTF::move(result));
    NSView *view = viewOfPage(page);

    auto type = event.getString("type"_s);
    NSPoint location = basePoint(page, view, event);
    NSEventModifierFlags flags = modifierFlags(event);

    if (type == "scrollWheel"_s) {
        [view _aquaWebKitHandleExtensionWheelEvent:wheelEvent(view, location, flags, event).get()];
        return completionHandler({ });
    }

    auto button = event.getString("button"_s);
    if (button.isNull())
        button = "left"_s;
    bool down = type == "mouseDown"_s;
    bool up = type == "mouseUp"_s;
    NSEventType eventType;
    if (type == "mouseMoved"_s)
        eventType = NSEventTypeMouseMoved;
    else if (down || up || type == "mouseDragged"_s) {
        if (button == "left"_s)
            eventType = down ? NSEventTypeLeftMouseDown : up ? NSEventTypeLeftMouseUp : NSEventTypeLeftMouseDragged;
        else if (button == "right"_s)
            eventType = down ? NSEventTypeRightMouseDown : up ? NSEventTypeRightMouseUp : NSEventTypeRightMouseDragged;
        else if (button == "middle"_s)
            eventType = down ? NSEventTypeOtherMouseDown : up ? NSEventTypeOtherMouseUp : NSEventTypeOtherMouseDragged;
        else
            return completionHandler(makeUnexpected(makeString("Unknown mouse button: "_s, button)));
    } else
        return completionHandler(makeUnexpected(makeString("Unknown mouse event type: "_s, type)));

    auto& state = pointerStates().ensure(page, [] { return PointerState { }; }).iterator->value;
    if (down)
        state.buttons |= buttonMask(button);
    else if (up)
        state.buttons &= ~buttonMask(button);
    unsigned short buttons = state.buttons;
    if (auto specified = event.getDouble("buttons"_s))
        buttons = static_cast<unsigned short>(*specified);

    auto clickCount = static_cast<NSInteger>(event.getDouble("clickCount"_s).value_or(down || up ? 1 : 0));
    RetainPtr nsEvent = [NSEvent mouseEventWithType:eventType location:location modifierFlags:flags timestamp:eventTimestamp() windowNumber:view.window.windowNumber context:nil eventNumber:0 clickCount:clickCount pressure:down ? 1 : 0];
    // The movement from the last position, as WebAutomationSession reports it, and the button number of a
    // middle button's events.
    RetainPtr cgEvent = adoptCF(CGEventCreateCopy([nsEvent CGEvent]));
    NSPoint lastLocation = state.lastLocation.value_or(location);
    CGEventSetIntegerValueField(cgEvent.get(), kCGMouseEventDeltaX, static_cast<int64_t>(location.x - lastLocation.x));
    CGEventSetIntegerValueField(cgEvent.get(), kCGMouseEventDeltaY, static_cast<int64_t>(-(location.y - lastLocation.y)));
    if (button == "middle"_s && eventType != NSEventTypeMouseMoved)
        CGEventSetIntegerValueField(cgEvent.get(), kCGMouseEventButtonNumber, 2);
    nsEvent = [NSEvent eventWithCGEvent:cgEvent.get()];
    state.lastLocation = location;

    [view _aquaWebKitHandleExtensionMouseEvent:nsEvent.get() buttons:buttons completionHandler:makeBlockPtr([completionHandler = WTF::move(completionHandler)] mutable {
        completionHandler({ });
    }).get()];
}

void dispatchKeyEvent(WebPageProxy& page, const String& extensionKey, const WebsiteAccess& access, const JSON::Object& event, CompletionHandler<void(InputResult&&)>&& completionHandler)
{
    if (auto result = checkInputAccess(page, extensionKey, access); !result)
        return completionHandler(WTF::move(result));
    NSView *view = viewOfPage(page);

    auto type = event.getString("type"_s);
    NSEventType eventType;
    if (type == "keyDown"_s)
        eventType = NSEventTypeKeyDown;
    else if (type == "keyUp"_s)
        eventType = NSEventTypeKeyUp;
    else if (type == "flagsChanged"_s)
        eventType = NSEventTypeFlagsChanged;
    else
        return completionHandler(makeUnexpected(makeString("Unknown key event type: "_s, type)));

    auto characters = event.getString("characters"_s);
    auto unmodified = event.getString("charactersIgnoringModifiers"_s);
    if (unmodified.isNull())
        unmodified = characters;
    auto keyCode = static_cast<unsigned short>(event.getDouble("keyCode"_s).value_or(0));
    RetainPtr nsEvent = [NSEvent keyEventWithType:eventType location:NSZeroPoint modifierFlags:modifierFlags(event) timestamp:eventTimestamp() windowNumber:view.window.windowNumber context:nil characters:(characters.isNull() ? @"" : characters.createNSString().get()) charactersIgnoringModifiers:(unmodified.isNull() ? @"" : unmodified.createNSString().get()) isARepeat:event.getBoolean("isRepeat"_s).value_or(false) keyCode:keyCode];
    [view _aquaWebKitHandleExtensionKeyEvent:nsEvent.get() completionHandler:makeBlockPtr([completionHandler = WTF::move(completionHandler)] mutable {
        completionHandler({ });
    }).get()];
}

// The Edit menu's text, selection and history actions.
static bool isEditingAction(const String& action)
{
    static constexpr ASCIILiteral actions[] = {
        "selectAll:"_s, "copy:"_s, "cut:"_s, "paste:"_s, "pasteAsPlainText:"_s, "delete:"_s,
        "undo:"_s, "redo:"_s, "uppercaseWord:"_s, "lowercaseWord:"_s, "capitalizeWord:"_s,
    };
    for (auto name : actions) {
        if (action == name)
            return true;
    }
    return false;
}

void performEditingAction(WebPageProxy& page, const String& extensionKey, const WebsiteAccess& access, const String& action, CompletionHandler<void(InputResult&&)>&& completionHandler)
{
    if (auto result = checkInputAccess(page, extensionKey, access); !result)
        return completionHandler(WTF::move(result));
    if (!isEditingAction(action))
        return completionHandler(makeUnexpected(makeString("Unsupported editing action: "_s, action)));

    RetainPtr view = viewOfPage(page);
    SEL selector = NSSelectorFromString(action.createNSString().get());
    RetainPtr<NSResponder> target = view.get();
    while (target && ![target respondsToSelector:selector])
        target = [target nextResponder];
    if (!target)
        return completionHandler(makeUnexpected(makeString("No target for editing action: "_s, action)));

    RetainPtr item = adoptNS([[NSMenuItem alloc] initWithTitle:@"" action:selector keyEquivalent:@""]);
    [item setTarget:target.get()];
    auto perform = [page = Ref { page }, target, item, extensionKey, access, action, selector, completionHandler = WTF::move(completionHandler)](BOOL enabled) mutable {
        if (auto result = checkInputAccess(page, extensionKey, access); !result)
            return completionHandler(WTF::move(result));
        if (!enabled)
            return completionHandler(makeUnexpected(makeString("Editing action is disabled: "_s, action)));
        [NSApp sendAction:selector to:target.get() from:item.get()];
        completionHandler({ });
    };

    // NSMenu prefers validateMenuItem: to validateUserInterfaceItem: on its action target.
    if ([target respondsToSelector:@selector(validateMenuItem:)])
        return perform([(id<NSMenuItemValidation>)target.get() validateMenuItem:item.get()]);
    if (target.get() == view.get()) {
        [view _aquaWebKitValidateEditingAction:item.get() completionHandler:makeBlockPtr(WTF::move(perform)).get()];
        return;
    }
    if ([target respondsToSelector:@selector(validateUserInterfaceItem:)])
        return perform([(id<NSUserInterfaceValidations>)target.get() validateUserInterfaceItem:item.get()]);
    perform(YES);
}

InputResult insertText(WebPageProxy& page, const String& extensionKey, const WebsiteAccess& access, const String& text)
{
    if (auto result = checkInputAccess(page, extensionKey, access); !result)
        return result;
    [viewOfPage(page) _aquaWebKitInsertExtensionText:text.createNSString().get()];
    return { };
}

} // namespace WebKit::LegacyExtensions
