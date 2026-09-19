#import "config.h"
#import "PrivateClickMeasurementCurlLoadTask.h"

#import <Foundation/Foundation.h>
#import <WebCore/CocoaCurlConnection.h>
#import <WebCore/MIMETypeRegistry.h>
#import <WebCore/ResourceError.h>
#import <WebCore/ResourceRequest.h>
#import <WebCore/SharedBuffer.h>
#import <wtf/HashMap.h>
#import <wtf/JSONValues.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/ObjectIdentifier.h>
#import <wtf/RefCounted.h>

namespace WebKit::PCM {

enum class LoadTaskIdentifierType { };
using LoadTaskIdentifier = ObjectIdentifier<LoadTaskIdentifierType>;
class LoadTask;
static HashMap<LoadTaskIdentifier, Ref<LoadTask>>& taskMap();

class LoadTask final : public RefCounted<LoadTask>, public WebCore::CocoaCurlTransferClient {
public:
    static Ref<LoadTask> create(LoadTaskIdentifier identifier, NSURLRequest *request, const RetainPtr<SecTrustRef>& allowedServerTrust, NetworkLoader::Callback&& callback)
    {
        return adoptRef(*new LoadTask(identifier, request, allowedServerTrust, WTF::move(callback)));
    }
    ~LoadTask()
    {
        m_transfer->invalidateClient();
    }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    void start() { m_transfer->start(); }
private:
    LoadTask(LoadTaskIdentifier identifier, NSURLRequest *request, const RetainPtr<SecTrustRef>& allowedServerTrust, NetworkLoader::Callback&& callback)
        : m_identifier(identifier)
        , m_callback(WTF::move(callback))
    {
        static NeverDestroyed<Ref<WebCore::CocoaCurlConnectionPool>> pool(WebCore::CocoaCurlConnectionPool::create());
        WebCore::CocoaCurlTransferOptions options(tls_protocol_version_TLSv12);
        options.request = WebCore::ResourceRequest(request);
        options.request.setAllowCookies(false);
        if (auto body = options.request.httpBody())
            options.upload = WebCore::CocoaCurlUploadBody::create(*body);
        options.allowedServerTrust = allowedServerTrust;
        m_transfer = WebCore::CocoaCurlConnection::create(pool.get(), *this, WTF::move(options));
    }
    void curlReceivedCookies(Vector<String>&&, const String&, const String&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
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
    void curlRequestedServerTrust(CompletionHandler<void(bool)>&& completion) final
    {
        // The native evaluation already folded in allowedServerTrust; the request raises no challenge of its own.
        completion(m_transfer->tlsState()->accepted);
    }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final
    {
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

void startCurlLoadTask(NSURLRequest *request, const RetainPtr<SecTrustRef>& allowedServerTrust, NetworkLoader::Callback&& callback)
{
    auto identifier = LoadTaskIdentifier::generate();
    auto task = LoadTask::create(identifier, request, allowedServerTrust, WTF::move(callback));
    taskMap().add(identifier, task.copyRef());
    task->start();
}

} // namespace WebKit::PCM
