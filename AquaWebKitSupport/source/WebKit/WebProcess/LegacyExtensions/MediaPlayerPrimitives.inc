static JSValueRef mediaJSON(JSContextRef context, const String& json)
{
    auto string = adopt(JSStringCreateWithUTF8CString(json.utf8().data()));
    return JSValueMakeFromJSONString(context, string.get());
}

static void mediaResult(NativePromise& pending, Expected<String, String>&& result)
{
    if (!result)
        return pending.rejectWith(result.error());
    pending.resolveWith(mediaJSON(pending.context.get(), *result));
}

struct NativeMediaSource;
struct NativePlaylistRequest : std::enable_shared_from_this<NativePlaylistRequest> {
    std::weak_ptr<NativeMediaSource> owner;
    uint64_t identifier;
    CompletionHandler<void(String&&)> reply;
    RunLoop::Timer deadline;
    NativePlaylistRequest(std::weak_ptr<NativeMediaSource> source, uint64_t request, CompletionHandler<void(String&&)>&& completion)
        : owner(WTF::move(source)), identifier(request), reply(WTF::move(completion))
        , deadline(RunLoop::mainSingleton(), "Media playlist response"_s, [this] { finish({ }); }) { }
    void finish(String);
};
struct NativeMediaSession : std::enable_shared_from_this<NativeMediaSession> {
    ContentContextNative native;
    WeakPtr<WebCore::HTMLMediaElement> media;
    WebCore::ScriptExecutionContextIdentifier document;
    Vector<Ref<WebCore::TextTrack>> tracks;
    uint64_t identifier { nextMediaPlayerHandoffIdentifier() };
    bool closed { false };
    bool connected { false };
    Vector<std::weak_ptr<NativeMediaSource>> sources;
    RunLoop::Timer unusedLease;

    NativeMediaSession(const ContentContextNative& context, WebCore::HTMLMediaElement& element, Vector<Ref<WebCore::TextTrack>>&& selected)
        : native(context), media(element), document(element.document().identifier()), tracks(WTF::move(selected))
        , unusedLease(RunLoop::mainSingleton(), "Unattached media session lease"_s, [this] { close(); }) { }
    ~NativeMediaSession() { close(); }
    static std::vector<std::weak_ptr<NativeMediaSession>>& sessions()
    {
        static NeverDestroyed<std::vector<std::weak_ptr<NativeMediaSession>>> value;
        return value;
    }
    bool valid() const
    {
        return !closed && documentForNative(native) && media && media->document().identifier() == document && media->document().page();
    }
    void close();
    void playerClosed();
    void disconnect()
    {
        connected = false;
        if (media)
            WebCore::MediaRestreamSource::setExternalPlaybackTarget(*media, identifier, false);
    }
};

struct NativeMediaSource : std::enable_shared_from_this<NativeMediaSource> {
    std::shared_ptr<NativeMediaSession> owner;
    uint64_t identifier;
    URL url;
    bool capture;
    bool localResources;
    bool publishesResources { false };
    bool opened { false };
    bool accepted { false };
    bool closed { false };
    std::unique_ptr<NativePromise> ended;
    JSObjectRef closedPromise { nullptr };
    JSRetainPtr<JSGlobalContextRef> providerContext;
    JSObjectRef provider { nullptr };
    Seconds providerTimeout { 30_s };
    uint64_t nextRequest { 1 };
    std::map<uint64_t, std::shared_ptr<NativePlaylistRequest>> requests;

