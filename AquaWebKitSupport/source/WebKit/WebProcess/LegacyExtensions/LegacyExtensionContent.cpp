#include "config.h"
#include "LegacyExtensionContent.h"
#include "MediaRestreamSession.h"
#include <WebCore/MediaPlayer.h>
#include <WebCore/EventListener.h>
#include <WebCore/EventNames.h>
#include <WebCore/Event.h>
#include <wtf/RunLoop.h>
#include <wtf/Scope.h>
#include <map>

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
#include <WebCore/ActiveDOMObject.h>
#include <WebCore/ContextDestructionObserverInlines.h>
#include <WebCore/DOMWrapperWorld.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/DocumentPage.h>
#include <WebCore/HTMLFrameOwnerElement.h>
#include <WebCore/HTMLMediaElement.h>
#include <WebCore/SecurityOrigin.h>
#include <JavaScriptCore/JSRetainPtr.h>
#include <JavaScriptCore/JSStringRef.h>
#include <wtf/Expected.h>
#include <wtf/HashSet.h>
#include <cmath>
#include <vector>
#include <WebCore/JSDOMWindow.h>
#include <WebCore/JSElement.h>
#include <WebCore/JSTextTrack.h>
#include <WebCore/JSWindowProxy.h>
#include <WebCore/DocumentLoader.h>
#include <WebCore/LegacyExtensionMimeHandlerDocument.h>
#include <WebCore/LegacyExtensionStyleSheets.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/LocalFrameInlines.h>
#include <WebCore/MemoryCache.h>
#include <WebCore/Page.h>
#include <WebCore/PageInspectorController.h>
#include <WebCore/WebInjectedScriptManager.h>
#include <WebCore/RunJavaScriptParameters.h>
#include <WebCore/ScriptController.h>
#include <WebCore/Settings.h>
#include <WebCore/UserGestureIndicator.h>
#include <WebCore/UserScript.h>
#include <WebCore/UserStyleSheet.h>
#include <WebCore/WindowProxy.h>
#include <wtf/JSONValues.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>

namespace WebKit {

static constexpr auto extensionScheme = "safari-extension"_s;

// The native object LegacyExtensionAPI.js receives in a content context. A context stays bound to the
// document and world it was installed for, and a content script's to the copy of its extension, at `root`,
// whose user content the world held: once its frame shows another document, or that copy's user content is
// withdrawn from the world, the context is inert.
struct ContentContextNative {
    WebCore::FrameIdentifier frameID;
    WebCore::ScriptExecutionContextIdentifier documentIdentifier;
    String extensionKey;
    SingleThreadWeakPtr<WebCore::DOMWrapperWorld> world;
    String root;
};

static RefPtr<WebCore::Document> documentForNative(const ContentContextNative& native)
{
    if (!native.world || !LegacyExtensionContent::singleton().isContextLive(*native.world, native.root))
        return nullptr;
    RefPtr frame = WebFrame::webFrame(native.frameID);
    RefPtr coreFrame = frame ? frame->coreLocalFrame() : nullptr;
    RefPtr document = coreFrame ? coreFrame->document() : nullptr;
    if (!document || document->identifier() != native.documentIdentifier)
        return nullptr;
    return document;
}

// Tells the router that a document with extension contexts enters the back/forward cache. The document is
// suspended before its frame commits the next document, and the message goes ahead of that commit's on the
// same connection, so the router closes the document's channels with Chrome's error for a cached page.
class BackForwardCacheObserver final : public RefCounted<BackForwardCacheObserver>, public WebCore::ActiveDOMObject {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(BackForwardCacheObserver);
public:
    static Ref<BackForwardCacheObserver> create(WebCore::Document& document, WebCore::FrameIdentifier frameID, const String& extensionKey)
    {
        Ref observer = adoptRef(*new BackForwardCacheObserver(document, frameID, extensionKey));
        observer->suspendIfNeeded();
        return observer;
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    BackForwardCacheObserver(WebCore::Document& document, WebCore::FrameIdentifier frameID, const String& extensionKey)
        : ActiveDOMObject(document)
        , m_frameID(frameID)
        , m_extensionKey(extensionKey)
    {
    }

    void suspend(WebCore::ReasonForSuspension reason) final
    {
        RefPtr document = dynamicDowncast<WebCore::Document>(scriptExecutionContext());
        if (reason != WebCore::ReasonForSuspension::BackForwardCache || !document)
            return;
        WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::Post(m_frameID, document->identifier(), document->url(), m_extensionKey, "{\"t\":\"cached\"}"_s, { }), 0);
    }

