#include "config.h"
#include "LegacyExtensionContent.h"
#include "MediaRestreamSession.h"
#include <WebCore/MediaPlayer.h>
#include <WebCore/EventListener.h>
#include <WebCore/EventNames.h>
#include <WebCore/Event.h>
#include <wtf/RunLoop.h>

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
#include <WebCore/ScriptController.h>
#include <WebCore/Settings.h>
#include <WebCore/UserScript.h>
#include <WebCore/UserStyleSheet.h>
#include <WebCore/WindowProxy.h>
#include <wtf/JSONValues.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>

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

struct MediaPlayerPromise {
    JSRetainPtr<JSGlobalContextRef> context;
    JSObjectRef resolve;
    JSObjectRef reject;
    bool restream { false };
    std::optional<ContentContextNative> caller;

    MediaPlayerPromise(JSContextRef context, JSObjectRef resolve, JSObjectRef reject)
        : context(JSContextGetGlobalContext(context)), resolve(resolve), reject(reject)
    {
        JSValueProtect(context, resolve);
        JSValueProtect(context, reject);
    }

    ~MediaPlayerPromise()
    {
        JSValueUnprotect(context.get(), resolve);
        JSValueUnprotect(context.get(), reject);
    }

    void complete(Expected<URL, String>&& result)
    {
        if (result && caller && !documentForNative(*caller))
            result = makeUnexpected("no-source"_s);
        auto text = result ? result->string() : result.error();
        auto string = adopt(JSStringCreateWithUTF8CString(text.utf8().data()));
        JSValueRef value = JSValueMakeString(context.get(), string.get());
        if (result) {
            auto object = JSON::Object::create();
            object->setString("method"_s, restream ? "restream"_s : "url"_s);
            object->setString("url"_s, text);
            auto json = adopt(JSStringCreateWithUTF8CString(object->toJSONString().utf8().data()));
            value = JSValueMakeFromJSONString(context.get(), json.get());
        } else
            value = JSObjectMakeError(context.get(), 1, &value, nullptr);
        JSObjectCallAsFunction(context.get(), result ? resolve : reject, nullptr, 1, &value, nullptr);
    }
};

class MediaPlayerSourceListener final : public WebCore::EventListener {
public:
    static Ref<MediaPlayerSourceListener> create(Function<void()>&& changed) { return adoptRef(*new MediaPlayerSourceListener(WTF::move(changed))); }
    void handleEvent(WebCore::ScriptExecutionContext&, WebCore::Event&) final { m_changed(); }
private:
    explicit MediaPlayerSourceListener(Function<void()>&& changed) : EventListener(NativeEventListenerType), m_changed(WTF::move(changed)) { }
    Function<void()> m_changed;
};

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

enum class MediaPlayerSourceMode { Auto, Direct, Capture };

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

struct MediaPlayerOpenRequest : std::enable_shared_from_this<MediaPlayerOpenRequest> {
    Vector<std::unique_ptr<MediaPlayerPromise>> pending;
    std::optional<URL> completedURL;
    std::optional<uint64_t> sourceIdentifier;
    bool finished { false };
    bool restream { false };
    MediaPlayerSourceMode sourceMode { MediaPlayerSourceMode::Auto };
    ContentContextNative native;
    WeakPtr<WebCore::HTMLMediaElement> media;
    RefPtr<WebCore::MediaPlayer> player;
    WebCore::ScriptExecutionContextIdentifier document;
    URL sourceURL;
    String application;
    String title;
    String adapter;
    Vector<URL> candidates;
    std::optional<Vector<Ref<WebCore::TextTrack>>> textTracks;
    size_t nextCandidate { 0 };
    std::optional<uint64_t> directIdentifier;
    uint64_t requestIdentifier { 0 };
    uint64_t parentHandoffIdentifier { 0 };
    uint64_t presentationIdentifier { 0 };
    WebCore::IntSize captureSize;
    String captureCodec;
    std::optional<double> captureHistoryDuration;
    std::optional<uint64_t> captureMinimumFreeStorage;
    double routeTimeout { 30 };
    String openingMessage;
    bool negotiating { false };
    bool returningToLocal { false };
    bool negotiatedRemote { false };
    bool restoringPlayIntent { false };
    bool resolvingSource { false };
    JSRetainPtr<JSGlobalContextRef> resolverContext;
    JSObjectRef resolver { nullptr };
    double initialPosition { 0 };
    double initialRate { 1 };
    bool initiallyPaused { false };
    RefPtr<MediaPlayerSourceListener> sourceListener;
    RunLoop::Timer sourceTimer;
    std::shared_ptr<MediaPlayerOpenRequest> preparing;

