// Where this port keeps GStreamer's plugins and its plugin registry.
//
// The plugins ship inside WebCore.framework rather than at the prefix libgstreamer was compiled with,
// and the registry belongs in a cache directory a sandboxed process can write. Both are decided before
// gst_init() reads them, and both are this port's packaging rather than anything upstream describes, so
// they live here rather than in GStreamerCommon.cpp.

#pragma once

namespace WebCore {

void configureGStreamerCacheLocation();
void configureGStreamerPluginPath();

} // namespace WebCore
