// Firefox's tabs.saveAsPDF for Safari 7 extensions: a tab's page saved as a PDF file the user names in a
// save panel, printed as WebKit 2 prints a page.

#pragma once

#include <wtf/CompletionHandler.h>
#include <wtf/JSONValues.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class WebPageProxy;

namespace LegacyExtensions {

// Answers with Firefox's status: "saved", "replaced", "canceled", "not_saved" or "not_replaced".
// `pageSettings` is a tabs.PageSettings object.
void saveTabAsPDF(WebPageProxy&, const JSON::Object& pageSettings, CompletionHandler<void(String&&)>&&);

} // namespace LegacyExtensions

} // namespace WebKit
