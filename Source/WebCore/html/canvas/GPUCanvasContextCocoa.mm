// MAVERICKS_BACKPORT: build glue. WebGPU is OFF on Mac (ENABLE_WEBGPU OFF / GPU_PROCESS OFF);
// the Metal/GPU-process plumbing this TU implements is non-functional on 10.9. Body gutted to
// an empty translation unit so the build links without the WebGPU canvas-context backend.
#include "config.h"
