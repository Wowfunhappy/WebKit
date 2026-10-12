#include "config.h"
#include "LegacyExtensionMimeHandlerDocument.h"

#include "Blob.h"
#include "DocumentLoader.h"
#include "FrameDestructionObserverInlines.h"
#include "FrameLoader.h"
#include "HTMLBodyElement.h"
#include "HTMLHeadElement.h"
#include "HTMLHtmlElement.h"
#include "HTMLIFrameElement.h"
#include "HTMLNames.h"
#include "JSBlob.h"
#include "JSDOMGlobalObject.h"
#include "LocalFrame.h"
#include "RawDataDocumentParser.h"
#include "SharedBuffer.h"
#include <pal/text/TextEncoding.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WeakHashSet.h>
#include <wtf/text/MakeString.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(LegacyExtensionMimeHandlerDocument);

using namespace HTMLNames;

static HashMap<String, LegacyExtensionMimeHandler, ASCIICaseInsensitiveHash>& handlers()
{
    static NeverDestroyed<HashMap<String, LegacyExtensionMimeHandler, ASCIICaseInsensitiveHash>> handlers;
    return handlers;
}

static WeakHashSet<LegacyExtensionMimeHandlerDocument, WeakPtrImplWithEventTargetData>& documents()
{
    static NeverDestroyed<WeakHashSet<LegacyExtensionMimeHandlerDocument, WeakPtrImplWithEventTargetData>> documents;
    return documents;
}

// Whether the frame whose response policy is being decided is below the top level.
static std::optional<bool>& decidingFrameIsEmbedded()
{
    static std::optional<bool> isEmbedded;
    return isEmbedded;
}

LegacyExtensionMimeHandlerDocument::ResponsePolicyScope::ResponsePolicyScope(const LocalFrame& frame)
    : m_previousFrameIsEmbedded(std::exchange(decidingFrameIsEmbedded(), !frame.isMainFrame()))
{
}

LegacyExtensionMimeHandlerDocument::ResponsePolicyScope::~ResponsePolicyScope()
{
    decidingFrameIsEmbedded() = m_previousFrameIsEmbedded;
}

void LegacyExtensionMimeHandlerDocument::setHandlers(HashMap<String, LegacyExtensionMimeHandler, ASCIICaseInsensitiveHash>&& newHandlers)
{
    handlers() = WTF::move(newHandlers);
}

bool LegacyExtensionMimeHandlerDocument::handles(const String& mimeType)
{
    if (decidingFrameIsEmbedded().value_or(false))
        return handlesEmbedded(mimeType);
    return !mimeType.isEmpty() && handlers().contains(mimeType);
}

bool LegacyExtensionMimeHandlerDocument::handlesEmbedded(const String& mimeType)
{
    if (mimeType.isEmpty())
        return false;
    auto iterator = handlers().find(mimeType);
    return iterator != handlers().end() && iterator->value.canEmbed;
}

// The body arrives here; the document loader keeps it.
class LegacyExtensionMimeHandlerDocumentParser final : public RawDataDocumentParser {
public:
    static Ref<LegacyExtensionMimeHandlerDocumentParser> create(LegacyExtensionMimeHandlerDocument& document)
    {
        return adoptRef(*new LegacyExtensionMimeHandlerDocumentParser(document));
    }

private:
    explicit LegacyExtensionMimeHandlerDocumentParser(LegacyExtensionMimeHandlerDocument& document)
        : RawDataDocumentParser(document)
        , m_document(document)
    {
    }

    void appendBytes(DocumentWriter&, std::span<const uint8_t>) final
    {
        if (RefPtr document = m_document.get())
            document->bodyDidStart();
    }

    void finish() final
    {
        RefPtr document = m_document.get();
        if (document)
            document->bodyDidStart();
        RawDataDocumentParser::finish();
        if (document)
            document->bodyDidFinish();
    }

    WeakPtr<LegacyExtensionMimeHandlerDocument, WeakPtrImplWithEventTargetData> m_document;
};

RefPtr<Document> LegacyExtensionMimeHandlerDocument::createIfHandled(LocalFrame& frame, const URL& url, const String& mimeType)
{
    auto iterator = mimeType.isEmpty() ? handlers().end() : handlers().find(mimeType);
    bool isEmbedded = !frame.isMainFrame();
    if (iterator == handlers().end() || (isEmbedded && !iterator->value.canEmbed))
        return nullptr;
    Ref document = adoptRef(*new LegacyExtensionMimeHandlerDocument(frame, url, mimeType, iterator->value, isEmbedded));
    document->addToContextsMap();
    documents().add(document.get());
    return document;
}

