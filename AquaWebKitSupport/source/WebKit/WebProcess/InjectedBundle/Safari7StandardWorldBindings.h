#pragma once

namespace WebCore {
class DOMWrapperWorld;
}

namespace WebKit {

class WebFrame;

void removeSafari7StandardWorldBindings(WebFrame&, WebCore::DOMWrapperWorld&);

}
