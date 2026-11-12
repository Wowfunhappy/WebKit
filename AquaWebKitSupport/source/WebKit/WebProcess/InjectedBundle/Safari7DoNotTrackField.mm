// Safari 7's bundle sets DNT on the NSURLRequest it returns from willSendRequestForFrame; the
// browser this WebKit reports itself as sends no such field.
//
// WebKit reads the returned request's fields back out of -[NSURLRequest allHTTPHeaderFields], so the
// field leaves the NSURLRequest before WebKit reads it.

#import "config.h"
#import "Safari7DoNotTrackField.h"

#import <WebCore/ResourceRequest.h>
#import <wtf/RetainPtr.h>
#import <wtf/cocoa/RuntimeApplicationChecksCocoa.h>

namespace WebKit {

WebCore::ResourceRequest requestWithoutSafari7DoNotTrackField(const WebCore::ResourceRequest& returnedRequest)
{
    if (!WTF::MacApplication::isSafari())
        return returnedRequest;

    NSURLRequest *platformRequest = returnedRequest.nsURLRequest(WebCore::HTTPBodyUpdatePolicy::DoNotUpdateHTTPBody);
    if (![platformRequest valueForHTTPHeaderField:@"DNT"])
        return returnedRequest;

    RetainPtr<NSMutableURLRequest> withoutField = adoptNS([platformRequest mutableCopy]);
    [withoutField setValue:nil forHTTPHeaderField:@"DNT"];
    return WebCore::ResourceRequest { withoutField.get() };
}

}
