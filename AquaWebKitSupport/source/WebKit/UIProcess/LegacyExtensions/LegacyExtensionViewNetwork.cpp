#include "config.h"
#include "LegacyExtensionViewNetwork.h"

#include "LegacyExtensionErrors.h"
#include "LegacyExtensionHost.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/AuthenticationClient.h>
#include <WebCore/CocoaCookie.h>
#include <WebCore/CocoaCurlResourceHandle.h>
#include <WebCore/CookieJar.h>
#include <WebCore/Credential.h>
#include <WebCore/Document.h>
#include <WebCore/FrameDestructionObserverInlines.h>
#include <WebCore/FrameLoader.h>
#include <WebCore/FrameTree.h>
#include <WebCore/LocalFrame.h>
#include <WebCore/LocalFrameInlines.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/NetworkingContext.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceLoader.h>
#include <WebCore/ResourceLoaderOptions.h>
#include <WebCore/SecurityOrigin.h>
#include <wtf/ProcessID.h>

namespace WebKit {

using namespace WebCore;
using namespace LegacyExtensions;

static constexpr auto extensionScheme = "safari-extension"_s;

LegacyExtensionViewNetwork& LegacyExtensionViewNetwork::singleton()
{
    static NeverDestroyed<LegacyExtensionViewNetwork> network;
    return network;
}

void LegacyExtensionViewNetwork::setListeners(const Vector<String>& observedEvents, const Vector<String>& listenerOptions, const String& blockingListeners)
{
    m_listeners.set(Vector<String> { observedEvents }, Vector<String> { listenerOptions }, blockingListeners);
}

static Ref<JSON::Object> copy(const JSON::Object& object)
{
    return JSON::Value::parseJSON(object.toJSONString())->asObject().releaseNonNull();
}

static double frameIdentifier(const Frame& frame)
{
    return frame.isMainFrame() ? 0 : static_cast<double>(frame.frameID().toUInt64());
}

static RefPtr<CocoaCurlResourceHandle> curlHandle(ResourceLoader& loader)
{
    RefPtr handle = loader.handle();
    return handle ? handle->cocoaCurlHandle() : nullptr;
}

// WebKit fails a subresource's redirect to a data: URL, which only a document's load decodes itself.
static bool loadsInPlace(bool isMainFrameLoad, ASCIILiteral type, const URL& url)
{
    return url.protocolIsData() && !isMainFrameLoad && type != "sub_frame"_s;
}

// A redirect's request moved to another target by an onHeadersReceived verdict: a request that leaves the
// redirect's origin carries none of its credentials.
static void retarget(ResourceRequest& request, const ResourceResponse& redirectResponse, const URL& target)
{
    request.setURL(URL { target });
    if (!protocolHostAndPortAreEqual(redirectResponse.url(), target)) {
        request.clearHTTPAuthorization();
        request.clearHTTPOrigin();
        request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    }
}

RefPtr<LegacyExtensionViewNetwork::Load> LegacyExtensionViewNetwork::createLoad(LocalFrame* frame, const ResourceRequest& request, FetchOptions::Destination destination, bool isMainFrameLoad, String&& requestId)
{
    if (m_listeners.isEmpty() || !frame)
        return nullptr;
    RefPtr mainFrame = frame->localMainFrame();
    RefPtr mainDocument = mainFrame ? mainFrame->document() : nullptr;
    bool showsExtensionPage = mainDocument && mainDocument->url().protocolIs(extensionScheme);
    if (!showsExtensionPage && !(isMainFrameLoad && request.url().protocolIs(extensionScheme)))
        return nullptr;

    auto load = Load::create();
    load->requestId = WTF::move(requestId);
    load->type = resourceType(request, destination, isMainFrameLoad);
    load->isMainFrameLoad = isMainFrameLoad;
    load->frameId = frameIdentifier(*frame);
    RefPtr parent = frame->tree().parent();
    load->parentFrameId = parent ? frameIdentifier(*parent) : -1;
    // A frame's navigation is made for its parent's document.
    RefPtr<Document> document;
    if (load->type == "sub_frame"_s) {
        if (RefPtr localParent = dynamicDowncast<LocalFrame>(parent))
            document = localParent->document();
    } else if (!isMainFrameLoad)
        document = frame->document();
    if (document) {
        load->documentURL = document->url().string();
        load->initiator = document->securityOrigin().toString();
    }
    load->networkingContext = frame->loader().networkingContext();
    load->url = request.url();
    load->method = request.httpMethod();
    return load;
}

Ref<JSON::Object> LegacyExtensionViewNetwork::details(const Load& load) const
{
    auto details = JSON::Object::create();
    details->setString("requestId"_s, load.requestId);
    details->setString("url"_s, load.url.string());
    details->setString("method"_s, load.method);
    details->setString("type"_s, load.type);
    details->setDouble("timeStamp"_s, timeStamp());
    details->setDouble("tabId"_s, -1);
    details->setDouble("frameId"_s, load.frameId);
    details->setDouble("parentFrameId"_s, load.parentFrameId);
    if (!load.documentURL.isEmpty())
        details->setString("documentUrl"_s, load.documentURL);
    if (!load.initiator.isEmpty())
        details->setString("initiator"_s, load.initiator);
    return details;
}

Ref<JSON::Object> LegacyExtensionViewNetwork::responseDetails(const Load& load, const ResourceResponse& response) const
{
    auto details = this->details(load);
    details->setString("url"_s, response.url().string());
    addResponseFields(details, response);
    return details;
}

// The Cookie field the network layer generates for a request, as CocoaCurlResourceHandle generates it.
String LegacyExtensionViewNetwork::generatedCookie(const Load& load, const ResourceRequest& request) const
{
    RefPtr networkingContext = load.networkingContext;
    auto* storage = networkingContext ? networkingContext->storageSession() : nullptr;
    if (!storage || !request.allowCookies() || !request.url().protocolIsInHTTPFamily())
        return { };
    return storage->cookieRequestHeaderFieldValue(request.firstPartyForCookies(), cookieRequestSameSiteInfo(request), request.url(), std::nullopt, std::nullopt, request.url().protocolIs("https"_s) ? IncludeSecureCookies::Yes : IncludeSecureCookies::No, ApplyTrackingPrevention::Yes, ShouldRelaxThirdPartyCookieBlocking::No, IsKnownCrossSiteTracker::No).first;
}

void LegacyExtensionViewNetwork::notify(ASCIILiteral eventName, Ref<JSON::Object>&& details)
{
    LegacyExtensionHost::singleton().dispatchWebRequestEvent(String { eventName }, WTF::move(details), { });
}

void LegacyExtensionViewNetwork::dispatch(ASCIILiteral eventName, Ref<JSON::Object>&& details, CompletionHandler<void(RefPtr<JSON::Object>&&)>&& completionHandler)
{
    LegacyExtensionHost::singleton().dispatchWebRequestEvent(String { eventName }, WTF::move(details), [completionHandler = WTF::move(completionHandler)](String&& response) mutable {
        auto value = JSON::Value::parseJSON(response);
        completionHandler(value ? value->asObject() : nullptr);
    });
}

// Request steps.

void LegacyExtensionViewNetwork::willSendRequest(Ref<Load>&& load, ResourceRequest&& request, const ResourceResponse& redirectResponse, RequestCompletion&& completion)
{
    // An extension's Cookie edit is its exchange's alone: a redirect generates its own.
    if (auto editedCookie = std::exchange(load->editedCookie, String()); !editedCookie.isNull() && request.httpHeaderField(HTTPHeaderName::Cookie) == editedCookie)
        request.removeHTTPHeaderField(HTTPHeaderName::Cookie);
    load->url = request.url();
    load->method = request.httpMethod();
    if (!redirectResponse.isNull()) {
        load->isRedirected = true;
        if (m_listeners.observes(onBeforeRedirect) && isInterceptable(redirectResponse.url())) {
            auto details = this->details(load);
            details->setString("url"_s, redirectResponse.url().string());
            details->setString("redirectUrl"_s, request.url().string());
            addResponseFields(details, redirectResponse);
            notify(onBeforeRedirect, WTF::move(details));
        }
    }
    if (!isInterceptable(request.url()))
        return completion({ RequestVerdict::Kind::Proceed, WTF::move(request), { }, { } });
    beforeRequest(WTF::move(load), WTF::move(request), WTF::move(completion));
}

// onBeforeRequest. A redirect the verdict makes before the request is sent is Chrome's internal redirect: a
// main frame follows it as a redirect; any other request loads the new URL in place, as WebKit's content
// rules redirect it, after the redirect's onBeforeRedirect and the new URL's own onBeforeRequest.
void LegacyExtensionViewNetwork::beforeRequest(Ref<Load>&& load, ResourceRequest&& request, RequestCompletion&& completion)
{
    load->url = request.url();
    load->method = request.httpMethod();
    auto details = this->details(load);
    if (m_listeners.hasOption(onBeforeRequest, requestBodyOption)) {
        if (auto body = requestBody(request))
            details->setObject("requestBody"_s, body.releaseNonNull());
    }
    if (!m_listeners.blocks(onBeforeRequest, details)) {
        if (m_listeners.observes(onBeforeRequest))
            notify(onBeforeRequest, WTF::move(details));
        return beforeSendHeaders(WTF::move(load), WTF::move(request), WTF::move(completion));
    }

    dispatch(onBeforeRequest, WTF::move(details), [this, load = WTF::move(load), request = WTF::move(request), completion = WTF::move(completion)](RefPtr<JSON::Object>&& verdict) mutable {
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false))
            return completion({ RequestVerdict::Kind::Fail, { }, { }, cancellationError(request) });
        URL redirectURL { verdict ? verdict->getString("redirectUrl"_s) : String() };
        if (!redirectURL.isValid() || redirectURL == request.url())
            return beforeSendHeaders(WTF::move(load), WTF::move(request), WTF::move(completion));

        auto redirectResponse = internalRedirectResponse(request.url(), redirectURL);
        if (load->isMainFrameLoad && !load->isRedirected) {
            request.setURL(WTF::move(redirectURL));
            return completion({ RequestVerdict::Kind::MainFrameRedirect, WTF::move(request), WTF::move(redirectResponse), { } });
        }
        if (++load->internalRedirectCount > ResourceLoaderOptions { }.maxRedirectCount)
            return completion({ RequestVerdict::Kind::Fail, { }, { }, ResourceError { errorDomainWebKitInternal, 0, redirectURL, "Load cannot follow more than 20 redirections"_s } });
        if (m_listeners.observes(onBeforeRedirect)) {
            auto details = this->details(load);
            details->setString("redirectUrl"_s, redirectURL.string());
            addResponseFields(details, redirectResponse);
            notify(onBeforeRedirect, WTF::move(details));
        }
        request.setURL(WTF::move(redirectURL));
        load->url = request.url();
        if (!isInterceptable(request.url()))
            return completion({ RequestVerdict::Kind::Proceed, WTF::move(request), { }, { } });
        beforeRequest(WTF::move(load), WTF::move(request), WTF::move(completion));
    });
}

