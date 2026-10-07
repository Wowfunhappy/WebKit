// This port's BidiBrowserAgent::platformCreateUserContext. The port is USE(GLIB) for GStreamer, so
// BidiBrowserAgent.cpp leaves the function to a platform file, and the GLib one
// (glib/BidiBrowserAgentGlib.cpp) needs the GTK/WPE API layer this port does not have.

#include "config.h"
#include "BidiBrowserAgent.h"

#if ENABLE(WEBDRIVER_BIDI)

#include "BidiUserContext.h"

namespace WebKit {

std::unique_ptr<BidiUserContext> BidiBrowserAgent::platformCreateUserContext(String& error)
{
    error = "User context creation is not implemented for this platform yet."_s;
    return nullptr;
}

} // namespace WebKit

#endif // ENABLE(WEBDRIVER_BIDI)