    WebCore::FrameIdentifier m_frameID;
    String m_extensionKey;
};

// Each extension context of this process while its document exists, in the frame or in the back/forward
// cache: whether it is a content script's, and whether its world was live when user content last changed.
struct ExtensionContext {
    WeakPtr<WebCore::Document, WebCore::WeakPtrImplWithEventTargetData> document;
    WebCore::FrameIdentifier frameID;
    String extensionKey;
    SingleThreadWeakPtr<WebCore::DOMWrapperWorld> world;
    String root;
    bool isContentScript { false };
    bool wasLive { true };
    // One per document, shared by its contexts.
    RefPtr<BackForwardCacheObserver> backForwardCacheObserver;
    // An extension page whose extension Safari disabled or reloaded, as the router reports it.
    bool isInvalidated { false };
};

static Vector<ExtensionContext>& extensionContexts()
{
    static NeverDestroyed<Vector<ExtensionContext>> contexts;
    return contexts;
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

// isValid(): whether the context is valid. A context whose document is gone, a content script's whose world Safari
// withdrew when it disabled or reloaded the extension, and an extension page's the router invalidated for that, are
// invalidated, as Chrome invalidates an unloaded extension's contexts.
static JSValueRef contentContextIsValid(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t, const JSValueRef[], JSValueRef*)
{
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr document = documentForNative(*native);
    bool isInvalidated = document && std::ranges::any_of(extensionContexts(), [&](auto& extensionContext) {
        return extensionContext.isInvalidated && extensionContext.document == document.get() && extensionContext.world.get() == native->world.get();
    });
    return JSValueMakeBoolean(context, document && !isInvalidated);
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

// executeScript(code, userGesture): runs code as a classic script of the context's world, as upstream runs a
// WebExtension's injected code, with the caller's user gesture, and returns its completion value. Code that throws,
// or cannot run, returns null; ScriptController reports the exception to the frame's console.
static JSValueRef contentContextExecuteScript(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef*)
{
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr document = documentForNative(*native);
    RefPtr frame = document ? document->frame() : nullptr;
    auto code = LegacyExtensions::stringArgument(context, argumentCount, arguments, 0);
    if (!frame || code.isNull())
        return JSValueMakeNull(context);
    bool userGesture = argumentCount > 1 && JSValueToBoolean(context, arguments[1]);
    JSValueRef completionValue = JSValueMakeNull(context);
    frame->script().executeAsynchronousUserAgentScriptInWorld(*native->world, { WTF::move(code), JSC::SourceTaintedOrigin::Untainted, URL { }, false, std::nullopt, userGesture, WebCore::RemoveTransientActivation::Yes }, [&](WebCore::ValueOrException result) {
        if (!result)
            return;
        auto* globalObject = toJS(context);
        JSC::JSLockHolder lock(globalObject->vm());
        completionValue = toRef(globalObject, result.value());
    });
    return completionValue;
}

// isProcessingUserGesture(): whether the caller runs inside a user gesture, which a call it makes carries on as
// upstream's API calls do.
static JSValueRef contentContextIsProcessingUserGesture(JSContextRef context, JSObjectRef, JSObjectRef, size_t, const JSValueRef[], JSValueRef*)
{
    return JSValueMakeBoolean(context, WebCore::UserGestureIndicator::processingUserGesture());
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


// The JS completion owns only a weak request reference and can be called once.
static JSObjectRef sourceCompletion(JSContextRef context, Function<void(String)>&& completion)
{
    using Callback = Function<void(String)>;
    static JSClassRef callbackClass = [] {
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.className = "MediaSourceCompletion";
        definition.finalize = [](JSObjectRef object) { delete static_cast<Callback*>(JSObjectGetPrivate(object)); };
        definition.callAsFunction = [](JSContextRef context, JSObjectRef function, JSObjectRef, size_t count, const JSValueRef arguments[], JSValueRef*) -> JSValueRef {
            auto& callback = *static_cast<Callback*>(JSObjectGetPrivate(function));
            if (callback) {
                auto complete = std::exchange(callback, { });
                complete(count && JSValueIsString(context, arguments[0]) ? LegacyExtensions::stringArgument(context, count, arguments, 0) : String { });
            }
            return JSValueMakeUndefined(context);
        };
        return JSClassCreate(&definition);
    }();
    return JSObjectMake(context, callbackClass, new Callback(WTF::move(completion)));
}


static uint64_t nextMediaPlayerHandoffIdentifier()
{
    static uint64_t identifier = 0;
    return ++identifier;
}

static bool activeMediaPlayerHandoffScope(const ContentContextNative&, uint64_t);

static std::optional<uint64_t> parentMediaPlayerHandoff(JSContextRef context, size_t count, const JSValueRef arguments[], size_t index, const ContentContextNative& native)
{
    if (count <= index || JSValueIsUndefined(context, arguments[index]))
        return 0;
    auto identifier = parseInteger<uint64_t>(LegacyExtensions::stringArgument(context, count, arguments, index));
    if (!identifier || !activeMediaPlayerHandoffScope(native, *identifier))
        return std::nullopt;
    return identifier;
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

// Calls its function once its document stops: the document is navigated away from, enters the back/forward cache,
// or leaves its frame.
class DocumentStopObserver final : public RefCounted<DocumentStopObserver>, public WebCore::ActiveDOMObject {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(DocumentStopObserver);
public:
    static Ref<DocumentStopObserver> create(WebCore::Document& document, Function<void()>&& documentStopped)
    {
        Ref observer = adoptRef(*new DocumentStopObserver(document, WTF::move(documentStopped)));
        observer->suspendIfNeeded();
        return observer;
    }

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    DocumentStopObserver(WebCore::Document& document, Function<void()>&& documentStopped)
        : ActiveDOMObject(document)
        , m_documentStopped(WTF::move(documentStopped))
    {
    }

    void stop() final
    {
        if (auto documentStopped = std::exchange(m_documentStopped, nullptr))
            documentStopped();
    }

    void suspend(WebCore::ReasonForSuspension reason) final
    {
        if (reason == WebCore::ReasonForSuspension::BackForwardCache)
            stop();
    }

    Function<void()> m_documentStopped;
};

// A handoff lasts until its operation finishes, or its document stops or its content world is withdrawn.
struct MediaPlayerHandoffScope : std::enable_shared_from_this<MediaPlayerHandoffScope> {
    ContentContextNative native;
    std::unique_ptr<NativePromise> promise;
    JSObjectRef callback;
    uint64_t identifier { nextMediaPlayerHandoffIdentifier() };
    uint64_t parentIdentifier;
    String ticket;
    RefPtr<DocumentStopObserver> documentObserver;
    std::shared_ptr<MediaPlayerHandoffScope> active;
    bool finished { false };

    MediaPlayerHandoffScope(const ContentContextNative& context, std::unique_ptr<NativePromise>&& pending, JSObjectRef operation, uint64_t parent, String&& preparedTicket)
        : native(context), promise(WTF::move(pending)), callback(operation), parentIdentifier(parent), ticket(WTF::move(preparedTicket))
    {
        JSValueProtect(promise->context.get(), callback);
    }

    static std::vector<std::weak_ptr<MediaPlayerHandoffScope>>& scopes()
    {
        static NeverDestroyed<std::vector<std::weak_ptr<MediaPlayerHandoffScope>>> scopes;
        return scopes;
    }

    ~MediaPlayerHandoffScope()
    {
        JSValueUnprotect(promise->context.get(), callback);
    }

    void complete(const String& error = { })
    {
        if (std::exchange(finished, true))
            return;
        auto protect = shared_from_this();
        active = nullptr;
        if (error.isEmpty())
            promise->resolveWith(JSValueMakeUndefined(promise->context.get()));
        else
            promise->rejectWith(error);
        WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::EndMediaPlayerHandoff(identifier), 0);
    }

    void start(WebCore::Document& document)
    {
        active = shared_from_this();
        std::erase_if(scopes(), [](auto& scope) { return scope.expired(); });
        scopes().push_back(active);
        documentObserver = DocumentStopObserver::create(document, [weakThis = weak_from_this()] {
            if (auto scope = weakThis.lock())
                scope->complete("no-source"_s);
        });
        WebProcess::singleton().parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionHost::BeginMediaPlayerHandoff(native.frameID, identifier, parentIdentifier, ticket, native.extensionKey), [self = shared_from_this()](Expected<bool, String>&& began) {
            if (self->finished)
                return;
            if (!began)
                return self->complete(began.error());
            if (!*began || !documentForNative(self->native))
                return self->complete("no-source"_s);
            JSValueRef finish = sourceCompletion(self->promise->context.get(), [weakThis = self->weak_from_this()](String) {
                if (auto scope = weakThis.lock())
                    scope->complete();
            });
            JSValueRef exception = nullptr;
            auto identifierString = adopt(JSStringCreateWithUTF8CString(String::number(self->identifier).utf8().data()));
            JSValueRef arguments[] = { finish, JSValueMakeString(self->promise->context.get(), identifierString.get()) };
            JSObjectCallAsFunction(self->promise->context.get(), self->callback, nullptr, 2, arguments, &exception);
            if (exception)
                self->complete("handoff-failed"_s);
        }, 0);
    }
};

static bool activeMediaPlayerHandoffScope(const ContentContextNative& native, uint64_t identifier)
{
    return std::any_of(MediaPlayerHandoffScope::scopes().begin(), MediaPlayerHandoffScope::scopes().end(), [&](auto& weakScope) {
        auto scope = weakScope.lock();
        return scope && !scope->finished && scope->identifier == identifier && scope->native.frameID == native.frameID
            && scope->native.documentIdentifier == native.documentIdentifier && scope->native.extensionKey == native.extensionKey
            && documentForNative(scope->native);
    });
}

static JSValueRef contentContextWithMediaPlayerHandoff(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception)
{
    JSObjectRef resolve;
    JSObjectRef reject;
    auto promise = JSObjectMakeDeferredPromise(context, &resolve, &reject, exception);
    if (!promise)
        return JSValueMakeUndefined(context);
    auto pending = std::make_unique<NativePromise>(context, resolve, reject);
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    auto callback = argumentCount && JSValueIsObject(context, arguments[0]) ? JSValueToObject(context, arguments[0], nullptr) : nullptr;
    auto parent = parentMediaPlayerHandoff(context, argumentCount, arguments, 1, *native);
    RefPtr document = documentForNative(*native);
    if (!parent || !document || !callback || !JSObjectIsFunction(context, callback)) {
        pending->rejectWith("no-source"_s);
        return promise;
    }
    auto ticket = LegacyExtensions::stringArgument(context, argumentCount, arguments, 2);
    std::make_shared<MediaPlayerHandoffScope>(*native, WTF::move(pending), callback, *parent, WTF::move(ticket))->start(*document);
    return promise;
}

#include "MediaPlayerPrimitives.inc"

// The roots of the extensions whose content scripts and style sheets this process holds,
// safari-extension://<key>/<token>/, from which the router knows those extensions are loaded.
static Vector<String> userContentExtensionRoots()
{
    Vector<String> roots;
    WebUserContentController::forEachUserContentOfAllControllers([&](auto&, auto* script, auto* styleSheet) {
        auto& url = script ? script->url() : styleSheet->url();
        auto path = url.path();
        size_t tokenEnd = path.find('/', 1);
        if (!url.protocolIs(extensionScheme) || !path.startsWith('/') || tokenEnd == notFound)
            return;
        auto root = makeString(extensionScheme, "://"_s, url.host(), path.left(tokenEnd + 1));
        if (!roots.contains(root))
            roots.append(WTF::move(root));
    });
    std::ranges::sort(roots, codePointCompareLessThan);
    return roots;
}

void LegacyExtensionContent::userContentDidChange()
{
    if (auto roots = userContentExtensionRoots(); roots != m_reportedUserContentExtensionRoots) {
        if (RefPtr connection = WebProcess::singleton().parentProcessConnection()) {
            m_reportedUserContentExtensionRoots = roots;
            connection->send(Messages::LegacyExtensionHost::SetUserContentExtensionRoots(WTF::move(roots)), 0);
        }
    }

    Vector<std::shared_ptr<NativeMediaSession>> expired;
    std::erase_if(NativeMediaSession::sessions(), [](auto& weakSession) { return weakSession.expired(); });
    for (auto& weakSession : NativeMediaSession::sessions()) {
        if (auto session = weakSession.lock(); session && !session->closed && !documentForNative(session->native))
            expired.append(WTF::move(session));
    }
    for (auto& session : expired)
        session->close();

    Vector<std::shared_ptr<MediaPlayerHandoffScope>> endedScopes;
    for (auto& weakScope : MediaPlayerHandoffScope::scopes()) {
        if (auto scope = weakScope.lock(); scope && !scope->finished && !documentForNative(scope->native))
            endedScopes.append(WTF::move(scope));
    }
    for (auto& scope : endedScopes)
        scope->complete("no-source"_s);

    // A content script's context whose world Safari withdraws while its frame shows its document is gone for
    // the router, which ends its ports. The router ended those of a document in the back/forward cache when
    // the frame committed another.
    extensionContexts().removeAllMatching([this](auto& context) {
        RefPtr document = context.document.get();
        if (!document)
            return true;
        bool isLive = context.world && isContextLive(*context.world, context.root);
        bool wasLive = std::exchange(context.wasLive, isLive);
        if (!context.isContentScript || !wasLive || isLive)
            return false;
        RefPtr frame = WebFrame::webFrame(context.frameID);
        RefPtr coreFrame = frame ? frame->coreLocalFrame() : nullptr;
        if (!coreFrame || coreFrame->document() != document.get())
            return false;
        WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::Post(context.frameID, document->identifier(), document->url(), context.extensionKey, "{\"t\":\"gone\"}"_s, { }), 0);
        return false;
    });
}

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
            { "createMediaSession", contentContextCreateMediaSession, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "withMediaPlayerHandoff", contentContextWithMediaPlayerHandoff, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "send", contentContextSend, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "isValid", contentContextIsValid, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "insertCSS", contentContextInsertCSS, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "removeCSS", contentContextRemoveCSS, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "frameId", contentContextFrameID, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "executeScript", contentContextExecuteScript, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
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
            { "isProcessingUserGesture", contentContextIsProcessingUserGesture, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
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

// The root an extension's files are served at, safari-extension://<key>/<token>/: Safari serves an extension it
// reloads at another.
static String extensionRootOfURL(const URL& url)
{
    auto path = url.path();
    auto tokenEnd = path.find('/', 1);
    if (!url.protocolIs(extensionScheme) || !path.startsWith('/') || tokenEnd == notFound)
        return { };
    return makeString(extensionScheme, "://"_s, url.host(), path.left(tokenEnd + 1));
}

// The roots of the copies of an extension whose user content a content-script world holds. A controller holds a
// world's scripts in the order Safari added them, so a copy Safari added after another comes after it.
static Vector<String> contentWorldRoots(WebCore::DOMWrapperWorld& world)
{
    RefPtr bundleWorld = world.isNormal() ? nullptr : InjectedBundleScriptWorld::get(world);
    Vector<String> roots;
    if (!bundleWorld)
        return roots;
    WebUserContentController::forEachUserContentOfAllControllers([&](auto& candidate, auto* script, auto* styleSheet) {
        if (&candidate != bundleWorld.get())
            return;
        auto root = extensionRootOfURL(script ? script->url() : styleSheet->url());
        if (root.isEmpty())
            return;
        roots.removeAll(root);
        roots.append(WTF::move(root));
    });
    return roots;
}

bool LegacyExtensionContent::isContextLive(WebCore::DOMWrapperWorld& world, const String& root) const
{
    if (world.isNormal())
        return true;
    auto roots = contentWorldRoots(world);
    return root.isEmpty() ? !roots.isEmpty() : roots.contains(root);
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
    userContentDidChange();
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
    String root;
    if (kind == LegacyExtensions::ContextKind::Content) {
        auto roots = contentWorldRoots(world);
        if (!roots.isEmpty())
            root = roots.last();
    }
    if (!LegacyExtensions::installAPI(*globalObject, kind, contentContextNativeClass(kind), new ContentContextNative { frame.frameID(), document->identifier(), extensionKey, world, root }))
        return;
    extensionContexts().removeAllMatching([&](auto& context) {
        return context.document == document.get() && context.world == &world;
    });
    RefPtr<BackForwardCacheObserver> backForwardCacheObserver;
    for (auto& context : extensionContexts()) {
        if (context.document == document.get())
            backForwardCacheObserver = context.backForwardCacheObserver;
    }
    if (!backForwardCacheObserver)
        backForwardCacheObserver = BackForwardCacheObserver::create(*document, frame.frameID(), extensionKey);
    extensionContexts().append(ExtensionContext { *document, frame.frameID(), extensionKey, world, root, kind == LegacyExtensions::ContextKind::Content, isContextLive(world, root), WTF::move(backForwardCacheObserver) });
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

// tabs.saveAsPDF's backgrounds, for one print of one page, in the page's own settings; the router sets them
// back to the page's preferences when the print ends.
void LegacyExtensionContent::setPrintsBackgrounds(WebCore::PageIdentifier pageID, bool printsBackgrounds)
{
    RefPtr webPage = WebProcess::singleton().webPage(pageID);
    RefPtr page = webPage ? webPage->corePage() : nullptr;
    if (page)
        page->settings().setShouldPrintBackgrounds(printsBackgrounds);
}

// devtools.inspectedWindow.eval's frameURL: the frame of the page that upstream's
// WebInspectorExtensionController._frameForFrameURL would pick, by its document's URL, else without the
// document's fragment when frameURL has none, else also without its query when frameURL has neither; and the
// execution context of its main world, the identifier the page's inspector reports for it in
// Runtime.executionContextCreated. The inspector numbers a global object when first asked and creates its
// injected script only when a command uses it.
void LegacyExtensionContent::executionContextForFrameURL(WebCore::PageIdentifier pageID, String&& frameURL, CompletionHandler<void(std::optional<int>, URL&&)>&& completionHandler)
{
    RefPtr webPage = WebProcess::singleton().webPage(pageID);
    RefPtr page = webPage ? webPage->corePage() : nullptr;
    if (!page)
        return completionHandler(std::nullopt, { });
    Vector<Ref<WebCore::LocalFrame>> frames;
    for (RefPtr frame = &page->mainFrame(); frame; frame = frame->tree().traverseNext()) {
        if (RefPtr localFrame = dynamicDowncast<WebCore::LocalFrame>(frame); localFrame && localFrame->document())
            frames.append(localFrame.releaseNonNull());
    }
    URL wanted { frameURL };
    auto find = [&](NOESCAPE const Function<void(URL&)>& adjust) -> RefPtr<WebCore::LocalFrame> {
        for (auto& frame : frames) {
            URL known = protect(frame->document())->url();
            adjust(known);
            if (known.string() == wanted.string())
                return frame.ptr();
        }
        return nullptr;
    };
    RefPtr frame = find([](URL&) { });
    if (!frame && !wanted.hasFragmentIdentifier()) {
        frame = find([](URL& url) { url.removeFragmentIdentifier(); });
        if (!frame && !wanted.hasQuery())
            frame = find([](URL& url) { url.removeQueryAndFragmentIdentifier(); });
    }
    auto* globalObject = frame ? frame->script().globalObject(WebCore::mainThreadNormalWorldSingleton()) : nullptr;
    if (!globalObject)
        return completionHandler(std::nullopt, { });
    completionHandler(page->inspectorController().injectedScriptManager().injectedScriptIdFor(globalObject), URL { protect(frame->document())->url() });
}

void LegacyExtensionContent::invalidateExtensionPage(WebCore::FrameIdentifier frameID, WebCore::ScriptExecutionContextIdentifier documentID)
{
    for (auto& context : extensionContexts()) {
        RefPtr document = context.document.get();
        if (!context.isContentScript && context.frameID == frameID && document && document->identifier() == documentID)
            context.isInvalidated = true;
    }
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