// onBeforeSendHeaders and onSendHeaders, with the headers the request is sent with. "extraHeaders" listeners
// see the fields the network layer adds to a request that carries none, and a verdict that changes or
// removes one sends the verdict's field instead.
void LegacyExtensionViewNetwork::beforeSendHeaders(Ref<Load>&& load, ResourceRequest&& request, RequestCompletion&& completion)
{
    Vector<GeneratedField> fields;
    if (m_listeners.hasOption(onBeforeSendHeaders, extraHeadersOption) || m_listeners.hasOption(onSendHeaders, extraHeadersOption))
        fields = generatedFields(request, generatedCookie(load, request));
    auto details = this->details(load);
    details->setArray("requestHeaders"_s, requestHeadersWithFields(request, fields));
    if (!m_listeners.blocks(onBeforeSendHeaders, details)) {
        if (m_listeners.observes(onBeforeSendHeaders))
            notify(onBeforeSendHeaders, copy(details));
        if (m_listeners.observes(onSendHeaders))
            notify(onSendHeaders, WTF::move(details));
        return completion({ RequestVerdict::Kind::Proceed, WTF::move(request), { }, { } });
    }

    dispatch(onBeforeSendHeaders, WTF::move(details), [this, load = WTF::move(load), request = WTF::move(request), fields = WTF::move(fields), completion = WTF::move(completion)](RefPtr<JSON::Object>&& verdict) mutable {
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false))
            return completion({ RequestVerdict::Kind::Fail, { }, { }, cancellationError(request) });
        if (RefPtr headers = verdict ? verdict->getArray("requestHeaders"_s) : nullptr)
            load->editedCookie = applyRequestHeaders(request, *headers, fields);
        if (m_listeners.observes(onSendHeaders)) {
            auto details = this->details(load);
            details->setArray("requestHeaders"_s, requestHeadersWithFields(request, fields));
            notify(onSendHeaders, WTF::move(details));
        }
        completion({ RequestVerdict::Kind::Proceed, WTF::move(request), { }, { } });
    });
}