    NativeMediaSource(std::shared_ptr<NativeMediaSession> session, uint64_t source, bool isCapture, bool hasPlaylist)
        : owner(WTF::move(session)), identifier(source), capture(isCapture), localResources(!isCapture && hasPlaylist) { }
    bool valid() const { return !closed && documentForNative(owner->native); }
    void close() { if (!closed) MediaRestreamSession::singleton().stop(identifier); }
    ~NativeMediaSource() { clearProvider(); }
    void clearProvider()
    {
        MediaRestreamSession::singleton().setPlaylistProvider(identifier, { });
        for (auto& [identifier, request] : std::exchange(requests, { }))
            request->finish({ });
        if (provider) JSValueUnprotect(providerContext.get(), provider);
        provider = nullptr;
        providerContext = nullptr;
    }
    void requestPlaylist(const String& name, CompletionHandler<void(String&&)>&& reply)
    {
        if (!valid() || !provider || requests.size() >= 16)
            return reply({ });
        auto identifier = nextRequest++;
        auto request = std::make_shared<NativePlaylistRequest>(weak_from_this(), identifier, WTF::move(reply));
        requests.emplace(identifier, request);
        request->deadline.startOneShot(providerTimeout);
        Ref document = *documentForNative(owner->native);
        document->eventLoop().queueTask(WebCore::TaskSource::Networking, [weakSource = weak_from_this(), request, name] {
            if (auto source = weakSource.lock(); source && source->valid() && source->provider)
                source->invokeProvider(name, request);
            else
                request->finish({ });
        });
    }
    void invokeProvider(const String& name, const std::shared_ptr<NativePlaylistRequest>& request)
    {
        if (!request->reply)
            return;
        JSRetainPtr context = providerContext;
        JSObjectRef callback = provider;
        JSValueProtect(context.get(), callback);
        auto unprotect = makeScopeExit([&] { JSValueUnprotect(context.get(), callback); });
        auto path = adopt(JSStringCreateWithUTF8CString(name.utf8().data()));
        JSValueRef arguments[] = {
            JSValueMakeString(context.get(), path.get()),
            sourceCompletion(context.get(), [weakRequest = std::weak_ptr { request }](String text) {
                if (auto pending = weakRequest.lock())
                    pending->finish(text.length() <= 1024 * 1024 ? WTF::move(text) : String { });
            })
        };
        JSValueRef error = nullptr;
        JSObjectCallAsFunction(context.get(), callback, nullptr, 2, arguments, &error);
        if (error) request->finish({ });
    }
    void observe(JSContextRef context)
    {
        JSObjectRef resolve, reject;
        closedPromise = JSObjectMakeDeferredPromise(context, &resolve, &reject, nullptr);
        ended = std::make_unique<NativePromise>(owner->native, context, resolve, reject);
        MediaRestreamSession::singleton().setDidEnd(identifier, [self = shared_from_this()] {
            self->closed = true;
            self->clearProvider();
            if (self->accepted)
                self->owner->playerClosed();
            self->ended->resolveWith(JSValueMakeUndefined(self->ended->context.get()));
            self->ended = nullptr;
        });
        owner->sources.append(weak_from_this());
    }
};

void NativePlaylistRequest::finish(String text)
{
    if (!reply) return;
    auto protect = shared_from_this();
    deadline.stop();
    if (auto source = owner.lock())
        source->requests.erase(identifier);
    std::exchange(reply, { })(WTF::move(text));
}

void NativeMediaSession::close()
{
    if (std::exchange(closed, true))
        return;
    auto protect = weak_from_this().lock();
    unusedLease.stop();
    for (auto& weakSource : sources) {
        if (auto source = weakSource.lock(); source && (!source->opened || source->capture || source->publishesResources))
            source->close();
    }
    disconnect();
    if (RefPtr element = media.get()) {
        WebCore::MediaRestreamSource::cancelPending(*element, identifier);
        WebCore::MediaRestreamSource::setPreparingExternalPlayback(*element, identifier, false);
        if (!WebCore::MediaRestreamSource::isPlayingExternally(*element))
            element->setMediaPlayerPresentedExternally(false, identifier);
    }
    WebProcess::singleton().parentProcessConnection()->send(Messages::LegacyExtensionHost::EndMediaPlayerHandoff(identifier), 0);
}

void NativeMediaSession::playerClosed()
{
    if (closed)
        return;
    bool pending = false;
    for (auto& weakSource : sources) {
        if (auto source = weakSource.lock(); source && !source->closed) {
            if (source->accepted)
                return;
            pending = true;
        }
    }
    if (pending)
        unusedLease.startOneShot(5_min);
    else
        close();
}

static JSClassRef mediaSessionClass();
static JSClassRef mediaSourceClass();

template<typename T> static JSObjectRef mediaHandle(JSContextRef context, JSClassRef type, const std::shared_ptr<T>& owner)
{
    return JSObjectMake(context, type, new std::shared_ptr<T>(owner));
}

