/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// a Cocoa HTTP transaction exposes native values to browser policy clients.
// Transfers and their callbacks remain on the owning scheduler run loop; callers bridge UI policy.
#include "CocoaCurlScheduler.h"
#include "CocoaCurlTLS.h"
#include <WebCore/FormData.h>
#include <WebCore/NetworkLoadMetrics.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <wtf/AbstractRefCounted.h>
#include <wtf/CompletionHandler.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/FileHandle.h>

namespace WebCore {
class CocoaCurlProxyResolver;
class ResourceError;
class SharedBuffer;
class CocoaCurlTransfer;
class BlobRegistryImpl;

// resolve blobs and own generated archives on main; read immutable upload parts on the transport loop.
class WEBCORE_EXPORT CocoaCurlUploadBody final : public ThreadSafeRefCounted<CocoaCurlUploadBody, WTF::DestructionThread::Main> {
public:
    static Ref<CocoaCurlUploadBody> create(FormData&, BlobRegistryImpl* = nullptr);
    ~CocoaCurlUploadBody();
    const FormData& data() const { return m_data; }
    const String& error() const { return m_error; }
    // The errno the failing read left, where the failure was a filesystem one.
    int errorCode() const { return m_errorCode; }
    uint64_t length() const { return m_length; }
    uint64_t elementLength(size_t index) const { return m_elementLengths[index]; }
private:
    CocoaCurlUploadBody(FormData&, BlobRegistryImpl*);
    Ref<FormData> m_data;
    std::optional<FormDataForUpload> m_preparation;
    String m_error;
    int m_errorCode { 0 };
    uint64_t m_length { 0 };
    Vector<uint64_t> m_elementLengths;
};

WEBCORE_EXPORT std::optional<uint64_t> cocoaCurlUploadLength(const FormData&);
WEBCORE_EXPORT bool validateCocoaCurlResumeResponse(const ResourceResponse&, uint64_t offset, const String& validator);
WEBCORE_EXPORT bool validateCocoaCurlCompletedResume(const ResourceResponse&, uint64_t fileLength);
WEBCORE_EXPORT void collectCocoaCurlMetrics(CURL*, const ResourceRequest&, MonotonicTime start, bool isProxy, NetworkLoadMetrics&);

struct CocoaCurlTransferOptions {
    ResourceRequest request;
    RefPtr<CocoaCurlUploadBody> upload;
    RetainPtr<CFDictionaryRef> proxySettings;
    RetainPtr<CFArrayRef> acceptedCertificateChain;
    RetainPtr<SecTrustRef> allowedServerTrust;
    String boundInterface;
    String user;
    String password;
    String proxyCredentialHost;
    int proxyCredentialPort { 0 };
    String proxyUser;
    String proxyPassword;
    long authentication { CURLAUTH_NONE };
    long proxyAuthentication { CURLAUTH_NONE };
    bool preconnect { false };
    bool decodeContent { true };
};

struct CocoaCurlTransferResponse {
    ResourceResponse response;
    String proxyHost;
    int proxyPort { 0 };
    long authentication { CURLAUTH_NONE };
    long proxyAuthentication { CURLAUTH_NONE };
    NetworkLoadMetrics metrics;
};

class CocoaCurlTransferClient : public AbstractRefCounted {
public:
    virtual void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&&) = 0;
    virtual void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&&) = 0;
    virtual void curlReceivedInformationalResponse(ResourceResponse&&) = 0;
    virtual void curlReceivedData(const SharedBuffer&, CompletionHandler<void()>&&) = 0;
    virtual void curlSentData(uint64_t uploaded, uint64_t total) = 0;
    virtual void curlRequestedIdentity(CFArrayRef authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&) = 0;
    virtual void curlCompleted(const ResourceError&, const NetworkLoadMetrics&) = 0;
};

class WEBCORE_EXPORT CocoaCurlTransfer final : public RefCountedAndCanMakeWeakPtr<CocoaCurlTransfer>, public CocoaCurlSchedulerClient {
public:
    static Ref<CocoaCurlTransfer> create(CocoaCurlScheduler&, CocoaCurlTransferClient&, CocoaCurlTransferOptions&&);
    ~CocoaCurlTransfer();
    void ref() const final { RefCountedAndCanMakeWeakPtr::ref(); }
    void deref() const final { RefCountedAndCanMakeWeakPtr::deref(); }
    void start();
    void cancel();
    void invalidateClient();
    void setPriority(ResourceLoadPriority);
    void setDefersLoading(bool);
    std::shared_ptr<CocoaCurlTLSState> tlsState() const { return m_tls; }
    const ResourceRequest& request() const { return m_options.request; }
    const CocoaCurlTransferResponse& response() const { return m_response; }
private:
    CocoaCurlTransfer(CocoaCurlScheduler&, CocoaCurlTransferClient&, CocoaCurlTransferOptions&&);
    CURL* curlHandle() const final { return m_easy; }
    void curlDidComplete(CURLcode) final;
    void curlDidFail() final;
    void curlCancel() final { cancel(); }
    bool setup();
    bool openUpload();
    void closeUpload();
    void activity();
    void timeout();
    void publishResponse();
    void deliverData();
    void resumeTransfer();
    void updateTLS();
    void updateMetrics();
    void finish(int, const String&);
    size_t header(std::span<const char>);
    size_t data(std::span<const char>);
    size_t invalidResponse(ASCIILiteral);
    static size_t headerCallback(char*, size_t, size_t, void*);
    static size_t dataCallback(char*, size_t, size_t, void*);
    static size_t readCallback(char*, size_t, size_t, void*);
    static int seekCallback(void*, curl_off_t, int);
    static int progressCallback(void*, curl_off_t, curl_off_t, curl_off_t, curl_off_t);
    static CURLcode sslContextCallback(CURL*, void*, void*);

    Ref<CocoaCurlScheduler> m_scheduler;
    CocoaCurlTransferClient* m_client;
    CocoaCurlTransferOptions m_options;
    CocoaCurlTransferResponse m_response;
    FileSystem::FileHandle m_uploadFile;
    size_t m_uploadElement { 0 };
    uint64_t m_uploadElementOffset { 0 };
    uint64_t m_uploadElementLength { 0 };
    RefPtr<CocoaCurlProxyResolver> m_proxyResolver;
    std::shared_ptr<CocoaCurlTLSState> m_tls;
    CURL* m_easy { nullptr };
    curl_slist* m_headers { nullptr };
    std::array<char, CURL_ERROR_SIZE> m_errorBuffer { };
    RefPtr<SharedBuffer> m_data;
    HTTPHeaderMap m_responseHeaders;
    Vector<String> m_setCookies;
    String m_statusText;
    String m_version;
    String m_invalidResponse;
    String m_uploadError;
    int m_uploadErrorCode { 0 };
    int m_status { 0 };
    uint64_t m_uploaded { 0 };
    MonotonicTime m_started;
    NetworkLoadMetrics m_metrics;
    RunLoop::Timer m_timer;
    Seconds m_timeout;
    std::optional<CURLcode> m_result;
    bool m_running { false };
    bool m_complete { false };
    bool m_cancelled { false };
    bool m_finalHeaders { false };
    bool m_publishedResponse { false };
    // Client interactions overlap: a trust evaluation, an identity request and a signature can all be
    // outstanding at once, and the transfer resumes when the last of them retires.
    unsigned m_clientInteractions { 0 };
    // decoded output may grow while paused; acknowledge only bytes the client received.
    size_t m_deliveredDataBytes { 0 };
    bool m_acknowledgeHeader { false };
    bool m_deferred { false };
};
} // namespace WebCore
