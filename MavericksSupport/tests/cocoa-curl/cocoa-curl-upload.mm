// Checks mixed data/file upload streams, finite/to-EOF ranges, methods, and file errors through curl.
#include "config.h"
#include <WebCore/CocoaCurlConnection.h>
#include <WebCore/ResourceError.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/MainThread.h>
#include <wtf/RefCounted.h>
#include <wtf/text/MakeString.h>
#include <Foundation/Foundation.h>
#include <WebCore/FormDataStreamCocoa.h>
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
    // A request with no body at all: returns the header fields the server read, lowercased.
    RetainPtr<NSDictionary> runBodiless(const String& method, bool eventID = false, bool delegateRoundTrip = false)
    {
        Ref scheduler = CocoaCurlConnectionPool::create();
        CocoaCurlTransferOptions options(tls_protocol_version_TLSv12);
        options.request = ResourceRequest(URL { "http://127.0.0.1:18981/echo/bodiless"_s });
        options.request.setHTTPMethod(method);
        options.request.setTimeoutInterval(15);
        if (eventID)
            options.request.setHTTPHeaderField(HTTPHeaderName::LastEventID, String::fromUTF8("\xe2\x80\xa6"));
        if (delegateRoundTrip) {
            options.request.setPriority(ResourceLoadPriority::High);
            auto native = options.request.nsURLRequest(HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody);
            auto modified = adoptNS([native mutableCopy]);
            options.request.updateFromDelegatePreservingOldProperties(ResourceRequest(modified.get()));
            check(options.request.httpHeaderField(HTTPHeaderName::LastEventID) == String::fromUTF8("\xe2\x80\xa6"), "native delegate restores the Unicode event ID");
            options.request.setHTTPHeaderField(HTTPHeaderName::Cookie, "native-roundtrip=1"_s);
        }
        m_transfer = CocoaCurlConnection::create(scheduler, *this, WTF::move(options));
        m_transfer->start();
        CFRunLoopRun();
        check(!m_error, "bodiless request completes");
        auto bytes = m_body.takeBufferAsContiguous();
        NSDictionary *response = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes->span().data() length:bytes->size()] options:0 error:nil];
        check([[response objectForKey:@"method"] isEqualToString:method.createNSString().get()], "bodiless request method is preserved");
        check([[response objectForKey:@"body_hex"] isEqualToString:@""], "bodiless request sends no body");
        return [response objectForKey:@"headers"];
    }
    void run(const String& method, FormData& data, bool expectContinue, int expectedError = 0, ASCIILiteral expectedHex = "00ff333435363737383941"_s, uint64_t expectedLength = 11)
    {
        Ref scheduler = CocoaCurlConnectionPool::create();
        CocoaCurlTransferOptions options(tls_protocol_version_TLSv12);
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
            check([[response objectForKey:@"body_hex"] isEqualToString:String(expectedHex).createNSString().get()], "upload body arrives byte-for-byte");
            check([[response objectForKey:@"headers"] objectForKey:@"content-type"] == nil, "curl does not invent Content-Type");
            check(m_uploaded == expectedLength && m_uploadTotal == expectedLength, "upload progress reports actual body bytes");
            check(m_interim == (expectContinue ? 1 : 0), "Expect receives exactly one informational response");
        }
        printf("upload %s expect=%d error=%d\n", method.utf8().data(), expectContinue, m_error);
    }