// Response steps.

// onHeadersReceived. A rewritten Location header moves a redirect to the new location; a redirectUrl
// rewrites the response to a 302 Found to it.
void LegacyExtensionViewNetwork::headersReceived(Ref<Load>&& load, ResourceResponse&& response, RefPtr<CocoaCurlResourceHandle>&& curl, bool isRedirect, ResponseCompletion&& completion)
{
    auto details = responseDetails(load, response);
    if (curl && curl->heldCookies())
        setSetCookieFields(details, *curl->heldCookies());
    if (!m_listeners.blocks(onHeadersReceived, details)) {
        if (m_listeners.observes(onHeadersReceived))
            notify(onHeadersReceived, WTF::move(details));
        if (curl)
            curl->storeHeldCookies();
        return completion({ false, WTF::move(response), { } });
    }

    dispatch(onHeadersReceived, WTF::move(details), [response = WTF::move(response), curl = WTF::move(curl), isRedirect, completion = WTF::move(completion)](RefPtr<JSON::Object>&& verdict) mutable {
        if (verdict && verdict->getBoolean("cancel"_s).value_or(false)) {
            if (curl)
                curl->discardHeldCookies();
            return completion({ true, WTF::move(response), { } });
        }
        URL target;
        if (RefPtr headers = verdict ? verdict->getArray("responseHeaders"_s) : nullptr) {
            if (curl && curl->heldCookies())
                curl->storeHeldCookies(setCookieFields(*headers));
            auto location = response.httpHeaderField(HTTPHeaderName::Location);
            response = responseWithHeaders(response, *headers);
            if (auto newLocation = response.httpHeaderField(HTTPHeaderName::Location); isRedirect && newLocation != location)
                target = URL { response.url(), newLocation };
        }
        if (curl)
            curl->storeHeldCookies();
        if (URL redirectURL { verdict ? verdict->getString("redirectUrl"_s) : String() }; redirectURL.isValid()) {
            response = redirectedResponse(response, redirectURL);
            target = WTF::move(redirectURL);
        }
        if (target.isValid() && response.httpHeaderField(HTTPHeaderName::Location) != target.string())
            response.setHTTPHeaderField(HTTPHeaderName::Location, target.string());
        completion({ false, WTF::move(response), WTF::move(target) });
    });
}

