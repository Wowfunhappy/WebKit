#include "config.h"
#include "LegacyExtensionScheme.h"

#include <WebCore/LegacySchemeRegistry.h>

namespace WebKit::LegacyExtensions {

void registerExtensionScheme()
{
    static constexpr auto scheme = "safari-extension"_s;
    WebCore::LegacySchemeRegistry::registerURLSchemeAsSecure(scheme);
    WebCore::LegacySchemeRegistry::registerURLSchemeAsHandledBySchemeHandler(scheme);
    WebCore::LegacySchemeRegistry::registerURLSchemeAsBypassingContentSecurityPolicy(scheme);
}

} // namespace WebKit::LegacyExtensions
