// This port's GStreamer setup around gst_init(): where the plugin registry lives (a cache directory a
// sandboxed process can write, decided before gst_init() reads it), and the element ranks applied once
// it returns.

#pragma once

namespace WebCore {

void configureGStreamerCacheLocation();
void configureGStreamerFeatureRanks();

} // namespace WebCore