void LegacyExtensionViewNetwork::responseStarted(Load& load, const ResourceResponse& response)
{
    load.response = response;
    if (m_listeners.observes(onResponseStarted))
        notify(onResponseStarted, responseDetails(load, response));
}

// onCompleted and onErrorOccurred.
void LegacyExtensionViewNetwork::completed(Load& load, const ResourceResponse& response, const ResourceError& error)
{
    bool succeeded = error.isNull();
    auto eventName = succeeded ? onCompleted : onErrorOccurred;
    if (!m_listeners.observes(eventName) || !isInterceptable(load.url))
        return;
    auto details = this->details(load);
    if (succeeded)
        addResponseFields(details, response);
    else {
        details->setBoolean("fromCache"_s, isFromCache(response));
        details->setString("error"_s, networkErrorName(error));
    }
    notify(eventName, WTF::move(details));
}

// A ResourceLoader's load.

bool LegacyExtensionViewNetwork::interceptStart(ResourceLoader& loader)
{
    if (m_resumingStarts.remove(loader))
        return false;
    if (m_listeners.isEmpty() || !isInterceptable(loader.request().url()))
        return false;
    RefPtr load = m_loads.get(loader);
    if (!load) {
        RefPtr frame = loader.frame();
        bool isMainFrameLoad = frame && frame->isMainFrame() && loader.options().mode == FetchOptions::Mode::Navigate;
        load = createLoad(frame.get(), loader.request(), loader.options().destination, isMainFrameLoad, makeString(getCurrentProcessID(), '-', loader.identifier()->toUInt64()));
        if (!load)
            return false;
        m_loads.set(loader, *load);
    }

    willSendRequest(*load, ResourceRequest { loader.request() }, { }, [this, weakLoader = WeakPtr { loader }, load = Ref { *load }](RequestVerdict&& verdict) mutable {
        if (RefPtr loader = weakLoader.get(); loader && !loader->reachedTerminalState())
            continueStart(*loader, WTF::move(load), WTF::move(verdict));
    });
    return true;
}

// A main frame's internal redirect goes through the loader's redirect steps, as a server's redirect does,
// before its request's own webRequest steps.
void LegacyExtensionViewNetwork::continueStart(ResourceLoader& loader, Ref<Load>&& load, RequestVerdict&& verdict)
{
    switch (verdict.kind) {
    case RequestVerdict::Kind::Fail:
        loader.cancel(verdict.error);
        return;
    case RequestVerdict::Kind::MainFrameRedirect:
        continueRedirection(loader, WTF::move(verdict.request), verdict.redirectResponse, [this, weakLoader = WeakPtr { loader }, load = WTF::move(load), redirectResponse = verdict.redirectResponse](ResourceRequest&& approved) mutable {
            RefPtr loader = weakLoader.get();
            if (!loader || approved.isNull() || loader->reachedTerminalState() || approved.url().protocolIsData())
                return;
            willSendRequest(WTF::move(load), WTF::move(approved), redirectResponse, [this, weakLoader = WTF::move(weakLoader)](RequestVerdict&& verdict) mutable {
                RefPtr loader = weakLoader.get();
                if (!loader || loader->reachedTerminalState())
                    return;
                if (verdict.kind == RequestVerdict::Kind::Fail)
                    return loader->cancel(verdict.error);
                loader->setRequest(WTF::move(verdict.request));
                restart(*loader);
            });
        });
        return;
    case RequestVerdict::Kind::Proceed:
        loader.setRequest(WTF::move(verdict.request));
        restart(loader);
        return;
    }
}

// The loader starts its network load with its request, which its webRequest steps approved.
void LegacyExtensionViewNetwork::restart(ResourceLoader& loader)
{
    stopNetworkLoad(loader);
    if (isInterceptable(loader.request().url()))
        m_resumingStarts.add(loader);
    loader.start();
}