    MediaPlayerOpenRequest(std::unique_ptr<MediaPlayerPromise>&& promise, const ContentContextNative& context, WebCore::HTMLMediaElement& element, String app, String mediaTitle, String message, String description, std::optional<Vector<Ref<WebCore::TextTrack>>>&& tracks)
        : native(context), media(element), player(element.player()), document(element.document().identifier()), sourceURL(element.currentSrc()), application(WTF::move(app)), title(WTF::move(mediaTitle)), adapter(WTF::move(description)), candidates(element.externalMediaSourceURLs()), textTracks(WTF::move(tracks)), openingMessage(WTF::move(message)), sourceTimer(RunLoop::mainSingleton(), "External playback source negotiation"_s, [this] { sourceDeadline(); })
    {
        initialPosition = std::isfinite(element.duration()) ? element.currentTime() : 0;
        initialRate = element.playbackRate();
        initiallyPaused = element.paused();
        pending.append(WTF::move(promise));
        for (auto& track : *textTracks) {
            if (track->trackType() != WebCore::TextTrack::InBand) {
                candidates.clear();
                break;
            }
            candidates.removeAllMatching([&](auto& url) { return url != sourceURL; });
        }
    }

    static std::vector<std::weak_ptr<MediaPlayerOpenRequest>>& requests()
    {
        static NeverDestroyed<std::vector<std::weak_ptr<MediaPlayerOpenRequest>>> requests;
        return requests;
    }

    static bool sameAdapter(const String& a, const String& b)
    {
        if (a == b)
            return true;
        auto firstValue = JSON::Value::parseJSON(a);
        auto secondValue = JSON::Value::parseJSON(b);
        auto first = firstValue ? firstValue->asObject() : nullptr;
        auto second = secondValue ? secondValue->asObject() : nullptr;
        if (!first || !second || first->size() != 5 || second->size() != 5)
            return false;
        for (auto key : { "position"_s, "duration"_s, "rate"_s, "play"_s, "pause"_s }) {
            if (first->getString(key) != second->getString(key))
                return false;
        }
        return true;
    }

    bool matches(const ContentContextNative& context, const String& app, const String& description, const Vector<Ref<WebCore::TextTrack>>& tracks, MediaPlayerSourceMode mode, const WebCore::IntSize& size, const String& codec, std::optional<double> historyDuration, std::optional<uint64_t> minimumFreeStorage, double timeout) const
    {
        return native.extensionKey == context.extensionKey && application == app && sameAdapter(adapter, description)
            && (finished ? (mode == MediaPlayerSourceMode::Auto || (restream ? mode == MediaPlayerSourceMode::Capture : mode == MediaPlayerSourceMode::Direct)) : mode == sourceMode)
            && ((finished && !restream) || (captureSize == size && captureCodec == codec && captureHistoryDuration == historyDuration && captureMinimumFreeStorage == minimumFreeStorage))
            && (finished || routeTimeout == timeout)
            && textTracks->size() == tracks.size()
            && std::equal(textTracks->begin(), textTracks->end(), tracks.begin(), [](auto& a, auto& b) { return a.ptr() == b.ptr(); });
    }

