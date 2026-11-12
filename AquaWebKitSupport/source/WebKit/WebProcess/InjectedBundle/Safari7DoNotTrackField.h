#pragma once

namespace WebCore {
class ResourceRequest;
}

namespace WebKit {

// The request Safari 7's bundle returned from willSendRequestForFrame, without the DNT field the
// bundle adds.
WebCore::ResourceRequest requestWithoutSafari7DoNotTrackField(const WebCore::ResourceRequest& returnedRequest);

}