// onHeadersReceived for a redirect response; then the loader's redirect steps, and the redirect's request's
// own webRequest steps.
bool LegacyExtensionViewNetwork::interceptRedirection(ResourceLoader& loader, ResourceRequest& request, ResourceResponse& redirectResponse, CompletionHandler<void(ResourceRequest&&)>& completionHandler)
{
    RefPtr load = m_loads.get(loader);
    if (!load)
        return false;
    headersReceived(*load, ResourceResponse { redirectResponse }, curlHandle(loader), true, [this, weakLoader = WeakPtr { loader }, load = Ref { *load }, request = WTF::move(request), completionHandler = WTF::move(completionHandler)](ResponseVerdict&& verdict) mutable {
        RefPtr loader = weakLoader.get();
        if (!loader || loader->reachedTerminalState())
            return completionHandler({ });
        if (verdict.cancel) {
            loader->cancel(cancellationError(request));
            return completionHandler({ });
        }
        if (verdict.target.isValid() && verdict.target != request.url()) {
            if (loadsInPlace(load->isMainFrameLoad, load->type, verdict.target)) {
                completionHandler({ });
                return redirectInPlace(*loader, load, verdict.response, verdict.target);
            }
            retarget(request, verdict.response, verdict.target);
        }
        followRedirect(*loader, WTF::move(load), WTF::move(request), WTF::move(verdict.response), WTF::move(completionHandler));
    });
    return true;
}

// The loader's redirect steps, then the redirected request's webRequest steps. A request an extension sends
// in place to a URL the network does not load, such as a data: URL or an extension's page, starts the
// loader's load again.
void LegacyExtensionViewNetwork::followRedirect(ResourceLoader& loader, Ref<Load>&& load, ResourceRequest&& request, ResourceResponse&& redirectResponse, CompletionHandler<void(ResourceRequest&&)>&& completionHandler)
{
    continueRedirection(loader, WTF::move(request), redirectResponse, [this, weakLoader = WeakPtr { loader }, load = WTF::move(load), redirectResponse, completionHandler = WTF::move(completionHandler)](ResourceRequest&& approved) mutable {
        RefPtr loader = weakLoader.get();
        if (!loader || approved.isNull() || !isInterceptable(approved.url()))
            return completionHandler(WTF::move(approved));
        auto approvedURL = approved.url();
        willSendRequest(WTF::move(load), WTF::move(approved), redirectResponse, [weakLoader = WTF::move(weakLoader), approvedURL = WTF::move(approvedURL), completionHandler = WTF::move(completionHandler)](RequestVerdict&& verdict) mutable {
            RefPtr loader = weakLoader.get();
            if (!loader || loader->reachedTerminalState())
                return completionHandler({ });
            if (verdict.kind == RequestVerdict::Kind::Fail) {
                loader->cancel(verdict.error);
                return completionHandler({ });
            }
            loader->setRequest(ResourceRequest { verdict.request });
            if (verdict.request.url() != approvedURL && !verdict.request.url().protocolIsInHTTPFamily()) {
                completionHandler({ });
                return LegacyExtensionViewNetwork::singleton().restart(*loader);
            }
            completionHandler(WTF::move(verdict.request));
        });
    });
}

// A subresource's redirect to a data: URL, loaded in place, as an onBeforeRequest redirect of a subresource
// is: its onBeforeRedirect, then the data: URL's load in place of the load's own.
void LegacyExtensionViewNetwork::redirectInPlace(ResourceLoader& loader, Load& load, const ResourceResponse& redirectResponse, const URL& url)
{
    if (m_listeners.observes(onBeforeRedirect)) {
        auto details = this->details(load);
        details->setString("url"_s, redirectResponse.url().string());
        details->setString("redirectUrl"_s, url.string());
        addResponseFields(details, redirectResponse);
        notify(onBeforeRedirect, WTF::move(details));
    }
    load.url = url;
    auto request = loader.request();
    request.setURL(URL { url });
    loader.setRequest(WTF::move(request));
    restart(loader);
}