    void subscribe(std::unique_ptr<MediaPlayerPromise>&& promise)
    {
        if (!finished) {
            pending.append(WTF::move(promise));
            return;
        }
        ASSERT(completedURL && sourceIdentifier);
        auto identifier = *sourceIdentifier;
        WebProcess::singleton().parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionHost::ActivateMediaPlayer(identifier), [self = shared_from_this(), identifier, promise = WTF::move(promise)](Expected<bool, String>&& activated) mutable {
            if (!activated)
                return promise->complete(makeUnexpected(activated.error()));
            if (!*activated) {
                MediaRestreamSession::singleton().stop(identifier, true);
                return promise->complete(makeUnexpected("no-source"_s));
            }
            if (!self->sourceValid() || !self->completedURL || self->sourceIdentifier != identifier
                || !WebCore::MediaRestreamSource::validateTextTracks(*self->media, *self->textTracks))
                return promise->complete(makeUnexpected("no-source"_s));
            promise->restream = self->restream;
            promise->complete(URL { *self->completedURL });
        }, 0);
    }

    void endHandoff()
    {
        if (auto identifier = std::exchange(requestIdentifier, 0))
            WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::EndMediaPlayerHandoff(identifier), 0);
    }

    ~MediaPlayerOpenRequest()
    {
        stopSourceObservation();
        if (resolver)
            JSValueUnprotect(resolverContext.get(), resolver);
        endHandoff();
    }

    void complete(Expected<URL, String>&& result)
    {
        auto protect = shared_from_this();
        stopSourceObservation();
        preparing = nullptr;
        finished = true;
        resolvingSource = false;
        if (media)
            WebCore::MediaRestreamSource::setPreparingExternalPlayback(*media, presentationIdentifier, false);
        if (!result && directIdentifier)
            MediaRestreamSession::singleton().stop(*std::exchange(directIdentifier, std::nullopt), result.error() != "application-start-uncertain"_s);
        if (!result && media)
            WebCore::MediaRestreamSource::setExternalPlaybackTarget(*media, presentationIdentifier, false);
        if (!result && media)
            media->setMediaPlayerPresentedExternally(false, presentationIdentifier);
        if (result)
            completedURL = *result;
        endHandoff();
        for (auto& promise : std::exchange(pending, { })) {
            promise->restream = restream;
            if (result)
                promise->complete(URL { *result });
            else
                promise->complete(makeUnexpected(result.error()));
        }
    }

    void observeSource(uint64_t identifier)
    {
        sourceIdentifier = identifier;
        MediaRestreamSession::singleton().setDidEnd(identifier, [self = shared_from_this(), identifier] {
            if (self->sourceIdentifier == identifier) {
                self->sourceIdentifier = std::nullopt;
                self->completedURL = std::nullopt;
            }
        });
    }

    void start()
    {
        requests().push_back(shared_from_this());
        requestIdentifier = nextMediaPlayerHandoffIdentifier();
        presentationIdentifier = requestIdentifier;
        WebProcess::singleton().parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionHost::BeginMediaPlayerHandoff(native.frameID, requestIdentifier, parentHandoffIdentifier, String { }, native.extensionKey), [self = shared_from_this()](Expected<bool, String>&& began) {
            if (!began)
                return self->complete(makeUnexpected(began.error()));
            if (!self->valid())
                return self->complete(makeUnexpected("no-source"_s));
            self->media->setMediaPlayerPresentedExternally(true, self->presentationIdentifier, self->openingMessage);
            self->prepareSource();
        }, 0);
    }

    void observeSourceChanges()
    {
        negotiating = true;
        preparing = shared_from_this();
        sourceListener = MediaPlayerSourceListener::create([weakThis = weak_from_this()] {
            if (auto self = weakThis.lock())
                self->sourceChanged();
        });
        for (auto& name : { WebCore::eventNames().loadstartEvent, WebCore::eventNames().loadedmetadataEvent, WebCore::eventNames().loadeddataEvent, WebCore::eventNames().canplayEvent, WebCore::eventNames().seekedEvent, WebCore::eventNames().playingEvent, WebCore::eventNames().errorEvent })
            media->addEventListener(name, Ref { *sourceListener });
    }

    void stopSourceObservation()
    {
        sourceTimer.stop();
        if (media && sourceListener) {
            for (auto& name : { WebCore::eventNames().loadstartEvent, WebCore::eventNames().loadedmetadataEvent, WebCore::eventNames().loadeddataEvent, WebCore::eventNames().canplayEvent, WebCore::eventNames().seekedEvent, WebCore::eventNames().playingEvent, WebCore::eventNames().errorEvent })
                media->removeEventListener(name, *sourceListener, { });
        }
        sourceListener = nullptr;
    }

    void prepareSource()
    {
        if (sourceMode == MediaPlayerSourceMode::Capture) {
            candidates.clear();
            return next();
        }
        if (!candidates.isEmpty() || adapter.isEmpty() || !textTracks->isEmpty() || !WebCore::MediaRestreamSource::canNegotiateRemotePlayback(*media))
            return next();
        observeSourceChanges();
        directIdentifier = MediaRestreamSession::singleton().createDirect(*media, std::isfinite(media->duration()), true);
        sourceTimer.startOneShot(Seconds(routeTimeout));
        WebCore::MediaRestreamSource::setExternalPlaybackTarget(*media, presentationIdentifier, true);
    }

    void returnToLocalSource()
    {
        auto protect = shared_from_this();
        stopSourceObservation();
        returningToLocal = true;
        observeSourceChanges();
        sourceTimer.startOneShot(15_s);
        WebCore::MediaRestreamSource::setPreparingExternalPlayback(*media, presentationIdentifier, true);
        if (directIdentifier)
            MediaRestreamSession::singleton().stop(*std::exchange(directIdentifier, std::nullopt), true);
        WebCore::MediaRestreamSource::setExternalPlaybackTarget(*media, presentationIdentifier, false);
        media->setMediaPlayerPresentedExternally(true, presentationIdentifier, openingMessage);
        sourceChanged();
    }

    void sourceDeadline()
    {
        auto protect = shared_from_this();
        if (resolvingSource)
            return complete(makeUnexpected(resolutionSourceValid() ? "source-resolution-failed"_s : "no-source"_s));
        if (!valid() || returningToLocal)
            return complete(makeUnexpected("no-source"_s));
        returnToLocalSource();
    }

    void sourceChanged()
    {
        if (!negotiating)
            return;
        auto protect = shared_from_this();
        if (!valid())
            return complete(makeUnexpected("no-source"_s));
        if (media->error()) {
            if (!returningToLocal)
                return returnToLocalSource();
            return complete(makeUnexpected("unsupported-source"_s));
        }
        if (returningToLocal) {
            if (media->readyState() < WebCore::HTMLMediaElement::HAVE_CURRENT_DATA || media->seeking())
                return;
            if (!WebCore::MediaRestreamSource::requiresCapture(*media))
                return;
            if (sourceMode == MediaPlayerSourceMode::Direct) {
                if (RefPtr route = WebCore::MediaRestreamSource::remoteSourceForPlayer(*media->player())) {
                    route->stop();
                    if (!initiallyPaused)
                        media->play();
                }
            }
            if (initiallyPaused && !media->paused())
                media->pause();
            if (!initiallyPaused && media->paused()) {
                if (!std::exchange(restoringPlayIntent, true))
                    media->play();
                return;
            }
        } else if (WebCore::MediaRestreamSource::requiresCapture(*media))
            return;
        stopSourceObservation();
        negotiating = false;
        negotiatedRemote = !returningToLocal;
        preparing = nullptr;
        player = media->player();
        sourceURL = media->currentSrc();
        candidates = negotiatedRemote ? media->externalMediaSourceURLs() : Vector<URL> { };
        nextCandidate = 0;
        WebCore::MediaRestreamSource::setPreparingExternalPlayback(*media, presentationIdentifier, false);
        next();
    }

    bool sourceValid() const
    {
        return media && media->document().identifier() == document
            && media->document().page() && (negotiating || ((restream || negotiatedRemote) && WebCore::MediaRestreamSource::isPlayingExternally(*media)) || (media->player() == player.get() && media->currentSrc() == sourceURL));
    }

    bool valid() const { return documentForNative(native) && sourceValid(); }
    bool resolutionSourceValid() const { return valid() && media->currentSrc() == sourceURL && media->player() == player.get(); }

    void next()
    {
        if (!valid()) {
            if (directIdentifier)
                MediaRestreamSession::singleton().stop(*directIdentifier, true);
            return complete(makeUnexpected("no-source"_s));
        }
        bool direct = nextCandidate < candidates.size();
        if (!direct && WebCore::MediaRestreamSource::externalPlaybackTarget(*media))
            return returnToLocalSource();
        if (!direct && directIdentifier)
            MediaRestreamSession::singleton().stop(*std::exchange(directIdentifier, std::nullopt), true);
        if (!direct && sourceMode == MediaPlayerSourceMode::Direct)
            return complete(makeUnexpected("no-direct-source"_s));
        restream = !direct;
        URL url = direct ? candidates[nextCandidate++] : URL { };
        if (direct && resolver) {
            resolvingSource = true;
            preparing = shared_from_this();
            sourceTimer.startOneShot(30_s);
            auto complete = sourceCompletion(resolverContext.get(), [weakThis = weak_from_this(), url](String json) {
                auto self = weakThis.lock();
                if (!self || self->finished || !self->resolvingSource)
                    return;
                self->sourceTimer.stop();
                self->resolvingSource = false;
                self->preparing = nullptr;
                if (!self->resolutionSourceValid())
                    return self->complete(makeUnexpected("no-source"_s));
                auto value = JSON::Value::parseJSON(json);
                auto source = value ? value->asObject() : nullptr;
                URL resolved { source ? source->getString("url"_s) : String { } };
                auto playlist = source ? source->getString("playlist"_s) : String { };
                if ((source && source->getValue("playlist"_s) && source->getValue("playlist"_s)->type() != JSON::Value::Type::String) || !resolved.protocolIsInHTTPFamily() || playlist.length() > 1024 * 1024 || (!playlist.isEmpty() && !playlist.startsWith("#EXTM3U"_s)))
                    return self->complete(makeUnexpected("source-resolution-failed"_s));
                self->launchSource(url, resolved, playlist);
            });
            auto urlString = adopt(JSStringCreateWithUTF8CString(url.string().utf8().data()));
            JSValueRef arguments[] = { JSValueMakeString(resolverContext.get(), urlString.get()), complete };
            JSValueRef exception = nullptr;
            JSObjectCallAsFunction(resolverContext.get(), resolver, nullptr, 2, arguments, &exception);
            if (exception && !finished)
                this->complete(makeUnexpected("source-resolution-failed"_s));
            return;
        }
        launchSource(url, url, { });
    }

    void launchSource(const URL& source, const URL& url, const String& playlist)
    {
        bool direct = !source.isEmpty();
        bool matchingTimeline = source == sourceURL && std::isfinite(media->duration());
        double position = negotiatedRemote ? initialPosition : matchingTimeline ? media->currentTime() : 0;
        double rate = negotiatedRemote ? initialRate : media->playbackRate();
        bool paused = negotiatedRemote ? initiallyPaused : WebCore::MediaRestreamSource::handoffPaused(*media);
        auto launch = [self = shared_from_this(), source, url, playlist, position, rate, paused](Expected<uint64_t, String>&& created) mutable {
            if (!created)
                return self->complete(makeUnexpected(created.error()));
            auto identifier = *created;
            if (!self->valid()) {
                MediaRestreamSession::singleton().stop(identifier, true);
                return self->complete(makeUnexpected("no-source"_s));
            }
            self->observeSource(identifier);
            Ref document = *documentForNative(self->native);
            WebProcess::singleton().parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionHost::OpenInMediaPlayer(self->native.frameID, self->native.documentIdentifier, document->url(), self->native.extensionKey, self->application, self->requestIdentifier, identifier, url, playlist, self->title, self->adapter, source.isEmpty() ? self->captureCodec : String { }, position, rate, paused), [self, identifier, source, direct = !source.isEmpty()](IPC::Connection* connection, Expected<URL, String>&& result) mutable {
                if (!connection)
                    result = makeUnexpected("application-unavailable"_s);
                if (!self->valid() || !MediaRestreamSession::singleton().contains(identifier))
                    result = makeUnexpected("no-source"_s);
                if (!result) {
                    if (direct && result.error() == "unsupported-source"_s && self->valid() && MediaRestreamSession::singleton().contains(identifier))
                        return self->next();
                    MediaRestreamSession::singleton().stop(identifier, result.error() != "application-start-uncertain"_s);
                } else
                    MediaRestreamSession::singleton().accept(identifier, source);
                self->complete(WTF::move(result));
            }, 0);
        };
        if (direct) {
            if (!directIdentifier)
                directIdentifier = MediaRestreamSession::singleton().createDirect(*media, matchingTimeline);
            launch(*directIdentifier);
        } else
            MediaRestreamSession::singleton().create(*media, textTracks, captureSize, captureCodec, captureHistoryDuration, captureMinimumFreeStorage, WTF::move(launch));
    }
};

