// Where this port keeps GStreamer's plugin registry: a cache directory a sandboxed process can write,
// decided before gst_init() reads it.

#pragma once

namespace WebCore {

void configureGStreamerCacheLocation();

} // namespace WebCore
