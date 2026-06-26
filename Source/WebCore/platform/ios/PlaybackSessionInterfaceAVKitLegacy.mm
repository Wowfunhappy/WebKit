// MAVERICKS_BACKPORT: AVKit-driven playback-session UI is an iOS/modern-macOS feature with no 10.9 backend; the
// upstream PlaybackSessionInterfaceAVKitLegacy implementation is gutted to an empty translation unit so the build's
// fixed source list still has a file to compile while no AVKit playback interface is provided on 10.9.
#include "config.h"