static JSValueRef contentContextOpenInMediaPlayer(JSContextRef context, JSObjectRef, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception)
{
    JSObjectRef resolve;
    JSObjectRef reject;
    auto promise = JSObjectMakeDeferredPromise(context, &resolve, &reject, exception);
    if (!promise)
        return JSValueMakeUndefined(context);
    auto pending = std::make_unique<MediaPlayerPromise>(context, resolve, reject);
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(thisObject));
    RefPtr document = documentForNative(*native);
    auto* globalObject = toJS(context);
    JSC::JSLockHolder lock(globalObject->vm());
    RefPtr media = argumentCount ? dynamicDowncast<WebCore::HTMLMediaElement>(WebCore::JSElement::toWrapped(globalObject->vm(), toJS(globalObject, arguments[0]))) : nullptr;
    if (!document || !media || !document->securityOrigin().isSameOriginDomain(media->document().securityOrigin())) {
        pending->complete(makeUnexpected("no-source"_s));
        return promise;
    }
    pending->caller = *native;
    auto parentHandoff = parentMediaPlayerHandoff(context, argumentCount, arguments, 8, *native);
    if (!parentHandoff) {
        pending->complete(makeUnexpected("no-source"_s));
        return promise;
    }
    auto application = LegacyExtensions::stringArgument(context, argumentCount, arguments, 1);
    if (application.isEmpty()) {
        pending->complete(makeUnexpected("application-unavailable"_s));
        return promise;
    }
    auto targetDocument = media->document().identifier();
    std::optional<Vector<Ref<WebCore::TextTrack>>> textTracks;
    if (argumentCount > 2 && !JSValueIsUndefined(context, arguments[2])) {
        if (!JSValueIsArray(context, arguments[2])) {
            pending->complete(makeUnexpected("unsupported-source"_s));
            return promise;
        }
        textTracks.emplace();
        auto array = JSValueToObject(context, arguments[2], nullptr);
        auto lengthName = adopt(JSStringCreateWithUTF8CString("length"));
        JSValueRef propertyError = nullptr;
        auto lengthValue = JSObjectGetProperty(context, array, lengthName.get(), &propertyError);
        double length = propertyError ? -1 : JSValueToNumber(context, lengthValue, &propertyError);
        if (propertyError || !std::isfinite(length) || length < 0 || length > WebCore::MediaRestreamSource::textTrackCount(*media) || length != std::floor(length)) {
            pending->complete(makeUnexpected("unsupported-source"_s));
            return promise;
        }
        HashSet<WebCore::TextTrack*> selected;
        for (unsigned i = 0; i < length; ++i) {
            JSValueRef error = nullptr;
            auto value = JSObjectGetPropertyAtIndex(context, array, i, &error);
            auto* track = error ? nullptr : WebCore::JSTextTrack::toWrapped(globalObject->vm(), toJS(globalObject, value));
            if (!track || !selected.add(track).isNewEntry) {
                pending->complete(makeUnexpected("unsupported-source"_s));
                return promise;
            }
            textTracks->append(Ref { *track });
        }
        if (!WebCore::MediaRestreamSource::validateTextTracks(*media, *textTracks)) {
            pending->complete(makeUnexpected("unsupported-source"_s));
            return promise;
        }
    }
    if (documentForNative(*native) != document || !media->document().page() || media->document().identifier() != targetDocument
        || !document->securityOrigin().isSameOriginDomain(media->document().securityOrigin())) {
        pending->complete(makeUnexpected("no-source"_s));
        return promise;
    }
    if (!media->player()) {
        pending->complete(makeUnexpected("no-source"_s));
        return promise;
    }
    auto adapter = LegacyExtensions::stringArgument(context, argumentCount, arguments, 3);
    auto mode = LegacyExtensions::stringArgument(context, argumentCount, arguments, 7);
    MediaPlayerSourceMode sourceMode;
    if (mode == "auto"_s)
        sourceMode = MediaPlayerSourceMode::Auto;
    else if (mode == "direct"_s)
        sourceMode = MediaPlayerSourceMode::Direct;
    else if (mode == "capture"_s)
        sourceMode = MediaPlayerSourceMode::Capture;
    else {
        pending->complete(makeUnexpected("unsupported-source"_s));
        return promise;
    }
    WebCore::IntSize captureSize;
    String captureCodec;
    std::optional<double> captureHistoryDuration;
    std::optional<uint64_t> captureMinimumFreeStorage;
    JSValueRef routeTimeoutError = nullptr;
    double routeTimeout = argumentCount > 10 ? JSValueToNumber(context, arguments[10], &routeTimeoutError) : 30;
    if (routeTimeoutError || !std::isfinite(routeTimeout) || routeTimeout < 1) {
        pending->complete(makeUnexpected("unsupported-source"_s));
        return promise;
    }
    auto capture = LegacyExtensions::stringArgument(context, argumentCount, arguments, 9);
    if (!capture.isEmpty()) {
        auto value = JSON::Value::parseJSON(capture);
        auto object = value ? value->asObject() : nullptr;
        auto width = object ? object->getDouble("maxWidth"_s) : std::nullopt;
        auto height = object ? object->getDouble("maxHeight"_s) : std::nullopt;
        auto validDimension = [](auto value) { return value && std::isfinite(*value) && *value >= 2 && *value <= 16384 && *value == std::floor(*value); };
        if (!validDimension(width) || !validDimension(height)) {
            pending->complete(makeUnexpected("unsupported-source"_s));
            return promise;
        }
        captureSize = { static_cast<int>(*width), static_cast<int>(*height) };
        captureHistoryDuration = object->getDouble("maxHistoryDuration"_s);
        if (captureHistoryDuration && (!std::isfinite(*captureHistoryDuration) || *captureHistoryDuration < 9)) {
            pending->complete(makeUnexpected("unsupported-source"_s));
            return promise;
        }
        auto minimumFreeStorage = object->getDouble("minimumFreeStorage"_s);
        if (minimumFreeStorage) {
            if (!std::isfinite(*minimumFreeStorage) || *minimumFreeStorage < 0 || *minimumFreeStorage > 9007199254740991.0 || *minimumFreeStorage != std::floor(*minimumFreeStorage)) {
                pending->complete(makeUnexpected("unsupported-source"_s));
                return promise;
            }
            captureMinimumFreeStorage = static_cast<uint64_t>(*minimumFreeStorage);
        }
        auto transport = object->getString("transport"_s);
        auto codec = object->getString("videoCodec"_s);
        if (transport == "rtsp"_s && !captureHistoryDuration && !captureMinimumFreeStorage && (codec == "utvideo"_s || codec == "jpeg"_s))
            captureCodec = codec;
        else if (transport != "hls"_s || codec != "h264"_s) {
            pending->complete(makeUnexpected("unsupported-source"_s));
            return promise;
        }
    }
    auto effectiveTracks = WebCore::MediaRestreamSource::selectedTextTracks(*media, textTracks);
    auto& requests = MediaPlayerOpenRequest::requests();
    std::erase_if(requests, [](auto& request) { return request.expired(); });
    for (auto& weakRequest : requests) {
        auto request = weakRequest.lock();
        if (!request || !request->sourceValid() || request->media.get() != media.get() || (request->finished && !request->completedURL))
            continue;
        if (request->matches(*native, application, adapter, effectiveTracks, sourceMode, captureSize, captureCodec, captureHistoryDuration, captureMinimumFreeStorage, routeTimeout))
            request->subscribe(WTF::move(pending));
        else if (sourceMode == MediaPlayerSourceMode::Direct && request->finished && request->restream
            && request->matches(*native, application, adapter, effectiveTracks, MediaPlayerSourceMode::Auto, captureSize, captureCodec, captureHistoryDuration, captureMinimumFreeStorage, routeTimeout))
            pending->complete(makeUnexpected("no-direct-source"_s));
        else
            pending->complete(makeUnexpected("application-busy"_s));
        return promise;
    }
    textTracks = WTF::move(effectiveTracks);
    auto title = argumentCount > 4 && JSValueIsString(context, arguments[4]) ? LegacyExtensions::stringArgument(context, argumentCount, arguments, 4) : String { };
    auto message = argumentCount > 5 && JSValueIsString(context, arguments[5]) ? LegacyExtensions::stringArgument(context, argumentCount, arguments, 5) : emptyString();
    auto request = std::make_shared<MediaPlayerOpenRequest>(WTF::move(pending), *native, *media, application, title.left(1024), message.left(1024), adapter, WTF::move(textTracks));
    request->sourceMode = sourceMode;
    request->captureSize = captureSize;
    request->captureCodec = captureCodec;
    request->captureHistoryDuration = captureHistoryDuration;
    request->captureMinimumFreeStorage = captureMinimumFreeStorage;
    request->routeTimeout = routeTimeout;
    request->parentHandoffIdentifier = *parentHandoff;
    if (argumentCount > 6 && JSValueIsObject(context, arguments[6])) {
        auto resolver = JSValueToObject(context, arguments[6], nullptr);
        if (JSObjectIsFunction(context, resolver)) {
            request->resolverContext = JSContextGetGlobalContext(context);
            request->resolver = resolver;
            JSValueProtect(context, resolver);
        }
    }
    request->start();
    return promise;
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

