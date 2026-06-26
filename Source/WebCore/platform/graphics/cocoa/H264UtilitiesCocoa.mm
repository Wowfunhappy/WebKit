// MAVERICKS_BACKPORT: Reduced to an empty translation unit on 10.9. The upstream createVideoInfoFromAVCC() builds an H.264 CMFormatDescription via PAL::CMVideoFormatDescriptionCreateFromH264ParameterSets, which is unavailable/unused on 10.9 (WebM/AVC sample paths route through GStreamer); the source list still compiles this file.
// Stubbed for 10.9 - media/AV
#include "config.h"
