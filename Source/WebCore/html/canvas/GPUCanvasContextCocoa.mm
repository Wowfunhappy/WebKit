// MAVERICKS_BACKPORT: build glue. WebGPU is OFF on Mac (ENABLE_WEBGPU OFF / GPU_PROCESS OFF);
// the Metal/GPU-process plumbing this TU implements is non-functional on 10.9. Body gutted to
// a single nullptr-returning factory so the build links without the WebGPU canvas-context backend.
// MAVERICKS_BACKPORT: build glue — include the cross-platform GPUCanvasContext.h (not the gutted Cocoa backend header).
#include "config.h"
#include "GPUCanvasContext.h"

namespace WebCore {

// MAVERICKS_BACKPORT: build glue (#137).
// The cross-platform GPUCanvasContext.cpp only defines create() for !PLATFORM(COCOA); on Cocoa the
// definition normally lives in the (here-gutted) WebGPU backend. Provide the same nullptr behaviour
// the non-Cocoa fallback uses so the symbol is DEFINED — otherwise WebCore ships an undefined
// WebCore::GPUCanvasContext::create that Safari never binds (lazy), but that breaks any flat-namespace
// /eager dlopen of a WebKit plug-in (e.g. Apple Mail's MailUIWebBundle, Spotlight's Mail.mdimporter),
// which then fails to load and leaves the rendered content blank. (#137)
std::unique_ptr<GPUCanvasContext> GPUCanvasContext::create(CanvasBase&, GPU&, Document*)
{
    // MAVERICKS_BACKPORT: build glue — WebGPU OFF on this port, so the factory returns nullptr.
    return nullptr;
}

/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
void GPUCanvasContextCocoa::unconfigure()
{
    m_presentationContext->unconfigure();
    m_configuration = std::nullopt;
    m_currentTexture = nullptr;
    m_readDisplayBuffer = nullptr;
    updateMemoryCost();
    ASSERT(!isConfigured());
}

std::optional<GPUCanvasConfiguration> GPUCanvasContextCocoa::getConfiguration() const
{
    std::optional<GPUCanvasConfiguration> configuration;
    if (m_configuration) {
        configuration.emplace(GPUCanvasConfiguration {
            m_configuration->device,
            m_configuration->format,
            m_configuration->usage,
            m_configuration->viewFormats,
            m_configuration->colorSpace,
            m_configuration->toneMapping,
            m_configuration->compositingAlphaMode,
        });
    }

    return configuration;
}

ExceptionOr<Ref<GPUTexture>> GPUCanvasContextCocoa::getCurrentTexture()
{
    if (!isConfigured())
        return Exception { ExceptionCode::InvalidStateError, "GPUCanvasContextCocoa::getCurrentTexture: canvas is not configured"_s };

    RefPtr currentTexture = m_currentTexture;
    if (currentTexture)
        return currentTexture.releaseNonNull();

    markContextChangedAndNotifyCanvasObservers();
    m_currentTexture = m_presentationContext->getCurrentTexture(m_configuration->frameCount);
    currentTexture = m_currentTexture;
    return currentTexture.releaseNonNull();
}

PixelFormat GPUCanvasContextCocoa::pixelFormat() const
{
#if ENABLE(PIXEL_FORMAT_RGBA16F)
    if (m_configuration)
        return m_configuration->toneMapping.mode == GPUCanvasToneMappingMode::Extended ? PixelFormat::RGBA16F : PixelFormat::BGRA8;
#endif
    return PixelFormat::BGRX8;
}

bool GPUCanvasContextCocoa::isOpaque() const
{
    if (m_configuration)
        return m_configuration->compositingAlphaMode == GPUCanvasAlphaMode::Opaque;
    return true;
}

DestinationColorSpace GPUCanvasContextCocoa::colorSpace() const
{
    if (!m_configuration)
        return DestinationColorSpace::SRGB();

    return toWebCoreColorSpace(m_configuration->colorSpace, m_configuration->toneMapping);
}

RefPtr<GraphicsLayerContentsDisplayDelegate> GPUCanvasContextCocoa::layerContentsDisplayDelegate()
{
    return m_layerContentsDisplayDelegate.ptr();
}

void GPUCanvasContextCocoa::present(uint32_t frameIndex)
{
    if (!m_configuration)
        return;

    m_compositingResultsNeedsUpdating = false;
    m_configuration->frameCount = (m_configuration->frameCount + 1) % m_configuration->renderBuffers.size();
    if (RefPtr currentTexture = m_currentTexture)
        currentTexture->destroy();
    m_currentTexture = nullptr;
    m_presentationContext->present(frameIndex);
}

void GPUCanvasContextCocoa::prepareForDisplay()
{
    if (!isConfigured())
        return;
    m_readDisplayBuffer = nullptr;
    updateMemoryCost();
    ASSERT(m_configuration->frameCount < m_configuration->renderBuffers.size());

    auto frameIndex = m_configuration->frameCount;
    m_compositorIntegration->prepareForDisplay(frameIndex, [weakThis = WeakPtr { *this }, frameIndex] {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;
        if (frameIndex >= protectedThis->m_configuration->renderBuffers.size())
            return;
        protectedThis->m_layerContentsDisplayDelegate->setDisplayBuffer(protectedThis->m_configuration->renderBuffers[frameIndex]);
        protectedThis->present(frameIndex);
    });
}

void GPUCanvasContextCocoa::markContextChangedAndNotifyCanvasObservers()
{
    m_compositingResultsNeedsUpdating = true;
    if (m_readDisplayBuffer) {
        m_readDisplayBuffer = nullptr;
        updateMemoryCost();
    }
    markCanvasChanged();
}

void GPUCanvasContextCocoa::updateMemoryCost() const
{
    // Computes only a rough ballpark figure to drive garbage collection.
    size_t newMemoryCost = 0;
    if (m_readDisplayBuffer)
        newMemoryCost += m_readDisplayBuffer->memoryCost();
    if (m_currentTexture)
        newMemoryCost += m_width * m_height * 4;
    CanvasRenderingContext::updateMemoryCost(newMemoryCost);
}


MAVERICKS_BACKPORT */
} // namespace WebCore
