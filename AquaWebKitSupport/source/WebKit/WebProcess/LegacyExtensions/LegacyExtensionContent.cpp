#include "config.h"
#include "LegacyExtensionContent.h"

#include "InjectedBundleScriptWorld.h"
#include "LegacyExtensionContentMessages.h"
#include "LegacyExtensionHostMessages.h"
#include "LegacyExtensionJavaScript.h"
#include "LegacyExtensionScheme.h"
#include "SharedBufferReference.h"
#include "WebFrame.h"
#include "WebPage.h"
#include "WebProcess.h"
#include "WebUserContentController.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/JSLock.h>
#include <WebCore/DOMWrapperWorld.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/DocumentPage.h>
#include <WebCore/HTMLFrameOwnerElement.h>
#include <WebCore/JSDOMWindow.h>
#include <WebCore/JSElement.h>
#include <WebCore/JSWindowProxy.h>
#include <WebCore/DocumentLoader.h>
#include <WebCore/LegacyExtensionMimeHandlerDocument.h>
#include <WebCore/LegacyExtensionStyleSheets.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/LocalFrameInlines.h>
#include <WebCore/MemoryCache.h>
#include <WebCore/Page.h>
#include <WebCore/ScriptController.h>
#include <WebCore/Settings.h>
#include <WebCore/UserScript.h>
#include <WebCore/UserStyleSheet.h>
#include <WebCore/WindowProxy.h>
#include <wtf/JSONValues.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>

namespace WebKit {

static constexpr auto extensionScheme = "safari-extension"_s;

// The native object LegacyExtensionAPI.js receives in a content context. A context stays bound to the
// document and world it was installed for: once its frame shows another document, or its world is
// withdrawn, the context is inert.
struct ContentContextNative {
    WebCore::FrameIdentifier frameID;
    WebCore::ScriptExecutionContextIdentifier documentIdentifier;
    String extensionKey;
    SingleThreadWeakPtr<WebCore::DOMWrapperWorld> world;
};

static RefPtr<WebCore::Document> documentForNative(const ContentContextNative& native)
{
    if (!native.world || !LegacyExtensionContent::singleton().isContextWorldLive(*native.world))
        return nullptr;
    RefPtr frame = WebFrame::webFrame(native.frameID);
    RefPtr coreFrame = frame ? frame->coreLocalFrame() : nullptr;
    RefPtr document = coreFrame ? coreFrame->document() : nullptr;
    if (!document || document->identifier() != native.documentIdentifier)
        return nullptr;
    return document;
}

static JSValueRef contentContextSend(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef*)
{
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    auto message = LegacyExtensions::stringArgument(context, argumentCount, arguments, 0);
    RefPtr document = !message.isNull() ? documentForNative(*native) : nullptr;
    if (document)
        WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::Post(native->frameID, native->documentIdentifier, document->url(), native->extensionKey, message, IPC::SharedBufferReference { LegacyExtensions::bufferArgument(context, argumentCount, arguments, 1) }), 0);
    return JSValueMakeUndefined(context);
}

// insertCSS(code, isAuthorLevel, url) and removeCSS(code): a style sheet of the context's document
// alone, which the page cannot see in document.styleSheets. A file's sheet has the file's URL; code's
// gets a URL of its own from UserStyleSheet, as upstream's do.
static JSValueRef contentContextInsertCSS(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef*)
{
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr document = documentForNative(*native);
    auto code = LegacyExtensions::stringArgument(context, argumentCount, arguments, 0);
    if (!document || code.isNull())
        return JSValueMakeUndefined(context);
    bool isAuthorLevel = argumentCount > 1 && JSValueToBoolean(context, arguments[1]);
    URL url { LegacyExtensions::stringArgument(context, argumentCount, arguments, 2) };
    LegacyExtensionContent::singleton().insertStyleSheet(*document, native->extensionKey, WebCore::UserStyleSheet { code, url.protocolIs(extensionScheme) ? url : URL { }, { }, { }, WebCore::UserContentInjectedFrames::InjectInAllFrames, WebCore::UserContentMatchParentFrame::Never, isAuthorLevel ? WebCore::UserStyleLevel::Author : WebCore::UserStyleLevel::User });
    return JSValueMakeUndefined(context);
}

static JSValueRef contentContextRemoveCSS(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef*)
{
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr document = documentForNative(*native);
    auto code = LegacyExtensions::stringArgument(context, argumentCount, arguments, 0);
    if (document && !code.isNull())
        LegacyExtensionContent::singleton().removeStyleSheets(*document, native->extensionKey, code);
    return JSValueMakeUndefined(context);
}

