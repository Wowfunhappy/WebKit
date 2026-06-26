// MAVERICKS_BACKPORT: Reduced to an empty translation unit on 10.9. The upstream makeNSArray(PlatformTimeRanges) builds an NSArray of CMTimeRange NSValues via PAL CoreMedia soft-links; that AVFoundation/CoreMedia helper is unused on 10.9 (media routes through GStreamer), so the body is dropped while the source list still compiles this file.
// Stubbed for 10.9 - media/AV
#include "config.h"
