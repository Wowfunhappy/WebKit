// 10.9 backport: RevealKit (RVPresentingContext / RVItem / RVPresenter) is macOS 10.13+ and absent on
// 10.9. The only symbol WebCore references is createRVPresentingContextWithRetainedDelegate (used by the
// force-touch dictionary-lookup popover in DictionaryLookup.mm). Return null so callers degrade
// gracefully; this also resolves the otherwise-undefined symbol that crashes WebContent once referenced.
#include "config.h"
#import "RevealUtilities.h"

#if PLATFORM(MAC)

namespace WebCore {

RetainPtr<RVPresentingContext> createRVPresentingContextWithRetainedDelegate(NSPoint, NSView *, id<RVPresenterHighlightDelegate>)
{
    return { };
}

} // namespace WebCore

#endif // PLATFORM(MAC)
