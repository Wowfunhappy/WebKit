// MAVERICKS_BACKPORT: the VP9 codec-config/capabilities path that normally lives in this translation unit
// depends on VideoToolbox/AVFoundation SPI absent from 10.9 and stays gutted (media/AV).
// VP9TestingOverrides, however, is a pure testing data-holder — a singleton of override flags with no AV
// dependency — that WebCore test support (Internals) and the GPU process reference under ENABLE(VP9).
// Restore just those methods: consumers that statically link the test support (DumpRenderTree) need them
// resolved, and in the shipping frameworks they would otherwise be undefined-dynamic-lookup symbols that
// would crash if a VP9TestingOverrides path were ever hit at runtime.
#include "config.h"

#if ENABLE(VP9)

#import "VP9UtilitiesCocoa.h"
#import <wtf/NeverDestroyed.h>

namespace WebCore {

VP9TestingOverrides& VP9TestingOverrides::singleton()
{
    static NeverDestroyed<VP9TestingOverrides> instance;
    return instance;
}

void VP9TestingOverrides::setHardwareDecoderDisabled(std::optional<bool>&& disabled)
{
    m_hardwareDecoderDisabled = WTF::move(disabled);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setVP9HardwareDecoderEnabledOverride(std::optional<bool>&& disabled)
{
    m_vp9HardwareDecoderEnabledOverride = WTF::move(disabled);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setVP9DecoderDisabled(std::optional<bool>&& disabled)
{
    m_vp9DecoderDisabled = WTF::move(disabled);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setSWVPDecodersAlwaysEnabled(bool enabled)
{
    m_swVPDecodersAlwaysEnabled = enabled;
    // We don't call the configurationChangedCallback to prevent unnecessarily starting the GPU process.
}

void VP9TestingOverrides::setVP9ScreenSizeAndScale(std::optional<ScreenDataOverrides>&& overrides)
{
    m_screenSizeAndScale = WTF::move(overrides);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(false);
}

void VP9TestingOverrides::setConfigurationChangedCallback(std::function<void(bool)>&& callback)
{
    m_configurationChangedCallback = WTF::move(callback);
}

void VP9TestingOverrides::resetOverridesToDefaultValues()
{
    setHardwareDecoderDisabled(std::nullopt);
    setVP9DecoderDisabled(std::nullopt);
    setVP9ScreenSizeAndScale(std::nullopt);
    if (m_configurationChangedCallback)
        m_configurationChangedCallback(true);
}

void VP9TestingOverrides::setShouldEnableVP9Decoder(bool enabled)
{
    m_vp9DecoderEnabled = enabled;
}

bool VP9TestingOverrides::shouldEnableVP9Decoder() const
{
    return m_vp9DecoderEnabled;
}

} // namespace WebCore

#endif // ENABLE(VP9)
