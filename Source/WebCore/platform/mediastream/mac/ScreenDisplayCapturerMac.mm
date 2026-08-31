/*
 * Copyright (C) 2017-2021 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// MAVERICKS_BACKPORT: upstream's CGDisplayStream-backed screen capturer, serving
// DisplayCaptureSourceCocoa on systems without ScreenCaptureKit (macOS < 12.3).

#include "config.h"
#include "ScreenDisplayCapturerMac.h"

#if ENABLE(MEDIA_STREAM) && PLATFORM(MAC) && !HAVE(SCREEN_CAPTURE_KIT)

#import "ColorSpaceCG.h"
#import "Logging.h"
#import "PlatformScreen.h"
#import "RealtimeMediaSourceSettings.h"
#import "RealtimeVideoUtilities.h"
#import <AppKit/AppKit.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/StringToIntegerConversion.h>

#import "CoreVideoSoftLink.h"

extern "C" {
size_t CGDisplayModeGetPixelsWide(CGDisplayModeRef);
size_t CGDisplayModeGetPixelsHigh(CGDisplayModeRef);
}

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScreenDisplayCapturerMac);

std::optional<uint32_t> ScreenDisplayCapturerMac::updateDisplayID(uint32_t displayID)
{
    uint32_t displayCount = 0;
    auto err = CGGetActiveDisplayList(0, nullptr, &displayCount);
    if (err) {
        RELEASE_LOG(WebRTC, "CGGetActiveDisplayList() returned error %d when trying to get display count", static_cast<int>(err));
        return std::nullopt;
    }

    if (!displayCount) {
        RELEASE_LOG(WebRTC, "CGGetActiveDisplayList() returned a display count of 0");
        return std::nullopt;
    }

    Vector<CGDirectDisplayID> activeDisplays(displayCount);
    err = CGGetActiveDisplayList(displayCount, activeDisplays.mutableSpan().data(), &displayCount);
    if (err) {
        RELEASE_LOG(WebRTC, "CGGetActiveDisplayList() returned error %d when trying to get the active display list", static_cast<int>(err));
        return std::nullopt;
    }

    auto displayMask = CGDisplayIDToOpenGLDisplayMask(displayID);
    for (auto display : activeDisplays) {
        if (displayMask == CGDisplayIDToOpenGLDisplayMask(display))
            return display;
    }

    return std::nullopt;
}

ScreenDisplayCapturerMac::ScreenDisplayCapturerMac(CapturerObserver& observer, uint32_t displayID)
    : DisplayCaptureSourceCocoa::Capturer(observer)
    , m_displayID(displayID)
{
}

ScreenDisplayCapturerMac::~ScreenDisplayCapturerMac()
{
    if (m_observingDisplayChanges)
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallBack, this);

    m_currentFrame = nullptr;
}

bool ScreenDisplayCapturerMac::createDisplayStream(float frameRate)
{
    static const int screenQueueMaximumLength = 6;

    ALWAYS_LOG_IF(loggerPtr(), LOGIDENTIFIER);

    auto actualDisplayID = updateDisplayID(m_displayID);
    if (!actualDisplayID) {
        ERROR_LOG_IF(loggerPtr(), LOGIDENTIFIER, "invalid display ID: ", m_displayID);
        return false;
    }

    if (m_displayID != actualDisplayID.value()) {
        m_displayID = actualDisplayID.value();
        ALWAYS_LOG_IF(loggerPtr(), LOGIDENTIFIER, "display ID changed to ", static_cast<int>(m_displayID));
        m_displayStream = nullptr;
    }

    if (!m_displayStream) {
        auto displayMode = adoptCF(CGDisplayCopyDisplayMode(m_displayID));
        auto screenWidth = CGDisplayModeGetPixelsWide(displayMode.get());
        auto screenHeight = CGDisplayModeGetPixelsHigh(displayMode.get());
        if (!screenWidth || !screenHeight) {
            ERROR_LOG_IF(loggerPtr(), LOGIDENTIFIER, "unable to get screen width/height");
            return false;
        }

        if (!m_captureQueue)
            m_captureQueue = adoptOSObject(dispatch_queue_create("ScreenDisplayCapturerMac Capture Queue", DISPATCH_QUEUE_SERIAL));

        NSDictionary* streamOptions = @{
            (__bridge NSString *)kCGDisplayStreamMinimumFrameTime : @(1 / frameRate),
            (__bridge NSString *)kCGDisplayStreamQueueDepth : @(screenQueueMaximumLength),
            (__bridge NSString *)kCGDisplayStreamColorSpace : (__bridge id)sRGBColorSpaceSingleton(),
            (__bridge NSString *)kCGDisplayStreamShowCursor : @YES,
        };

        WeakPtr weakThis { *this };
        auto frameAvailableBlock = ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef) {

            if (!frameSurface || !displayTime)
                return;

            size_t count;
            auto* rects = CGDisplayStreamUpdateGetRects(updateRef, kCGDisplayStreamUpdateDirtyRects, &count);
            if (!rects || !count)
                return;

            RunLoop::mainSingleton().dispatch([weakThis, status, frame = DisplaySurface { frameSurface }]() mutable {
                if (!weakThis)
                    return;
                weakThis->newFrame(status, WTF::move(frame));
            });
        };

        // MAVERICKS_BACKPORT: 10.9's CGDisplayStream accepts the biplanar YUV format
        // preferedPixelBufferFormat() names, then delivers frames whose planes it never writes (measured:
        // every frame all-zero for '420v' and '420f', every frame written for 'BGRA'). BGRA is the format
        // it fills; emitFrame runs each surface through ImageTransferSessionVT into
        // preferedPixelBufferFormat() regardless.
        // m_displayStream = adoptCF(CGDisplayStreamCreateWithDispatchQueue(m_displayID, screenWidth, screenHeight, preferedPixelBufferFormat(), (__bridge CFDictionaryRef)streamOptions, m_captureQueue.get(), frameAvailableBlock));
        m_displayStream = adoptCF(CGDisplayStreamCreateWithDispatchQueue(m_displayID, screenWidth, screenHeight, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)streamOptions, m_captureQueue.get(), frameAvailableBlock));
        if (!m_displayStream) {
            ERROR_LOG_IF(loggerPtr(), LOGIDENTIFIER, "CGDisplayStreamCreate failed");
            return false;
        }
    }

    if (!m_observingDisplayChanges) {
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallBack, this);
        m_observingDisplayChanges = true;
    }

    return true;
}

bool ScreenDisplayCapturerMac::start()
{
    ALWAYS_LOG_IF(loggerPtr(), LOGIDENTIFIER);

    if (m_isRunning)
        return true;

    return startDisplayStream(m_frameRate);
}

void ScreenDisplayCapturerMac::stop()
{
    ALWAYS_LOG_IF(loggerPtr(), LOGIDENTIFIER);

    if (!m_isRunning)
        return;

    if (m_displayStream)
        CGDisplayStreamStop(m_displayStream.get());

    m_isRunning = false;
}

DisplayCaptureSourceCocoa::DisplayFrameType ScreenDisplayCapturerMac::generateFrame()
{
    return DisplayCaptureSourceCocoa::DisplayFrameType { RetainPtr<IOSurfaceRef> { m_currentFrame.ioSurface() } };
}

bool ScreenDisplayCapturerMac::startDisplayStream(float frameRate)
{
    auto actualDisplayID = updateDisplayID(m_displayID);
    if (!actualDisplayID)
        return false;

    if (m_displayID != actualDisplayID.value()) {
        m_displayID = actualDisplayID.value();
        ALWAYS_LOG_IF(loggerPtr(), LOGIDENTIFIER, "display ID changed to ", static_cast<int>(m_displayID));
    }

    if (!m_displayStream && !createDisplayStream(frameRate))
        return false;

    auto err = CGDisplayStreamStart(m_displayStream.get());
    if (err) {
        ERROR_LOG_IF(loggerPtr(), LOGIDENTIFIER, "CGDisplayStreamStart failed with error ", static_cast<int>(err));
        return false;
    }

    m_isRunning = true;
    return true;
}

void ScreenDisplayCapturerMac::commitConfiguration(const RealtimeMediaSourceSettings& settings)
{
    if (settings.frameRate())
        m_frameRate = settings.frameRate();

    if (m_isRunning && !m_displayStream)
        startDisplayStream(m_frameRate);
}

IntSize ScreenDisplayCapturerMac::intrinsicSize() const
{
    auto displayMode = adoptCF(CGDisplayCopyDisplayMode(m_displayID));
    return IntSize(static_cast<int>(CGDisplayModeGetPixelsWide(displayMode.get())), static_cast<int>(CGDisplayModeGetPixelsHigh(displayMode.get())));
}

void ScreenDisplayCapturerMac::displayWasReconfigured(CGDirectDisplayID, CGDisplayChangeSummaryFlags)
{
    // FIXME: implement!
}

void ScreenDisplayCapturerMac::displayReconfigurationCallBack(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo)
{
    if (userInfo)
        reinterpret_cast<ScreenDisplayCapturerMac *>(userInfo)->displayWasReconfigured(display, flags);
}

void ScreenDisplayCapturerMac::newFrame(CGDisplayStreamFrameStatus status, DisplaySurface&& newFrame)
{
    switch (status) {
    case kCGDisplayStreamFrameStatusFrameComplete:
        break;

    case kCGDisplayStreamFrameStatusFrameIdle:
        break;

    case kCGDisplayStreamFrameStatusFrameBlank:
        RELEASE_LOG(WebRTC, "ScreenDisplayCapturerMac::frameAvailable: kCGDisplayStreamFrameStatusFrameBlank");
        break;

    case kCGDisplayStreamFrameStatusStopped:
        RELEASE_LOG(WebRTC, "ScreenDisplayCapturerMac::frameAvailable: kCGDisplayStreamFrameStatusStopped");
        break;
    }

    m_currentFrame = WTF::move(newFrame);
}

std::optional<CaptureDevice> ScreenDisplayCapturerMac::screenCaptureDeviceWithPersistentID(const String& deviceID)
{
    auto displayID = parseInteger<uint32_t>(deviceID);
    if (!displayID) {
        RELEASE_LOG(WebRTC, "ScreenDisplayCapturerMac::screenCaptureDeviceWithPersistentID: display ID does not convert to 32-bit integer");
        return std::nullopt;
    }

    auto actualDisplayID = updateDisplayID(*displayID);
    if (!actualDisplayID)
        return std::nullopt;

    auto device = CaptureDevice(String::number(*actualDisplayID), CaptureDevice::DeviceType::Screen, "ScreenCaptureDevice"_s);
    device.setEnabled(true);
    return device;
}

void ScreenDisplayCapturerMac::screenCaptureDevices(Vector<CaptureDevice>& displays)
{
    auto screenID = displayID([NSScreen mainScreen]);
    if (CGDisplayIDToOpenGLDisplayMask(screenID)) {
        CaptureDevice displayDevice(String::number(screenID), CaptureDevice::DeviceType::Screen, "Screen 0"_s);
        displayDevice.setEnabled(true);
        displays.append(WTF::move(displayDevice));
        return;
    }

    uint32_t displayCount = 0;
    auto err = CGGetActiveDisplayList(0, nullptr, &displayCount);
    if (err) {
        RELEASE_LOG(WebRTC, "CGGetActiveDisplayList() returned error %d when trying to get display count", (int)err);
        return;
    }

    if (!displayCount) {
        RELEASE_LOG(WebRTC, "CGGetActiveDisplayList() returned a display count of 0");
        return;
    }

    Vector<CGDirectDisplayID> activeDisplays(displayCount);
    err = CGGetActiveDisplayList(displayCount, activeDisplays.mutableSpan().data(), &displayCount);
    if (err) {
        RELEASE_LOG(WebRTC, "CGGetActiveDisplayList() returned error %d when trying to get the active display list", (int)err);
        return;
    }

    int count = 0;
    for (auto displayID : activeDisplays) {
        CaptureDevice displayDevice(String::number(displayID), CaptureDevice::DeviceType::Screen, makeString("Screen "_s, String::number(count++)));
        displayDevice.setEnabled(CGDisplayIDToOpenGLDisplayMask(displayID));
        displays.append(WTF::move(displayDevice));
    }
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && PLATFORM(MAC) && !HAVE(SCREEN_CAPTURE_KIT)
