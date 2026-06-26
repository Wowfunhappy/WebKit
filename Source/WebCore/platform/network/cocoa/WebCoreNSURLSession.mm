// MAVERICKS_BACKPORT: the AVFoundation-backed media-loader NSURLSession is replaced by an empty translation unit on 10.9; media loading is routed through the GStreamer pipeline instead, so this CFNetwork/AVFoundation resource-loader path is unused.
// Stubbed for 10.9
#include "config.h"
