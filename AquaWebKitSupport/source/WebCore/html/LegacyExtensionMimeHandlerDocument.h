// The document viewers Safari 7 extensions supply through the mimeHandler API (a WebExtension's
// `mime_types_handler`). A frame whose response has a type an extension handles shows a
// LegacyExtensionMimeHandlerDocument, which hosts the extension's handler page in a frame filling it, as a
// PDFJSDocument hosts WebCore's PDF.js viewer. The handler page reads the response's body through the API.

#pragma once

#include "HTMLDocument.h"
#include <wtf/Function.h>
#include <wtf/HashMap.h>
#include <wtf/text/StringHash.h>

namespace WebCore {

class FragmentedSharedBuffer;
class HTMLIFrameElement;
class JSDOMGlobalObject;

struct LegacyExtensionMimeHandler {
    String extensionKey;
    URL handlerURL;
    // Whether the handler also serves <embed>, <object> and frames, and not only top-level documents.
    bool canEmbed { false };
};

class LegacyExtensionMimeHandlerDocument final : public HTMLDocument {
    WTF_MAKE_TZONE_ALLOCATED(LegacyExtensionMimeHandlerDocument);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(LegacyExtensionMimeHandlerDocument);
public:
    // The handler of each type, as the web process's router sends them.
    WEBCORE_EXPORT static void setHandlers(HashMap<String, LegacyExtensionMimeHandler, ASCIICaseInsensitiveHash>&&);
    // Whether a page shows the type: an extension handles it at the top level or embedded, and, while a frame's
    // response policy is decided, in that frame.
    WEBCORE_EXPORT static bool handles(const String& mimeType);
    // Whether an <embed> or <object> of the type shows the handler.
    WEBCORE_EXPORT static bool handlesEmbedded(const String& mimeType);

    // The document of a frame's response of a type a handler serves in that frame.
    static RefPtr<Document> createIfHandled(LocalFrame&, const URL&, const String& mimeType);

    // Scopes the decision of a frame's response policy, during which `handles` answers for that frame: a frame
    // below the top level shows a type only when its handler embeds.
    class ResponsePolicyScope {
        WTF_MAKE_NONCOPYABLE(ResponsePolicyScope);
    public:
        WEBCORE_EXPORT explicit ResponsePolicyScope(const LocalFrame&);
        WEBCORE_EXPORT ~ResponsePolicyScope();

    private:
        std::optional<bool> m_previousFrameIsEmbedded;
    };
    // The document whose handler page the frame shows.
    WEBCORE_EXPORT static LegacyExtensionMimeHandlerDocument* forHandlerFrame(LocalFrame&);

    ~LegacyExtensionMimeHandlerDocument();

    const String& extensionKey() const LIFETIME_BOUND { return m_handler.extensionKey; }
    const String& mimeType() const LIFETIME_BOUND { return m_mimeType; }
    bool isEmbedded() const { return m_isEmbedded; }

    // Calls back once the response's body has arrived, with the body, or null when the load failed.
    WEBCORE_EXPORT void whenBodyIsComplete(Function<void(RefPtr<FragmentedSharedBuffer>&&)>&&);
    // The body as a Blob of the response's type, in a global object of the handler page.
    WEBCORE_EXPORT JSC::JSValue bodyBlob(JSDOMGlobalObject&, Ref<FragmentedSharedBuffer>&&) const;
    // The browser's own handling: the response downloads, and the handler page goes away.
    WEBCORE_EXPORT void fallBackToBrowser();

    void bodyDidStart();
    void bodyDidFinish();

private:
    LegacyExtensionMimeHandlerDocument(LocalFrame&, const URL&, const String& mimeType, const LegacyExtensionMimeHandler&, bool isEmbedded);

    Ref<DocumentParser> createParser() final;
    void createDocumentStructure();

    LegacyExtensionMimeHandler m_handler;
    String m_mimeType;
    bool m_isEmbedded { false };
    bool m_hasStructure { false };
    bool m_bodyIsComplete { false };
    RefPtr<HTMLIFrameElement> m_handlerFrameOwner;
    Vector<Function<void(RefPtr<FragmentedSharedBuffer>&&)>> m_bodyWaiters;
};

} // namespace WebCore
