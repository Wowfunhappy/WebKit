#include "config.h"
#include "LegacyExtensionURL.h"

#include <wtf/ASCIICType.h>
#include <wtf/URL.h>
#include <wtf/text/MakeString.h>

namespace WTF {

static bool startsWithScheme(StringView reference)
{
    if (reference.isEmpty() || !isASCIIAlpha(reference[0]))
        return false;
    for (auto character : reference.codeUnits()) {
        if (character == ':')
            return true;
        if (!isASCIIAlphanumeric(character) && character != '+' && character != '-' && character != '.')
            return false;
    }
    return false;
}

std::optional<LegacyExtensionRoot> legacyExtensionRootForReference(const URL& base, const String& relative)
{
    if (!base.protocolIs("safari-extension"_s))
        return std::nullopt;

    // The URL parser ignores leading and trailing C0 controls and spaces, and every tab and newline.
    auto reference = StringView { relative }.trim([](char16_t character) { return character <= ' '; }).toString().removeCharacters([](char16_t character) {
        return character == '\t' || character == '\n' || character == '\r';
    });
    if (reference.startsWith("//"_s) || startsWithScheme(reference))
        return std::nullopt;

    auto basePath = base.path();
    size_t tokenEnd = basePath.find('/', 1);
    if (!basePath.startsWith('/') || tokenEnd == notFound)
        return std::nullopt;
    auto rootPath = basePath.left(tokenEnd);

    // A reference that spells the root names the same place as one that starts at it.
    if (reference.startsWith(rootPath) && (reference.length() == rootPath.length() || reference[rootPath.length()] == '/' || reference[rootPath.length()] == '?' || reference[rootPath.length()] == '#')) {
        reference = reference.substring(rootPath.length());
        if (!reference.startsWith('/'))
            reference = makeString('/', reference);
    }

    URL baseBelowRoot = base;
    baseBelowRoot.setPath(basePath.substring(tokenEnd));
    return LegacyExtensionRoot { WTF::move(baseBelowRoot), WTF::move(reference), rootPath.toString() };
}

void placeUnderLegacyExtensionRoot(URL& url, const LegacyExtensionRoot& root)
{
    if (url.isValid())
        url.setPath(makeString(root.path, url.path()));
}

} // namespace WTF