// onHeadersReceived and onResponseStarted for a response. A response the verdict redirects ends its network
// load and goes through the loader's redirect steps, as a 302 Found to the new location.
bool LegacyExtensionViewNetwork::interceptResponse(ResourceLoader& loader, ResourceResponse& response, CompletionHandler<void()>& completionHandler)
{
    RefPtr load = m_loads.get(loader);
    if (!load || !isInterceptable(response.url()))
        return false;
    headersReceived(*load, WTF::move(response), curlHandle(loader), false, [this, weakLoader = WeakPtr { loader }, load = Ref { *load }, completionHandler = WTF::move(completionHandler)](ResponseVerdict&& verdict) mutable {
        RefPtr loader = weakLoader.get();
        if (!loader || loader->reachedTerminalState())
            return completionHandler();
        if (verdict.cancel) {
            loader->cancel(cancellationError(loader->request()));
            return completionHandler();
        }
        if (!verdict.target.isValid()) {
            responseStarted(load, verdict.response);
            return loader->didReceiveResponse(WTF::move(verdict.response), WTF::move(completionHandler));
        }

        stopNetworkLoad(*loader);
        completionHandler();
        if (loadsInPlace(load->isMainFrameLoad, load->type, verdict.target))
            return redirectInPlace(*loader, load, verdict.response, verdict.target);
        auto request = loader->request();
        if (!loader->originalRequest().isConditional())
            request.makeUnconditional();
        RefPtr frame = loader->frame();
        bool shouldClearReferrer = !frame || !frame->loader().networkingContext() || frame->loader().networkingContext()->shouldClearReferrerOnHTTPSToHTTPRedirect();
        auto redirectRequest = request.redirectedRequest(verdict.response, shouldClearReferrer);
        if (load->isMainFrameLoad)
            redirectRequest.setFirstPartyForCookies(URL { redirectRequest.url() });
        followRedirect(*loader, WTF::move(load), WTF::move(redirectRequest), WTF::move(verdict.response), [weakLoader = WTF::move(weakLoader)](ResourceRequest&& request) {
            // A document's redirect to a data: URL is loaded by the loader's redirect steps.
            RefPtr loader = weakLoader.get();
            if (!loader || request.isNull() || loader->reachedTerminalState() || request.url().protocolIsData())
                return;
            loader->setRequest(WTF::move(request));
            LegacyExtensionViewNetwork::singleton().restart(*loader);
        });
    });
    return true;
}

// onAuthRequired, for a load's HTTP or proxy authentication challenge. A verdict's authCredentials answer it;
// a cancel continues without credentials, so the 401 or 407 response is the load's; a load no verdict
// answers leaves the challenge to the browser.
bool LegacyExtensionViewNetwork::interceptAuthenticationChallenge(ResourceLoader& loader, const AuthenticationChallenge& challenge)
{
    if (m_resumingChallenges.remove(loader))
        return false;
    RefPtr load = m_loads.get(loader);
    if (!load || !m_listeners.observes(onAuthRequired))
        return false;
    auto scheme = authenticationSchemeName(challenge);
    if (scheme.isNull())
        return false;

    auto& protectionSpace = challenge.protectionSpace();
    auto details = responseDetails(*load, challenge.failureResponse());
    details->setString("url"_s, load->url.string());
    details->setString("scheme"_s, scheme);
    if (!protectionSpace.realm().isEmpty())
        details->setString("realm"_s, protectionSpace.realm());
    auto challenger = JSON::Object::create();
    challenger->setString("host"_s, protectionSpace.host());
    challenger->setDouble("port"_s, protectionSpace.port());
    details->setObject("challenger"_s, WTF::move(challenger));
    details->setBoolean("isProxy"_s, protectionSpace.isProxy());
    if (!m_listeners.blocks(onAuthRequired, details)) {
        notify(onAuthRequired, WTF::move(details));
        return false;
    }

    dispatch(onAuthRequired, WTF::move(details), [this, weakLoader = WeakPtr { loader }, challenge](RefPtr<JSON::Object>&& verdict) mutable {
        RefPtr loader = weakLoader.get();
        if (!loader || loader->reachedTerminalState())
            return;
        RefPtr client = challenge.authenticationClient();
        if (client && verdict && verdict->getBoolean("cancel"_s).value_or(false))
            return client->receivedRequestToContinueWithoutCredential(challenge);
        if (RefPtr credentials = verdict ? verdict->getObject("authCredentials"_s) : nullptr; client && credentials)
            return client->receivedCredential(challenge, Credential { credentials->getString("username"_s), credentials->getString("password"_s), CredentialPersistence::ForSession });
        m_resumingChallenges.add(*loader);
        continueAuthenticationChallenge(*loader, challenge);
    });
    return true;
}

void LegacyExtensionViewNetwork::loaderDidFinish(ResourceLoader& loader)
{
    if (auto load = m_loads.take(loader))
        completed(*load, load->response, { });
}

void LegacyExtensionViewNetwork::loaderDidFail(ResourceLoader& loader, const ResourceError& error)
{
    if (auto load = m_loads.take(loader))
        completed(*load, load->response, error);
}

// A ping, beacon or report.
class LegacyExtensionViewPing final : public LegacyLoadInterceptor::Load, public CanMakeWeakPtr<LegacyExtensionViewPing> {
public:
    static Ref<LegacyExtensionViewPing> create(Ref<LegacyExtensionViewNetwork::Load>&& load) { return adoptRef(*new LegacyExtensionViewPing(WTF::move(load))); }

