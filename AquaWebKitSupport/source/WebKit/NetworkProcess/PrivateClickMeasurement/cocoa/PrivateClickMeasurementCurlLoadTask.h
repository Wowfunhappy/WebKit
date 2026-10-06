// NetworkLoader::start's request, sent over the Cocoa curl transport.
#pragma once

#include "PrivateClickMeasurementNetworkLoader.h"
#include <Security/SecTrust.h>
#include <wtf/RetainPtr.h>

OBJC_CLASS NSURLRequest;

namespace WebKit::PCM {

// A stateless request: no cookie jar, no client identity, and a server trust that also accepts
// |allowedServerTrust|. The callback takes the JSON object a JSON response carries.
void startCurlLoadTask(NSURLRequest *, const RetainPtr<SecTrustRef>& allowedServerTrust, NetworkLoader::Callback&&);

} // namespace WebKit::PCM
