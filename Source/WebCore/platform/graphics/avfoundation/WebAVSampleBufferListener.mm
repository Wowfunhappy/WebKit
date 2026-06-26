// MAVERICKS_BACKPORT: gutted to an empty TU on 10.9 — the upstream AVSampleBufferVideoRenderer/audio-renderer KVO listener relies on AVFoundation notification/SPI symbols absent on 10.9; this non-critical observer is omitted.
// Stubbed for 10.9 - non-critical feature
#include "config.h"
