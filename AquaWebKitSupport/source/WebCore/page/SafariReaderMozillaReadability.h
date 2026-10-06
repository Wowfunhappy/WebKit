#pragma once

#include "PlatformExportMacros.h"
#include <wtf/Noncopyable.h>

namespace WebCore {

// Puts Mozilla's Readability behind Safari 7's Reader: Safari's own article finder runs against
// documents built from Firefox's Reader View verdict and Readability's article rather than against
// the page itself. Safari only.
WEBCORE_EXPORT void installMozillaReadabilityForSafariReader();

// Held while the injected bundle handles a message from the UI process or a finished load. Safari
// evaluates its Reader article finder in a page's main frame then only to show the page in Reader or
// to save it to the Reading List; that evaluation runs against the article Mozilla's Readability
// extracts.
class SafariReaderMozillaReadabilityArticleScope {
    WTF_MAKE_NONCOPYABLE(SafariReaderMozillaReadabilityArticleScope);
public:
    WEBCORE_EXPORT SafariReaderMozillaReadabilityArticleScope();
    WEBCORE_EXPORT ~SafariReaderMozillaReadabilityArticleScope();
};

} // namespace WebCore
