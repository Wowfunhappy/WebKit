#pragma once

#include "PlatformExportMacros.h"

namespace WebCore {

class LocalFrameView;
class ScrollAnchoringSuppressionScope;

// A ScrollAnchoringSuppressionScope over a frame view, held from outside WebCore: the Web Clip plug-in's
// injected bundle holds one over a clip's main frame from each commit until the clip has its place.
WEBCORE_EXPORT ScrollAnchoringSuppressionScope* beginScrollAnchoringSuppression(LocalFrameView&);
WEBCORE_EXPORT void endScrollAnchoringSuppression(ScrollAnchoringSuppressionScope*);

} // namespace WebCore
