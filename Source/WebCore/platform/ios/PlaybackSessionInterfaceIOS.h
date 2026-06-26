// MAVERICKS_BACKPORT: the AVKit-based PlaybackSessionInterfaceIOS class has no 10.9 backend; the upstream
// declaration is gutted to an empty header so dependents that still #include it compile while no AVKit
// playback session interface is provided on 10.9.
#include "config.h"
