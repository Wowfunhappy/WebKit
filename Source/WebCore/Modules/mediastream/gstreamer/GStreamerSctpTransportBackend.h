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

#pragma once

#if ENABLE(WEB_RTC) && USE(GSTREAMER_WEBRTC)

#include "GRefPtrGStreamer.h"
#include "RTCSctpTransportBackend.h"
// MAVERICKS_BACKPORT: ThreadSafeRefCounted base for the AliveGuard the SCTP-thread notify::state callback keeps alive.
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>

typedef struct _GstWebRTCSCTPTransport GstWebRTCSCTPTransport;

namespace WebCore {

class GStreamerSctpTransportBackend final : public RTCSctpTransportBackend, public CanMakeWeakPtr<GStreamerSctpTransportBackend> {
    WTF_MAKE_TZONE_ALLOCATED(GStreamerSctpTransportBackend);
public:
    explicit GStreamerSctpTransportBackend(GRefPtr<GstWebRTCSCTPTransport>&&);
    ~GStreamerSctpTransportBackend();

protected:
    void stateChanged();

private :
    // RTCSctpTransportBackend
    const void* backend() const final { return m_backend.get(); }
    UniqueRef<RTCDtlsTransportBackend> dtlsTransportBackend() final;
    void registerClient(RTCSctpTransportBackendClient&) final;
    void unregisterClient() final;

    // MAVERICKS_BACKPORT: notify::state fires on the SCTP/usrsctp thread and this backend is not
    // ref-counted. The signal callback must not capture a raw `this` (g_signal_handler_disconnect does
    // not wait for an in-flight emission on another thread). It holds this thread-safe guard instead
    // and marshals to the main thread; `backend` is only ever read/written on the main thread (see
    // registerClient), so a notification arriving after teardown finds it null. Thread-safe-refcounted
    // so the SCTP thread can keep the guard alive while it posts.
    class AliveGuard : public ThreadSafeRefCounted<AliveGuard> {
    public:
        static Ref<AliveGuard> create(GStreamerSctpTransportBackend& backend) { return adoptRef(*new AliveGuard(backend)); }
        GStreamerSctpTransportBackend* backend { nullptr };
    private:
        explicit AliveGuard(GStreamerSctpTransportBackend& backendRef) : backend(&backendRef) { }
    };

    GRefPtr<GstWebRTCSCTPTransport> m_backend;
    WeakPtr<RTCSctpTransportBackendClient> m_client;
    // MAVERICKS_BACKPORT: the AliveGuard ref and stored notify::state handler id back the cross-thread-safe SCTP-thread callback teardown.
    const Ref<AliveGuard> m_guard;
    unsigned long m_stateSignalHandler { 0 };
};

} // namespace WebCore

#endif // ENABLE(WEB_RTC) && USE(GSTREAMER_WEBRTC)
