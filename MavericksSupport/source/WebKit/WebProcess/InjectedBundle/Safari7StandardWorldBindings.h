#pragma once

namespace WebCore {
class DOMWrapperWorld;
}

namespace WebKit {

class WebFrame;

void applyModernSafariStandardWorldBindings(WebFrame&, WebCore::DOMWrapperWorld&);

}
