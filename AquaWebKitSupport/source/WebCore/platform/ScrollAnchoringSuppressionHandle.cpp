#include "config.h"
#include "ScrollAnchoringSuppressionHandle.h"

#include "LocalFrameView.h"
#include "ScrollableArea.h"

namespace WebCore {

ScrollAnchoringSuppressionScope* beginScrollAnchoringSuppression(LocalFrameView& view)
{
    return std::make_unique<ScrollAnchoringSuppressionScope>(view).release();
}

void endScrollAnchoringSuppression(ScrollAnchoringSuppressionScope* scope)
{
    std::unique_ptr<ScrollAnchoringSuppressionScope> { scope };
}

} // namespace WebCore
