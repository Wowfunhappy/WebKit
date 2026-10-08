#pragma once

#if ENABLE(VIDEO) && USE(GSTREAMER) && PLATFORM(COCOA)

#include "ImageOrientation.h"
#include "VideoFrame.h"
#include <utility>

namespace WebCore {

std::pair<bool, VideoFrame::Rotation> videoFrameTransformation(ImageOrientation::Orientation);

} // namespace WebCore

#endif