struct MediaPlayerHandoffScope : std::enable_shared_from_this<MediaPlayerHandoffScope> {
    ContentContextNative native;
    std::unique_ptr<NativePromise> promise;
    JSObjectRef callback;
    uint64_t identifier { nextMediaPlayerHandoffIdentifier() };
    uint64_t parentIdentifier;
    String ticket;
    RunLoop::Timer deadline;
    std::shared_ptr<MediaPlayerHandoffScope> active;
    bool finished { false };

    MediaPlayerHandoffScope(const ContentContextNative& context, std::unique_ptr<NativePromise>&& pending, JSObjectRef operation, uint64_t parent, String&& preparedTicket)
        : native(context), promise(WTF::move(pending)), callback(operation), parentIdentifier(parent), ticket(WTF::move(preparedTicket))
        , deadline(RunLoop::mainSingleton(), "External playback selection"_s, [this] { complete("handoff-timeout"_s); })
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
        deadline.stop();
        active = nullptr;
        if (error.isEmpty())
            promise->resolveWith(JSValueMakeUndefined(promise->context.get()));
        else
            promise->rejectWith(error);
        WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::EndMediaPlayerHandoff(identifier), 0);
    }

    void start()
    {
        active = shared_from_this();
        std::erase_if(scopes(), [](auto& scope) { return scope.expired(); });
        scopes().push_back(active);
        deadline.startOneShot(5_min);
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
    if (!parent || !documentForNative(*native) || !callback || !JSObjectIsFunction(context, callback)) {
        pending->rejectWith("no-source"_s);
        return promise;
    }
    auto ticket = LegacyExtensions::stringArgument(context, argumentCount, arguments, 2);
    std::make_shared<MediaPlayerHandoffScope>(*native, WTF::move(pending), callback, *parent, WTF::move(ticket))->start();
    return promise;
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
            { "openInMediaPlayer", contentContextOpenInMediaPlayer, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
            { "withMediaPlayerHandoff", contentContextWithMediaPlayerHandoff, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete },
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
