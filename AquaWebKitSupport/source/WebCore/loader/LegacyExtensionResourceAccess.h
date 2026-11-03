// The files of a Safari 7 extension a web page can use. safari-extension: is a can-display-only-if-can-request scheme,
// so SecurityOrigin lets another origin's document load one of its files only through OriginAccessPatterns, which also
// lets the document read it. An extension's current policy answers for a file its Info.plist lists under
// `web_accessible_resources` or a declarativeNetRequest rule redirects to. A file gets an origin access pattern, which
// lasts as long as the process, as its memory cache does, when the extension itself exposes it to a page: its content
// script writes the file's URL into a URL attribute or into CSS it hands the page, or navigates to it; its injected
// style sheet, or the file of one of its exposed style sheets, refers to it; its exposed module or its content script
// imports it; or its webRequest listener redirects a request to it. `web_inaccessible_resources` overrides all of these.

#pragma once

#include <optional>
#include <wtf/Noncopyable.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

namespace ContentExtensions {
struct RedirectAction;
}

class DOMWrapperWorld;
class Element;
class QualifiedName;
class ResourceResponse;

class LegacyExtensionResourceAccess {
public:
    class Client {
    public:
        virtual ~Client() = default;
        // The extension a content-script world belongs to; empty for any other world.
        virtual String extensionKeyOfWorld(DOMWrapperWorld&) = 0;
        // A load asks about a file of the extension at `root`, whose policy this process does not have yet.
        virtual void policyNeeded(const String& root) = 0;
    };

    struct Policy {
        // safari-extension://<key>/<token>/
        String root;
        // Path patterns within the root, `*` matching any run of characters.
        Vector<String> accessible;
        Vector<String> inaccessible;
    };

    WEBCORE_EXPORT static void setClient(Client*);
    // What identifies an extension's root to its policy: another spelling of the root gives the same key.
    WEBCORE_EXPORT static String policyKeyOfRoot(const String& root);
    // Every extension's policy, replacing those from the last call.
    WEBCORE_EXPORT static void setPolicies(const Vector<Policy>&);

    // OriginAccessPatternsForWebProcess's answer before it looks at its patterns, when this class decides it.
    static std::optional<bool> accessOverride(const URL&);
    // Whether a declarativeNetRequest rule's redirect of `url` goes somewhere other than a file no page can use.
    static bool ruleMayRedirect(const URL&, const ContentExtensions::RedirectAction&, const URL& extensionBaseURL);
    // Whether no web page can use the file, whatever the extension does.
    WEBCORE_EXPORT static bool isInaccessible(const URL&);
    // Whether the running script is a content script of the extension the file belongs to.
    static bool callerOwns(const URL&);

    WEBCORE_EXPORT static void expose(const URL&);
    static void exposeFromCallingWorld(const URL&);
    // The extension's URLs in CSS, or in other text that an extension hands over as CSS.
    WEBCORE_EXPORT static void exposeURLsInStyleText(StringView, const String& extensionKey);
    static void styleTextFromScript(StringView);

    static void attributeWillChange(Element&, const QualifiedName&, const AtomString& value, bool isCloning);
    static void styleElementChildrenChanged(Element&, bool isCloning);
    // A URL in the style sheet being parsed.
    static void styleURLDidResolve(const URL&);
    // An import of `url` by the module `importer`, when no import map chose the URL. Only a fetched module is one.
    static void moduleDidResolve(const URL&, const URL& importer, bool importerIsFetchedModule);

    // The URL of a loaded style sheet that is an extension's: its file is named .css. A page can load any exposed file
    // as a style sheet, and Safari's file protocol serves .css and .txt files alike as text/plain.
    static URL extensionStyleSheetURL(const ResourceResponse&);

    // The parse of the text of a style sheet: the file at `sheetURL`, or an extension's injected style sheet at it.
    // It exposes the files of its own extension that it names, including in values that wait for substitution, which
    // are in its text; a style sheet from anywhere else exposes nothing.
    class StyleSheetParseScope {
        WTF_MAKE_NONCOPYABLE(StyleSheetParseScope);
    public:
        StyleSheetParseScope(const URL& sheetURL, const String& text);
        ~StyleSheetParseScope();
    private:
        String m_previousExtensionKey;
    };

    // A content script's own fetch or XMLHttpRequest of `url`, while it starts: the file is its to load, and
    // `web_inaccessible_resources` does not apply.
    class OwnReadScope {
        WTF_MAKE_NONCOPYABLE(OwnReadScope);
    public:
        explicit OwnReadScope(const URL* ownRead);
        ~OwnReadScope();
    private:
        const URL* m_previousOwnRead;
    };
};

} // namespace WebCore
