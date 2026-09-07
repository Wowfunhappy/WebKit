/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

#import "config.h"
#import "PrivateClickMeasurementNetworkLoader.h"

#import "NetworkDataTaskCocoa.h"
// MAVERICKS_BACKPORT: PCM uses the shared stateless Cocoa curl transaction.
#import <WebCore/CocoaCurlConnection.h>
#import <WebCore/ResourceError.h>
#import <WebCore/SharedBuffer.h>
#import <wtf/RefCounted.h>
#import <WebCore/HTTPHeaderValues.h>
#import <WebCore/MIMETypeRegistry.h>
#import <WebCore/UserAgent.h>
#import <pal/spi/cf/CFNetworkSPI.h>
#import <wtf/BlockPtr.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/cocoa/SpanCocoa.h>

static RetainPtr<SecTrustRef>& NODELETE allowedLocalTestServerTrust()
{
    static NeverDestroyed<RetainPtr<SecTrustRef>> serverTrust;
    return serverTrust.get();
}

// MAVERICKS_BACKPORT: native NSURLSession PCM implementation retained beside the curl client.
#if 0
static bool trustsServerForLocalTests(NSURLAuthenticationChallenge *challenge)
{
    if (![challenge.protectionSpace.host isEqualToString:@"127.0.0.1"]
        || !allowedLocalTestServerTrust())
        return false;

    return WebCore::certificatesMatch(allowedLocalTestServerTrust().get(), RetainPtr { challenge.protectionSpace.serverTrust }.get());
}

@interface WKNetworkSessionDelegateAllowingOnlyNonRedirectedJSON : NSObject <NSURLSessionDataDelegate>
@end

@implementation WKNetworkSessionDelegateAllowingOnlyNonRedirectedJSON

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    if (WebCore::MIMETypeRegistry::isSupportedJSONMIMEType(response.MIMEType))
        return completionHandler(NSURLSessionResponseAllow);
    completionHandler(NSURLSessionResponseCancel);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]
        && trustsServerForLocalTests(challenge))
        return completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust: RetainPtr { challenge.protectionSpace.serverTrust }.get()]);
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

@end

