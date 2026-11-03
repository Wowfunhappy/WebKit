#include "config.h"
#include "LegacyExtensionResourceAccess.h"

#include "Attribute.h"
#include "CSSParserTokenRange.h"
#include "CSSTokenizer.h"
#include "ContentExtensionActions.h"
#include "CommonVM.h"
#include "DOMWrapperWorld.h"
#include "DocumentInlines.h"
#include "Element.h"
#include "HTMLNames.h"
#include "HTMLSrcsetParser.h"
#include "JSDOMGlobalObject.h"
#include "LocalFrame.h"
#include "OriginAccessPatterns.h"
#include "ResourceResponse.h"
#include "UserContentURLPattern.h"
#include <JavaScriptCore/CallFrameInlines.h>
#include <JavaScriptCore/VM.h>
#include <pal/text/DecodeEscapeSequences.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/Lock.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringHash.h>

namespace WebCore {

using namespace HTMLNames;

static constexpr auto scheme = "safari-extension"_s;

static Lock accessLock;
static LegacyExtensionResourceAccess::Client* client;
static const URL* ownRead;
static String parsingStyleSheetExtensionKey;

// A path as the volume Safari's file protocol reads resolves it: decoded, composed, without regard to case, and
// without the code points HFS+ ignores in a name.
static String canonicalPath(StringView path)
{
    return normalizedNFC(PAL::decodeURLEscapeSequences(path)).removeCharacters([](char16_t character) {
        return (character >= 0x200C && character <= 0x200F) || (character >= 0x202A && character <= 0x202E) || (character >= 0x206A && character <= 0x206F) || character == 0xFEFF;
    }).foldCase();
}

// Encoded separators and encoded dot segments, which name another file once decoded.
static bool escapesItsDirectory(StringView path)
{
    auto canonical = canonicalPath(path);
    return canonical.contains('\\') || canonical.contains("/../"_s) || canonical.contains("/./"_s) || canonical.endsWith("/.."_s) || canonical.endsWith("/."_s)
        || path.containsIgnoringASCIICase("%2f"_s) || path.containsIgnoringASCIICase("%5c"_s);
}

// An extension's entry in policies(). Hosts match without regard to ASCII case, as origin access patterns do.
static String policyKey(StringView host, StringView rootPath)
{
    return makeString(host.convertToASCIILowercase(), canonicalPath(rootPath));
}

// Whether a path pattern with `*`, each already canonical, matches a path.
static bool matchesPathPattern(StringView pattern, StringView path)
{
    size_t patternIndex = 0;
    size_t pathIndex = 0;
    std::optional<std::pair<size_t, size_t>> lastStar;
    while (pathIndex < path.length()) {
        if (patternIndex < pattern.length() && pattern[patternIndex] == '*') {
            lastStar = { ++patternIndex, pathIndex };
            continue;
        }
        if (patternIndex < pattern.length() && pattern[patternIndex] == path[pathIndex]) {
            ++patternIndex;
            ++pathIndex;
            continue;
        }
        if (!lastStar)
            return false;
        patternIndex = lastStar->first;
        pathIndex = ++lastStar->second;
    }
    while (patternIndex < pattern.length() && pattern[patternIndex] == '*')
        ++patternIndex;
    return patternIndex == pattern.length();
}

// What a policy lists, as canonical path patterns from the root's own path.
struct PolicyPaths {
    Vector<String> accessible;
    Vector<String> inaccessible;
};

static HashMap<String, PolicyPaths>& policies() WTF_REQUIRES_LOCK(accessLock)
{
    static NeverDestroyed<HashMap<String, PolicyPaths>> policies;
    return policies;
}

static HashSet<String>& allowedPatterns() WTF_REQUIRES_LOCK(accessLock)
{
    static NeverDestroyed<HashSet<String>> patterns;
    return patterns;
}

static void allowPattern(StringView host, StringView path)
{
    UserContentURLPattern pattern { scheme, host, path };
    if (!pattern.isValid())
        return;
    {
        Locker locker { accessLock };
        if (!allowedPatterns().add(makeString(host, path)).isNewEntry)
            return;
    }
    OriginAccessPatternsForWebProcess::singleton().allowAccessTo(pattern);
}

static StringView withoutLeadingSlashes(StringView path)
{
    while (path.startsWith('/'))
        path = path.substring(1);
    return path;
}

// A frame's document, or the document of a template in one, whose content a script can then move into the frame's.
static bool isDocumentOfFrame(Document& document)
{
    if (document.frame())
        return true;
    RefPtr host = document.templateDocumentHost();
    return host && host->frame();
}

static String callingExtensionKey()
{
    if (!client || !isMainThread())
        return { };
    auto& vm = commonVM();
    auto* callFrame = vm.topCallFrame;
    if (!callFrame || callFrame == JSC::CallFrame::noCaller())
        return { };
    auto& world = currentWorld(*callFrame->lexicalGlobalObject(vm));
    if (world.isNormal())
        return { };
    return client->extensionKeyOfWorld(world);
}

void LegacyExtensionResourceAccess::setClient(Client* newClient)
{
    client = newClient;
}

String LegacyExtensionResourceAccess::policyKeyOfRoot(const String& root)
{
    URL url { root };
    return policyKey(url.host(), url.path());
}

void LegacyExtensionResourceAccess::setPolicies(const Vector<Policy>& newPolicies)
{
    HashMap<String, PolicyPaths> canonicalPolicies;
    for (auto& policy : newPolicies) {
        URL root { policy.root };
        if (!root.protocolIs(scheme))
            continue;
        auto canonicalPaths = [&](auto& paths) {
            return paths.map([&](auto& path) {
                return canonicalPath(makeString(root.path(), withoutLeadingSlashes(path)));
            });
        };
        canonicalPolicies.set(policyKey(root.host(), root.path()), PolicyPaths { canonicalPaths(policy.accessible), canonicalPaths(policy.inaccessible) });
    }
    Locker locker { accessLock };
    policies() = WTF::move(canonicalPolicies);
}

std::optional<bool> LegacyExtensionResourceAccess::accessOverride(const URL& url)
{
    if (!url.protocolIs(scheme))
        return std::nullopt;
    if (isMainThread() && ownRead && *ownRead == url)
        return true;
    auto path = url.path();
    if (escapesItsDirectory(path))
        return false;
    auto canonical = canonicalPath(path);
    auto tokenEnd = path.find('/', 1);
    if (tokenEnd == notFound)
        return std::nullopt;
    auto rootKey = policyKey(url.host(), path.left(tokenEnd + 1));
    if (client && isMainThread()) {
        bool hasRootPolicy;
        {
            Locker locker { accessLock };
            hasRootPolicy = policies().contains(rootKey);
        }
        if (!hasRootPolicy)
            client->policyNeeded(makeString(scheme, "://"_s, url.host(), path.left(tokenEnd + 1)));
    }
    Locker locker { accessLock };
    auto iterator = policies().find(rootKey);
    if (iterator == policies().end())
        return std::nullopt;
    auto anyMatches = [&](auto& patterns) {
        return std::ranges::any_of(patterns, [&](auto& pattern) {
            return matchesPathPattern(pattern, canonical);
        });
    };
    if (anyMatches(iterator->value.inaccessible))
        return false;
    if (anyMatches(iterator->value.accessible))
        return true;
    return std::nullopt;
}

bool LegacyExtensionResourceAccess::ruleMayRedirect(const URL& url, const ContentExtensions::RedirectAction& action, const URL& extensionBaseURL)
{
    auto target = url;
    auto redirect = action;
    redirect.modifyURL(target, extensionBaseURL);
    if (!target.protocolIs(scheme))
        return true;
    const OriginAccessPatterns& patterns = OriginAccessPatternsForWebProcess::singleton();
    return patterns.anyPatternMatches(target);
}

bool LegacyExtensionResourceAccess::isInaccessible(const URL& url)
{
    auto access = accessOverride(url);
    return access && !*access;
}

bool LegacyExtensionResourceAccess::callerOwns(const URL& url)
{
    if (!url.protocolIs(scheme))
        return false;
    auto extensionKey = callingExtensionKey();
    return !extensionKey.isEmpty() && url.host() == extensionKey;
}

void LegacyExtensionResourceAccess::expose(const URL& url)
{
    // A `*` in a host or path written into a page is a name, which a pattern would read as a wildcard.
    if (!url.protocolIs(scheme) || url.path().contains('*') || url.host().contains('*'))
        return;
    allowPattern(url.host(), url.path());
}

void LegacyExtensionResourceAccess::exposeFromCallingWorld(const URL& url)
{
    if (callerOwns(url))
        expose(url);
}

void LegacyExtensionResourceAccess::exposeURLsInStyleText(StringView text, const String& extensionKey)
{
    if (extensionKey.isEmpty())
        return;
    static constexpr auto prefix = "safari-extension:"_s;
    size_t start = text.findIgnoringASCIICase(prefix);
    while (start != notFound) {
        size_t end = start + prefix.length();
        while (end < text.length() && !isASCIIWhitespace(text[end]) && text[end] != '"' && text[end] != '\'' && text[end] != ')' && text[end] != ',' && text[end] != ';')
            ++end;
        if (URL url { text.substring(start, end - start).toString() }; url.host() == extensionKey)
            expose(url);
        start = text.findIgnoringASCIICase(prefix, end);
    }
}

void LegacyExtensionResourceAccess::styleTextFromScript(StringView text)
{
    if (auto extensionKey = callingExtensionKey(); !extensionKey.isEmpty())
        exposeURLsInStyleText(text, extensionKey);
}

void LegacyExtensionResourceAccess::attributeWillChange(Element& element, const QualifiedName& name, const AtomString& value, bool isCloning)
{
    if (value.isEmpty())
        return;
    bool isListOfURLs = name == srcsetAttr || name == imagesrcsetAttr;
    bool isStyle = name == styleAttr;
    if (!isListOfURLs && !isStyle) {
        // The URL parser ignores leading whitespace and the case of a scheme.
        unsigned start = 0;
        while (start < value.length() && value[start] <= ' ')
            ++start;
        if (start == value.length() || toASCIILower(value[start]) != 's')
            return;
    }
    if (isCloning || !isDocumentOfFrame(element.document()))
        return;
    auto extensionKey = callingExtensionKey();
    if (extensionKey.isEmpty())
        return;
    if (isStyle)
        return exposeURLsInStyleText(value, extensionKey);
    if (isListOfURLs) {
        for (auto& candidate : parseImageCandidatesFromSrcsetAttribute(value)) {
            if (URL url { candidate.string.view.toString() }; url.protocolIs(scheme) && url.host() == extensionKey)
                expose(url);
        }
        return;
    }
    Attribute attribute { name, value };
    if (!element.isURLAttribute(attribute) && !element.attributeContainsURL(attribute))
        return;
    if (URL url { value.string() }; url.protocolIs(scheme) && url.host() == extensionKey)
        expose(url);
}

void LegacyExtensionResourceAccess::styleElementChildrenChanged(Element& element, bool isCloning)
{
    if (isCloning || !isDocumentOfFrame(element.document()))
        return;
    if (auto extensionKey = callingExtensionKey(); !extensionKey.isEmpty())
        exposeURLsInStyleText(element.textContent(), extensionKey);
}

void LegacyExtensionResourceAccess::styleURLDidResolve(const URL& url)
{
    if (isMainThread() && !parsingStyleSheetExtensionKey.isEmpty() && url.protocolIs(scheme) && url.host() == parsingStyleSheetExtensionKey)
        expose(url);
}

void LegacyExtensionResourceAccess::moduleDidResolve(const URL& url, const URL& importer, bool importerIsFetchedModule)
{
    if (!url.protocolIs(scheme))
        return;
    if (importerIsFetchedModule && importer.protocolIs(scheme) && importer.host() == url.host())
        expose(url);
    else
        exposeFromCallingWorld(url);
}

URL LegacyExtensionResourceAccess::extensionStyleSheetURL(const ResourceResponse& response)
{
    auto& url = response.url();
    if (!url.protocolIs(scheme) || !url.path().endsWithIgnoringASCIICase(".css"_s))
        return { };
    return url;
}

LegacyExtensionResourceAccess::StyleSheetParseScope::StyleSheetParseScope(const URL& sheetURL, const String& text)
{
    if (!isMainThread())
        return;
    m_previousExtensionKey = std::exchange(parsingStyleSheetExtensionKey, sheetURL.protocolIs(scheme) ? sheetURL.host().toString() : String());
    if (parsingStyleSheetExtensionKey.isEmpty())
        return;
    auto exposeReference = [&](StringView reference) {
        if (URL url { sheetURL, reference.toString() }; url.protocolIs(scheme) && url.host() == parsingStyleSheetExtensionKey)
            expose(url);
    };
    CSSTokenizer tokenizer { text };
    auto range = tokenizer.tokenRange();
    while (!range.atEnd()) {
        auto& token = range.consumeIncludingWhitespace();
        if (token.type() == UrlToken)
            exposeReference(token.value());
        else if (token.type() == FunctionToken && equalLettersIgnoringASCIICase(token.value(), "url"_s) && !range.atEnd() && range.peek().type() == StringToken)
            exposeReference(range.peek().value());
    }
}

LegacyExtensionResourceAccess::StyleSheetParseScope::~StyleSheetParseScope()
{
    if (isMainThread())
        parsingStyleSheetExtensionKey = WTF::move(m_previousExtensionKey);
}

LegacyExtensionResourceAccess::OwnReadScope::OwnReadScope(const URL* url)
    : m_previousOwnRead(std::exchange(ownRead, url))
{
}

LegacyExtensionResourceAccess::OwnReadScope::~OwnReadScope()
{
    ownRead = m_previousOwnRead;
}

} // namespace WebCore