template<typename T> static void releaseMediaHandle(JSObjectRef object)
{
    auto holder = std::unique_ptr<std::shared_ptr<T>>(static_cast<std::shared_ptr<T>*>(JSObjectGetPrivate(object)));
    RunLoop::mainSingleton().dispatch([holder = WTF::move(holder)] { });
}

static JSObjectRef mediaSourceHandle(JSContextRef context, const std::shared_ptr<NativeMediaSource>& source)
{
    auto object = mediaHandle(context, mediaSourceClass(), source);
    auto put = [&](const char* name, JSValueRef value) {
        auto key = adopt(JSStringCreateWithUTF8CString(name));
        JSObjectSetProperty(context, object, key.get(), value, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete, nullptr);
    };
    auto url = adopt(JSStringCreateWithUTF8CString(source->url.string().utf8().data()));
    put("url", JSValueMakeString(context, url.get()));
    put("capture", JSValueMakeBoolean(context, source->capture));
    put("closed", source->closedPromise);
    return object;
}

static JSValueRef mediaSourceCommand(JSContextRef context, JSObjectRef, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    if (!JSValueIsObjectOfClass(context, object, mediaSourceClass())) {
        auto message = adopt(JSStringCreateWithUTF8CString("invalid-handle"));
        JSValueRef argument = JSValueMakeString(context, message.get());
        *exception = JSObjectMakeError(context, 1, &argument, nullptr);
        return JSValueMakeUndefined(context);
    }
    auto source = *static_cast<std::shared_ptr<NativeMediaSource>*>(JSObjectGetPrivate(object));
    JSObjectRef resolve, reject;
    auto promise = JSObjectMakeDeferredPromise(context, &resolve, &reject, exception);
    if (!promise)
        return JSValueMakeUndefined(context);
    auto pending = std::make_unique<NativePromise>(source->owner->native, context, resolve, reject);
    auto operation = LegacyExtensions::stringArgument(context, count, arguments, 0);
    if (!documentForNative(source->owner->native)) {
        pending->rejectWith("no-source"_s);
        return promise;
    }
    if (operation == "close"_s) {
        source->close();
        pending->resolveWith(JSValueMakeUndefined(context));
        return promise;
    }
    if (!source->valid()) {
        pending->rejectWith("player-closed"_s);
        return promise;
    }
    if ((operation == "playlist-provider"_s || operation == "resource"_s || operation == "remove-resource"_s) && !source->owner->valid()) {
        pending->rejectWith("no-source"_s);
        return promise;
    }
    auto value = JSON::Value::parseJSON(LegacyExtensions::stringArgument(context, count, arguments, 1));
    auto options = value ? value->asObject() : nullptr;
    if (!options) {
        pending->rejectWith("invalid-options"_s);
        return promise;
    }
    auto* connection = WebProcess::singleton().parentProcessConnection();
    if (operation == "playlist-provider"_s) {
        auto callback = count > 2 && JSValueIsObject(context, arguments[2]) ? JSValueToObject(context, arguments[2], nullptr) : nullptr;
        auto timeout = options->getDouble("timeout"_s);
        if (!source->localResources || !timeout || !std::isfinite(*timeout) || *timeout <= 0 || *timeout > 300
            || (count > 2 && !JSValueIsNull(context, arguments[2]) && !JSValueIsUndefined(context, arguments[2]) && !callback)
            || (callback && !JSObjectIsFunction(context, callback))) {
            pending->rejectWith("invalid-options"_s);
            return promise;
        }
        source->clearProvider();
        if (callback) {
            source->publishesResources = true;
            source->providerContext = JSContextGetGlobalContext(context);
            source->provider = callback;
            source->providerTimeout = Seconds { *timeout };
            JSValueProtect(context, callback);
            MediaRestreamSession::singleton().setPlaylistProvider(source->identifier, [weakSource = std::weak_ptr { source }](const String& name, CompletionHandler<void(String&&)>&& reply) {
                if (auto source = weakSource.lock())
                    source->requestPlaylist(name, WTF::move(reply));
                else reply({ });
            });
        }
        connection->sendWithAsyncReply(Messages::LegacyExtensionHost::SetMediaPlaylistProvider(source->identifier, !!callback), [source, pending = WTF::move(pending)](bool succeeded) mutable {
            if (!succeeded) {
                source->clearProvider();
                return pending->rejectWith("no-source"_s);
            }
            pending->resolveWith(JSValueMakeUndefined(pending->context.get()));
        }, 0);
    } else if (operation == "resource"_s || operation == "remove-resource"_s) {
        if (!source->localResources) {
            pending->rejectWith("unsupported-source"_s);
            return promise;
        }
        auto data = operation == "resource"_s ? LegacyExtensions::bufferArgument(context, count, arguments, 2) : nullptr;
        if (operation == "resource"_s && (!data || data->size() > 64 * 1024 * 1024)) {
            pending->rejectWith("invalid-resource"_s);
            return promise;
        }
        source->publishesResources = true;
        std::optional<IPC::SharedBufferReference> bytes;
        if (data) bytes.emplace(data);
        connection->sendWithAsyncReply(Messages::LegacyExtensionHost::SetMediaResource(source->identifier, options->getString("name"_s), options->getString("type"_s), bytes), [pending = WTF::move(pending)](Expected<URL, String>&& result) mutable {
            if (!result)
                return pending->rejectWith(result.error());
            auto text = adopt(JSStringCreateWithUTF8CString(result->string().utf8().data()));
            pending->resolveWith(JSValueMakeString(pending->context.get(), text.get()));
        }, 0);
    } else if (operation == "open"_s) {
        auto timeout = options->getDouble("timeout"_s);
        auto application = options->getString("application"_s);
        if (source->opened || application.isEmpty() || !timeout || !std::isfinite(*timeout) || *timeout <= 0 || *timeout > 300) {
            pending->rejectWith("invalid-options"_s);
            return promise;
        }
        source->opened = true;
        connection->sendWithAsyncReply(Messages::LegacyExtensionHost::OpenPublishedMedia(source->identifier, application, options->getString("adapter"_s), *timeout), [source, pending = WTF::move(pending)](Expected<URL, String>&& result) mutable {
            if (!result) {
                source->opened = false;
                return pending->rejectWith(result.error());
            }
            if (!source->valid())
                return pending->rejectWith("player-closed"_s);
            source->accepted = true;
            source->owner->unusedLease.stop();
            pending->resolveWith(JSValueMakeUndefined(pending->context.get()));
        }, 0);
    } else if (operation == "state"_s) {
        connection->sendWithAsyncReply(Messages::LegacyExtensionHost::MediaPlayerState(source->identifier), [pending = WTF::move(pending)](Expected<String, String>&& result) mutable {
            mediaResult(*pending, WTF::move(result));
        }, 0);
    } else if (operation == "activate"_s) {
        connection->sendWithAsyncReply(Messages::LegacyExtensionHost::ActivateMediaPlayer(source->identifier), [pending = WTF::move(pending)](Expected<bool, String>&& result) mutable {
            if (!result)
                return pending->rejectWith(result.error());
            pending->resolveWith(JSValueMakeBoolean(pending->context.get(), *result));
        }, 0);
    } else if (operation == "play"_s || operation == "pause"_s || operation == "seek"_s || operation == "rate"_s) {
        auto supplied = options->getDouble("value"_s);
        auto number = supplied.value_or(0);
        if (!std::isfinite(number) || ((operation == "seek"_s || operation == "rate"_s) && !supplied)) {
            pending->rejectWith("invalid-options"_s);
            return promise;
        }
        connection->sendWithAsyncReply(Messages::LegacyExtensionHost::ControlMediaPlayer(source->identifier, operation, number), [pending = WTF::move(pending)](bool succeeded) mutable {
            if (!succeeded)
                return pending->rejectWith("player-command-failed"_s);
            pending->resolveWith(JSValueMakeUndefined(pending->context.get()));
        }, 0);
    } else
        pending->rejectWith("unsupported-operation"_s);
    return promise;
}

