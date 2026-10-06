#pragma once

#include "PlatformExportMacros.h"

namespace WebCore {

class Document;
class UserStyleSheet;

// A style sheet Safari 7 extensions' tabs.insertCSS adds to one document, as the document's own
// page-specific user style sheets are: the page's style sheet list never shows it.
WEBCORE_EXPORT void injectLegacyExtensionStyleSheet(Document&, const UserStyleSheet&);
WEBCORE_EXPORT void removeLegacyExtensionStyleSheet(Document&, const UserStyleSheet&);

} // namespace WebCore
