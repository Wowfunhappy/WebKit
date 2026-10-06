#include "config.h"
#include <WebCore/CocoaCurlTransfer.h>
#include <WebCore/FormData.h>
#include <wtf/MainThread.h>
#include <Foundation/Foundation.h>
#include <cstdio>

using namespace WebCore;

int main()
{
    unsigned failures = 0;
    @autoreleasepool {
        WTF::initializeMainThread();
        for (bool streamed : { false, true }) {
            ResourceRequest original(URL { "http://127.0.0.1/redirect"_s });
            original.setHTTPMethod("POST"_s);
            original.setPriority(ResourceLoadPriority::High);
            original.setHiddenFromInspector(true);
            Ref body = FormData::create();
            const uint8_t bytes[] = { 'a', 'b', 'c' };
            body->appendData(bytes);
            body->setAlwaysStream(streamed);
            original.setHTTPBody(WTF::move(body));
            RetainPtr delegate = adoptNS([original.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody) mutableCopy]);
            [NSURLProtocol setProperty:@"preserved" forKey:@"ProbeProtocolMetadata" inRequest:delegate.get()];
            original.updateFromDelegatePreservingOldProperties(ResourceRequest(delegate.get()));
            ResourceRequest redirected = original;
            redirected.setURL(URL { "http://127.0.0.1/target"_s });
            redirected.setHTTPMethod("GET"_s);
            clearCocoaCurlHTTPBody(redirected);
            redirected.removeHTTPHeaderField(HTTPHeaderName::ContentLength);
            RetainPtr output = adoptNS([redirected.nsURLRequest(HTTPBodyUpdatePolicy::UpdateHTTPBody) mutableCopy]);
            redirected.updateFromDelegatePreservingOldProperties(ResourceRequest(output.get()));
            bool passed = ![output HTTPBody] && ![output HTTPBodyStream] && !redirected.httpBody()
                && redirected.httpHeaderField(HTTPHeaderName::ContentLength).isEmpty()
                && redirected.priority() == ResourceLoadPriority::High && redirected.hiddenFromInspector()
                && [[NSURLProtocol propertyForKey:@"ProbeProtocolMetadata" inRequest:output.get()] isEqual:@"preserved"]
                && original.httpMethod() == "POST"_s && original.httpBody();
            printf("redirect %s body remains cleared through native delegate copying: %s\n", streamed ? "stream" : "data", passed ? "PASS" : "FAIL");
            failures += !passed;
        }
        printf("Cocoa curl redirect body: FAILED=%u\n", failures);
    }
    return failures ? 1 : 0;
}
