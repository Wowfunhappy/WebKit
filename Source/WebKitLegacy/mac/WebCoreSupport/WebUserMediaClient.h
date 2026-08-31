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

// MAVERICKS_BACKPORT: getUserMedia for WebKit1, whose client upstream removed in a5c8561
// ("[MediaStream] remove WK1 support", 2018) while keeping the embedder SPI it called
// (-webView:decidePolicyForUserMediaRequestFromOrigin:listener: in WebUIDelegatePrivate.h). WebKit1 is
// a first-class host on this port: every 10.9 application that embeds a WebView asks for its camera and
// microphone here. One class covers what WebKit2 splits over two processes -- the WebProcess-side
// UserMediaPermissionRequestManager (media-can-start deferral, request bookkeeping) and the
// UIProcess-side UserMediaPermissionRequestManagerProxy (constraint validation, consent, device-list
// filtering, hash salts) -- because a WebKit1 host is both sides at once.

#pragma once

#if ENABLE(MEDIA_STREAM)

#import <WebCore/MediaCanStartListener.h>
#import <WebCore/MediaDeviceHashSalts.h>
#import <WebCore/RealtimeMediaSourceCenter.h>
#import <WebCore/UserMediaClient.h>
#import <WebCore/UserMediaRequestIdentifier.h>
#import <wtf/Deque.h>
#import <wtf/HashMap.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RunLoop.h>
#import <wtf/Ref.h>
#import <wtf/RefCounted.h>
#import <wtf/RefPtr.h>
#import <wtf/TZoneMalloc.h>
#import <wtf/WeakHashMap.h>
#import <wtf/text/WTFString.h>

namespace WebCore {
class Document;
class Page;
class SecurityOrigin;
class UserMediaRequest;
class WeakPtrImplWithEventTargetData;
}

@class WebView;

class WebUserMediaClient final : public WebCore::UserMediaClient, public WebCore::RealtimeMediaSourceCenterObserver, public WebCore::MediaCanStartListener, public RefCounted<WebUserMediaClient> {
    WTF_MAKE_TZONE_ALLOCATED(WebUserMediaClient);
public:
    USING_CAN_MAKE_WEAKPTR(WebCore::MediaCanStartListener);

    static Ref<WebUserMediaClient> create(WebView *webView) { return adoptRef(*new WebUserMediaClient(webView)); }
    ~WebUserMediaClient();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

    // The client this page's UserMediaController holds, if it has one. WebKitLegacy installs no other.
    static WebUserMediaClient* from(WebCore::Page*);

    // The answer to the request the listener was made for, which the UI delegate or the consent sheet
    // holds while the user decides.
    void requestWasAllowed(WebCore::UserMediaRequestIdentifier);
    void requestWasDenied(WebCore::UserMediaRequestIdentifier);

    // The page's capture state, from WebChromeClient::isPlayingMediaDidChange().
    void captureStateChanged(WebCore::MediaProducerMediaStateFlags);

private:
    explicit WebUserMediaClient(WebView *);

    // WebCore::UserMediaClient
    void requestUserMediaAccess(WebCore::UserMediaRequest&) final;
    void cancelUserMediaAccessRequest(WebCore::UserMediaRequest&) final;
    void enumerateMediaDevices(WebCore::Document&, EnumerateDevicesCallback&&) final;
    DeviceChangeObserverToken addDeviceChangeObserver(Function<void()>&&) final;
    void removeDeviceChangeObserver(DeviceChangeObserverToken) final;
    void updateCaptureState(const WebCore::Document&, bool isActive, WebCore::MediaProducerMediaCaptureKind, CompletionHandler<void(std::optional<WebCore::Exception>&&)>&&) final;
    void setShouldListenToVoiceActivity(bool) final;

    // WebCore::RealtimeMediaSourceCenterObserver
    void devicesChanged() final;
    void deviceWillBeRemoved(const String&) final { }

    // WebCore::MediaCanStartListener
    void mediaCanStart(WebCore::Document&) final;

    // A request the user has answered for, tied to the document that asked: a navigation, a reload or
    // a web archive replacing that document leaves nothing to inherit.
    struct GrantedRequest {
        WeakPtr<WebCore::Document, WebCore::WeakPtrImplWithEventTargetData> document;
        Ref<WebCore::SecurityOrigin> userMediaDocumentOrigin;
        Ref<WebCore::SecurityOrigin> topLevelDocumentOrigin;
        bool requiresAudio;
        bool requiresVideo;
    };

    void enqueueRequest(Ref<WebCore::UserMediaRequest>&&);
    void startProcessingRequest(Ref<WebCore::UserMediaRequest>&&);
    void constraintsValidated(WebCore::UserMediaRequestIdentifier, Expected<WebCore::RealtimeMediaSourceCenter::ValidDevices, WebCore::MediaConstraintType>&&);
    void decidePermission();
    void processNextRequestIfNeeded();

    WebCore::MediaDeviceHashSalts hashSaltsForDocument(WebCore::Document&);
    Seconds inactiveMediaCaptureStreamDuration() const;
    void watchdogTimerFired();
    bool hasGrantedRequest(WebCore::UserMediaRequest&) const;
    void rememberGrantedRequest(WebCore::UserMediaRequest&);
    void updateCaptureDevices(bool shouldNotifyObservers);

    WebView *m_webView;

    RefPtr<WebCore::UserMediaRequest> m_currentRequest;
    WebCore::RealtimeMediaSourceCenter::ValidDevices m_currentRequestDevices;
    WebCore::MediaDeviceHashSalts m_currentRequestHashSalts;
    Deque<Ref<WebCore::UserMediaRequest>> m_pendingRequests;
    HashMap<Ref<WebCore::Document>, Vector<Ref<WebCore::UserMediaRequest>>> m_requestsWaitingForMediaToStart;

    Vector<GrantedRequest> m_grantedRequests;
    HashMap<String, String> m_persistentHashSaltForOrigin;
    WeakHashMap<WebCore::Document, String, WebCore::WeakPtrImplWithEventTargetData> m_ephemeralHashSaltForDocument;

    WebCore::MediaProducerMediaStateFlags m_captureState;
    std::optional<MonotonicTime> m_lastCaptureTime;
    Seconds m_currentWatchdogInterval { 0_s };
    RunLoop::Timer m_watchdogTimer;

    HashMap<DeviceChangeObserverToken, Function<void()>> m_deviceChangeObserverMap;
    Vector<WebCore::CaptureDevice> m_captureDevices;
    bool m_monitoringDeviceChange { false };
    bool m_listeningToVoiceActivity { false };
};

#endif // ENABLE(MEDIA_STREAM)
