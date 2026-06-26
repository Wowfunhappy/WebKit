/*
 *  Copyright (C) 2019-2022 Igalia S.L. All rights reserved.
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

#if USE(GSTREAMER_WEBRTC)

#include "GRefPtrGStreamer.h"
#include "GUniquePtrGStreamer.h"
#include "RTCDataChannelHandler.h"
#include "RTCDataChannelState.h"
#include "SharedBuffer.h"

#include <wtf/Condition.h>
#include <wtf/Lock.h>
#include <wtf/TZoneMalloc.h>
// MAVERICKS_BACKPORT: base class for the DataChannelHandlerGuard alive-guard below.
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/WeakPtr.h>

namespace WebCore {

class Document;
// MAVERICKS_BACKPORT: forward-declared for the DataChannelHandlerGuard alive-guard below.
class GStreamerDataChannelHandler;
class RTCDataChannelEvent;
class RTCDataChannelHandlerClient;
struct RTCDataChannelInit;

// MAVERICKS_BACKPORT: the GstWebRTCDataChannel GObject signals (on-message-*, notify::*, on-error,
// on-close) fire on GStreamer's streaming thread and deref the (non-refcounted) handler. The handler is
// destroyed on the main thread; g_signal_handler_disconnect does NOT wait for an in-flight handler on
// another thread, so a signal racing setup/teardown used to deref freed memory → heap corruption (#94,
// observed as a garbage GstSample on the CoreAudio thread). This shared guard lets every signal check,
// under a lock, whether the handler is still alive; the handler nulls it (under the same lock) before
// teardown, so an in-flight signal either completes before destruction or is skipped.
class DataChannelHandlerGuard : public ThreadSafeRefCounted<DataChannelHandlerGuard> {
public:
    static Ref<DataChannelHandlerGuard> create(GStreamerDataChannelHandler& handler) { return adoptRef(*new DataChannelHandlerGuard(handler)); }
    Lock lock;
    GStreamerDataChannelHandler* handler { nullptr };
private:
    explicit DataChannelHandlerGuard(GStreamerDataChannelHandler& handlerRef) : handler(&handlerRef) { }
};

class GStreamerDataChannelHandler final : public RTCDataChannelHandler {
    WTF_MAKE_TZONE_ALLOCATED(GStreamerDataChannelHandler);
public:
    explicit GStreamerDataChannelHandler(GRefPtr<GstWebRTCDataChannel>&&);
    ~GStreamerDataChannelHandler();

    RTCDataChannelInit dataChannelInit() const;
    String label() const;

    static GUniquePtr<GstStructure> fromRTCDataChannelInit(const RTCDataChannelInit&);

    const GstWebRTCDataChannel* channel() const { return m_channel.get(); }

private:
    // RTCDataChannelHandler API
    void setClient(RTCDataChannelHandlerClient&, std::optional<ScriptExecutionContextIdentifier>) final;
    bool sendStringData(const CString&) final;
    bool sendRawData(std::span<const uint8_t>) final;
    std::optional<unsigned short> id() const final;
    void close() final;

    void onMessageData(GBytes*);
    void onMessageString(CStringView);
    void onError(GError*);
    void onClose();
    void readyStateChanged();
    void bufferedAmountChanged(size_t);

    bool checkState();
    void postTask(Function<void()>&&);

    struct StateChange {
        RTCDataChannelState state;
        std::optional<GError*> error;
    };
    using Message = Variant<StateChange, String, Ref<FragmentedSharedBuffer>>;
    using PendingMessages = Vector<Message>;

    Lock m_clientLock;
    GRefPtr<GstWebRTCDataChannel> m_channel;
    std::optional<WeakPtr<RTCDataChannelHandlerClient>> m_client WTF_GUARDED_BY_LOCK(m_clientLock);
    Markable<ScriptExecutionContextIdentifier> m_contextIdentifier;
    PendingMessages m_pendingMessages WTF_GUARDED_BY_LOCK(m_clientLock);

    std::optional<size_t> m_cachedBufferedAmount;
    bool m_closing { false };

    String m_channelId;

    Vector<unsigned long, 6> m_signalHandlers;

    // MAVERICKS_BACKPORT: keeps the GObject signal handlers from deref'ing this handler after it is
    // destroyed (see DataChannelHandlerGuard). Shared with every per-signal DataChannelNotifier.
    const Ref<DataChannelHandlerGuard> m_guard;
};

} // namespace WebCore

#endif // USE(GSTREAMER_WEBRTC)
