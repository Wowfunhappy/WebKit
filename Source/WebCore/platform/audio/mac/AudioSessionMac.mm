// MAVERICKS_BACKPORT: AudioSessionMac (Core Audio routing-arbitration / buffer-size / sample-rate / mute observation) is gutted to an empty translation unit on 10.9; the upstream implementation depends on routing-arbitration and AVFoundation soft-link paths unavailable on this OS, and the audio-session feature is not used in the 10.9 backport.
// Stubbed for 10.9 - non-critical feature
#include "config.h"