LegacyExtensionMimeHandlerDocument* LegacyExtensionMimeHandlerDocument::forHandlerFrame(LocalFrame& frame)
{
    for (auto& document : documents()) {
        if (document.m_handlerFrameOwner && document.m_handlerFrameOwner->contentFrame() == &frame)
            return &document;
    }
    return nullptr;
}

LegacyExtensionMimeHandlerDocument::LegacyExtensionMimeHandlerDocument(LocalFrame& frame, const URL& url, const String& mimeType, const LegacyExtensionMimeHandler& handler, bool isEmbedded)
    : HTMLDocument(&frame, frame.settings(), url, { }, { DocumentClass::HTML })
    , m_handler(handler)
    , m_mimeType(mimeType)
    , m_isEmbedded(isEmbedded)
{
}

LegacyExtensionMimeHandlerDocument::~LegacyExtensionMimeHandlerDocument() = default;

Ref<DocumentParser> LegacyExtensionMimeHandlerDocument::createParser()
{
    return LegacyExtensionMimeHandlerDocumentParser::create(*this);
}

// The handler page fills the document, which is titled with the response's file name, as an image or media
// document is.
void LegacyExtensionMimeHandlerDocument::createDocumentStructure()
{
    Ref rootElement = HTMLHtmlElement::create(*this);
    appendChild(rootElement);
    rootElement->appendChild(HTMLHeadElement::create(*this));

    Ref body = HTMLBodyElement::create(*this);
    body->setAttribute(styleAttr, "margin: 0; height: 100vh;"_s);
    rootElement->appendChild(body);

    m_handlerFrameOwner = HTMLIFrameElement::create(iframeTag, *this);
    m_handlerFrameOwner->setAttribute(styleAttr, "width: 100%; height: 100%; border: 0; display: block;"_s);
    m_handlerFrameOwner->setAttribute(allowfullscreenAttr, emptyAtom());
    m_handlerFrameOwner->setAttribute(srcAttr, AtomString { m_handler.handlerURL.string() });
    body->appendChild(*m_handlerFrameOwner);

    if (auto fileName = PAL::decodeURLEscapeSequences(url().lastPathComponent()); !fileName.isEmpty())
        setTitle(WTF::move(fileName));
}

void LegacyExtensionMimeHandlerDocument::bodyDidStart()
{
    if (m_hasStructure)
        return;
    m_hasStructure = true;
    createDocumentStructure();
}

void LegacyExtensionMimeHandlerDocument::bodyDidFinish()
{
    m_bodyIsComplete = true;
    for (auto& waiter : std::exchange(m_bodyWaiters, { }))
        whenBodyIsComplete(WTF::move(waiter));
}

void LegacyExtensionMimeHandlerDocument::whenBodyIsComplete(Function<void(RefPtr<FragmentedSharedBuffer>&&)>&& completionHandler)
{
    if (!m_bodyIsComplete) {
        m_bodyWaiters.append(WTF::move(completionHandler));
        return;
    }
    RefPtr loader = this->loader();
    if (!loader || !loader->mainDocumentError().isNull())
        return completionHandler(nullptr);
    RefPtr body = loader->mainResourceData();
    completionHandler(body ? WTF::move(body) : RefPtr<FragmentedSharedBuffer> { SharedBuffer::create() });
}

JSC::JSValue LegacyExtensionMimeHandlerDocument::bodyBlob(JSDOMGlobalObject& globalObject, Ref<FragmentedSharedBuffer>&& body) const
{
    JSC::JSLockHolder lock(globalObject.vm());
    Ref blob = Blob::create(globalObject.scriptExecutionContext(), WTF::move(body), m_mimeType);
    return toJS(&globalObject, &globalObject, blob.get());
}

// The response downloads as a navigation of the document's frame to it with a download attribute does, through
// the browser's policy.
void LegacyExtensionMimeHandlerDocument::fallBackToBrowser()
{
    RefPtr frame = this->frame();
    RefPtr loader = this->loader();
    if (!frame || !loader)
        return;
    frame->loader().changeLocation(url(), nullAtom(), nullptr, referrerPolicy(), shouldOpenExternalURLsPolicyToPropagate(), NewFrameOpenerPolicy::Suppress, AtomString { ResourceResponse::sanitizeSuggestedFilename(loader->response().suggestedFilename()) });
    if (RefPtr owner = std::exchange(m_handlerFrameOwner, nullptr))
        owner->remove();
}

} // namespace WebCore
