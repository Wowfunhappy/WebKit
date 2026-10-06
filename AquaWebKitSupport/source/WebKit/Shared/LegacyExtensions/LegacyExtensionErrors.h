// The network error names Chrome's webRequest and webNavigation events report for a failed load.

#pragma once

#include <wtf/text/ASCIILiteral.h>

namespace WebCore {
class ResourceError;
}

namespace WebKit::LegacyExtensions {

// net::ERR_BLOCKED_BY_CLIENT for a load an extension or content rule blocked; net::ERR_ABORTED for one
// cancelled, or interrupted by a policy decision; net::ERR_UNSAFE_PORT for a restricted port; otherwise
// the name of the network failure.
ASCIILiteral networkErrorName(const WebCore::ResourceError&);

} // namespace WebKit::LegacyExtensions
