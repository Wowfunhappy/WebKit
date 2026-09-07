// Checks mixed data/file upload streams, finite/to-EOF ranges, methods, and file errors through curl.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/MainThread.h>
#include <wtf/RefCounted.h>
#include <wtf/text/MakeString.h>
#include <Foundation/Foundation.h>
#include <WebCore/FormDataStreamCFNet.h>
#include <cerrno>
#include <cstdio>

using namespace WebCore;
static unsigned failures;
static void check(bool result, const char *message) { if (!result) { ++failures; printf("FAIL %s\n", message); } }
class UploadProbe final : public RefCounted<UploadProbe>, public CocoaCurlTransferClient {
public:
    static Ref<UploadProbe> create() { return adoptRef(*new UploadProbe); }
    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }
    void run(const String& method, FormData& data, bool expectContinue, int expectedError = 0)
    {
        Ref scheduler = CocoaCurlConnectionPool::create();
        CocoaCurlTransferOptions options;
        options.request = ResourceRequest(URL { "http://127.0.0.1:18981/echo/upload"_s });
        options.request.setHTTPMethod(method);
        options.request.setTimeoutInterval(15);
        if (expectContinue)
            options.request.setHTTPHeaderField(HTTPHeaderName::Expect, "100-continue"_s);
        options.upload = CocoaCurlUploadBody::create(data);
        m_transfer = CocoaCurlConnection::create(scheduler, *this, WTF::move(options));
        m_transfer->start();
        CFRunLoopRun();
        check(m_error == expectedError, "upload has the expected completion/error");
        if (!expectedError) {
            auto bytes = m_body.takeBufferAsContiguous();
            NSData *encoded = [NSData dataWithBytes:bytes->span().data() length:bytes->size()];
            NSDictionary *response = [NSJSONSerialization JSONObjectWithData:encoded options:0 error:nil];
            check([[response objectForKey:@"method"] isEqualToString:method.createNSString().get()], "request method is preserved");
            check([[response objectForKey:@"body_hex"] isEqualToString:@"00ff333435363737383941"], "mixed data and both file ranges arrive byte-for-byte");
            check([[response objectForKey:@"headers"] objectForKey:@"content-type"] == nil, "curl does not invent Content-Type");
            check(m_uploaded == 11 && m_uploadTotal == 11, "upload progress reports actual body bytes");
            check(m_interim == (expectContinue ? 1 : 0), "Expect receives exactly one informational response");
        }
        printf("upload %s expect=%d error=%d\n", method.utf8().data(), expectContinue, m_error);
    }
private:
    void curlReceivedCookies(Vector<String>&&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&& completion) final { completion(); }
    void curlReceivedInformationalResponse(ResourceResponse&& response) final { if (response.httpStatusCode() == 100) ++m_interim; }
    void curlSentData(uint64_t uploaded, uint64_t total) final { m_uploaded = uploaded; m_uploadTotal = total; }
    void curlReceivedData(const SharedBuffer& bytes, CompletionHandler<void()>&& completion) final { m_body.append(bytes); completion(); }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final { completion(nullptr, nullptr); }
    void curlCompleted(const ResourceError& error, const NetworkLoadMetrics&) final
    {
        m_error = error.errorCode();
        m_transfer->invalidateClient();
        m_transfer = nullptr;
        CFRunLoopStop(CFRunLoopGetCurrent());
    }
    RefPtr<CocoaCurlConnection> m_transfer;
    SharedBufferBuilder m_body;
    uint64_t m_uploaded { 0 };
    uint64_t m_uploadTotal { 0 };
    unsigned m_interim { 0 };
    int m_error { 0 };
};

int main()
{
    @autoreleasepool {
        setvbuf(stdout, nullptr, _IONBF, 0);
        WTF::initializeMainThread();
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        check([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil], "create isolated upload fixture directory");
        NSString *path = [directory stringByAppendingPathComponent:@"source"];
        check([[@"0123456789" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:NO], "create upload source");
        Ref data = FormData::create();
        const uint8_t prefix[] = { 0, 255 };
        const uint8_t suffix[] = { 65 };
        data->appendData(prefix);
        data->appendFileRange(String(path), 3, 5, std::nullopt);
        data->appendFileRange(String(path), 7, BlobDataItem::toEndOfFile, std::nullopt);
        data->appendData(suffix);
        data->setAlwaysStream(true);
        check(cocoaCurlUploadLength(data) == 11, "the declared curl length counts only the readable bytes of a to-EOF range");
        for (auto method : { "POST"_s, "PUT"_s, "PATCH"_s, "PROPFIND"_s, "DELETE"_s, "GET"_s }) {
            Ref probe = UploadProbe::create();
            probe->run(method, data, method == "POST"_s);
        }
        Ref missing = FormData::create();
        missing->appendData({ });
        missing->appendFileRange(String([directory stringByAppendingPathComponent:@"missing"]), 0, BlobDataItem::toEndOfFile, std::nullopt);
        check(!cocoaCurlUploadLength(missing), "missing zero-length upload element is not treated as empty data");
        Ref missingProbe = UploadProbe::create();
        // Stock reports an unreadable request body as NSPOSIXErrorDomain ENOENT.
        missingProbe->run("POST"_s, missing, false, ENOENT);
        Ref lateFailure = FormData::create();
        lateFailure->appendData(suffix);
        lateFailure->appendFileRange(String([directory stringByAppendingPathComponent:@"missing"]), 0, BlobDataItem::toEndOfFile, std::nullopt);
        // The CFNetwork body path this port still ships for NetworkDataTaskCocoa.
        auto stream = createHTTPBodyCFReadStream(lateFailure);
        check(stream && CFReadStreamOpen(stream.get()), "composite stream opens its first readable element");
        uint8_t buffer[8];
        check(CFReadStreamRead(stream.get(), buffer, sizeof(buffer)) == 1, "composite stream returns its readable prefix");
        // Measured against upstream's stream on this host: a later element it cannot open ends the
        // stream rather than failing it, so the body is truncated and the error is silent. The curl
        // transport this port loads over does not use this stream; the transfer below is its path.
        CFIndex second = CFReadStreamRead(stream.get(), buffer, sizeof(buffer));
        CFStreamError streamError = CFReadStreamGetError(stream.get());
        check(!second && CFReadStreamGetStatus(stream.get()) == kCFStreamStatusAtEnd && !streamError.domain && !streamError.error,
            "upstream's composite stream ends at an element it cannot open, reporting no error");
        CFReadStreamClose(stream.get());
        Ref lateProbe = UploadProbe::create();
        lateProbe->run("POST"_s, lateFailure, false, ENOENT);
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        printf("Cocoa curl uploads: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
