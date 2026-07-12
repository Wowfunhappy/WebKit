// MAVERICKS_BACKPORT: emptied to an empty translation unit on 10.9 — PAL::OutputContext wraps AVOutputContext (AirPlay audio-route picker), whose sharedSystemAudioContext/supportsMultipleOutputDevices APIs are absent on 10.9; the route-picker feature is unused here.
#include "config.h"
/* MAVERICKS_BACKPORT: upstream code kept commented so upstream merges see the original text; not built on this 10.9 backport
#include "OutputContext.h"

#if USE(AVFOUNDATION)

#include "OutputDevice.h"
#include <mutex>
#include <pal/spi/cocoa/AVFoundationSPI.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringConcatenate.h>

#include <pal/cocoa/AVFoundationSoftLink.h>

namespace PAL {

OutputContext::OutputContext(RetainPtr<AVOutputContext>&& context)
    : m_context(WTF::move(context))
{
}

std::optional<OutputContext>& OutputContext::sharedAudioPresentationOutputContext()
{
    static NeverDestroyed<std::optional<OutputContext>> sharedAudioPresentationOutputContext = [] () -> std::optional<OutputContext> {
#if PLATFORM(MAC) || PLATFORM(MACCATALYST)
        AVOutputContext* context = [getAVOutputContextClassSingleton() sharedSystemAudioContext];
#else
        auto context = [getAVOutputContextClassSingleton() sharedAudioPresentationOutputContext];
#endif
        if (!context)
            return std::nullopt;

        return OutputContext(retainPtr(context));
    }();
    return sharedAudioPresentationOutputContext;
}

bool OutputContext::supportsMultipleOutputDevices()
{
    return [m_context supportsMultipleOutputDevices];
}

String OutputContext::deviceName()
{
    if (!supportsMultipleOutputDevices())
        return [m_context deviceName];

    return makeString(interleave(outputDevices(), [](auto& device) {
        return device.name();
    }, " + "_s));
}

Vector<OutputDevice> OutputContext::outputDevices() const
{
    auto *avOutputDevices = [m_context outputDevices];
    return Vector<OutputDevice>(avOutputDevices.count, [&](size_t i) {
        return OutputDevice { retainPtr((AVOutputDevice *)avOutputDevices[i]) };
    });
}

}

#endif
MAVERICKS_BACKPORT */
