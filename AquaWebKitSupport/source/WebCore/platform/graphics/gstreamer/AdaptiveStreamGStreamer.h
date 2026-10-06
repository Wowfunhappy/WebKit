#pragma once

#include <gst/gst.h>
#include <optional>

namespace WebCore {

// Legacy GstAdaptiveDemux answers a live stream's duration query with TRUE and -1.
std::optional<bool> legacyAdaptiveStreamIsLive(GstElement* pipeline);

}
