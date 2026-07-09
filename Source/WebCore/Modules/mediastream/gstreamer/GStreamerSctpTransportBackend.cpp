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
#include "GStreamerSctpTransportBackend.h"

#if ENABLE(WEB_RTC) && USE(GSTREAMER_WEBRTC)

#include "GStreamerDtlsTransportBackend.h"
#include "GStreamerWebRTCUtils.h"
#include <wtf/TZoneMallocInlines.h>

GST_DEBUG_CATEGORY(webkit_webrtc_sctp_transport_debug);
#define GST_CAT_DEFAULT webkit_webrtc_sctp_transport_debug

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(RTCSctpTransportState);

static inline RTCSctpTransportState toRTCSctpTransportState(GstWebRTCSCTPTransportState state)
{
    switch (state) {
    case GST_WEBRTC_SCTP_TRANSPORT_STATE_NEW:
    case GST_WEBRTC_SCTP_TRANSPORT_STATE_CONNECTING:
        return RTCSctpTransportState::Connecting;
    case GST_WEBRTC_SCTP_TRANSPORT_STATE_CONNECTED:
        return RTCSctpTransportState::Connected;
    case GST_WEBRTC_SCTP_TRANSPORT_STATE_CLOSED:
        return RTCSctpTransportState::Closed;
    }

    RELEASE_ASSERT_NOT_REACHED();
}

GStreamerSctpTransportBackend::GStreamerSctpTransportBackend(GRefPtr<GstWebRTCSCTPTransport>&& transport)
    : m_backend(WTF::move(transport))
    , m_guard(AliveGuard::create(*this))
{
    static std::once_flag debugRegisteredFlag;
    std::call_once(debugRegisteredFlag, [] {
        GST_DEBUG_CATEGORY_INIT(webkit_webrtc_sctp_transport_debug, "webkitwebrtcsctp", 0, "WebKit WebRTC SCTP transport");
    });
    ASSERT(m_backend);
}

GStreamerSctpTransportBackend::~GStreamerSctpTransportBackend()
{
    unregisterClient();
}

UniqueRef<RTCDtlsTransportBackend> GStreamerSctpTransportBackend::dtlsTransportBackend()
{
    GRefPtr<GstWebRTCDTLSTransport> transport;
    g_object_get(m_backend.get(), "transport", &transport.outPtr(), nullptr);
    return makeUniqueRef<GStreamerDtlsTransportBackend>(WTF::move(transport));
}

void GStreamerSctpTransportBackend::registerClient(RTCSctpTransportBackendClient& client)
{
    ASSERT(isMainThread());
    ASSERT(!m_client);
    m_client = client;
    m_guard->backend = this;

    // MAVERICKS_BACKPORT: notify::state is emitted on GStreamer's SCTP/usrsctp thread, and this
    // backend is not ref-counted. The earlier lock-guarded design took a WTF Lock from that thread
    // and dereferenced the backend cross-thread; it raced backend teardown/GC and crashed
    // (freed AliveGuard → "Invalid value for lock"). Instead, do the minimum on the SCTP thread —
    // take a thread-safe ref to the guard (the notifier is kept alive for the duration of the
    // emission by GObject's handler ref) and marshal to the main thread. backend is then read and
    // used ONLY on the main thread, where registerClient/unregisterClient/~backend also run, so
    // there is no cross-thread access at all: an emission that arrives after teardown finds
    // guard->backend already null.
    struct Notifier {
        Ref<AliveGuard> guard;
        static void destruct(gpointer data, GClosure*) { delete static_cast<Notifier*>(data); }
    };
    m_stateSignalHandler = g_signal_connect_data(m_backend.get(), "notify::state", G_CALLBACK(+[](GstWebRTCSCTPTransport*, GParamSpec*, Notifier* notifier) {
        callOnMainThread([guard = Ref { notifier->guard.get() }] {
            if (auto* backend = guard->backend)
                backend->stateChanged();
        });
    }), new Notifier { m_guard.copyRef() }, Notifier::destruct, static_cast<GConnectFlags>(0));
}

void GStreamerSctpTransportBackend::unregisterClient()
{
    // MAVERICKS_BACKPORT: main-thread only (see registerClient). Null the backend so any marshaled
    // notification that has not yet run becomes a no-op, then disconnect.
    ASSERT(isMainThread());
    m_guard->backend = nullptr;
    if (m_stateSignalHandler) {
        g_signal_handler_disconnect(m_backend.get(), m_stateSignalHandler);
        m_stateSignalHandler = 0;
    }
    m_client.clear();
}

void GStreamerSctpTransportBackend::stateChanged()
{
    if (!m_client)
        return;

    GstWebRTCSCTPTransportState transportState;
    guint16 maxChannels;
    uint64_t maxMessageSize;
    g_object_get(m_backend.get(), "state", &transportState, "max-message-size", &maxMessageSize, "max-channels", &maxChannels, nullptr);
    GST_DEBUG("Notifying SCTP transport state, max-message-size: %" G_GUINT64_FORMAT " max-channels: %" G_GUINT16_FORMAT, maxMessageSize, maxChannels);
    callOnMainThread([weakClient = m_client, transportState, maxChannels, maxMessageSize] {
        if (RefPtr client = weakClient.get())
            client->onStateChanged(toRTCSctpTransportState(transportState), maxMessageSize, maxChannels);
    });
}

#undef GST_CAT_DEFAULT

} // namespace WebCore

#endif // ENABLE(WEB_RTC) && USE(GSTREAMER_WEBRTC)