private:
    void curlReceivedCookies(Vector<String>&&, const String&, const String&, CompletionHandler<void(std::optional<String>&&)>&& completion) final { completion(std::nullopt); }
    void curlReceivedResponse(CocoaCurlTransferResponse&&, CompletionHandler<void()>&& completion) final { completion(); }
    void curlReceivedInformationalResponse(ResourceResponse&& response) final { if (response.httpStatusCode() == 100) ++m_interim; }
    void curlSentData(uint64_t uploaded, uint64_t total) final { m_uploaded = uploaded; m_uploadTotal = total; }
    void curlReceivedData(const SharedBuffer& bytes, CompletionHandler<void()>&& completion) final { m_body.append(bytes); completion(); }
    void curlRequestedIdentity(CFArrayRef, CompletionHandler<void(RetainPtr<SecIdentityRef>&&, RetainPtr<CFArrayRef>&&)>&& completion) final { completion(nullptr, nullptr); }
    // The platform's own evaluation of the server chain is the answer.
    void curlRequestedServerTrust(CompletionHandler<void(bool)>&& completion) final
    {
        auto tls = m_transfer->tlsState();
        completion(tls && tls->accepted);
    }
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
        // Safari frames a bodiless request whose method is not GET or HEAD with Content-Length: 0 and
        // nothing else: the "Fetch with Chicken" line of Apple's
        // imported/w3c/web-platform-tests/fetch/api/basic/request-headers.any-expected.txt. Each method's
        // fields are GET's, plus that one.
        RetainPtr getFields = UploadProbe::create()->runBodiless("GET"_s);
        check(getFields && ![getFields objectForKey:@"content-length"] && ![getFields objectForKey:@"transfer-encoding"], "a bodiless GET carries no body framing");
        for (bool delegateRoundTrip : { false, true }) {
            auto probe = UploadProbe::create();
            auto fields = probe->runBodiless("GET"_s, true, delegateRoundTrip);
            bool matches = [[fields objectForKey:@"last-event-id"] isEqualToString:@"\u00e2\u0080\u00a6"];
            check(matches, "Last-Event-ID reaches the wire as UTF-8 exactly once");
            printf("Last-Event-ID native delegate=%d %s\n", delegateRoundTrip, matches ? "PASS" : "FAIL");
        }
        for (auto method : { "POST"_s, "PUT"_s, "PATCH"_s, "DELETE"_s, "OPTIONS"_s, "Chicken"_s }) {
            RetainPtr fields = UploadProbe::create()->runBodiless(method);
            RetainPtr expected = adoptNS([getFields mutableCopy]);
            [expected setObject:@"0" forKey:@"content-length"];
            bool matches = [fields isEqualToDictionary:expected.get()];
            check(matches, "a bodiless request's fields are GET's plus Content-Length: 0");
            printf("bodiless %s fields=%s %s\n", method.characters(), [[[fields allKeys] componentsJoinedByString:@","] UTF8String], matches ? "PASS" : "FAIL");
        }
        for (auto method : { "POST"_s, "PUT"_s, "PATCH"_s, "PROPFIND"_s, "DELETE"_s, "GET"_s }) {
            Ref probe = UploadProbe::create();
            probe->run(method, data, method == "POST"_s);
        }
        Ref missing = FormData::create();
        missing->appendData({ });
        missing->appendFileRange(String([directory stringByAppendingPathComponent:@"missing"]), 0, BlobDataItem::toEndOfFile, std::nullopt);
        check(cocoaCurlUploadLength(missing) == 0, "a missing to-EOF file has the upstream FormData zero length");
        Ref missingProbe = UploadProbe::create();
        missingProbe->run("POST"_s, missing, false, 0, ""_s, 0);
        Ref missingRange = FormData::create();
        missingRange->appendFileRange(String([directory stringByAppendingPathComponent:@"missing"]), 0, 1, std::nullopt);
        check(!cocoaCurlUploadLength(missingRange), "an explicit nonempty range requires a readable file");
        UploadProbe::create()->run("POST"_s, missingRange, false, ENOENT);
        Ref lateFailure = FormData::create();
        lateFailure->appendData(suffix);
        lateFailure->appendFileRange(String([directory stringByAppendingPathComponent:@"missing"]), 0, BlobDataItem::toEndOfFile, std::nullopt);
        // The body stream NetworkSessionCocoa hands CFNetwork.
        RetainPtr bodyStream = createHTTPBodyNSInputStream(lateFailure.copyRef());
        auto stream = RetainPtr { (__bridge CFReadStreamRef)bodyStream.get() };
        check(stream && CFReadStreamOpen(stream.get()), "composite stream opens its first readable element");
        uint8_t buffer[8];
        check(CFReadStreamRead(stream.get(), buffer, sizeof(buffer)) == 1, "composite stream returns its readable prefix");
        // The composite stream ends at a missing to-EOF file; FormDataElement counts it as zero bytes.
        CFIndex second = CFReadStreamRead(stream.get(), buffer, sizeof(buffer));
        CFStreamError streamError = CFReadStreamGetError(stream.get());
        check(!second && CFReadStreamGetStatus(stream.get()) == kCFStreamStatusAtEnd && !streamError.domain && !streamError.error,
            "upstream's composite stream ends at an element it cannot open, reporting no error");
        CFReadStreamClose(stream.get());
        Ref lateProbe = UploadProbe::create();
        lateProbe->run("POST"_s, lateFailure, false, 0, "41"_s, 1);
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        printf("Cocoa curl uploads: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