    const ResourceHandle* handle() const { return m_handle.get(); }

private:
    using Network = LegacyExtensionViewNetwork;

    explicit LegacyExtensionViewPing(Ref<Network::Load>&& load)
        : m_load(WTF::move(load))
    {
    }

    RefPtr<CocoaCurlResourceHandle> curl() const
    {
        RefPtr handle = m_handle;
        return handle ? handle->cocoaCurlHandle() : nullptr;
    }

    void willSendRequest(ResourceRequest&& request, ResourceResponse&& redirectResponse, CompletionHandler<void(ResourceRequest&&, ResourceError&&)>&& completionHandler) final
    {
        auto& network = Network::singleton();
        auto proceed = [protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](Network::RequestVerdict&& verdict) mutable {
            if (verdict.kind == Network::RequestVerdict::Kind::Fail)
                return completionHandler({ }, WTF::move(verdict.error));
            protectedThis->m_request = verdict.request;
            completionHandler(WTF::move(verdict.request), { });
        };
        if (redirectResponse.isNull())
            return network.willSendRequest(m_load.copyRef(), WTF::move(request), { }, WTF::move(proceed));
        network.headersReceived(m_load.copyRef(), WTF::move(redirectResponse), curl(), true, [request = WTF::move(request), protectedThis = Ref { *this }, proceed = WTF::move(proceed)](Network::ResponseVerdict&& verdict) mutable {
            if (verdict.cancel)
                return proceed({ Network::RequestVerdict::Kind::Fail, { }, { }, cancellationError(request) });
            if (verdict.target.isValid() && verdict.target != request.url())
                retarget(request, verdict.response, verdict.target);
            Network::singleton().willSendRequest(protectedThis->m_load.copyRef(), WTF::move(request), verdict.response, WTF::move(proceed));
        });
    }

    void didCreateHandle(ResourceHandle& handle) final
    {
        m_handle = &handle;
        Network::singleton().m_pings.add(*this);
    }

    void didReceiveRedirectResponse(ResourceResponse&& response, CompletionHandler<void(ResourceError&&)>&& completionHandler) final
    {
        if (!isInterceptable(response.url()))
            return completionHandler({ });
        Network::singleton().headersReceived(m_load.copyRef(), WTF::move(response), curl(), true, [protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](Network::ResponseVerdict&& verdict) mutable {
            if (verdict.cancel)
                return completionHandler(cancellationError(protectedThis->m_request));
            Network::singleton().responseStarted(protectedThis->m_load, verdict.response);
            completionHandler({ });
        });
    }

    // A response the verdict redirects ends the ping's network load, which starts again with the redirect's
    // request; as a redirect, it counts against the load's redirect limit.
    void didReceiveResponse(ResourceResponse&& response, CompletionHandler<void(ResourceResponse&&, ResourceRequest&&, ResourceError&&)>&& completionHandler) final
    {
        if (!isInterceptable(response.url()))
            return completionHandler(WTF::move(response), { }, { });
        Network::singleton().headersReceived(m_load.copyRef(), WTF::move(response), curl(), false, [protectedThis = Ref { *this }, completionHandler = WTF::move(completionHandler)](Network::ResponseVerdict&& verdict) mutable {
            if (verdict.cancel)
                return completionHandler(WTF::move(verdict.response), { }, cancellationError(protectedThis->m_request));
            if (!verdict.target.isValid()) {
                Network::singleton().responseStarted(protectedThis->m_load, verdict.response);
                return completionHandler(WTF::move(verdict.response), { }, { });
            }
            if (++protectedThis->m_redirectCount > ResourceLoaderOptions { }.maxRedirectCount)
                return completionHandler(WTF::move(verdict.response), { }, ResourceError { errorDomainWebKitInternal, 0, verdict.target, "Load cannot follow more than 20 redirections"_s });
            protectedThis->m_handle = nullptr;
            auto redirectRequest = protectedThis->m_request.redirectedRequest(verdict.response, false);
            Network::singleton().willSendRequest(protectedThis->m_load.copyRef(), WTF::move(redirectRequest), verdict.response, [response = verdict.response, protectedThis, completionHandler = WTF::move(completionHandler)](Network::RequestVerdict&& verdict) mutable {
                if (verdict.kind == Network::RequestVerdict::Kind::Fail)
                    return completionHandler(WTF::move(response), { }, WTF::move(verdict.error));
                protectedThis->m_request = verdict.request;
                completionHandler(WTF::move(response), WTF::move(verdict.request), { });
            });
        });
    }

    void didComplete(const ResourceError& error, const ResourceResponse& response) final
    {
        m_handle = nullptr;
        Network::singleton().completed(m_load, response.isNull() ? m_load->response : response, error);
    }