// frameId(target): the WebExtensions frame ID of a window, or of a frame element's content; -1 for
// anything else.
static JSValueRef contentContextFrameID(JSContextRef context, JSObjectRef, JSObjectRef, size_t argumentCount, const JSValueRef arguments[], JSValueRef*)
{
    if (!argumentCount)
        return JSValueMakeNumber(context, -1);
    auto* globalObject = toJS(context);
    auto& vm = globalObject->vm();
    JSC::JSLockHolder lock(vm);
    auto value = toJS(globalObject, arguments[0]);

    RefPtr<WebCore::Frame> frame;
    if (RefPtr window = WebCore::JSDOMWindow::toWrapped(vm, value))
        frame = window->frame();
    else if (RefPtr owner = dynamicDowncast<WebCore::HTMLFrameOwnerElement>(WebCore::JSElement::toWrapped(vm, value)))
        frame = owner->contentFrame();
    RefPtr webFrame = frame ? WebFrame::fromCoreFrame(*frame) : nullptr;
    if (!webFrame)
        return JSValueMakeNumber(context, -1);
    return JSValueMakeNumber(context, webFrame->isMainFrame() ? 0 : static_cast<double>(webFrame->frameID().toUInt64()));
}

// withClipboardWriteAccess(callback): calls callback with the context's page allowed to write the clipboard,
// as javaScriptCanAccessClipboard allows a WebExtension's pages, and returns its result. The page's own
// setting is back in place once the callback returns. A context whose document is gone calls it under the
// page's own rules.
static JSValueRef contentContextWithClipboardWriteAccess(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t, const JSValueRef arguments[], JSValueRef* exception)
{
    JSObjectRef callback = JSValueToObject(context, arguments[0], nullptr);
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr document = documentForNative(*native);
    RefPtr page = document ? document->page() : nullptr;
    if (!page)
        return JSObjectCallAsFunction(context, callback, nullptr, 0, nullptr, exception);

    auto& settings = page->settings();
    bool pageAllowsClipboardAccess = settings.javaScriptCanAccessClipboard();
    settings.setJavaScriptCanAccessClipboard(true);
    JSValueRef result = JSObjectCallAsFunction(context, callback, nullptr, 0, nullptr, exception);
    settings.setJavaScriptCanAccessClipboard(pageAllowsClipboardAccess);
    return result;
}

// A promise a native function returns, which a callback settles.
struct NativePromise {
    JSRetainPtr<JSGlobalContextRef> context;
    JSObjectRef resolve;
    JSObjectRef reject;

    NativePromise(JSContextRef context, JSObjectRef resolve, JSObjectRef reject)
        : context(JSContextGetGlobalContext(context)), resolve(resolve), reject(reject)
    {
        JSValueProtect(context, resolve);
        JSValueProtect(context, reject);
    }

    ~NativePromise()
    {
        JSValueUnprotect(context.get(), resolve);
        JSValueUnprotect(context.get(), reject);
    }

    void resolveWith(JSValueRef value)
    {
        JSObjectCallAsFunction(context.get(), resolve, nullptr, 1, &value, nullptr);
    }

    void rejectWith(const String& message)
    {
        auto string = adopt(JSStringCreateWithUTF8CString(message.utf8().data()));
        JSValueRef argument = JSValueMakeString(context.get(), string.get());
        JSValueRef error = JSObjectMakeError(context.get(), 1, &argument, nullptr);
        JSObjectCallAsFunction(context.get(), reject, nullptr, 1, &error, nullptr);
    }
};

// mimeHandler: the document whose handler page is the context's own, the extension's page in a frame.
static RefPtr<WebCore::LegacyExtensionMimeHandlerDocument> mimeHandlerDocument(const ContentContextNative& native)
{
    RefPtr document = documentForNative(native);
    RefPtr frame = document ? document->frame() : nullptr;
    RefPtr handlerDocument = frame ? WebCore::LegacyExtensionMimeHandlerDocument::forHandlerFrame(*frame) : nullptr;
    if (!handlerDocument || handlerDocument->extensionKey() != native.extensionKey)
        return nullptr;
    return handlerDocument;
}

