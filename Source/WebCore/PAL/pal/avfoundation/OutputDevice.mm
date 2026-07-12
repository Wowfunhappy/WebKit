// MAVERICKS_BACKPORT: emptied to an empty translation unit on 10.9 — PAL::OutputDevice wraps AVOutputDevice and its deviceFeatures/AVOutputDeviceFeature* enum (AirPlay route metadata), which are absent on 10.9; the route-picker feature is unused here.
#include "config.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#include "OutputDevice.h"

#if USE(AVFOUNDATION)

#include <pal/spi/cocoa/AVFoundationSPI.h>

#include <pal/cocoa/AVFoundationSoftLink.h>

namespace PAL {

OutputDevice::OutputDevice(RetainPtr<AVOutputDevice>&& device)
    : m_device(WTF::move(device))
{
}

String OutputDevice::name() const
{
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    return [m_device name];
ALLOW_DEPRECATED_DECLARATIONS_END
}

uint8_t OutputDevice::deviceFeatures() const
{
    auto avDeviceFeatures = [m_device deviceFeatures];
    uint8_t deviceFeatures { 0 };
    if (avDeviceFeatures & AVOutputDeviceFeatureAudio)
        deviceFeatures |= (uint8_t)DeviceFeatures::Audio;
    if (avDeviceFeatures & AVOutputDeviceFeatureScreen)
        deviceFeatures |= (uint8_t)DeviceFeatures::Screen;
    if (avDeviceFeatures & AVOutputDeviceFeatureVideo)
        deviceFeatures |= (uint8_t)DeviceFeatures::Video;
    return deviceFeatures;
}

}

#endif
MAVERICKS_BACKPORT */