    Ref<Network::Load> m_load;
    ResourceRequest m_request;
    RefPtr<ResourceHandle> m_handle;
    unsigned m_redirectCount { 0 };
};

bool LegacyExtensionViewNetwork::holdsReceivedCookies(const ResourceHandle& handle)
{
    if (!m_listeners.hasOption(onHeadersReceived, extraHeadersOption))
        return false;
    for (auto& ping : m_pings) {
        if (ping.handle() == &handle)
            return true;
    }
    for (auto entry : m_loads) {
        if (entry.key.handle() == &handle)
            return true;
    }
    return false;
}

RefPtr<LegacyLoadInterceptor::Load> LegacyExtensionViewNetwork::pingLoad(LocalFrame& frame, const ResourceRequest& request, const FetchOptions& options)
{
    if (!isInterceptable(request.url()))
        return nullptr;
    RefPtr load = createLoad(&frame, request, options.destination, false, makeString(getCurrentProcessID(), "-ping-"_s, m_nextIdentifier++));
    if (!load)
        return nullptr;
    return LegacyExtensionViewPing::create(load.releaseNonNull());
}

// A synchronous load reports its events, and no listener's verdict holds it.
class LegacyExtensionViewSynchronousLoad final : public LegacyLoadInterceptor::SynchronousLoad {
public:
    static Ref<LegacyExtensionViewSynchronousLoad> create(Ref<LegacyExtensionViewNetwork::Load>&& load) { return adoptRef(*new LegacyExtensionViewSynchronousLoad(WTF::move(load))); }

private:
    explicit LegacyExtensionViewSynchronousLoad(Ref<LegacyExtensionViewNetwork::Load>&& load)
        : m_load(WTF::move(load))
    {
    }

    void didComplete(const ResourceResponse& response, const ResourceError& error) final
    {
        auto& network = LegacyExtensionViewNetwork::singleton();
        if (!response.isNull() && isInterceptable(response.url())) {
            if (network.m_listeners.observes(onHeadersReceived))
                network.notify(onHeadersReceived, network.responseDetails(m_load, response));
            network.responseStarted(m_load, response);
        }
        network.completed(m_load, response, error);
    }

    Ref<LegacyExtensionViewNetwork::Load> m_load;
};

RefPtr<LegacyLoadInterceptor::SynchronousLoad> LegacyExtensionViewNetwork::willLoadSynchronously(FrameLoader& frameLoader, const ResourceRequest& request, const FetchOptions& options)
{
    RefPtr load = isInterceptable(request.url()) ? createLoad(&frameLoader.frame(), request, options.destination, false, makeString(getCurrentProcessID(), "-sync-"_s, m_nextIdentifier++)) : nullptr;
    if (!load)
        return nullptr;
    auto details = this->details(*load);
    if (m_listeners.hasOption(onBeforeRequest, requestBodyOption)) {
        if (auto body = requestBody(request))
            details->setObject("requestBody"_s, body.releaseNonNull());
    }
    if (m_listeners.observes(onBeforeRequest))
        notify(onBeforeRequest, WTF::move(details));
    Vector<GeneratedField> fields;
    if (m_listeners.hasOption(onBeforeSendHeaders, extraHeadersOption) || m_listeners.hasOption(onSendHeaders, extraHeadersOption))
        fields = generatedFields(request, generatedCookie(*load, request));
    for (auto eventName : { onBeforeSendHeaders, onSendHeaders }) {
        if (!m_listeners.observes(eventName))
            continue;
        auto details = this->details(*load);
        details->setArray("requestHeaders"_s, requestHeadersWithFields(request, fields));
        notify(eventName, WTF::move(details));
    }
    return LegacyExtensionViewSynchronousLoad::create(load.releaseNonNull());
}

// onBeforeRequest for a WebSocket handshake.
bool LegacyExtensionViewNetwork::interceptWebSocket(Document& document, const URL& url, CompletionHandler<void(bool)>&& completionHandler)
{
    if (!m_listeners.observes(onBeforeRequest))
        return false;
    ResourceRequest request { URL { url } };
    request.setHTTPMethod("GET"_s);
    RefPtr load = createLoad(document.frame(), request, FetchOptions::Destination::EmptyString, false, makeString(getCurrentProcessID(), "-ws-"_s, m_nextIdentifier++));
    if (!load)
        return false;
    load->type = "websocket"_s;
    load->documentURL = { };
    auto details = this->details(*load);
    if (!m_listeners.blocks(onBeforeRequest, details)) {
        notify(onBeforeRequest, WTF::move(details));
        return false;
    }
    dispatch(onBeforeRequest, WTF::move(details), [completionHandler = WTF::move(completionHandler)](RefPtr<JSON::Object>&& verdict) mutable {
        completionHandler(!verdict || !verdict->getBoolean("cancel"_s).value_or(false));
    });
    return true;
}

} // namespace WebKit
