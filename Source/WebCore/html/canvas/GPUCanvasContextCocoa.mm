// MAVERICKS_BACKPORT: build glue. WebGPU is OFF on Mac (ENABLE_WEBGPU OFF / GPU_PROCESS OFF);
// the Metal/GPU-process plumbing this TU implements is non-functional on 10.9. Body gutted to
// a single nullptr-returning factory so the build links without the WebGPU canvas-context backend.
#include "config.h"
#include "GPUCanvasContext.h"

namespace WebCore {

// The cross-platform GPUCanvasContext.cpp only defines create() for !PLATFORM(COCOA); on Cocoa the
// definition normally lives in the (here-gutted) WebGPU backend. Provide the same nullptr behaviour
// the non-Cocoa fallback uses so the symbol is DEFINED — otherwise WebCore ships an undefined
// WebCore::GPUCanvasContext::create that Safari never binds (lazy), but that breaks any flat-namespace
// /eager dlopen of a WebKit plug-in (e.g. Apple Mail's MailUIWebBundle, Spotlight's Mail.mdimporter),
// which then fails to load and leaves the rendered content blank. (#137)
std::unique_ptr<GPUCanvasContext> GPUCanvasContext::create(CanvasBase&, GPU&, Document*)
{
    return nullptr;
}

} // namespace WebCore