// mimeHandlerStream(): a promise of the stream info getStreamInfo answers with, without its streamUrl, and with
// the response's body as `body`, a Blob, once the body has arrived.
static JSValueRef contentContextMimeHandlerStream(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t, const JSValueRef[], JSValueRef* exception)
{
    JSObjectRef resolve;
    JSObjectRef reject;
    auto promise = JSObjectMakeDeferredPromise(context, &resolve, &reject, exception);
    if (!promise)
        return JSValueMakeUndefined(context);
    auto pending = std::make_unique<NativePromise>(context, resolve, reject);
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr handlerDocument = mimeHandlerDocument(*native);
    RefPtr loader = handlerDocument ? handlerDocument->loader() : nullptr;
    RefPtr page = handlerDocument ? handlerDocument->page() : nullptr;
    RefPtr webPage = page ? WebPage::fromCorePage(*page) : nullptr;
    if (!loader || !webPage) {
        pending->rejectWith("No stream is attached to this page."_s);
        return promise;
    }

    auto info = JSON::Object::create();
    info->setBoolean("embedded"_s, handlerDocument->isEmbedded());
    info->setString("mimeType"_s, handlerDocument->mimeType());
    info->setString("originalUrl"_s, handlerDocument->url().string());
    auto headers = JSON::Object::create();
    for (auto& field : loader->response().httpHeaderFields())
        headers->setString(field.key, field.value);
    info->setObject("responseHeaders"_s, WTF::move(headers));
    info->setDouble("tabId"_s, static_cast<double>(webPage->webPageProxyIdentifier().toUInt64()));

    handlerDocument->whenBodyIsComplete([pending = WTF::move(pending), info = info->toJSONString(), native = *native](RefPtr<WebCore::FragmentedSharedBuffer>&& body) mutable {
        if (!body || !documentForNative(native))
            return pending->rejectWith("The stream failed."_s);
        JSContextRef context = pending->context.get();
        auto json = adopt(JSStringCreateWithUTF8CString(info.utf8().data()));
        JSObjectRef object = JSValueToObject(context, JSValueMakeFromJSONString(context, json.get()), nullptr);
        auto* globalObject = dynamicDowncast<WebCore::JSDOMGlobalObject>(toJS(context));
        if (!object || !globalObject)
            return pending->rejectWith("The stream failed."_s);
        RefPtr handlerDocument = mimeHandlerDocument(native);
        if (!handlerDocument)
            return pending->rejectWith("The stream failed."_s);
        // The body, as a Blob of the handler page holding the response's own buffer.
        JSValueRef blobValue;
        {
            JSC::JSLockHolder lock(globalObject->vm());
            blobValue = toRef(globalObject, handlerDocument->bodyBlob(*globalObject, body.releaseNonNull()));
        }
        auto name = adopt(JSStringCreateWithUTF8CString("body"));
        JSObjectSetProperty(context, object, name.get(), blobValue, kJSPropertyAttributeNone, nullptr);
        pending->resolveWith(object);
    });
    return promise;
}

// mimeHandlerFallBack(): hands the response to the browser's own handling; false when no stream is attached.
static JSValueRef contentContextMimeHandlerFallBack(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t, const JSValueRef[], JSValueRef*)
{
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr handlerDocument = mimeHandlerDocument(*native);
    if (handlerDocument)
        handlerDocument->fallBackToBrowser();
    return JSValueMakeBoolean(context, !!handlerDocument);
}

static void contentContextFinalize(JSObjectRef object)
{
    delete static_cast<ContentContextNative*>(JSObjectGetPrivate(object));
}

