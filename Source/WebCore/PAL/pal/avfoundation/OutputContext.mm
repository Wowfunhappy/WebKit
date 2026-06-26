// MAVERICKS_BACKPORT: emptied to an empty translation unit on 10.9 — PAL::OutputContext wraps AVOutputContext (AirPlay audio-route picker), whose sharedSystemAudioContext/supportsMultipleOutputDevices APIs are absent on 10.9; the route-picker feature is unused here.
#include "config.h"
