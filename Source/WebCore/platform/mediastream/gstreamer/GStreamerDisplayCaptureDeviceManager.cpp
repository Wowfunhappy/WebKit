/*
 * Copyright (C) 2018 Metrological Group B.V.
 * Author: Thibault Saunier <tsaunier@igalia.com>
 * Author: Alejandro G. Castro <alex@igalia.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * aint with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

#include "config.h"

#if ENABLE(MEDIA_STREAM) && USE(GSTREAMER)
#include "GStreamerCaptureDeviceManager.h"

#include "GStreamerVideoCaptureSource.h"
#include "PipeWireCaptureDevice.h"
#include <wtf/UUID.h>
#include <wtf/glib/GMallocString.h>
#include <wtf/glib/GUniquePtr.h>
#include <wtf/text/MakeString.h>

#if PLATFORM(MAC)
#include <CoreGraphics/CoreGraphics.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/text/StringToIntegerConversion.h>
#endif

namespace WebCore {

#if PLATFORM(MAC)
// MAVERICKS_BACKPORT: macOS has no xdg-desktop-portal / PipeWire, so the portal path below can never
// work here. The vendored applemedia avfvideosrc element supports screen capture natively
// (capture-screen=true, AVCaptureScreenInput, 10.7+). Wrap each active display in a minimal
// GstDevice whose create_element vtable returns a configured avfvideosrc, so the stock
// GStreamerCapturer device pipeline (gst_device_create_element / gst_device_get_caps) works
// unchanged.

struct WebKitMacScreenCaptureDevice {
    GstDevice parent;
    guint deviceIndex;
};

struct WebKitMacScreenCaptureDeviceClass {
    GstDeviceClass parentClass;
};

G_DEFINE_TYPE(WebKitMacScreenCaptureDevice, webkit_mac_screen_capture_device, GST_TYPE_DEVICE)

static GstElement* webkitMacScreenCaptureDeviceCreateElement(GstDevice* device, const char* name)
{
    auto* self = reinterpret_cast<WebKitMacScreenCaptureDevice*>(device);
    auto* element = gst_element_factory_make("avfvideosrc", name);
    if (!element)
        return nullptr;
    g_object_set(element, "capture-screen", TRUE, "capture-screen-cursor", TRUE, "device-index", self->deviceIndex, nullptr);
    return element;
}

static void webkit_mac_screen_capture_device_class_init(WebKitMacScreenCaptureDeviceClass* klass)
{
    GST_DEVICE_CLASS(klass)->create_element = webkitMacScreenCaptureDeviceCreateElement;
}

static void webkit_mac_screen_capture_device_init(WebKitMacScreenCaptureDevice*)
{
}

static constexpr auto macScreenPersistentIdPrefix = "mac-screen-"_s;

static GRefPtr<GstDevice> createMacScreenCaptureGstDevice(unsigned displayIndex, const String& label)
{
    CGDirectDisplayID displays[32];
    uint32_t displayCount = 0;
    CGGetActiveDisplayList(32, displays, &displayCount);
    if (displayIndex >= displayCount)
        return nullptr;

    auto displayID = displays[displayIndex];
    int width = static_cast<int>(CGDisplayPixelsWide(displayID));
    int height = static_cast<int>(CGDisplayPixelsHigh(displayID));
    // The framerate range matters: GStreamerVideoCaptureSource::generatePresets() builds a
    // VideoPreset per caps structure and crashes on structures with no framerate information.
    auto caps = adoptGRef(gst_caps_new_simple("video/x-raw", "width", G_TYPE_INT, width, "height", G_TYPE_INT, height, "framerate", GST_TYPE_FRACTION_RANGE, 1, 1, 60, 1, nullptr));
    GRefPtr<GstDevice> device = adoptGRef(GST_DEVICE(g_object_new(webkit_mac_screen_capture_device_get_type(), "display-name", label.utf8().data(), "device-class", "Video/Source", "caps", caps.get(), nullptr)));
    reinterpret_cast<WebKitMacScreenCaptureDevice*>(device.get())->deviceIndex = displayIndex;
    return device;
}
#endif // PLATFORM(MAC)

GStreamerDisplayCaptureDeviceManager& GStreamerDisplayCaptureDeviceManager::singleton()
{
    static NeverDestroyed<GStreamerDisplayCaptureDeviceManager> manager;
    return manager;
}

GStreamerDisplayCaptureDeviceManager::GStreamerDisplayCaptureDeviceManager()
{
}

GStreamerDisplayCaptureDeviceManager::~GStreamerDisplayCaptureDeviceManager()
{
    for (auto& sourceId : m_sessions.keys())
        stopSource(sourceId);
}

void GStreamerDisplayCaptureDeviceManager::computeCaptureDevices(CompletionHandler<void()>&& callback)
{
    m_devices.clear();

#if PLATFORM(MAC)
    // MAVERICKS_BACKPORT: one device per active display, with a stable persistent id carrying the
    // display index (see the avfvideosrc device wrapper above).
    uint32_t displayCount = 0;
    CGGetActiveDisplayList(0, nullptr, &displayCount);
    for (uint32_t i = 0; i < displayCount; ++i) {
        CaptureDevice screenCaptureDevice(makeString(macScreenPersistentIdPrefix, i), CaptureDevice::DeviceType::Screen, displayCount > 1 ? makeString("Screen "_s, i + 1) : String("Screen"_s));
        screenCaptureDevice.setEnabled(true);
        m_devices.append(WTF::move(screenCaptureDevice));
    }
#else
    CaptureDevice screenCaptureDevice(createVersion4UUIDString(), CaptureDevice::DeviceType::Screen, "Capture Screen"_s);
    screenCaptureDevice.setEnabled(true);
    m_devices.append(WTF::move(screenCaptureDevice));
#endif
    callback();
}

CaptureSourceOrError GStreamerDisplayCaptureDeviceManager::createDisplayCaptureSource(const CaptureDevice& device, MediaDeviceHashSalts&& hashSalts, const MediaConstraints* constraints)
{
#if PLATFORM(MAC)
    // MAVERICKS_BACKPORT: macOS path — capture via avfvideosrc capture-screen (see wrapper above);
    // the portal/PipeWire flow below requires a Linux desktop session.
    if (isInWebProcess())
        ensureGStreamerInitialized();
    else
        ensureGStreamerInitializedNonWebProcess();

    unsigned displayIndex = 0;
    auto& persistentId = device.persistentId();
    if (persistentId.startsWith(macScreenPersistentIdPrefix))
        displayIndex = parseInteger<unsigned>(StringView(persistentId).substring(macScreenPersistentIdPrefix.length())).value_or(0);

    auto gstDevice = createMacScreenCaptureGstDevice(displayIndex, device.label());
    if (!gstDevice)
        return CaptureSourceOrError({ { }, MediaAccessDenialReason::HardwareError });

    GStreamerCaptureDevice screenDevice(WTF::move(gstDevice), persistentId, CaptureDevice::DeviceType::Screen, device.label());
    screenDevice.setEnabled(true);
    return GStreamerVideoCaptureSource::createFromGStreamerDevice(WTF::move(screenDevice), WTF::move(hashSalts), constraints);
#endif

    const auto it = m_sessions.find(device.persistentId());
    if (it != m_sessions.end()) {
        auto& node = it->value;
        PipeWireCaptureDevice pipewireCaptureDevice { *node, device.persistentId(), device.type(), device.label(), device.groupId() };
        return GStreamerVideoCaptureSource::createPipewireSource(WTF::move(pipewireCaptureDevice), WTF::move(hashSalts), constraints);
    }

    if (!m_portal)
        m_portal = DesktopPortalScreenCast::create();
    if (!m_portal)
        return CaptureSourceOrError({ { }, MediaAccessDenialReason::PermissionDenied });

    auto session = m_portal->createScreencastSession();
    if (!session)
        return CaptureSourceOrError({ { }, MediaAccessDenialReason::PermissionDenied });

    // FIXME: Maybe check this depending on device.type().
    auto outputType = GStreamerDisplayCaptureDeviceManager::PipeWireOutputType::Monitor | GStreamerDisplayCaptureDeviceManager::PipeWireOutputType::Window;

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(static_cast<uint32_t>(outputType)));
    g_variant_builder_add(&options, "{sv}", "multiple", g_variant_new_boolean(false));

    if (auto version = m_portal->getProperty("version")) {
        if (g_variant_get_uint32(version.get()) >= 2) {
            // Enable embedded cursor. FIXME: Should be checked in the constraints.
            g_variant_builder_add(&options, "{sv}", "cursor_mode", g_variant_new_uint32(2));
        }
    }

    auto result = session->selectSources(options);
    if (!result)
        return CaptureSourceOrError({ { }, MediaAccessDenialReason::PermissionDenied });

    GUniqueOutPtr<char> objectPathChars;
    g_variant_get(result.get(), "(o)", &objectPathChars.outPtr());
    auto objectPath = GMallocString::unsafeAdoptFromUTF8(WTF::move(objectPathChars));
    m_portal->waitResponseSignal(toCStringView(objectPath));

    result = session->start();
    if (!result)
        return CaptureSourceOrError({ { }, MediaAccessDenialReason::PermissionDenied });

    std::optional<uint32_t> nodeId;
    g_variant_get(result.get(), "(o)", &objectPathChars.outPtr());
    objectPath = GMallocString::unsafeAdoptFromUTF8(WTF::move(objectPathChars));
    m_portal->waitResponseSignal(toCStringView(objectPath), [&nodeId](GVariant* parameters) mutable {
        uint32_t portalResponse;
        GRefPtr<GVariant> responseData;
        g_variant_get(parameters, "(u@a{sv})", &portalResponse, &responseData.outPtr());

        if (portalResponse) {
            WTFLogAlways("User cancelled the Start request or an unknown error happened");
            return;
        }

        // The portal interface allows multiple streams but we care only about the first one.
        GUniqueOutPtr<GVariantIter> iter;
        if (g_variant_lookup(responseData.get(), "streams", "a(ua{sv})", &iter.outPtr())) {
            auto variant = adoptGRef(g_variant_iter_next_value(iter.get()));
            if (!variant) {
                WTFLogAlways("Stream list is empty");
                return;
            }

            uint32_t streamId;
            GRefPtr<GVariant> options;
            g_variant_get(variant.get(), "(u@a{sv})", &streamId, &options.outPtr());
            nodeId = streamId;
        }
    });

    if (!nodeId) {
        WTFLogAlways("Unable to retrieve display capture session data");
        return CaptureSourceOrError({ { } , MediaAccessDenialReason::PermissionDenied });
    }

    auto nodeData = session->openPipewireRemote();
    if (!nodeData)
        return CaptureSourceOrError({ { }, MediaAccessDenialReason::PermissionDenied });

    nodeData->objectId = *nodeId;
    PipeWireCaptureDevice pipewireCaptureDevice { *nodeData, device.persistentId(), device.type(), device.label(), device.groupId() };
    m_sessions.add(device.persistentId(), makeUnique<PipeWireNodeData>(WTF::move(*nodeData)));
    return GStreamerVideoCaptureSource::createPipewireSource(WTF::move(pipewireCaptureDevice), WTF::move(hashSalts), constraints);
}

void GStreamerDisplayCaptureDeviceManager::stopSource(const String& persistentID)
{
    if (!m_portal) [[unlikely]]
        return;

    auto session = m_sessions.take(persistentID);
    m_portal->closeSession(session->path);
}

} // namespace WebCore

#endif // ENABLE(MEDIA_STREAM) && USE(GSTREAMER)
