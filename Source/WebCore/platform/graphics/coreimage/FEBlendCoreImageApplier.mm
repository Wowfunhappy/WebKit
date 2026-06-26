// MAVERICKS_BACKPORT: gutted to an empty translation unit on 10.9 — the upstream FEBlend Core Image applier relies on CIFilter class-property blend-mode factory accessors (e.g. +[CIFilter multiplyBlendModeFilter]) that are unavailable on 10.9 Core Image.
// Stubbed for 10.9
#include "config.h"