static JSValueRef mediaSessionCommand(JSContextRef context, JSObjectRef, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    if (!JSValueIsObjectOfClass(context, object, mediaSessionClass())) {
        auto message = adopt(JSStringCreateWithUTF8CString("invalid-handle"));
        JSValueRef argument = JSValueMakeString(context, message.get());
        *exception = JSObjectMakeError(context, 1, &argument, nullptr);
        return JSValueMakeUndefined(context);
    }
    auto session = *static_cast<std::shared_ptr<NativeMediaSession>*>(JSObjectGetPrivate(object));
    JSObjectRef resolve, reject;
    auto promise = JSObjectMakeDeferredPromise(context, &resolve, &reject, exception);
    if (!promise)
        return JSValueMakeUndefined(context);
    auto pending = std::make_unique<NativePromise>(session->native, context, resolve, reject);
    auto operation = LegacyExtensions::stringArgument(context, count, arguments, 0);
    if (operation == "close"_s) {
        session->close();
        pending->resolveWith(JSValueMakeUndefined(context));
        return promise;
    }
    if (!session->valid()) {
        pending->rejectWith("no-source"_s);
        return promise;
    }
    Ref media = *session->media;
    auto value = JSON::Value::parseJSON(LegacyExtensions::stringArgument(context, count, arguments, 1));
    auto options = value ? value->asObject() : nullptr;
    if (!options) {
        pending->rejectWith("invalid-options"_s);
        return promise;
    }
    if (operation == "inspect"_s) {
        auto result = JSON::Object::create();
        auto urls = JSON::Array::create();
        bool externalTracks = std::any_of(session->tracks.begin(), session->tracks.end(), [](auto& track) { return track->trackType() != WebCore::TextTrack::InBand; });
        if (!externalTracks) {
            for (auto& url : media->externalMediaSourceURLs())
                urls->pushString(url.string());
        }
        result->setArray("sources"_s, WTF::move(urls));
        result->setBoolean("requiresCapture"_s, externalTracks || WebCore::MediaRestreamSource::requiresCapture(media));
        result->setBoolean("canConnect"_s, session->tracks.isEmpty() && WebCore::MediaRestreamSource::canNegotiateRemotePlayback(media));
        result->setBoolean("tracksValid"_s, WebCore::MediaRestreamSource::validateTextTracks(media, session->tracks));
        pending->resolveWith(mediaJSON(context, result->toJSONString()));
    } else if (operation == "connect"_s) {
        if (!WebCore::MediaRestreamSource::allowsExternalPlayback(media)) {
            pending->rejectWith("remote-playback-disabled"_s);
            return promise;
        }
        session->connected = true;
        WebCore::MediaRestreamSource::setPreparingExternalPlayback(media, session->identifier, true);
        media->setMediaPlayerPresentedExternally(true, session->identifier, options->getString("message"_s));
        WebCore::MediaRestreamSource::setExternalPlaybackTarget(media, session->identifier, true);
        pending->resolveWith(JSValueMakeUndefined(context));
    } else if (operation == "connected"_s) {
        if (!session->connected || !WebCore::MediaRestreamSource::externalPlaybackTarget(media) || media->readyState() < WebCore::HTMLMediaElement::HAVE_METADATA) {
            pending->rejectWith("source-not-ready"_s);
            return promise;
        }
        WebCore::MediaRestreamSource::confirmExternalPlaybackTarget(media, session->identifier);
        pending->resolveWith(JSValueMakeUndefined(context));
    } else if (operation == "disconnect"_s) {
        session->disconnect();
        pending->resolveWith(JSValueMakeUndefined(context));
    } else if (operation == "present"_s) {
        auto mode = options->getString("mode"_s);
        if (mode != "opening"_s && mode != "external"_s && mode != "inline"_s) {
            pending->rejectWith("invalid-options"_s);
            return promise;
        }
        bool external = mode != "inline"_s;
        if (!external)
            session->disconnect();
        WebCore::MediaRestreamSource::setPreparingExternalPlayback(media, session->identifier, external);
        media->setMediaPlayerPresentedExternally(external, session->identifier, mode == "opening"_s ? options->getString("message"_s) : String { });
        pending->resolveWith(JSValueMakeUndefined(context));
    } else if (operation == "publish"_s || operation == "capture"_s) {
        bool capture = operation == "capture"_s;
        URL url { options->getString("url"_s) };
        auto playlist = options->getString("playlist"_s);
        auto title = options->getString("title"_s).left(1024);
        if ((!capture && !url.protocolIsInHTTPFamily()) || (options->getValue("playlist"_s) && options->getValue("playlist"_s)->type() != JSON::Value::Type::String)
            || playlist.length() > 1024 * 1024 || (!playlist.isEmpty() && !playlist.startsWith("#EXTM3U"_s))) {
            pending->rejectWith("unsupported-source"_s);
            return promise;
        }
        auto codec = options->getString("videoCodec"_s);
        auto transport = options->getString("transport"_s);
        if (transport == "hls"_s)
            codec = { };
        auto publish = [session, capture, url, playlist, title, codec, pending = WTF::move(pending)](Expected<uint64_t, String>&& created) mutable {
            if (!created)
                return pending->rejectWith(created.error());
            auto identifier = *created;
            if (!session->valid()) {
                MediaRestreamSession::singleton().stop(identifier);
                return pending->rejectWith("no-source"_s);
            }
            auto source = std::make_shared<NativeMediaSource>(session, identifier, capture, !playlist.isEmpty());
            source->observe(pending->context.get());
            Ref document = *documentForNative(session->native);
            WebProcess::singleton().parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionHost::PublishMediaSource(session->native.frameID, session->native.documentIdentifier, document->url(), session->native.extensionKey, session->identifier, identifier, url, playlist, title, codec), [source, pending = WTF::move(pending)](Expected<URL, String>&& result) mutable {
                if (!result || !source->owner->valid() || source->closed) {
                    source->close();
                    return pending->rejectWith(result ? "no-source"_s : result.error());
                }
                source->url = *result;
                MediaRestreamSession::singleton().accept(source->identifier);
                pending->resolveWith(mediaSourceHandle(pending->context.get(), source));
            }, 0);
        };
        if (!capture)
            publish(MediaRestreamSession::singleton().reserve());
        else {
            auto width = options->getDouble("maxWidth"_s);
            auto height = options->getDouble("maxHeight"_s);
            auto history = options->getDouble("maxHistoryDuration"_s);
            auto storage = options->getDouble("minimumFreeStorage"_s);
            auto dimension = [](auto value) { return value && std::isfinite(*value) && *value >= 2 && *value <= 16384 && *value == std::floor(*value); };
            bool valid = dimension(width) && dimension(height)
                && (!options->getValue("maxHistoryDuration"_s) || history.has_value())
                && (!options->getValue("minimumFreeStorage"_s) || storage.has_value())
                && (!history || (std::isfinite(*history) && *history >= 9))
                && (!storage || (std::isfinite(*storage) && *storage >= 0 && *storage <= 9007199254740991.0 && *storage == std::floor(*storage)))
                && ((transport == "hls"_s && options->getString("videoCodec"_s) == "h264"_s) || (transport == "rtsp"_s && (codec == "jpeg"_s || codec == "utvideo"_s) && !history && !storage))
                && WebCore::MediaRestreamSource::validateTextTracks(media, session->tracks);
            if (!valid)
                publish(makeUnexpected("unsupported-source"_s));
            else {
                media->setMediaPlayerPresentedExternally(true, session->identifier, options->getString("openingMessage"_s));
                MediaRestreamSession::singleton().create(media, session->tracks, { static_cast<int>(*width), static_cast<int>(*height) }, codec, history, storage ? std::optional<uint64_t> { static_cast<uint64_t>(*storage) } : std::nullopt, WTF::move(publish));
            }
        }
    } else
        pending->rejectWith("unsupported-operation"_s);
    return promise;
}

