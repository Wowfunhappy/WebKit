// MAVERICKS_BACKPORT: PlatformMac.cmake lists platform/graphics/mac/FloatPointMac.mm as a WebCore source, but upstream 83b24ce never ships the file. This empty translation unit is provided so the 10.9 build's source list resolves; the actual FloatPoint<->CGPoint conversions live in platform/graphics/cg/FloatPointCG.cpp (mirrors the empty IntPointMac.mm).
#include "config.h"
