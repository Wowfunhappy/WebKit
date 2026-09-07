/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

// Cocoa HTTP transport; CF values and session-owned curl connection pools.
#if PLATFORM(COCOA)

#include "NetworkDataTask.h"
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/CurlMultipartHandle.h>
#include <WebCore/CurlMultipartHandleClient.h>
#include <wtf/CheckedRef.h>
#include <WebCore/FormData.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <wtf/FileSystem.h>
#include <openssl/ssl.h>
#include <Security/Security.h>
#include <curl/curl.h>
#include <wtf/HashMap.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/RetainPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore { struct CocoaCurlTLSState; }

namespace WebKit {

class NetworkDataTaskCurlCocoa;
using CocoaCurlTLSState = WebCore::CocoaCurlTLSState;

using CurlNetworkScheduler = WebCore::CocoaCurlConnectionPool;

class NetworkDataTaskCurlCocoa final : public NetworkDataTask, public WebCore::CurlMultipartHandleClient, public CanMakeThreadSafeCheckedPtr<NetworkDataTaskCurlCocoa>, public WebCore::CocoaCurlTransferClient {
    WTF_MAKE_TZONE_ALLOCATED(NetworkDataTaskCurlCocoa);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(NetworkDataTaskCurlCocoa);
public:
    static bool canHandle(NetworkSession&, const NetworkLoadParameters&);
    static Ref<NetworkDataTask> create(NetworkSession&, NetworkDataTaskClient&, const NetworkLoadParameters&);
    ~NetworkDataTaskCurlCocoa();
    void ref() const final { NetworkDataTask::ref(); }
    void deref() const final { NetworkDataTask::deref(); }


    uint32_t checkedPtrCount() const final { return CanMakeThreadSafeCheckedPtr::checkedPtrCount(); }
    uint32_t checkedPtrCountWithoutThreadCheck() const final { return CanMakeThreadSafeCheckedPtr::checkedPtrCountWithoutThreadCheck(); }
    void incrementCheckedPtrCount() const final { CanMakeThreadSafeCheckedPtr::incrementCheckedPtrCount(); }
    void decrementCheckedPtrCount() const final { CanMakeThreadSafeCheckedPtr::decrementCheckedPtrCount(); }
    void setDidBeginCheckedPtrDeletion() final { CanMakeThreadSafeCheckedPtr::setDidBeginCheckedPtrDeletion(); }

    void resume() final;
    void cancel() final;
    void invalidateAndCancel() final;
    State state() const final { return m_state; }
    String description() const final { return "Cocoa curl HTTP task"_s; }
    void setPriority(WebCore::ResourceLoadPriority) final;
    void setPendingDownloadLocation(const String&, SandboxExtension::Handle&&, bool) final;
    String suggestedFilename() const final;
    void cancelWithResumeData(CompletionHandler<void(std::span<const uint8_t>)>&&) final;
    void setTimingAllowFailedFlag() final { m_metrics.failsTAOCheck = true; }

private:
    NetworkDataTaskCurlCocoa(NetworkSession&, NetworkDataTaskClient&, const NetworkLoadParameters&);
    // native cookie policy runs before internal curl authentication exchanges.
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&&) final;
    void curlReceivedResponse(WebCore::CocoaCurlTransferResponse&&, CompletionHandler<void()>&&) final;
    void curlReceivedInformationalResponse(WebCore::ResourceResponse&&) final;
    void curlReceivedData(const WebCore::SharedBuffer&, CompletionHandler<void()>&&) final;
    void curlSentData(uint64_t, uint64_t) final;
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&) final;
    void curlCompleted(const WebCore::ResourceError&, const WebCore::NetworkLoadMetrics&) final;
    void setup();
    void start();
    void continueAfterHeaders();
    void continueTransfer();
    void detachTransfer();
    void redirect();
    void authenticate(bool proxy);
    void challengeServerTrust();
    void restart(WebCore::ResourceRequest&&);
    void updateMetrics(const WebCore::NetworkLoadMetrics&);
    bool cookiesBlocked();
    Vector<uint8_t> downloadResumeData() const;
    void publishResponse();
    void decidePolicy(WebCore::PolicyAction);
    void deliverData();
    void didReceiveHeaderFromMultipart(Vector<String>&&) final;
    void didReceiveDataFromMultipart(std::span<const uint8_t>) final;
    void didCompleteFromMultipart() final;
    // preserve native transport NSError details through terminal delivery.
    void finish(int, const String&, const WebCore::ResourceError& = { });

    WebCore::ResourceRequest m_request;
    RetainPtr<SecTrustRef> m_serverTrust;
    RetainPtr<CFArrayRef> m_acceptedCertificateChain;
    std::shared_ptr<CocoaCurlTLSState> m_tlsState;
    RefPtr<SandboxExtension> m_downloadSandboxExtension;
    FileSystem::FileHandle m_downloadFile;
    std::optional<WebCore::FrameIdentifier> m_frameID;
    std::optional<WebCore::PageIdentifier> m_pageID;
    std::optional<WebPageProxyIdentifier> m_webPageProxyID;
    uint64_t m_requiredCookiesVersion { 0 };
    uint64_t m_downloadedBytes { 0 };
    std::optional<uint64_t> m_resumeOffset;
    uint64_t m_downloadExpectedBytes { 0 };
    std::optional<NavigatingToAppBoundDomain> m_isNavigatingToAppBoundDomain;
    unsigned m_redirectCount { 0 };
    std::optional<WebCore::ProtectionSpace> m_lastAuthenticationSpace;
    std::optional<WebCore::ProtectionSpace> m_lastProxyAuthenticationSpace;
    unsigned m_authFailureCount { 0 };
    unsigned m_proxyAuthFailureCount { 0 };
    long m_authMethod { CURLAUTH_NONE };
    long m_proxyAuthMethod { CURLAUTH_NONE };
    String m_authUser;
    String m_authPassword;
    String m_proxyUser;
    String m_proxyPassword;
    String m_proxyHost;
    int m_proxyPort { 0 };
    bool m_shouldPreconnect { false };
    bool m_shouldSniff { false };
    bool m_responseNeedsSniff { false };
    bool m_noSniff { false };
    Vector<uint8_t> m_sniffPrefix;
    bool m_isMainResource { false };
    bool m_cookieBlockingLatched { false };
    bool m_generatedCookieHeader { false };
    bool m_isDownloadSink { false };
    bool m_allowOverwriteDownload { false };
    bool m_authResponseApproved { false };
    bool m_proxyResponseApproved { false };
    RefPtr<CurlNetworkScheduler> m_scheduler;
    std::unique_ptr<WebCore::CurlMultipartHandle> m_multipart;
    bool m_waitingForMultipartPolicy { false };
    WebCore::ResourceResponse m_response;
    RefPtr<const WebCore::SharedBuffer> m_pendingData;
    WebCore::NetworkLoadMetrics m_metrics;
    std::optional<WebCore::ResourceError> m_result;
    RefPtr<WebCore::CocoaCurlConnection> m_transfer;
    CompletionHandler<void()> m_continueTransfer;
    long m_availableAuthentication { CURLAUTH_NONE };
    long m_availableProxyAuthentication { CURLAUTH_NONE };
    State m_state { State::Suspended };
    bool m_cancelled { false };
    int m_status { 0 };
    bool m_finalHeaders { false };
    bool m_waitingForPolicy { false };
    bool m_useResponse { false };
};

} // namespace WebKit

#endif
