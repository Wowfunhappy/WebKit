#pragma once
// MAVERICKS_BACKPORT: empty stub at the GPUProcess/media/ include path so the
// `#include "VideoReceiverEndpointManager.h"` references in GPUConnectionToWebProcess
// and the Remote*MediaPlayer proxies resolve. The real manager lives under media/cocoa/
// and is gated on ENABLE(LINEAR_MEDIA_PLAYER), which is off on 10.9, so this stub
// supplies no definitions.
// stubbed
