#include "config.h"
#include <WebCore/CocoaCurlTransfer.h>
#include <WebCore/CocoaMIMESniffing.h>
#include <WebCore/ResourceResponse.h>
#include <Foundation/Foundation.h>
#include <wtf/MainThread.h>
#include <array>
#include <cstdio>

using namespace WebCore;

int main()
{
    unsigned failures = 0;
    @autoreleasepool {
        WTF::initializeMainThread();
        struct Case { ASCIILiteral field; ASCIILiteral mime; ASCIILiteral charset; };
        for (auto test : {
                 Case { "text/plain;charset=gbk,text/plain"_s, "text/plain"_s, "gbk"_s },
                 Case { "text/html;charset=gbk,text/html;x=\",text/plain"_s, "text/html"_s, "gbk"_s },
                 Case { "text/plain;charset=gbk,text/html;charset=windows-1254"_s, "text/plain"_s, "gbk"_s },
                 Case { "*/*"_s, "*/*"_s, ""_s },
                 Case { "text/html,*/*"_s, "*/*"_s, ""_s } }) {
            ResourceResponse response(URL { "http://127.0.0.1/content-type"_s }, String(), 0, String());
            response.setHTTPStatusCode(200);
            response.setHTTPHeaderField(HTTPHeaderName::ContentType, test.field);
            setCocoaCurlContentType(response, test.field);
            RetainPtr native = adoptNS([[NSHTTPURLResponse alloc] initWithURL:response.url().createNSURL().get() statusCode:200 HTTPVersion:nil headerFields:@{ @"Content-Type": String(test.field).createNSString().get() }]);
            bool parsed = response.mimeType() == test.mime
                && response.mimeType() == String([native MIMEType])
                && (test.charset.isEmpty() ? response.textEncodingName().isNull() : response.textEncodingName() == test.charset)
                && response.textEncodingName() == String([native textEncodingName])
                && response.httpHeaderField(HTTPHeaderName::ContentType) == test.field;
            std::array<uint8_t, 6> body { '<', 'h', 't', 'm', 'l', '>' };
            auto sniffed = MIMESniffer::computeHTTPMIMEType(body, response.mimeType(), test.field, true);
            bool sniffing = sniffed == (test.mime == "*/*"_s ? "text/plain"_s : test.mime);
            printf("%s native MIME/charset and post-sniff type: %s\n", test.field.characters(), parsed && sniffing ? "PASS" : "FAIL");
            failures += !parsed || !sniffing;
        }
        printf("Cocoa curl Content-Type: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
