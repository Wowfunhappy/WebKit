// MAVERICKS_BACKPORT: PlatformMac.cmake lists platform/graphics/mac/FloatSizeMac.mm as a WebCore source, but upstream 83b24ce never ships the file. This empty translation unit is provided so the 10.9 build's source list resolves; the actual FloatSize<->CGSize conversions live in platform/graphics/cg/FloatSizeCG.cpp (mirrors the empty IntSizeMac.mm).
#include "config.h"
