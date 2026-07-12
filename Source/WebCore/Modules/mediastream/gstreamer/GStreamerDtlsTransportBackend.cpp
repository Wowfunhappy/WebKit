/*
 *  Copyright (C) 2021-2022 Igalia S.L. All rights reserved.
 *  Copyright (C) 2022 Metrological Group B.V.
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "config.h"
#include "GStreamerDtlsTransportBackend.h"

#if ENABLE(WEB_RTC) && USE(GSTREAMER_WEBRTC)

#include "GStreamerIceTransportBackend.h"
#include "GStreamerWebRTCUtils.h"
#include <JavaScriptCore/ArrayBuffer.h>
#include <wtf/Noncopyable.h>
#include <wtf/glib/GMallocString.h>
// MAVERICKS_BACKPORT: include for the ThreadSafeWeakPtr the DTLS signal callback holds the observer through (see below).
#include <wtf/ThreadSafeWeakPtr.h>
#include <wtf/glib/GUniquePtr.h>

namespace WebCore {

GST_DEBUG_CATEGORY(webkit_webrtc_dtls_transport_debug);
#define GST_CAT_DEFAULT webkit_webrtc_dtls_transport_debug

// MAVERICKS_BACKPORT: base widened to ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr so the
// notify::state callback (which fires on GStreamer's DTLS/transport thread) can hold the observer
// through a ThreadSafeWeakPtr instead of a raw `this` — g_signal_handlers_disconnect* does not wait
// for an in-flight emission, so a raw pointer is a use-after-free when the observer is destroyed
// while the transport thread is mid-notify.
class GStreamerDtlsTransportBackendObserver final : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<GStreamerDtlsTransportBackendObserver> {
    WTF_MAKE_NONCOPYABLE(GStreamerDtlsTransportBackendObserver);
public:
    static Ref<GStreamerDtlsTransportBackendObserver> create(RTCDtlsTransportBackendClient& client, GRefPtr<GstWebRTCDTLSTransport>&& backend) { return adoptRef(*new GStreamerDtlsTransportBackendObserver(client, WTF::move(backend))); }

    void start();
    void stop();

private:
    GStreamerDtlsTransportBackendObserver(RTCDtlsTransportBackendClient&, GRefPtr<GstWebRTCDTLSTransport>&&);

    void stateChanged();

    GRefPtr<GstWebRTCDTLSTransport> m_backend;
    WeakPtr<RTCDtlsTransportBackendClient> m_client;
    // MAVERICKS_BACKPORT: retained signal-handler id so stop() disconnects exactly this notify::state handler.
    unsigned long m_stateSignalHandler { 0 };
};

GStreamerDtlsTransportBackendObserver::GStreamerDtlsTransportBackendObserver(RTCDtlsTransportBackendClient& client, GRefPtr<GstWebRTCDTLSTransport>&& backend)
    : m_backend(WTF::move(backend))
    , m_client(client)
{
    ASSERT(m_backend);
}

void GStreamerDtlsTransportBackendObserver::stateChanged()
{
    if (!m_client)
        return;

    callOnMainThread([this, protectedThis = Ref { *this }]() mutable {
        if (!m_client || !m_backend)
            return;

        GstWebRTCDTLSTransportState state;
        g_object_get(m_backend.get(), "state", &state, nullptr);

#ifndef GST_DISABLE_GST_DEBUG
        auto desc = GMallocString::unsafeAdoptFromUTF8(g_enum_to_string(GST_TYPE_WEBRTC_DTLS_TRANSPORT_STATE, state));
        GST_DEBUG_OBJECT(m_backend.get(), "DTLS transport state changed to %s", desc.utf8());
#endif

        Vector<Ref<JSC::ArrayBuffer>> certificates;

        // Access to DTLS certificates is not memory-safe in GStreamer versions older than 1.22.3.
        // See also: https://gitlab.freedesktop.org/gstreamer/gstreamer/-/commit/d9c853f165288071b63af9a56b6d76e358fbdcc2
        if (gst_check_version(1, 22, 3)) {
            GUniqueOutPtr<char> remoteCertificate;
            GUniqueOutPtr<char> certificate;
            g_object_get(m_backend.get(), "remote-certificate", &remoteCertificate.outPtr(), "certificate", &certificate.outPtr(), nullptr);
            if (remoteCertificate)
                certificates.append(JSC::ArrayBuffer::create(byteCast<uint8_t>(unsafeSpan(remoteCertificate.get()))));
            if (certificate)
                certificates.append(JSC::ArrayBuffer::create(byteCast<uint8_t>(unsafeSpan(certificate.get()))));
        }
        m_client->onStateChanged(toRTCDtlsTransportState(state), WTF::move(certificates));
    });
}

// MAVERICKS_BACKPORT: heap-held weak reference passed as signal user-data (see the class comment);
// the destroy-notify runs when the handler is disconnected or the emitting object is finalized.
struct DtlsObserverNotifier {
    ThreadSafeWeakPtr<GStreamerDtlsTransportBackendObserver> weakObserver;
    static void destruct(gpointer data, GClosure*) { delete static_cast<DtlsObserverNotifier*>(data); }
};

void GStreamerDtlsTransportBackendObserver::start()
{
    // MAVERICKS_BACKPORT: connect through a heap DtlsObserverNotifier holding a ThreadSafeWeakPtr so the
    // transport-thread notify::state callback never dereferences a destroyed observer (see the class comment).
    m_stateSignalHandler = g_signal_connect_data(m_backend.get(), "notify::state", G_CALLBACK(+[](GstWebRTCDTLSTransport*, GParamSpec*, DtlsObserverNotifier* notifier) {
        if (RefPtr observer = notifier->weakObserver.get())
            observer->stateChanged();
    }), new DtlsObserverNotifier { ThreadSafeWeakPtr<GStreamerDtlsTransportBackendObserver> { *this } }, DtlsObserverNotifier::destruct, static_cast<GConnectFlags>(0));
}

void GStreamerDtlsTransportBackendObserver::stop()
{
    m_client = nullptr;
    // MAVERICKS_BACKPORT: disconnect the retained handler id (its user-data is the heap DtlsObserverNotifier, not this).
    if (m_stateSignalHandler) {
        g_signal_handler_disconnect(m_backend.get(), m_stateSignalHandler);
        m_stateSignalHandler = 0;
    }
}

GStreamerDtlsTransportBackend::GStreamerDtlsTransportBackend(GRefPtr<GstWebRTCDTLSTransport>&& transport)
    : m_backend(WTF::move(transport))
{
    static std::once_flag debugRegisteredFlag;
    std::call_once(debugRegisteredFlag, [] {
        GST_DEBUG_CATEGORY_INIT(webkit_webrtc_dtls_transport_debug, "webkitwebrtcdtls", 0, "WebKit WebRTC DTLS Transport");
    });
    ASSERT(m_backend);
    ASSERT(isMainThread());
}

GStreamerDtlsTransportBackend::~GStreamerDtlsTransportBackend()
{
    unregisterClient();
}

UniqueRef<RTCIceTransportBackend> GStreamerDtlsTransportBackend::iceTransportBackend()
{
    return makeUniqueRef<GStreamerIceTransportBackend>(GRefPtr<GstWebRTCDTLSTransport>(m_backend));
}

void GStreamerDtlsTransportBackend::registerClient(RTCDtlsTransportBackendClient& client)
{
    m_observer = GStreamerDtlsTransportBackendObserver::create(client, GRefPtr<GstWebRTCDTLSTransport>(m_backend));
    m_observer->start();
}

void GStreamerDtlsTransportBackend::unregisterClient()
{
    if (m_observer)
        m_observer->stop();
}

#undef GST_CAT_DEFAULT

} // namespace WebCore

#endif // ENABLE(WEB_RTC) && USE(GSTREAMER_WEBRTC)
