/*
 * Copyright (C) 2013-2016 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT: the WebKit1 getUserMedia client upstream removed in a5c8561; see WebUserMediaClient.h.
#import "WebUserMediaClient.h"

#if ENABLE(MEDIA_STREAM)

#import "WebDelegateImplementationCaching.h"
#import "WebSecurityOriginInternal.h"
#import "WebUIDelegatePrivate.h"
#import "WebViewInternal.h"
#import <WebCore/CaptureDevice.h>
#import <WebCore/CaptureDeviceWithCapabilities.h>
#import <WebCore/Document.h>
#import <WebCore/DocumentInlines.h>
#import <WebCore/DocumentPage.h>
#import <WebCore/Exception.h>
#import <WebCore/ExceptionCode.h>
#import <WebCore/LocalizedStrings.h>
#import <WebCore/MediaConstraints.h>
#import <WebCore/MediaProducer.h>
#import <WebCore/MediaStreamRequest.h>
#import <WebCore/Page.h>
#import <WebCore/RealtimeMediaSourceCapabilities.h>
#import <WebCore/SecurityOrigin.h>
#import <WebCore/UserMediaController.h>
#import <WebCore/UserMediaRequest.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/BlockPtr.h>
#import <wtf/CryptographicallyRandomNumber.h>
#import <wtf/HexNumber.h>
#import <wtf/RetainPtr.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/URLHelpers.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/spi/cf/CFBundleSPI.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringBuilder.h>

using namespace WebCore;

// The answer to one request. It carries the request's identifier rather than the request, so an answer
// that arrives after the request was cancelled or superseded is not matched, and it holds the client
// weakly, so a delegate that keeps the listener alive cannot outlive the WebView's page.
@interface WebUserMediaPolicyListener : NSObject <WebAllowDenyPolicyListener> {
    WeakPtr<WebCore::MediaCanStartListener> _clientIsAlive;
    WebUserMediaClient* _client;
    std::optional<UserMediaRequestIdentifier> _requestIdentifier;
}
- (id)initWithClient:(WebUserMediaClient&)client requestIdentifier:(UserMediaRequestIdentifier)identifier;
@end

@implementation WebUserMediaPolicyListener

- (id)initWithClient:(WebUserMediaClient&)client requestIdentifier:(UserMediaRequestIdentifier)identifier
{
    if (!(self = [super init]))
        return nil;

    _clientIsAlive = client;
    _client = &client;
    _requestIdentifier = identifier;
    return self;
}

- (void)allow
{
    auto identifier = std::exchange(_requestIdentifier, std::nullopt);
    if (_clientIsAlive && identifier)
        _client->requestWasAllowed(*identifier);
}

- (void)deny
{
    auto identifier = std::exchange(_requestIdentifier, std::nullopt);
    if (_clientIsAlive && identifier)
        _client->requestWasDenied(*identifier);
}

@end

WTF_MAKE_TZONE_ALLOCATED_IMPL(WebUserMediaClient);

// The capture a page has running right now, as UserMediaPermissionRequestManagerProxy reads it.
static const MediaProducerMediaStateFlags activeCaptureMask { MediaProducerMediaState::HasActiveAudioCaptureDevice, MediaProducerMediaState::HasActiveVideoCaptureDevice };

// The reprompt intervals UserMediaPermissionRequestManagerProxy runs on. They are WebKit2 preferences
// (webcoreBinding: none, exposed: [WebKit]), so WebKit1 carries the values themselves: the desktop
// defaults from WebPreferencesDefaultValues.cpp and UnifiedWebPreferences.yaml.
static constexpr double inactiveMediaCaptureStreamRepromptIntervalInMinutes { 10 };
static constexpr double inactiveMediaCaptureStreamRepromptWithoutUserGestureIntervalInMinutes { 10 };
static constexpr double longRunningMediaCaptureStreamRepromptIntervalInHours { 24 };

static constexpr unsigned hashSaltSize { 48 };
static constexpr unsigned randomDataSize { hashSaltSize / 16 };

static String generateHashSalt()
{
    std::array<uint64_t, randomDataSize> randomData;
    cryptographicallyRandomValues(asWritableBytes(std::span<uint64_t> { randomData }));

    StringBuilder builder;
    builder.reserveCapacity(hashSaltSize);
    for (unsigned i = 0; i < randomDataSize; i++)
        builder.append(hex(randomData[i]));

    return builder.toString();
}

static String originKey(const SecurityOrigin* documentOrigin, const SecurityOrigin* topLevelOrigin)
{
    return makeString(documentOrigin ? documentOrigin->toString() : emptyString(), '#', topLevelOrigin ? topLevelOrigin->toString() : emptyString());
}

static bool requiresDisplayCapture(const UserMediaRequest& request)
{
    return request.request().type != MediaStreamRequest::Type::UserMedia;
}

// The name the consent sheet puts in front of the user, as WebKit2's applicationVisibleNameFromOrigin()
// and applicationVisibleName() spell it: the requesting site, or the host application for an origin
// that is not a web site.
static RetainPtr<NSString> visibleNameForOrigin(const SecurityOrigin* origin)
{
    if (origin && (origin->protocol() == "http"_s || origin->protocol() == "https"_s)) {
        auto domain = WTF::URLHelpers::userVisibleURL(origin->host().utf8());
        return startsWithLettersIgnoringASCIICase(domain, "www."_s) ? StringView(domain).substring(4).createNSString() : domain.createNSString();
    }

    RetainPtr appBundle = [NSBundle mainBundle];
    if (RetainPtr<NSString> displayName = [[appBundle infoDictionary] objectForKey:bridge_cast(_kCFBundleDisplayNameKey)])
        return displayName;
    return [[appBundle infoDictionary] objectForKey:bridge_cast(kCFBundleNameKey)];
}

static RetainPtr<NSString> alertMessageText(bool isDisplayCapture, bool requiresAudio, bool requiresVideo, const SecurityOrigin* topLevelOrigin)
{
    RetainPtr visibleOrigin = visibleNameForOrigin(topLevelOrigin);
    if (!visibleOrigin)
        return nil;

    // The same strings WebKit2's alertForPermission() puts up, resolved from the same WebCore table.
    if (isDisplayCapture)
        return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to observe your screen?", @"Message for screen sharing prompt"), visibleOrigin.get()]);
    if (requiresAudio && requiresVideo)
        return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to use your camera and microphone?", @"Message for user media prompt"), visibleOrigin.get()]);
    if (requiresAudio)
        return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to use your microphone?", @"Message for user microphone access prompt"), visibleOrigin.get()]);
    return adoptNS([[NSString alloc] initWithFormat:WEB_UI_NSSTRING(@"Allow “%@” to use your camera?", @"Message for user camera access prompt"), visibleOrigin.get()]);
}

static RetainPtr<NSString> allowButtonText(bool isDisplayCapture)
{
    if (isDisplayCapture)
        return WEB_UI_STRING_KEY(@"Allow", "Allow (screensharing)", @"Allow button title in screen sharing prompt").createNSString();
    return WEB_UI_STRING_KEY(@"Allow", "Allow (usermedia)", @"Allow button title in user media prompt").createNSString();
}

static RetainPtr<NSString> doNotAllowButtonText(bool isDisplayCapture)
{
    if (isDisplayCapture)
        return WEB_UI_STRING_KEY(@"Don’t Allow", "Don’t Allow (screensharing)", @"Disallow button title in screen sharing prompt").createNSString();
    return WEB_UI_STRING_KEY(@"Don’t Allow", "Don’t Allow (usermedia)", @"Disallow button title in user media prompt").createNSString();
}

// The muted flags a capture kind covers, as Page::updateCaptureState() reads them.
static MediaProducerMutedStateFlags mutedStateFlagsForCaptureKind(MediaProducerMediaCaptureKind kind)
{
    switch (kind) {
    case MediaProducerMediaCaptureKind::Microphone:
        return MediaProducerMutedState::AudioCaptureIsMuted;
    case MediaProducerMediaCaptureKind::Camera:
        return MediaProducerMutedState::VideoCaptureIsMuted;
    case MediaProducerMediaCaptureKind::Display:
        return { MediaProducerMutedState::ScreenCaptureIsMuted, MediaProducerMutedState::WindowCaptureIsMuted };
    case MediaProducerMediaCaptureKind::SystemAudio:
    case MediaProducerMediaCaptureKind::EveryKind:
        break;
    }
    return { };
}

static void presentConsentSheet(WebView *webView, bool isDisplayCapture, RetainPtr<NSString> messageText, CompletionHandler<void(bool)>&& completionHandler)
{
    RetainPtr<NSWindow> window = [webView window];
    if (!window)
        window = [webView hostWindow];
    if (!window || !messageText) {
        completionHandler(false);
        return;
    }

    auto alert = adoptNS([[NSAlert alloc] init]);
    [alert setMessageText:messageText.get()];
    RetainPtr button = [alert addButtonWithTitle:allowButtonText(isDisplayCapture).get()];
    [button setKeyEquivalent:@""];
    button = [alert addButtonWithTitle:doNotAllowButtonText(isDisplayCapture).get()];
    [button setKeyEquivalent:@"\E"];

    auto completionBlock = makeBlockPtr(WTF::move(completionHandler));
    [alert beginSheetModalForWindow:window.get() completionHandler:[completionBlock](NSModalResponse returnCode) {
        completionBlock(returnCode == NSAlertFirstButtonReturn);
    }];
}

WebUserMediaClient::WebUserMediaClient(WebView *webView)
    : m_webView(webView)
    , m_watchdogTimer(RunLoop::mainSingleton(), "WebUserMediaClient::watchdogTimer"_s, [this] { watchdogTimerFired(); })
{
}

WebUserMediaClient* WebUserMediaClient::from(Page* page)
{
    auto* controller = UserMediaController::from(page);
    if (!controller)
        return nullptr;
    return static_cast<WebUserMediaClient*>(controller->client());
}

WebUserMediaClient::~WebUserMediaClient()
{
    for (auto& document : copyToVector(m_requestsWaitingForMediaToStart.keys()))
        document->removeMediaCanStartListener(*this);

    if (m_monitoringDeviceChange)
        RealtimeMediaSourceCenter::singleton().removeDevicesChangedObserver(*this);
    if (m_listeningToVoiceActivity)
        RealtimeMediaSourceCenter::singleton().audioCaptureFactory().disableMutedSpeechActivityEventListener();
}

void WebUserMediaClient::requestUserMediaAccess(UserMediaRequest& request)
{
    RefPtr document = request.document();
    RefPtr page = document ? document->page() : nullptr;
    if (!document || !page) {
        request.deny(MediaAccessDenialReason::OtherFailure);
        return;
    }

    if (page->canStartMedia()) {
        enqueueRequest(request);
        return;
    }

    auto& requests = m_requestsWaitingForMediaToStart.add(*document, Vector<Ref<UserMediaRequest>>()).iterator->value;
    if (requests.isEmpty())
        document->addMediaCanStartListener(*this);
    requests.append(request);
}

void WebUserMediaClient::mediaCanStart(Document& document)
{
    // Page::takeAnyMediaCanStartListener() has already unregistered this listener from the document.
    auto requests = m_requestsWaitingForMediaToStart.take(document);
    for (auto& request : requests)
        enqueueRequest(WTF::move(request));
}

void WebUserMediaClient::enqueueRequest(Ref<UserMediaRequest>&& request)
{
    // One request is put to the user at a time, and a second getDisplayMedia supersedes a first one
    // that is still on screen, as UserMediaPermissionRequestManagerProxy does.
    if (m_currentRequest) {
        if (requiresDisplayCapture(*m_currentRequest) && requiresDisplayCapture(request)) {
            RefPtr currentRequest = std::exchange(m_currentRequest, nullptr);
            currentRequest->deny(MediaAccessDenialReason::OtherFailure);
        } else {
            m_pendingRequests.append(WTF::move(request));
            return;
        }
    }

    startProcessingRequest(WTF::move(request));
}

void WebUserMediaClient::startProcessingRequest(Ref<UserMediaRequest>&& request)
{
    RefPtr document = request->document();
    if (!document) {
        request->deny(MediaAccessDenialReason::OtherFailure);
        processNextRequestIfNeeded();
        return;
    }

    m_currentRequest = request.copyRef();
    m_currentRequestDevices = { };
    m_currentRequestHashSalts = hashSaltsForDocument(*document);

    auto identifier = request->identifier();
    RealtimeMediaSourceCenter::singleton().validateRequestConstraints([protectedThis = Ref { *this }, identifier](auto&& result) mutable {
        protectedThis->constraintsValidated(identifier, WTF::move(result));
    }, request->request(), MediaDeviceHashSalts { m_currentRequestHashSalts });
}

void WebUserMediaClient::constraintsValidated(UserMediaRequestIdentifier identifier, Expected<RealtimeMediaSourceCenter::ValidDevices, MediaConstraintType>&& result)
{
    RefPtr request = m_currentRequest;
    if (!request || request->identifier() != identifier)
        return;

    if (!result) {
        // The constraint that could not be satisfied names a device the page has not been allowed to
        // see, so it is only reported back once access has been granted.
        auto invalidConstraint = hasGrantedRequest(*request) ? result.error() : MediaConstraintType::Unknown;
        m_currentRequest = nullptr;
        request->deny(MediaAccessDenialReason::InvalidConstraint, emptyString(), invalidConstraint);
        processNextRequestIfNeeded();
        return;
    }

    auto devices = WTF::move(result).value();
    if (!requiresDisplayCapture(*request) && devices.audioDevices.isEmpty() && devices.videoDevices.isEmpty()) {
        m_currentRequest = nullptr;
        request->deny(MediaAccessDenialReason::NoConstraints);
        processNextRequestIfNeeded();
        return;
    }

    m_currentRequestDevices = WTF::move(devices);
    decidePermission();
}

void WebUserMediaClient::decidePermission()
{
    RefPtr request = m_currentRequest;
    if (!request)
        return;

    bool isDisplayCapture = requiresDisplayCapture(*request);

    // Screen capture is asked for every time; camera and microphone are asked for once per document,
    // for as long as that document goes on capturing.
    if (!isDisplayCapture && hasGrantedRequest(*request)) {
        requestWasAllowed(request->identifier());
        return;
    }

    BEGIN_BLOCK_OBJC_EXCEPTIONS

    SEL selector = @selector(webView:decidePolicyForUserMediaRequestFromOrigin:listener:);
    auto listener = adoptNS([[WebUserMediaPolicyListener alloc] initWithClient:*this requestIdentifier:request->identifier()]);

    if ([[m_webView UIDelegate] respondsToSelector:selector]) {
        auto webOrigin = adoptNS([[WebSecurityOrigin alloc] _initWithWebCoreSecurityOrigin:request->userMediaDocumentOrigin()]);
        CallUIDelegate(m_webView, selector, webOrigin.get(), listener.get());
    } else {
        auto messageText = alertMessageText(isDisplayCapture, request->request().audioConstraints.isValid, request->request().videoConstraints.isValid, request->topLevelDocumentOrigin());
        presentConsentSheet(m_webView, isDisplayCapture, WTF::move(messageText), [listener](bool granted) {
            if (granted)
                [listener allow];
            else
                [listener deny];
        });
    }

    END_BLOCK_OBJC_EXCEPTIONS
}

void WebUserMediaClient::requestWasAllowed(UserMediaRequestIdentifier identifier)
{
    RefPtr request = m_currentRequest;
    if (!request || request->identifier() != identifier)
        return;

    rememberGrantedRequest(*request);

    auto hashSalts = m_currentRequestHashSalts;

    // Devices may have changed while the prompt was up.
    if (!requiresDisplayCapture(*request)) {
        auto validDevices = RealtimeMediaSourceCenter::singleton().validateRequestConstraintsAfterEnumeration(request->request(), hashSalts);
        if (!!validDevices)
            m_currentRequestDevices = WTF::move(validDevices.value());
    }

    CaptureDevice audioDevice = m_currentRequestDevices.audioDevices.isEmpty() ? CaptureDevice { } : m_currentRequestDevices.audioDevices.first();
    CaptureDevice videoDevice = m_currentRequestDevices.videoDevices.isEmpty() ? CaptureDevice { } : m_currentRequestDevices.videoDevices.first();

    m_currentRequest = nullptr;
    request->allow(WTF::move(audioDevice), WTF::move(videoDevice), WTF::move(hashSalts), [] { });
    processNextRequestIfNeeded();
}

void WebUserMediaClient::requestWasDenied(UserMediaRequestIdentifier identifier)
{
    RefPtr request = m_currentRequest;
    if (!request || request->identifier() != identifier)
        return;

    m_currentRequest = nullptr;
    request->deny(MediaAccessDenialReason::PermissionDenied);
    processNextRequestIfNeeded();
}

void WebUserMediaClient::processNextRequestIfNeeded()
{
    if (m_currentRequest || m_pendingRequests.isEmpty())
        return;

    startProcessingRequest(m_pendingRequests.takeFirst());
}

void WebUserMediaClient::cancelUserMediaAccessRequest(UserMediaRequest& request)
{
    if (m_currentRequest && m_currentRequest->identifier() == request.identifier()) {
        m_currentRequest = nullptr;
        processNextRequestIfNeeded();
        return;
    }

    Deque<Ref<UserMediaRequest>> remainingRequests;
    while (!m_pendingRequests.isEmpty()) {
        auto pendingRequest = m_pendingRequests.takeFirst();
        if (pendingRequest->identifier() != request.identifier())
            remainingRequests.append(WTF::move(pendingRequest));
    }
    m_pendingRequests = WTF::move(remainingRequests);

    RefPtr document = request.document();
    if (!document)
        return;

    auto iterator = m_requestsWaitingForMediaToStart.find(*document);
    if (iterator == m_requestsWaitingForMediaToStart.end())
        return;

    iterator->value.removeAllMatching([&request](auto& waitingRequest) {
        return waitingRequest->identifier() == request.identifier();
    });
    if (iterator->value.isEmpty()) {
        m_requestsWaitingForMediaToStart.remove(iterator);
        document->removeMediaCanStartListener(*this);
    }
}

MediaDeviceHashSalts WebUserMediaClient::hashSaltsForDocument(Document& document)
{
    // The persistent salt lasts as long as this process: WebKit1 has no website data store to keep it
    // in, so an origin's device identifiers are stable for the run of the application. The ephemeral
    // salt belongs to one document, so a navigation or a reload rotates the identifiers built on it.
    auto persistentSalt = m_persistentHashSaltForOrigin.ensure(originKey(&document.securityOrigin(), &document.topOrigin()), [] {
        return generateHashSalt();
    }).iterator->value;

    auto ephemeralSalt = m_ephemeralHashSaltForDocument.ensure(document, [] {
        return generateHashSalt();
    }).iterator->value;

    return { persistentSalt, ephemeralSalt };
}

void WebUserMediaClient::captureStateChanged(MediaProducerMediaStateFlags newState)
{
    if (m_captureState == (newState & activeCaptureMask))
        return;

    m_captureState = newState & activeCaptureMask;

    Seconds interval;
    if (m_captureState & activeCaptureMask) {
        interval = Seconds::fromHours(longRunningMediaCaptureStreamRepromptIntervalInHours);
        m_lastCaptureTime = { };
    } else {
        interval = Seconds::fromMinutes(inactiveMediaCaptureStreamRepromptIntervalInMinutes);
        m_lastCaptureTime = MonotonicTime::now();
    }

    if (interval == m_currentWatchdogInterval)
        return;

    m_currentWatchdogInterval = interval;
    m_watchdogTimer.startOneShot(m_currentWatchdogInterval);
}

void WebUserMediaClient::watchdogTimerFired()
{
    m_grantedRequests.clear();
    m_currentWatchdogInterval = 0_s;
}

Seconds WebUserMediaClient::inactiveMediaCaptureStreamDuration() const
{
    return m_lastCaptureTime ? MonotonicTime::now() - *m_lastCaptureTime : 0_s;
}

bool WebUserMediaClient::hasGrantedRequest(UserMediaRequest& request) const
{
    RefPtr document = request.document();
    RefPtr page = document ? document->page() : nullptr;
    if (!page || m_grantedRequests.isEmpty())
        return false;

    if (page->mutedState().containsAny(MediaProducer::MediaStreamCaptureIsMuted))
        return false;

    if (!request.request().isUserGesturePriviledged && inactiveMediaCaptureStreamDuration().minutes() > inactiveMediaCaptureStreamRepromptWithoutUserGestureIntervalInMinutes)
        return false;

    RefPtr userMediaDocumentOrigin = request.userMediaDocumentOrigin();
    RefPtr topLevelDocumentOrigin = request.topLevelDocumentOrigin();
    if (!userMediaDocumentOrigin || !topLevelDocumentOrigin)
        return false;

    bool checkForAudio = request.request().audioConstraints.isValid;
    bool checkForVideo = request.request().videoConstraints.isValid;
    for (auto& grantedRequest : m_grantedRequests) {
        if (grantedRequest.document.get() != document.get())
            continue;
        if (!grantedRequest.userMediaDocumentOrigin->isSameSchemeHostPort(*userMediaDocumentOrigin))
            continue;
        if (!grantedRequest.topLevelDocumentOrigin->isSameSchemeHostPort(*topLevelDocumentOrigin))
            continue;

        if (grantedRequest.requiresVideo)
            checkForVideo = false;
        if (grantedRequest.requiresAudio)
            checkForAudio = false;

        if (checkForVideo || checkForAudio)
            continue;

        return true;
    }

    return false;
}

void WebUserMediaClient::rememberGrantedRequest(UserMediaRequest& request)
{
    if (requiresDisplayCapture(request))
        return;

    RefPtr document = request.document();
    RefPtr userMediaDocumentOrigin = request.userMediaDocumentOrigin();
    RefPtr topLevelDocumentOrigin = request.topLevelDocumentOrigin();
    if (!document || !userMediaDocumentOrigin || !topLevelDocumentOrigin)
        return;

    m_grantedRequests.removeAllMatching([](auto& grantedRequest) {
        return !grantedRequest.document;
    });
    m_grantedRequests.append(GrantedRequest {
        *document,
        userMediaDocumentOrigin.releaseNonNull(),
        topLevelDocumentOrigin.releaseNonNull(),
        request.request().audioConstraints.isValid,
        request.request().videoConstraints.isValid
    });
}

void WebUserMediaClient::enumerateMediaDevices(Document& document, EnumerateDevicesCallback&& completionHandler)
{
    auto hashSalts = hashSaltsForDocument(document);

    bool revealCameras = false;
    bool revealMicrophones = false;
    for (auto& grantedRequest : m_grantedRequests) {
        if (grantedRequest.document.get() != &document)
            continue;
        revealCameras |= grantedRequest.requiresVideo;
        revealMicrophones |= grantedRequest.requiresAudio;
    }

    RealtimeMediaSourceCenter::singleton().getMediaStreamDevices([revealCameras, revealMicrophones, hashSalts, completionHandler = WTF::move(completionHandler)](auto&& devices) mutable {
        // Before access has been granted a page learns only that a camera or a microphone exists, one
        // of each at most, with neither identifier nor label; speakers stay hidden until microphone
        // access is granted.
        static const unsigned defaultMaximumCameraCount = 1;
        static const unsigned defaultMaximumMicrophoneCount = 1;
        unsigned cameraCount = 0;
        unsigned microphoneCount = 0;

        Vector<CaptureDeviceWithCapabilities> exposedDevices;
        for (auto& device : devices) {
            if (!device.enabled())
                continue;

            bool reveal = device.type() == CaptureDevice::DeviceType::Camera ? revealCameras : revealMicrophones;
            RealtimeMediaSourceCapabilities capabilities;
            if (reveal && device.isInputDevice()) {
                auto deviceCapabilities = RealtimeMediaSourceCenter::singleton().getCapabilities(device);
                if (!deviceCapabilities)
                    continue;
                capabilities = WTF::move(*deviceCapabilities);
            }

            switch (device.type()) {
            case CaptureDevice::DeviceType::Camera:
                cameraCount++;
                if (!reveal) {
                    if (cameraCount <= defaultMaximumCameraCount)
                        exposedDevices.append({ { { }, CaptureDevice::DeviceType::Camera, { }, { } }, { } });
                    break;
                }
                exposedDevices.append({ WTF::move(device), WTF::move(capabilities) });
                break;
            case CaptureDevice::DeviceType::Microphone:
                microphoneCount++;
                if (!reveal) {
                    if (microphoneCount <= defaultMaximumMicrophoneCount)
                        exposedDevices.append({ { { }, CaptureDevice::DeviceType::Microphone, { }, { } }, { } });
                    break;
                }
                exposedDevices.append({ WTF::move(device), WTF::move(capabilities) });
                break;
            case CaptureDevice::DeviceType::Speaker:
                if (!revealMicrophones)
                    break;
                exposedDevices.append({ WTF::move(device), { } });
                break;
            default:
                break;
            }
        }

        completionHandler(WTF::move(exposedDevices), MediaDeviceHashSalts { hashSalts });
    });
}

void WebUserMediaClient::updateCaptureDevices(bool shouldNotifyObservers)
{
    RealtimeMediaSourceCenter::singleton().getMediaStreamDevices([protectedThis = Ref { *this }, shouldNotifyObservers](auto&& newDevices) mutable {
        if (!haveDevicesChanged(protectedThis->m_captureDevices, newDevices))
            return;

        protectedThis->m_captureDevices = WTF::move(newDevices);
        if (!shouldNotifyObservers)
            return;

        for (auto& identifier : copyToVector(protectedThis->m_deviceChangeObserverMap.keys())) {
            auto observer = protectedThis->m_deviceChangeObserverMap.find(identifier);
            if (observer != protectedThis->m_deviceChangeObserverMap.end())
                (observer->value)();
        }
    });
}

void WebUserMediaClient::devicesChanged()
{
    updateCaptureDevices(true);
}

WebUserMediaClient::DeviceChangeObserverToken WebUserMediaClient::addDeviceChangeObserver(Function<void()>&& observer)
{
    auto identifier = DeviceChangeObserverToken::generate();
    m_deviceChangeObserverMap.add(identifier, WTF::move(observer));

    if (!m_monitoringDeviceChange) {
        m_monitoringDeviceChange = true;
        updateCaptureDevices(false);
        RealtimeMediaSourceCenter::singleton().addDevicesChangedObserver(*this);
    }

    return identifier;
}

void WebUserMediaClient::removeDeviceChangeObserver(DeviceChangeObserverToken token)
{
    m_deviceChangeObserverMap.remove(token);
}

void WebUserMediaClient::updateCaptureState(const Document& document, bool isActive, MediaProducerMediaCaptureKind kind, CompletionHandler<void(std::optional<Exception>&&)>&& completionHandler)
{
    RefPtr page = document.page();
    if (!page) {
        completionHandler(Exception { ExceptionCode::InvalidStateError, "no page available"_s });
        return;
    }

    // Muting needs no permission. Unmuting a kind the user muted asks again, as WebKit2's
    // validateCaptureStateUpdate does.
    if (!isActive || !page->mutedState().containsAny(mutedStateFlagsForCaptureKind(kind))) {
        page->updateCaptureState(isActive, kind);
        completionHandler({ });
        return;
    }

    bool isDisplayCapture = kind == MediaProducerMediaCaptureKind::Display;
    auto messageText = alertMessageText(isDisplayCapture, kind != MediaProducerMediaCaptureKind::Camera, kind != MediaProducerMediaCaptureKind::Microphone, &document.topOrigin());
    presentConsentSheet(m_webView, isDisplayCapture, WTF::move(messageText), [protectedPage = Ref { *page }, isActive, kind, completionHandler = WTF::move(completionHandler)](bool granted) mutable {
        if (!granted) {
            completionHandler(Exception { ExceptionCode::NotAllowedError, "Capture access is denied"_s });
            return;
        }
        protectedPage->updateCaptureState(isActive, kind);
        completionHandler({ });
    });
}

void WebUserMediaClient::setShouldListenToVoiceActivity(bool shouldListen)
{
    if (!shouldListen) {
        m_listeningToVoiceActivity = false;
        RealtimeMediaSourceCenter::singleton().audioCaptureFactory().disableMutedSpeechActivityEventListener();
        return;
    }

    m_listeningToVoiceActivity = true;
    RealtimeMediaSourceCenter::singleton().audioCaptureFactory().enableMutedSpeechActivityEventListener([webView = m_webView] {
        if (RefPtr page = [webView page].get())
            page->voiceActivityDetected();
    });
}

#endif // ENABLE(MEDIA_STREAM)
