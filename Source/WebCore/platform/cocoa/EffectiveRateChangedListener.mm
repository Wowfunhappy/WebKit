// MAVERICKS_BACKPORT: this translation unit is reduced to an empty stub on 10.9. The upstream
// implementation observes CoreMedia timebase effective-rate-change notifications via
// CFNotificationCenterGetLocalCenterSingleton()/_CFNotificationObserverIsObjC, which are not
// available on macOS 10.9, so the listener is compiled out; the source remains listed in the build.
// Stubbed for 10.9
#include "config.h"
