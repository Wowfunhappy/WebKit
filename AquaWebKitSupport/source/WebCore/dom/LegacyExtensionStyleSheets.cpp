#include "config.h"
#include "LegacyExtensionStyleSheets.h"

#include "DocumentInlines.h"
#include "ExtensionStyleSheets.h"

namespace WebCore {

void injectLegacyExtensionStyleSheet(Document& document, const UserStyleSheet& styleSheet)
{
    document.extensionStyleSheets().injectPageSpecificUserStyleSheet(styleSheet);
}

void removeLegacyExtensionStyleSheet(Document& document, const UserStyleSheet& styleSheet)
{
    document.extensionStyleSheets().removePageSpecificUserStyleSheet(styleSheet);
}

} // namespace WebCore
