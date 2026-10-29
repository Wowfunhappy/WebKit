// `aqua.input` for Safari 7 legacy extensions: user input an extension gives a tab.
//
// Each event is an AppKit event the tab's web view handles as it handles the window's events, whether or not
// the view is in a window: WebCore receives it as the user's input. The view marks it as an extension's: a drag
// it starts ends at once, it shows no native menu, and a key the page leaves unhandled goes no further. Mouse events
// report the buttons the tab's input from extensions holds down and the movement from its last position, as
// a pointing device does. Mouse and wheel events are at points of the tab's viewport in CSS pixels, which
// the page's zoom and scale map to the view. A mouse or key event completes once the page has processed
// every pending event of its kind. Inserted text is sent to the page at once, ahead of anything the extension
// sends after it; a wheel event completes once it is handed to the page, unordered with later input. Input
// reaches any page the tab shows, so it takes website access to every site, and a page the extension sees.

#pragma once

#include "LegacyExtensionWebsiteAccess.h"
#include <wtf/CompletionHandler.h>
#include <wtf/Expected.h>
#include <wtf/JSONValues.h>
#include <wtf/text/WTFString.h>

namespace WebKit {
class WebPageProxy;
}

namespace WebKit::LegacyExtensions {

using InputResult = Expected<void, String>;
InputResult checkInputAccess(WebPageProxy&, const String& extensionKey, const WebsiteAccess&);
void dispatchMouseEvent(WebPageProxy&, const String& extensionKey, const WebsiteAccess&, const JSON::Object&, CompletionHandler<void(InputResult&&)>&&);
void dispatchKeyEvent(WebPageProxy&, const String& extensionKey, const WebsiteAccess&, const JSON::Object&, CompletionHandler<void(InputResult&&)>&&);
void performEditingAction(WebPageProxy&, const String& extensionKey, const WebsiteAccess&, const String& action, CompletionHandler<void(InputResult&&)>&&);
InputResult insertText(WebPageProxy&, const String& extensionKey, const WebsiteAccess&, const String&);

} // namespace WebKit::LegacyExtensions
