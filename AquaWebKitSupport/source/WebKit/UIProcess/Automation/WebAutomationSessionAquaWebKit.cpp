// The Automation backend dispatcher declares loadWebExtension and unloadWebExtension for every
// PLATFORM(MAC) build. WebAutomationSession.cpp implements them only with
// ENABLE(WK_WEB_EXTENSIONS_IN_WEBDRIVER), which this port builds without; here they answer NotImplemented.

#include "config.h"
#include "WebAutomationSession.h"

#if PLATFORM(MAC) && !ENABLE(WK_WEB_EXTENSIONS_IN_WEBDRIVER)

#include "WebAutomationSessionMacros.h"

namespace WebKit {

using namespace Inspector;

void WebAutomationSession::loadWebExtension(const Inspector::Protocol::Automation::WebExtensionResourceOptions, const String&, CommandCallback<String>&& callback)
{
    ASYNC_FAIL_WITH_PREDEFINED_ERROR(NotImplemented);
}

void WebAutomationSession::unloadWebExtension(const String&, CommandCallback<void>&& callback)
{
    ASYNC_FAIL_WITH_PREDEFINED_ERROR(NotImplemented);
}

} // namespace WebKit

#endif // PLATFORM(MAC) && !ENABLE(WK_WEB_EXTENSIONS_IN_WEBDRIVER)
