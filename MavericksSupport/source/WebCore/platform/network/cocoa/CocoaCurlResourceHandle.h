/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// legacy ResourceHandle uses Cocoa native values and curl's worker transaction.
#include "CocoaCurlConnection.h"
#include "CocoaCurlAuthentication.h"
#include <WebCore/CurlMultipartHandle.h>
#include <WebCore/CurlMultipartHandleClient.h>
#include <WebCore/NetworkStorageSession.h>
#include <WebCore/ResourceError.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
OBJC_CLASS WebCoreResourceHandleAsOperationQueueDelegate;

namespace WebCore {
class ResourceHandle;
struct CocoaCurlDownloadTransfer {
    Ref<CocoaCurlConnection> connection;
    Ref<CocoaCurlConnectionPool> pool;
    WeakPtr<NetworkStorageSession> storage;
    ResourceRequest request;
    CocoaCurlTransferResponse response;
    CompletionHandler<void()> completion;
    Vector<uint8_t> bufferedData;
    bool generatedCookieHeader;
    bool allowStoredCredentials;
    std::optional<ResourceError> result;
};

class WEBCORE_EXPORT CocoaCurlResourceHandle final : public RefCountedAndCanMakeWeakPtr<CocoaCurlResourceHandle>, private CocoaCurlTransferClient, private CurlMultipartHandleClient, public CanMakeThreadSafeCheckedPtr<CocoaCurlResourceHandle> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(CocoaCurlResourceHandle, WEBCORE_EXPORT);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(CocoaCurlResourceHandle);
public:
    static Ref<CocoaCurlResourceHandle> create(ResourceHandle&, NetworkStorageSession&, SynchronousLoaderMessageQueue* = nullptr);
    ~CocoaCurlResourceHandle();
    void ref() const final { RefCountedAndCanMakeWeakPtr::ref(); }
    void deref() const final { RefCountedAndCanMakeWeakPtr::deref(); }
    uint32_t checkedPtrCount() const final { return CanMakeThreadSafeCheckedPtr::checkedPtrCount(); }
    uint32_t checkedPtrCountWithoutThreadCheck() const final { return CanMakeThreadSafeCheckedPtr::checkedPtrCountWithoutThreadCheck(); }
    void incrementCheckedPtrCount() const final { CanMakeThreadSafeCheckedPtr::incrementCheckedPtrCount(); }
    void decrementCheckedPtrCount() const final { CanMakeThreadSafeCheckedPtr::decrementCheckedPtrCount(); }
    void setDidBeginCheckedPtrDeletion() final { CanMakeThreadSafeCheckedPtr::setDidBeginCheckedPtrDeletion(); }
    void start();
    void cancel();
    void detach();
    void setDefersLoading(bool);
    std::optional<CocoaCurlDownloadTransfer> takeDownload();
private:
    CocoaCurlResourceHandle(ResourceHandle&, NetworkStorageSession&, bool allowStoredCredentials, SynchronousLoaderMessageQueue*);
    void beginTransfer();
    void detachTransfer();
    void continueTransfer();
    void publishResponse();
    void deliver(std::span<const uint8_t>);
    void redirect();
    void authenticate(bool proxy);
    void challenge(const ProtectionSpace&, const Credential&, unsigned, const ResourceError&, CocoaCurlAuthenticationCompletion&&);
    void finish(const ResourceError&);
    void fail(int, const String&);
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&&) final;
    void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&&) final;
    void curlReceivedInformationalResponse(ResourceResponse&&) final;
    void curlReceivedData(const SharedBuffer&, CompletionHandler<void()>&&) final;
    void curlSentData(uint64_t, uint64_t) final;
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&) final;
    void curlCompleted(const ResourceError&, const NetworkLoadMetrics&) final;
    void didReceiveHeaderFromMultipart(Vector<String>&&) final;
    void didReceiveDataFromMultipart(std::span<const uint8_t>) final;
    void didCompleteFromMultipart() final;

    ResourceHandle* m_handle;
    Ref<CocoaCurlConnectionPool> m_pool;
    WeakPtr<NetworkStorageSession> m_storage;
    RefPtr<SynchronousLoaderMessageQueue> m_queue;
    RetainPtr<WebCoreResourceHandleAsOperationQueueDelegate> m_dispatcher;
    RefPtr<CocoaCurlConnection> m_connection;
    ResourceRequest m_request;
    CocoaCurlTransferResponse m_response;
    CompletionHandler<void()> m_continuation;
    std::optional<ResourceError> m_result;
    NetworkLoadMetrics m_metrics;
    RetainPtr<CFArrayRef> m_acceptedChain;
    RetainPtr<NSURLAuthenticationChallenge> m_challenge;
    String m_user;
    String m_password;
    String m_proxyUser;
    String m_proxyPassword;
    long m_auth { CURLAUTH_NONE };
    long m_proxyAuth { CURLAUTH_NONE };
    unsigned m_authFailures { 0 };
    unsigned m_proxyAuthFailures { 0 };
    unsigned m_redirects { 0 };
    bool m_cancelled { false };
    bool m_deferred { false };
    bool m_waitingForPolicy { false };
    bool m_needsSniff { false };
    bool m_noSniff { false };
    bool m_useResponse { false };
    bool m_allowCredentials { false };
    bool m_generatedCookie { false };
    Vector<uint8_t> m_sniffed;
    std::unique_ptr<CurlMultipartHandle> m_multipart;
};
}