static JSClassRef mediaSessionClass()
{
    static JSClassRef type = [] {
        static const JSStaticFunction methods[] = { { "command", mediaSessionCommand, kJSPropertyAttributeReadOnly }, { nullptr, nullptr, 0 } };
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.className = "MediaSessionHandle";
        definition.staticFunctions = methods;
        definition.finalize = releaseMediaHandle<NativeMediaSession>;
        return JSClassCreate(&definition);
    }();
    return type;
}

static JSClassRef mediaSourceClass()
{
    static JSClassRef type = [] {
        static const JSStaticFunction methods[] = { { "command", mediaSourceCommand, kJSPropertyAttributeReadOnly }, { nullptr, nullptr, 0 } };
        JSClassDefinition definition = kJSClassDefinitionEmpty;
        definition.className = "MediaSourceHandle";
        definition.staticFunctions = methods;
        definition.finalize = releaseMediaHandle<NativeMediaSource>;
        return JSClassCreate(&definition);
    }();
    return type;
}

static JSValueRef contentContextCreateMediaSession(JSContextRef context, JSObjectRef, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    JSObjectRef resolve, reject;
    auto promise = JSObjectMakeDeferredPromise(context, &resolve, &reject, exception);
    if (!promise)
        return JSValueMakeUndefined(context);
    auto* native = static_cast<ContentContextNative*>(JSObjectGetPrivate(object));
    auto pending = std::make_unique<NativePromise>(*native, context, resolve, reject);
    RefPtr document = documentForNative(*native);
    auto* global = toJS(context);
    JSC::JSLockHolder lock(global->vm());
    RefPtr media = count ? dynamicDowncast<WebCore::HTMLMediaElement>(WebCore::JSElement::toWrapped(global->vm(), toJS(global, arguments[0]))) : nullptr;
    auto parent = parentMediaPlayerHandoff(context, count, arguments, 2, *native);
    if (!document || !media || !parent || !media->player() || !document->securityOrigin().isSameOriginDomain(media->document().securityOrigin())) {
        pending->rejectWith("no-source"_s);
        return promise;
    }
    auto target = media->document().identifier();
    std::optional<Vector<Ref<WebCore::TextTrack>>> tracks;
    if (count > 1 && !JSValueIsUndefined(context, arguments[1])) {
        if (!JSValueIsArray(context, arguments[1])) {
            pending->rejectWith("unsupported-source"_s);
            return promise;
        }
        tracks.emplace();
        auto array = JSValueToObject(context, arguments[1], nullptr);
        auto lengthKey = adopt(JSStringCreateWithUTF8CString("length"));
        JSValueRef error = nullptr;
        auto lengthValue = JSObjectGetProperty(context, array, lengthKey.get(), &error);
        double length = error ? -1 : JSValueToNumber(context, lengthValue, &error);
        if (error || !std::isfinite(length) || length < 0 || length > WebCore::MediaRestreamSource::textTrackCount(*media) || length != std::floor(length)) {
            pending->rejectWith("unsupported-source"_s);
            return promise;
        }
        HashSet<WebCore::TextTrack*> selected;
        for (unsigned i = 0; i < length; ++i) {
            auto value = JSObjectGetPropertyAtIndex(context, array, i, &error);
            auto* track = error ? nullptr : WebCore::JSTextTrack::toWrapped(global->vm(), toJS(global, value));
            if (!track || !selected.add(track).isNewEntry) {
                pending->rejectWith("unsupported-source"_s);
                return promise;
            }
            tracks->append(Ref { *track });
        }
        if (!WebCore::MediaRestreamSource::validateTextTracks(*media, *tracks)) {
            pending->rejectWith("unsupported-source"_s);
            return promise;
        }
    }
    if (documentForNative(*native) != document || !media->document().page() || media->document().identifier() != target) {
        pending->rejectWith("no-source"_s);
        return promise;
    }
    std::erase_if(NativeMediaSession::sessions(), [](auto& weakSession) { return weakSession.expired(); });
    if (WebCore::MediaRestreamSource::isPlayingExternally(*media) || std::any_of(NativeMediaSession::sessions().begin(), NativeMediaSession::sessions().end(), [&](auto& weakSession) {
        auto session = weakSession.lock();
        return session && !session->closed && session->media.get() == media.get();
    })) {
        pending->rejectWith("application-busy"_s);
        return promise;
    }
    auto session = std::make_shared<NativeMediaSession>(*native, *media, WebCore::MediaRestreamSource::selectedTextTracks(*media, tracks));
    NativeMediaSession::sessions().push_back(session);
    WebProcess::singleton().parentProcessConnection()->sendWithAsyncReply(Messages::LegacyExtensionHost::BeginMediaPlayerHandoff(native->frameID, session->identifier, *parent, String { }, native->extensionKey), [session, pending = WTF::move(pending)](Expected<bool, String>&& result) mutable {
        if (!result || !session->valid())
            return pending->rejectWith(result ? "no-source"_s : result.error());
        session->unusedLease.startOneShot(5_min);
        pending->resolveWith(mediaHandle(pending->context.get(), mediaSessionClass(), session));
    }, 0);
    return promise;
}
