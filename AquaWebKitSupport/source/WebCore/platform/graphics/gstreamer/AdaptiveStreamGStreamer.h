#pragma once

#include <gst/gst.h>
#include <optional>
#include <WebCore/PlatformTimeRanges.h>

namespace WebCore {

// Whether the adaptive demuxer in the pipeline plays a live stream, from its answer to the duration
// query: adaptivedemux2 answers TRUE with -1 for a live stream and its duration otherwise. Empty without
// an adaptive demuxer that has answered.
std::optional<bool> adaptiveStreamIsLive(GstElement* pipeline);
std::optional<PlatformTimeRanges> adaptiveStreamSeekable(GstElement* pipeline);

}
