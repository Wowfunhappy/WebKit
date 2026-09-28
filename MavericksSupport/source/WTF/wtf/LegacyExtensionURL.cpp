#include "config.h"
#include "LegacyExtensionURL.h"

#include <wtf/URL.h>
#include <wtf/text/MakeString.h>

namespace WTF {

std::optional<URL> resolveLegacyExtensionRootRelativeURL(const URL& base, const String& relative, const URLTextEncoding* encoding)
{
    if (!base.protocolIs("safari-extension"_s))
        return std::nullopt;

    // The URL parser ignores leading and trailing C0 controls and spaces, and every tab and newline.
    auto reference = StringView { relative }.trim([](char16_t character) { return character <= ' '; }).toString().removeCharacters([](char16_t character) {
        return character == '\t' || character == '\n' || character == '\r';
    });
    if (!reference.startsWith('/') || reference.startsWith("//"_s))
        return std::nullopt;

    auto basePath = base.path();
    size_t tokenEnd = basePath.find('/', 1);
    if (!basePath.startsWith('/') || tokenEnd == notFound)
        return std::nullopt;
    auto root = basePath.left(tokenEnd + 1);
    if (reference.startsWith(root) || reference == basePath.left(tokenEnd))
        return std::nullopt;

    URL rootURL = base;
    rootURL.setPath(root);
    rootURL.removeQueryAndFragmentIdentifier();
    return URL(rootURL, makeString('.', reference), encoding);
}

} // namespace WTF
