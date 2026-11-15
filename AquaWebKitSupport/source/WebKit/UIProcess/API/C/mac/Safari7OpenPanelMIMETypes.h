#pragma once

#include <wtf/Forward.h>

namespace API {
class OpenPanelParameters;
}

namespace WebKit {

// The accepted MIME types Safari 7 is handed for an open panel; Safari7OpenPanelMIMETypes.mm says how they are chosen.
Vector<String> safari7OpenPanelMIMETypes(const API::OpenPanelParameters&);

}
