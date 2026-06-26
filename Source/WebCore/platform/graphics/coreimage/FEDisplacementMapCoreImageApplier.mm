// MAVERICKS_BACKPORT: gutted to an empty translation unit on 10.9 — the upstream displacement-map applier builds its CIKernel via +[CIKernel kernelsWithMetalString:], a Metal-backed Core Image path that does not exist on 10.9.
// Stubbed for 10.9
#include "config.h"