namespace WebKit::PCM {

enum class LoadTaskIdentifierType { };
using LoadTaskIdentifier = ObjectIdentifier<LoadTaskIdentifierType>;
static HashMap<LoadTaskIdentifier, RetainPtr<NSURLSessionDataTask>>& NODELETE taskMap()
{
    static NeverDestroyed<HashMap<LoadTaskIdentifier, RetainPtr<NSURLSessionDataTask>>> map;
    return map.get();
}

static NSURLSession *statelessSessionWithoutRedirectsSingleton()
{
    static NeverDestroyed<RetainPtr<WKNetworkSessionDelegateAllowingOnlyNonRedirectedJSON>> delegate = adoptNS([WKNetworkSessionDelegateAllowingOnlyNonRedirectedJSON new]);
    static NeverDestroyed<RetainPtr<NSURLSession>> session = [&] {
        RetainPtr configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.get().HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.get().URLCredentialStorage = nil;
        configuration.get().URLCache = nil;
        configuration.get().HTTPCookieStorage = nil;
        configuration.get()._shouldSkipPreferredClientCertificateLookup = YES;
        return [NSURLSession sessionWithConfiguration:configuration.get() delegate:delegate.get().get() delegateQueue:[NSOperationQueue mainQueue]];
    }();
    return session.get().get();
}

#endif // MAVERICKS_BACKPORT: shared stateless curl client below.

namespace WebKit::PCM {

enum class LoadTaskIdentifierType { };
using LoadTaskIdentifier = ObjectIdentifier<LoadTaskIdentifierType>;
class LoadTask;
static HashMap<LoadTaskIdentifier, Ref<LoadTask>>& taskMap();

class LoadTask final : public RefCounted<LoadTask>, public WebCore::CocoaCurlTransferClient {
public:
    static Ref<LoadTask> create(LoadTaskIdentifier identifier, NSURLRequest *request, NetworkLoader::Callback&& callback)
    {
        return adoptRef(*new LoadTask(identifier, request, WTF::move(callback)));
    }
    ~LoadTask()
    {
        m_transfer->invalidateClient();
    }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    void start() { m_transfer->start(); }
private:
    LoadTask(LoadTaskIdentifier identifier, NSURLRequest *request, NetworkLoader::Callback&& callback)
        : m_identifier(identifier)
        , m_callback(WTF::move(callback))
    {
        static NeverDestroyed<Ref<WebCore::CocoaCurlConnectionPool>> pool(WebCore::CocoaCurlConnectionPool::create());
        WebCore::CocoaCurlTransferOptions options;
        options.request = WebCore::ResourceRequest(request);
        options.request.setAllowCookies(false);
        if (auto body = options.request.httpBody())
            options.upload = WebCore::CocoaCurlUploadBody::create(*body);
        options.allowedServerTrust = allowedLocalTestServerTrust();
        m_transfer = WebCore::CocoaCurlConnection::create(pool.get(), *this, WTF::move(options));
    }
    // MAVERICKS_BACKPORT: PCM uses a stateless request with no cookie jar.
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(WebCore::CocoaCurlTransferResponse&& response, CompletionHandler<void()>&& completion) final
    {
        if (!WebCore::MIMETypeRegistry::isSupportedJSONMIMEType(response.response.mimeType()))
            m_transfer->cancel();
        completion();
    }
    void curlReceivedInformationalResponse(WebCore::ResourceResponse&&) final { }
    void curlSentData(uint64_t, uint64_t) final { }
    void curlReceivedData(const WebCore::SharedBuffer& data, CompletionHandler<void()>&& completion) final
    {
        m_body.append(data);
        completion();
    }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final
    {
        // PCM's stateless request policy does not select a client identity.
        completion(nullptr, nullptr);
    }
    void curlCompleted(const WebCore::ResourceError& error, const WebCore::NetworkLoadMetrics&) final
    {
        Ref protectedThis { *this };
        taskMap().remove(m_identifier);
        if (!error.isNull()) {
            m_callback(error.localizedDescription(), nullptr);
            return;
        }
        auto data = m_body.takeBufferAsContiguous();
        auto value = JSON::Value::parseJSON(String::fromUTF8(data->span()));
        m_callback({ }, value ? value->asObject() : nullptr);
    }
    LoadTaskIdentifier m_identifier;
    NetworkLoader::Callback m_callback;
    RefPtr<WebCore::CocoaCurlConnection> m_transfer;
    WebCore::SharedBufferBuilder m_body;
};

static HashMap<LoadTaskIdentifier, Ref<LoadTask>>& taskMap()
{
    static NeverDestroyed<HashMap<LoadTaskIdentifier, Ref<LoadTask>>> map;
    return map;
}

void NetworkLoader::allowTLSCertificateChainForLocalPCMTesting(const WebCore::CertificateInfo& certificateInfo)
{
    allowedLocalTestServerTrust() = certificateInfo.trust();
}

void NetworkLoader::start(URL&& url, RefPtr<JSON::Object>&& jsonPayload, WebCore::PrivateClickMeasurement::PcmDataCarried pcmDataCarried, Callback&& callback)
{
    // Prevent contacting non-local servers when a test certificate chain is used for 127.0.0.1.
    // FIXME: Use a proxy server to have tests cover the reports sent to the destination, too.
    if (allowedLocalTestServerTrust() && url.host() != "127.0.0.1"_s)
        return callback({ }, { });

    auto request = adoptNS([[NSMutableURLRequest alloc] initWithURL:url.createNSURL().get()]);
    [request setValue:WebCore::HTTPHeaderValues::maxAge0().createNSString().get() forHTTPHeaderField:@"Cache-Control"];
    [request setValue:WebCore::standardUserAgentWithApplicationName({ }).createNSString().get() forHTTPHeaderField:@"User-Agent"];
    if (jsonPayload) {
        request.get().HTTPMethod = @"POST";
        [request setValue:WebCore::HTTPHeaderValues::applicationJSONContentType().createNSString().get() forHTTPHeaderField:@"Content-Type"];
        auto body = jsonPayload->toJSONString().utf8();
        request.get().HTTPBody = toNSData(byteCast<uint8_t>(body.span())).get();
    }

    setPCMDataCarriedOnRequest(pcmDataCarried, request.get());

    auto identifier = LoadTaskIdentifier::generate();
    // MAVERICKS_BACKPORT: each PCM report is an unredirected, credential-free curl transaction.
#if 0
    RetainPtr task = [statelessSessionWithoutRedirectsSingleton() dataTaskWithRequest:request.get() completionHandler:makeBlockPtr([callback = WTF::move(callback), identifier](NSData *data, NSURLResponse *response, NSError *error) mutable {
        taskMap().remove(identifier);
        if (error)
            return callback(error.localizedDescription, { });
        if (auto jsonValue = JSON::Value::parseJSON(String::fromUTF8(span(data))))
            return callback({ }, jsonValue->asObject());
        callback({ }, nullptr);
    }).get()];
    [task resume];
    taskMap().add(identifier, task.get());
#endif // MAVERICKS_BACKPORT: native values feed the common curl transport.
    auto task = LoadTask::create(identifier, request.get(), WTF::move(callback));
    taskMap().add(identifier, task.copyRef());
    task->start();
}

} // namespace WebKit::PCM