static JSClassRef contentContextNativeClass(LegacyExtensions::ContextKind kind)
{
    static JSClassRef contentClass = [] {
        static const JSStaticFunction functions[] = {
            { "send", contentContextSend, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "insertCSS", contentContextInsertCSS, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "removeCSS", contentContextRemoveCSS, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "frameId", contentContextFrameID, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { nullptr, nullptr, 0 },
        };
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.className = "LegacyExtensionNative";
        definition.staticFunctions = functions;
        definition.finalize = contentContextFinalize;
        return JSClassCreate(&definition);
    }();
    // An extension page shown in a frame of this process writes the clipboard as its pages do, and reads the
    // stream of the mimeHandler document it is the handler page of. Its parent class's finalizer releases the
    // private data.
    static JSClassRef hostClass = [] {
        static const JSStaticFunction functions[] = {
            { "withClipboardWriteAccess", contentContextWithClipboardWriteAccess, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "mimeHandlerStream", contentContextMimeHandlerStream, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "mimeHandlerFallBack", contentContextMimeHandlerFallBack, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { nullptr, nullptr, 0 },
        };
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.className = "LegacyExtensionNative";
        definition.parentClass = contentClass;
        definition.staticFunctions = functions;
        return JSClassCreate(&definition);
    }();
    return kind == LegacyExtensions::ContextKind::Host ? hostClass : contentClass;
}

static WebCore::JSDOMGlobalObject* existingGlobalObject(WebCore::LocalFrame& frame, WebCore::DOMWrapperWorld& world)
{
    auto* windowProxy = frame.windowProxy().existingJSWindowProxy(world);
    return windowProxy ? windowProxy->window() : nullptr;
}

LegacyExtensionContent& LegacyExtensionContent::singleton()
{
    static NeverDestroyed<LegacyExtensionContent> content;
    return content;
}

void LegacyExtensionContent::initialize(WebProcess& process)
{
    LegacyExtensions::registerExtensionScheme();
    process.addMessageReceiver(Messages::LegacyExtensionContent::messageReceiverName(), *this);
}

static String extensionKeyForURL(const URL& url)
{
    if (!url.protocolIs(extensionScheme))
        return { };
    return url.host().toString();
}

// The extension a content-script world belongs to: the one whose safari-extension:// URLs the world's
// user content has. A world Safari withdrew holds none.
static String extensionKeyOfContentWorld(WebCore::DOMWrapperWorld& world)
{
    RefPtr bundleWorld = world.isNormal() ? nullptr : InjectedBundleScriptWorld::get(world);
    if (!bundleWorld)
        return { };
    String extensionKey;
    WebUserContentController::forEachUserContentOfAllControllers([&](auto& candidate, auto* script, auto* styleSheet) {
        if (extensionKey.isEmpty() && &candidate == bundleWorld.get())
            extensionKey = extensionKeyForURL(script ? script->url() : styleSheet->url());
    });
    return extensionKey;
}

bool LegacyExtensionContent::isContextWorldLive(WebCore::DOMWrapperWorld& world) const
{
    return world.isNormal() || !extensionKeyOfContentWorld(world).isEmpty();
}

WebCore::DOMWrapperWorld* LegacyExtensionContent::contentScriptWorld(const String& extensionKey) const
{
    WebCore::DOMWrapperWorld* world = nullptr;
    WebUserContentController::forEachUserContentOfAllControllers([&](auto& candidate, auto* script, auto* styleSheet) {
        if (!world && extensionKeyForURL(script ? script->url() : styleSheet->url()) == extensionKey)
            world = &candidate.coreWorld();
    });
    return world;
}

String LegacyExtensionContent::extensionKeyForWorld(WebFrame& frame, WebCore::DOMWrapperWorld& world) const
{
    if (!world.isNormal())
        return extensionKeyOfContentWorld(world);
    RefPtr coreFrame = frame.coreLocalFrame();
    RefPtr document = coreFrame ? coreFrame->document() : nullptr;
    if (!document)
        return { };
    return extensionKeyForURL(document->url());
}

void LegacyExtensionContent::didClearWindowObjectForFrame(WebFrame& frame, WebCore::DOMWrapperWorld& world)
{
    auto extensionKey = extensionKeyForWorld(frame, world);
    if (extensionKey.isEmpty())
        return;
    RefPtr coreFrame = frame.coreLocalFrame();
    RefPtr document = coreFrame ? coreFrame->document() : nullptr;
    if (!document)
        return;
    auto* globalObject = coreFrame->script().globalObject(world);
    if (!globalObject)
        return;
    // The main world of a frame showing an extension page is that page; any other world is a content script.
    auto kind = world.isNormal() ? LegacyExtensions::ContextKind::Host : LegacyExtensions::ContextKind::Content;
    // Content scripts reach closed shadow roots through browser.dom.openOrClosedShadowRoot.
    if (kind == LegacyExtensions::ContextKind::Content)
        world.setClosedShadowRootIsExposedForExtensions();
    LegacyExtensions::installAPI(*globalObject, kind, contentContextNativeClass(kind), new ContentContextNative { frame.frameID(), document->identifier(), extensionKey, world });
}

void LegacyExtensionContent::insertStyleSheet(WebCore::Document& document, const String& extensionKey, WebCore::UserStyleSheet&& styleSheet)
{
    WebCore::injectLegacyExtensionStyleSheet(document, styleSheet);
    m_injectedStyleSheets.ensure(document, [] { return Vector<InjectedStyleSheet> { }; }).iterator->value.append({ extensionKey, WTF::move(styleSheet) });
}

void LegacyExtensionContent::removeStyleSheets(WebCore::Document& document, const String& extensionKey, const String& source)
{
    auto iterator = m_injectedStyleSheets.find(document);
    if (iterator == m_injectedStyleSheets.end())
        return;
    iterator->value.removeAllMatching([&](auto& injected) {
        if (injected.extensionKey != extensionKey || injected.styleSheet.source() != source)
            return false;
        WebCore::removeLegacyExtensionStyleSheet(document, injected.styleSheet);
        return true;
    });
}

void LegacyExtensionContent::evictMemoryCache()
{
    WebCore::MemoryCache::singleton().evictResources();
}

void LegacyExtensionContent::setMimeHandlers(String&& handlersJSON)
{
    HashMap<String, WebCore::LegacyExtensionMimeHandler, ASCIICaseInsensitiveHash> handlers;
    auto value = JSON::Value::parseJSON(handlersJSON);
    if (RefPtr array = value ? value->asArray() : nullptr) {
        for (auto& entry : *array) {
            RefPtr handler = entry->asObject();
            if (!handler)
                continue;
            handlers.set(handler->getString("mimeType"_s), WebCore::LegacyExtensionMimeHandler { handler->getString("extensionKey"_s), URL { handler->getString("handlerURL"_s) }, handler->getBoolean("canEmbed"_s).value_or(false) });
        }
    }
    WebCore::LegacyExtensionMimeHandlerDocument::setHandlers(WTF::move(handlers));
}

void LegacyExtensionContent::deliver(WebCore::FrameIdentifier frameID, std::optional<WebCore::ScriptExecutionContextIdentifier> documentID, String&& extensionKey, String&& message, IPC::SharedBufferReference&& data)
{
    RefPtr frame = WebFrame::webFrame(frameID);
    RefPtr coreFrame = frame ? frame->coreLocalFrame() : nullptr;
    RefPtr document = coreFrame ? coreFrame->document() : nullptr;
    if (!document)
        return;
    // A message for a document the frame no longer shows finds no context.
    if (documentID && document->identifier() != *documentID)
        return replyWithoutContext(frameID, *documentID, extensionKey, message);

    // A frame showing one of the extension's own pages hosts the page's context; any other frame, the
    // extension's content scripts.
    RefPtr<WebCore::DOMWrapperWorld> world;
    if (extensionKeyForWorld(*frame, WebCore::mainThreadNormalWorldSingleton()) == extensionKey)
        world = &WebCore::mainThreadNormalWorldSingleton();
    else
        world = contentScriptWorld(extensionKey);

    if (world) {
        if (auto* globalObject = existingGlobalObject(*coreFrame, *world); globalObject && LegacyExtensions::deliver(*globalObject, message, data.unsafeBuffer()))
            return;
    }

    replyWithoutContext(frameID, document->identifier(), extensionKey, message);
}

// A document with no context of the extension answers for it: scripts and style sheets run in the
// extension's content-script world of the frame's current document, created for them when it has none
// yet; ports and messages find no receiver.
void LegacyExtensionContent::replyWithoutContext(WebCore::FrameIdentifier frameID, WebCore::ScriptExecutionContextIdentifier documentID, const String& extensionKey, const String& message)
{
    auto value = JSON::Value::parseJSON(message);
    RefPtr object = value ? value->asObject() : nullptr;
    if (!object)
        return;
    auto type = object->getString("t"_s);

    RefPtr frame = WebFrame::webFrame(frameID);
    RefPtr coreFrame = frame ? frame->coreLocalFrame() : nullptr;
    RefPtr document = coreFrame ? coreFrame->document() : nullptr;
    if (document && document->identifier() != documentID)
        document = nullptr;
    URL documentURL = document ? document->url() : URL { };

    if (type == "exec"_s || type == "css"_s) {
        RefPtr world = contentScriptWorld(extensionKey);
        if (document && world) {
            auto* globalObject = coreFrame->script().globalObject(*world);
            if (globalObject && LegacyExtensions::deliver(*globalObject, message))
                return;
        }
        auto reply = JSON::Object::create();
        reply->setString("t"_s, "result"_s);
        if (auto callID = object->getDouble("callId"_s))
            reply->setDouble("callId"_s, *callID);
        reply->setString("error"_s, "The extension has no access to this frame."_s);
        WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::Post(frameID, documentID, documentURL, extensionKey, reply->toJSONString(), { }), 0);
        return;
    }

    auto reply = JSON::Object::create();
    if (type == "connect"_s) {
        reply->setString("t"_s, "disconnect"_s);
        reply->setString("portId"_s, object->getString("portId"_s));
    } else if (type == "message"_s) {
        reply->setString("t"_s, "reply"_s);
        reply->setString("msgId"_s, object->getString("msgId"_s));
        reply->setBoolean("none"_s, true);
    } else
        return;
    WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::Post(frameID, documentID, documentURL, extensionKey, reply->toJSONString(), { }), 0);
}

} // namespace WebKit
