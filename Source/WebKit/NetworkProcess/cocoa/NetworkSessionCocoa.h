/*
 * Copyright (C) 2016-2021 Apple Inc. All rights reserved.
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

#pragma once

OBJC_CLASS DMFWebsitePolicyMonitor;
OBJC_CLASS NSData;
OBJC_CLASS NSURLSession;
OBJC_CLASS NSURLSessionConfiguration;
OBJC_CLASS NSURLSessionDownloadTask;
OBJC_CLASS NSOperationQueue;
OBJC_CLASS WKNetworkSessionDelegate;
OBJC_CLASS WKNetworkSessionWebSocketDelegate;
OBJC_CLASS _NSHSTSStorage;
OBJC_CLASS NSURLCredentialStorage;

#include "DownloadID.h"
#include "NetworkDataTaskCocoa.h"
#include "NetworkSession.h"
// MAVERICKS_BACKPORT: the transport pool is shared with Cocoa legacy loaders.
#include <WebCore/CocoaCurlConnection.h>
// MAVERICKS_BACKPORT: HSTS remains a browser policy with native-session persistence boundaries.
#include <WebCore/HTTPStrictTransportSecurityStore.h>
#include "WebPageNetworkParameters.h"
#include "WebPageProxyIdentifier.h"
#include "WebSocketTask.h"
#include <WebCore/NetworkLoadMetrics.h>
#include <WebCore/RegistrableDomain.h>
#include <wtf/HashMap.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/Seconds.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {
enum class AdvancedPrivacyProtections : uint16_t;
}

namespace WebKit {

// MAVERICKS_BACKPORT: curl has its own session-owned transport registry, separate from native IDs.
using CurlNetworkScheduler = WebCore::CocoaCurlConnectionPool;

enum class NegotiatedLegacyTLS : bool;
class LegacyCustomProtocolManager;
class NetworkSessionCocoa;

struct SessionWrapper : public CanMakeWeakPtr<SessionWrapper>, public CanMakeCheckedPtr<SessionWrapper> {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(SessionWrapper);
    WTF_STRUCT_OVERRIDE_DELETE_FOR_CHECKED_PTR(SessionWrapper);

    // MAVERICKS_BACKPORT: construct the owning curl pointer where its complete type is visible.
    // SessionWrapper() = default;
    SessionWrapper();
    ~SessionWrapper();

    void initialize(NSURLSessionConfiguration*, NetworkSessionCocoa&, WebCore::StoredCredentialsPolicy, NavigatingToAppBoundDomain);

    void recreateSessionWithUpdatedProxyConfigurations(NetworkSessionCocoa&);

    // MAVERICKS_BACKPORT: curl owns its typed task registry within the same credential/privacy partition.
    RefPtr<CurlNetworkScheduler> curlScheduler;
    RetainPtr<NSURLSession> session;
    RetainPtr<WKNetworkSessionDelegate> delegate;
    // MAVERICKS_BACKPORT: 10.9's NSURLSessionTask.taskIdentifier is 0-based (the first task in a session is
    // identifier 0), but WTF::HashMap's default integer traits reserve 0 as the empty-slot sentinel and
    // UINT64_MAX as the deleted sentinel — so an identifier-0 task cannot be stored. Upstream relies on
    // modern taskIdentifier starting at 1. Use zero-key-permitting traits (empty=UINT64_MAX, deleted=
    // UINT64_MAX-1, both unreachable by a real session's task count) so identifier 0 is a valid key. This
    // localizes the 10.9 divergence to the map type and lets every access site match upstream verbatim —
    // and it fixes downloadMap/webSocketDataTaskMap, which were never covered by the prior +1-shift approach
    // and would silently lose a download or WebSocket that landed identifier 0.
    HashMap<NetworkDataTaskCocoa::TaskIdentifier, ThreadSafeWeakPtr<NetworkDataTaskCocoa>, DefaultHash<NetworkDataTaskCocoa::TaskIdentifier>, WTF::UnsignedWithZeroKeyHashTraits<NetworkDataTaskCocoa::TaskIdentifier>> dataTaskMap;
    HashMap<NetworkDataTaskCocoa::TaskIdentifier, DownloadID, DefaultHash<NetworkDataTaskCocoa::TaskIdentifier>, WTF::UnsignedWithZeroKeyHashTraits<NetworkDataTaskCocoa::TaskIdentifier>> downloadMap;
    HashMap<NetworkDataTaskCocoa::TaskIdentifier, ThreadSafeWeakPtr<WebSocketTask>, DefaultHash<NetworkDataTaskCocoa::TaskIdentifier>, WTF::UnsignedWithZeroKeyHashTraits<NetworkDataTaskCocoa::TaskIdentifier>> webSocketDataTaskMap;
};

struct IsolatedSession {
    WTF_MAKE_TZONE_ALLOCATED(IsolatedSession);
public:
    IsolatedSession()
        : sessionWithCredentialStorage(makeUniqueRef<SessionWrapper>())
        // MAVERICKS_BACKPORT: see sessionWithoutCredentialStorage below.
        , sessionWithoutCredentialStorage(makeUniqueRef<SessionWrapper>())
    { }

    UniqueRef<SessionWrapper> sessionWithCredentialStorage;
    // MAVERICKS_BACKPORT: the DoNotUse counterpart, see SessionSet::sessionWithoutCredentialStorage.
    UniqueRef<SessionWrapper> sessionWithoutCredentialStorage;
    WallTime lastUsed;
};

struct SessionSet : public RefCountedAndCanMakeWeakPtr<SessionSet> {
public:
    static Ref<SessionSet> create()
    {
        return adoptRef(*new SessionSet);
    }

    SessionWrapper& initializeEphemeralStatelessSessionIfNeeded(NavigatingToAppBoundDomain, NetworkSessionCocoa&);
    // MAVERICKS_BACKPORT: a StoredCredentialsPolicy::DoNotUse task needs a session of its own, see
    // sessionWrapperForTask.
    SessionWrapper& initializeSessionWithoutCredentialStorageIfNeeded(NetworkSessionCocoa&);

    CheckedRef<SessionWrapper> isolatedSession(WebCore::StoredCredentialsPolicy, const WebCore::RegistrableDomain&, NavigatingToAppBoundDomain, NetworkSessionCocoa&);
    HashMap<WebCore::RegistrableDomain, std::unique_ptr<IsolatedSession>> isolatedSessions;

    std::unique_ptr<IsolatedSession> appBoundSession;

    UniqueRef<SessionWrapper> sessionWithCredentialStorage;
    UniqueRef<SessionWrapper> ephemeralStatelessSession;
    // MAVERICKS_BACKPORT: same configuration as sessionWithCredentialStorage but with no
    // URLCredentialStorage, created on first use.
    UniqueRef<SessionWrapper> sessionWithoutCredentialStorage;

private:

    SessionSet()
        : sessionWithCredentialStorage(makeUniqueRef<SessionWrapper>())
        , ephemeralStatelessSession(makeUniqueRef<SessionWrapper>())
        // MAVERICKS_BACKPORT: see sessionWithoutCredentialStorage above.
        , sessionWithoutCredentialStorage(makeUniqueRef<SessionWrapper>())
    { }
};

class NetworkSessionCocoa final : public NetworkSession {
    WTF_MAKE_TZONE_ALLOCATED(NetworkSessionCocoa);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(NetworkSessionCocoa);
public:
    static std::unique_ptr<NetworkSession> create(NetworkProcess&, const NetworkSessionCreationParameters&);

    NetworkSessionCocoa(NetworkProcess&, const NetworkSessionCreationParameters&);
    ~NetworkSessionCocoa();

    // MAVERICKS_BACKPORT: the Cocoa session continues to own cookies, credentials, and native tasks.
    Ref<CurlNetworkScheduler> curlNetworkScheduler(std::optional<WebPageProxyIdentifier>, const WebCore::ResourceRequest&, WebCore::StoredCredentialsPolicy, std::optional<NavigatingToAppBoundDomain>);

    SessionWrapper& initializeEphemeralStatelessSessionIfNeeded(std::optional<WebPageProxyIdentifier>, NavigatingToAppBoundDomain);

    const String& boundInterfaceIdentifier() const LIFETIME_BOUND { return m_boundInterfaceIdentifier; }
    const String& sourceApplicationBundleIdentifier() const LIFETIME_BOUND { return m_sourceApplicationBundleIdentifier; }
    const String& sourceApplicationSecondaryIdentifier() const LIFETIME_BOUND { return m_sourceApplicationSecondaryIdentifier; }
#if PLATFORM(IOS_FAMILY)
    const String& dataConnectionServiceType() const LIFETIME_BOUND { return m_dataConnectionServiceType; }
#endif

    void setClientAuditToken(const WebCore::AuthenticationChallenge&);

    void continueDidReceiveChallenge(SessionWrapper&, const WebCore::AuthenticationChallenge&, NegotiatedLegacyTLS, NetworkDataTaskCocoa::TaskIdentifier, RefPtr<NetworkDataTaskCocoa>, CompletionHandler<void(WebKit::AuthenticationChallengeDisposition, const WebCore::Credential&)>&&);

    // MAVERICKS_BACKPORT: part of restoring WKContextAllowSpecificHTTPSCertificateForHost, which
    // upstream dropped and Safari 7's invalid-certificate sheet needs. True when this challenge
    // presents exactly the certificate the user accepted for its host (the certificates live on the
    // network process); any other chain still goes to the client.
    bool isAllowedHTTPSCertificateForHost(NSURLAuthenticationChallenge *);

    SessionWrapper& sessionWrapperForDownloadResume() { return m_defaultSessionSet->sessionWithCredentialStorage; }

    bool fastServerTrustEvaluationEnabled() const { return m_fastServerTrustEvaluationEnabled; }
    bool deviceManagementRestrictionsEnabled() const { return m_deviceManagementRestrictionsEnabled; }
    bool allLoadsBlockedByDeviceManagementRestrictionsForTesting() const { return m_allLoadsBlockedByDeviceManagementRestrictionsForTesting; }

    DMFWebsitePolicyMonitor *NODELETE deviceManagementPolicyMonitor();

    CFDictionaryRef proxyConfiguration() const { return m_proxyConfiguration.get(); }

    bool hasIsolatedSession(const WebCore::RegistrableDomain&) const override;
    void clearIsolatedSessions() override;

#if ENABLE(APP_BOUND_DOMAINS)
    bool hasAppBoundSession() const override;
    void clearAppBoundSession() override;
#endif

    CheckedRef<SessionWrapper> sessionWrapperForTask(std::optional<WebPageProxyIdentifier>, const WebCore::ResourceRequest&, WebCore::StoredCredentialsPolicy, std::optional<NavigatingToAppBoundDomain>);
    bool preventsSystemHTTPProxyAuthentication() const { return m_preventsSystemHTTPProxyAuthentication; }

    _NSHSTSStorage *hstsStorage() const;
    // MAVERICKS_BACKPORT: curl and the website-data APIs share this browser-owned dynamic store.
    WebCore::HTTPStrictTransportSecurityStore& httpStrictTransportSecurityStore() { return *m_httpStrictTransportSecurityStore; }

    NSURLCredentialStorage *nsCredentialStorage() const;

    void removeNetworkWebsiteData(std::optional<WallTime>, std::optional<HashSet<WebCore::RegistrableDomain>>&&, CompletionHandler<void()>&&) override;

    void removeDataTask(DataTaskIdentifier);
    // MAVERICKS_BACKPORT: blob and HTTP API tasks share removeDataTask.
    // void removeBlobDataTask(DataTaskIdentifier);

#if HAVE(NW_PROXY_CONFIG)
    const Vector<RetainPtr<nw_proxy_config_t>>& proxyConfigs() const LIFETIME_BOUND { return m_nwProxyConfigs; }

    void clearProxyConfigData() final;
    void setProxyConfigData(const Vector<std::pair<Vector<uint8_t>, std::optional<WTF::UUID>>>&) final;

    void applyProxyConfigurationToSessionConfiguration(NSURLSessionConfiguration *);
#endif
    bool isLegacyTLSAllowed() const { return m_isLegacyTLSAllowed; }

private:
    // MAVERICKS_BACKPORT: ephemeral sessions retain this state only in memory.
    std::unique_ptr<WebCore::HTTPStrictTransportSecurityStore> m_httpStrictTransportSecurityStore;
    void invalidateAndCancel() override;
    HashSet<WebCore::SecurityOriginData> originsWithCredentials() final;
    void removeCredentialsForOrigins(const Vector<WebCore::SecurityOriginData>&) final;
    void clearCredentials(WallTime) final;

    bool shouldLogCookieInformation() const override { return m_shouldLogCookieInformation; }
    CheckedRef<SessionWrapper> isolatedSession(WebPageProxyIdentifier, WebCore::StoredCredentialsPolicy, const WebCore::RegistrableDomain&, NavigatingToAppBoundDomain);

#if ENABLE(APP_BOUND_DOMAINS)
    SessionWrapper& appBoundSession(std::optional<WebPageProxyIdentifier>, WebCore::StoredCredentialsPolicy);
#endif

    void donateToSKAdNetwork(WebCore::PrivateClickMeasurement&&) final;
    void notifyAdAttributionKitOfSessionTermination() final;

    Vector<WebCore::SecurityOriginData> hostNamesWithAlternativeServices() const override;
    void deleteAlternativeServicesForHostNames(const Vector<String>&) override;
    void clearAlternativeServices(WallTime) override;

    RefPtr<WebSocketTask> createWebSocketTask(WebPageProxyIdentifier, std::optional<WebCore::FrameIdentifier>, std::optional<WebCore::PageIdentifier>, NetworkSocketChannel&, const WebCore::ResourceRequest&, const String& protocol, const WebCore::ClientOrigin&, bool hadMainFrameMainResourcePrivateRelayed, bool allowPrivacyProxy, OptionSet<WebCore::AdvancedPrivacyProtections>, WebCore::StoredCredentialsPolicy) final;
    void addWebSocketTask(WebPageProxyIdentifier, WebSocketTask&) final;
    void removeWebSocketTask(SessionSet&, WebSocketTask&) final;

    void loadImageForDecoding(WebCore::ResourceRequest&&, WebPageProxyIdentifier, size_t, CompletionHandler<void(Expected<Ref<WebCore::FragmentedSharedBuffer>, WebCore::ResourceError>&&)>&&) final;
    void dataTaskWithRequest(WebPageProxyIdentifier, WebCore::ResourceRequest&&, const std::optional<WebCore::SecurityOriginData>& topOrigin, CompletionHandler<void(DataTaskIdentifier)>&&) final;
    void cancelDataTask(DataTaskIdentifier) final;
    void addWebPageNetworkParameters(WebPageProxyIdentifier, WebPageNetworkParameters&&) final;
    void removeWebPageNetworkParameters(WebPageProxyIdentifier) final;
    size_t countNonDefaultSessionSets() const final;

    void forEachSessionWrapper(NOESCAPE const Function<void(SessionWrapper&)>&);

    bool isNetworkSessionCocoa() const final { return true; }

    Ref<SessionSet> m_defaultSessionSet;
    HashMap<WebPageProxyIdentifier, Ref<SessionSet>> m_perPageSessionSets;
    HashMap<WebPageNetworkParameters, WeakPtr<SessionSet>> m_perParametersSessionSets;

    void initializeNSURLSessionsInSet(SessionSet&, NSURLSessionConfiguration *);
    SessionSet& sessionSetForPage(std::optional<WebPageProxyIdentifier>);
    const SessionSet& sessionSetForPage(std::optional<WebPageProxyIdentifier>) const;

    void invalidateAndCancelSessionSet(SessionSet&);
    
    String m_boundInterfaceIdentifier;
    String m_sourceApplicationBundleIdentifier;
    String m_sourceApplicationSecondaryIdentifier;
    RetainPtr<CFDictionaryRef> m_proxyConfiguration;
#if HAVE(NW_PROXY_CONFIG)
    Vector<RetainPtr<nw_proxy_config_t>> m_nwProxyConfigs;
#endif
    RetainPtr<DMFWebsitePolicyMonitor> m_deviceManagementPolicyMonitor;
    bool m_deviceManagementRestrictionsEnabled { false };
    bool m_allLoadsBlockedByDeviceManagementRestrictionsForTesting { false };
    bool m_shouldLogCookieInformation { false };
    bool m_fastServerTrustEvaluationEnabled { false };
    String m_dataConnectionServiceType;
    bool m_preventsSystemHTTPProxyAuthentication { false };
    bool m_isLegacyTLSAllowed { false };
#if HAVE(AD_ATTRIBUTION_KIT_PRIVATE_BROWSING)
    Markable<WTF::UUID> m_donatedEphemeralImpressionSessionID;
#endif

    // MAVERICKS_BACKPORT: every API data task uses NetworkDataTask's transport and client contract.
    // class BlobDataTaskClient;
    // HashMap<DataTaskIdentifier, Ref<BlobDataTaskClient>> m_blobDataTasksForAPI;
    // HashMap<DataTaskIdentifier, RetainPtr<NSURLSessionDataTask>> m_dataTasksForAPI;
    class APIDataTaskClient;
    HashMap<DataTaskIdentifier, Ref<APIDataTaskClient>> m_dataTasksForAPI;
};

} // namespace WebKit

SPECIALIZE_TYPE_TRAITS_BEGIN(WebKit::NetworkSessionCocoa)
    static bool isType(const WebKit::NetworkSession& networkSession) { return networkSession.isNetworkSessionCocoa(); }
SPECIALIZE_TYPE_TRAITS_END()
