// MAVERICKS_BACKPORT: SharedRoutingArbitrator is gutted to an empty translation unit on 10.9; the upstream implementation drives AVAudioRoutingArbiter (a 10.10+ API absent on 10.9), so the routing-arbitration feature it backs is omitted from the backport.
// Stubbed for 10.9 - non-critical feature
#include "config.h"
