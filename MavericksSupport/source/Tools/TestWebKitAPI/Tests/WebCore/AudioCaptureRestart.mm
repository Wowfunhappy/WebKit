#include "config.h"
#include "Test.h"
#include <WebCore/CaptureDeviceManager.h>
#include <WebCore/CoreAudioCaptureUnit.h>
#include <WebCore/MediaDeviceHashSalts.h>
#include <WebCore/MockRealtimeMediaSourceCenter.h>
#include <WebCore/RealtimeMediaSource.h>
#include <WebCore/RealtimeMediaSourceCenter.h>
#include <WebCore/RealtimeMediaSourceFactory.h>
#include <wtf/CheckedPtr.h>
#include <wtf/MainThread.h>
#include <wtf/Scope.h>
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>

namespace TestWebKitAPI {
using namespace WebCore;

class CaptureSamples final : public RealtimeMediaSource::AudioSampleObserver, public CanMakeCheckedPtr<CaptureSamples> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(CaptureSamples);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(CaptureSamples);
public:
    OVERRIDE_ABSTRACT_CAN_MAKE_CHECKEDPTR(CanMakeCheckedPtr<CaptureSamples>);
    void audioSamplesAvailable(const WTF::MediaTime&, const PlatformAudioData&, const AudioStreamDescription&, size_t count) final { frames += count; }
    std::atomic<size_t> frames { 0 };
};

class Capture {
public:
    Capture(AudioCaptureFactory& factory, const CaptureDevice& device)
        : m_source(factory.createAudioCaptureSource(device, { "restart-persistent"_s, "restart-ephemeral"_s }, nullptr, std::nullopt).captureSource)
    {
        if (m_source) {
            m_source->addAudioSampleObserver(m_samples);
            m_source->start();
        }
    }
    ~Capture() { stop(); }
    bool receivesSamples()
    {
        if (!m_source)
            return false;
        auto deadline = CFAbsoluteTimeGetCurrent() + 3;
        while (!m_samples.frames && CFAbsoluteTimeGetCurrent() < deadline)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
        return !!m_samples.frames;
    }
    void stop()
    {
        if (!m_source)
            return;
        m_source->removeAudioSampleObserver(m_samples);
        m_source->endImmediatly();
        m_source = nullptr;
    }
private:
    CaptureSamples m_samples;
    RefPtr<RealtimeMediaSource> m_source;
};

static void checkRestart(bool reconfigure)
{
    WTF::initializeMainThread();
    MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled(true);
    auto reset = makeScopeExit([] {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        MockRealtimeMediaSourceCenter::setMockRealtimeMediaSourceCenterEnabled(false);
    });
    auto& factory = RealtimeMediaSourceCenter::singleton().audioCaptureFactory();
    auto devices = factory.audioCaptureDeviceManager().captureDevices();
    ASSERT_FALSE(devices.isEmpty());
    Capture first(factory, devices[0]);
    ASSERT_TRUE(first.receivesSamples());
    first.stop();
    auto& unit = CoreAudioCaptureUnit::defaultSingleton();
    ASSERT_FALSE(unit.hasClients());
    if (reconfigure) {
        unit.reconfigure();
        EXPECT_FALSE(unit.isRunning());
    }
    // Start within the same turn, before the previous source's deferred stop executes.
    Capture second(factory, devices[0]);
    EXPECT_TRUE(second.receivesSamples());
    EXPECT_TRUE(unit.isRunning());
}

TEST(AudioCaptureRestart, AfterLastClientReconfiguration)
{
    checkRestart(true);
}

TEST(AudioCaptureRestart, WhileStopIsPending)
{
    checkRestart(false);
}

}
