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
#include <wtf/Expected.h>
#include <wtf/RefCountedAndCanMakeWeakPtr.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/FileHandle.h>
#include <wtf/WallTime.h>

OBJC_CLASS NSCachedURLResponse;

namespace WebCore {
class CocoaCurlProxyResolver;
class NetworkStorageSession;
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
// The bytes a request field value may carry, as CFNetwork admits them: everything but NUL, CR and LF.
bool isValidCocoaCurlRequestHeaderValue(const String&);
// Parse the escaped native request URL before applying scheme, origin and port policy.
WEBCORE_EXPORT Expected<URL, int> cocoaCurlRequestURL(const URL&);
enum class IsMainResourceLoad : bool;
enum class IsNoSniffSet : bool;
// adjustMIMETypeIfNecessary over the native response CFNetwork would build from this one, for a response
// the transport found no type for.
WEBCORE_EXPORT void adjustCocoaCurlMIMETypeIfNecessary(ResourceResponse&, IsMainResourceLoad, IsNoSniffSet);
WEBCORE_EXPORT void setCocoaCurlContentType(ResourceResponse&, const String& selectedContentType);
WEBCORE_EXPORT void clearCocoaCurlHTTPBody(ResourceRequest&);

// The storage session's NSURLCache, consulted and filled as NSURLConnection does for WebKitLegacy
// loads. Private sessions own a memory-only cache. NSURLDownload consults it and stores nothing.
enum class CocoaCurlCacheAnswer : uint8_t { Load, UseCached, Revalidate, Unavailable };
struct CocoaCurlCacheLookup {
    CocoaCurlCacheAnswer answer { CocoaCurlCacheAnswer::Load };
    RetainPtr<NSCachedURLResponse> entry;
};
WEBCORE_EXPORT CocoaCurlCacheLookup lookUpCocoaCurlCachedResponse(NetworkStorageSession*, const ResourceRequest&);
WEBCORE_EXPORT void invalidateCocoaCurlCacheAfterResponse(NetworkStorageSession*, const ResourceRequest&, const ResourceResponse&);
// The stored response's validators, on a request that carries none of its own.
WEBCORE_EXPORT void addCocoaCurlCacheValidators(ResourceRequest&, NSCachedURLResponse *);
// The stored response a 304 confirms, carrying the fields the 304 updates.
WEBCORE_EXPORT ResourceResponse cocoaCurlRevalidatedResponse(NSCachedURLResponse *, const ResourceResponse& notModified);
WEBCORE_EXPORT ResourceResponse cocoaCurlCachedResponse(NSCachedURLResponse *, const ResourceRequest&);
WEBCORE_EXPORT bool cocoaCurlCacheMayStore(NetworkStorageSession*, const ResourceRequest&, const ResourceResponse&);
WEBCORE_EXPORT bool cocoaCurlCacheAcceptsLength(NetworkStorageSession*, uint64_t);
WEBCORE_EXPORT RetainPtr<NSCachedURLResponse> createCocoaCurlCachedResponse(NetworkStorageSession*, const ResourceRequest&, const ResourceResponse&, std::span<const uint8_t>, WallTime responseTimestamp);
WEBCORE_EXPORT void storeCocoaCurlCachedResponse(NetworkStorageSession*, NSCachedURLResponse *, const ResourceRequest&);
WEBCORE_EXPORT NSData *cocoaCurlCachedBody(NSCachedURLResponse *);
WEBCORE_EXPORT void removeCocoaCurlCachedResponse(NetworkStorageSession*, const ResourceRequest&);

struct CocoaCurlTransferOptions {
    // A WebKit2 load takes its session configuration's TLSMinimumSupportedProtocolVersion. Every other
    // client takes tls_protocol_version_TLSv12, the floor ENABLE(TLS_1_2_DEFAULT_MINIMUM) gives a
    // session that does not allow legacy TLS.
    explicit CocoaCurlTransferOptions(tls_protocol_version_t minimumTLSProtocol)
        : minimumTLSProtocol(minimumTLSProtocol) { }

    tls_protocol_version_t minimumTLSProtocol;
    ResourceRequest request;
    RefPtr<CocoaCurlUploadBody> upload;
    RetainPtr<CFDictionaryRef> proxySettings;
    RetainPtr<CFArrayRef> acceptedCertificateChain;
    RetainPtr<SecTrustRef> allowedServerTrust;
    String boundInterface;
    // Transfers in different network partitions never share a connection (Fetch's network partition key).
    String connectionPartition;
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
    String contentType;
    String canonicalName;
};

class CocoaCurlTransferClient : public AbstractRefCounted {
public:
    virtual void curlReceivedCookies(Vector<String>&&, const String& remoteAddress, const String& canonicalName, CompletionHandler<void(std::optional<String>&&)>&&) = 0;
    virtual void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&&) = 0;
    virtual void curlReceivedInformationalResponse(ResourceResponse&&) = 0;
    virtual void curlReceivedData(const SharedBuffer&, CompletionHandler<void()>&&) = 0;
    virtual void curlSentData(uint64_t uploaded, uint64_t total) = 0;
    virtual void curlRequestedIdentity(CFArrayRef authorities, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&&) = 0;
    virtual void curlRequestedServerTrust(CompletionHandler<void(bool)>&&) = 0;
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
    bool responseEndsAtConnectionClose() const;
    void finish(int, const String&);
    // Consumed leaves m_finalHeaders telling whether the section was the final one.
    enum class HeaderSection : uint8_t { Rejected, Consumed, AwaitingCookies };
    HeaderSection finalizeHeaders();
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
    String m_contentType;
    Vector<String> m_setCookies;
    String m_statusText;
    String m_version;
    String m_invalidResponse;
    String m_uploadError;
    int m_uploadErrorCode { 0 };
    // 0 is a status a response may actually carry, so absence is -1.
    int m_status { -1 };
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
