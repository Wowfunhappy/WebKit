/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// A PushServiceConnection backed by the Mozilla autopush
// service (push.services.mozilla.com) instead of the Apple Push Service. 10.9's apsd
// cannot mint web-push URL tokens (no -[APSConnection requestURLTokenForInfo:completion:]),
// so this port speaks the same WebSocket protocol Firefox uses: `hello` establishes a
// persistent user-agent id (uaid), `register` creates one channel per subscription and
// returns the public push endpoint, and `notification` messages deliver RFC 8291
// ciphertext which is handed to PushService in the exact userInfo shape apsd would use.
//
// The uaid is surfaced through the existing public-token plumbing: PushService persists
// it as the "public token" and clears every subscription when it changes, which matches
// autopush semantics (a new uaid means the server dropped all channels).
//
// The channelID -> topic map and the uaid live in MozillaPushService.plist alongside
// PushDatabase.db; autopush needs the full channel list at every `hello`, and an
// incoming notification only carries the channelID, which must map back to a topic.

#pragma once

#if USE(MOZILLA_PUSH_SERVICE)

#include "MozillaPushWebSocket.h"
#include "PushServiceConnection.h"
#include <wtf/Deque.h>
#include <wtf/HashMap.h>
#include <wtf/MonotonicTime.h>
#include <wtf/OSObjectPtr.h>
#include <wtf/RetainPtr.h>
#include <wtf/RunLoop.h>
#include <wtf/Seconds.h>
#include <wtf/spi/darwin/XPCSPI.h>

OBJC_CLASS MozillaPushServiceConnectionSocketDelegate;

namespace WebPushD {

class MozillaPushServiceConnection final : public PushServiceConnection {
public:
    // storageDirectory holds MozillaPushService.plist; pass the PushDatabase directory.
    static Ref<MozillaPushServiceConnection> create(const String& storageDirectory);
    ~MozillaPushServiceConnection();

    void subscribe(const String& topic, const Vector<uint8_t>& vapidPublicKey, SubscribeHandler&&) override;
    void unsubscribe(const String& topic, const Vector<uint8_t>& vapidPublicKey, UnsubscribeHandler&&) override;

    Vector<String> enabledTopics() override { return m_enabledTopics; }
    Vector<String> ignoredTopics() override { return m_ignoredTopics; }
    Vector<String> opportunisticTopics() override { return m_opportunisticTopics; }
    Vector<String> nonWakingTopics() override { return m_nonWakingTopics; }

    void setEnabledTopics(Vector<String>&&) override;
    void setIgnoredTopics(Vector<String>&& topics) override { m_ignoredTopics = WTF::move(topics); }
    void setOpportunisticTopics(Vector<String>&& topics) override { m_opportunisticTopics = WTF::move(topics); }
    void setNonWakingTopics(Vector<String>&& topics) override { m_nonWakingTopics = WTF::move(topics); }
    void setTopicLists(TopicLists&&) override;

    void acknowledgePushMessage(PushMessageReceipt, PushMessageDisposition) override;

    // Called by the socket delegate; main run loop only.
    void socketDidOpen();
    void socketDidReceiveMessage(NSString *);
    void socketDidClose(NSError *);
    void socketDidObserveActivity();

private:
    explicit MozillaPushServiceConnection(const String& storageDirectory);

    enum class State : uint8_t { Disconnected, Connecting, Connected };

    struct PendingSubscribe {
        String topic;
        Vector<uint8_t> vapidPublicKey;
        SubscribeHandler handler;
    };
    struct PendingUnsubscribe {
        String topic;
        UnsubscribeHandler handler;
    };
    struct InflightRegister {
        String topic;
        SubscribeHandler handler;
        std::unique_ptr<RunLoop::Timer> timeoutTimer;
    };
    struct InflightUnregister {
        String topic;
        UnsubscribeHandler handler;
        std::unique_ptr<RunLoop::Timer> timeoutTimer;
    };

    void connectIfNeeded();
    void disconnectSocket();
    void disconnectIfNoLongerNeeded();
    void scheduleReconnect();
    bool hasSubscriptionsOrPendingRequests() const;
    void updateProcessLifecycleAssertion();
    void connectionAttemptTimedOut();
    void keepAliveTimerFired();

    void sendJSONMessage(NSDictionary *);
    void sendHello();
    void flushPendingRequests();

    void handleHelloReply(NSDictionary *);
    void handleRegisterReply(NSDictionary *);
    void handleUnregisterReply(NSDictionary *);
    void handleNotification(NSDictionary *);
    void sendAckForChannel(NSString *channelID, id version, PushMessageDisposition);

    void failInflightAndPendingRequests(NSError *);

    void loadPersistentState();
    void savePersistentState();
    String persistentStatePath() const;

    String m_serverURLString;
    String m_storageDirectory;

    State m_state { State::Disconnected };
    RetainPtr<MozillaPushWebSocket> m_socket;
    RetainPtr<MozillaPushServiceConnectionSocketDelegate> m_socketDelegate;

    // This connection is the daemon's push transport, so launchd must leave the process alone for
    // as long as the transport is held: the transaction is taken while the socket is up or coming
    // back up, and dropped when the connection has nothing left to hold.
    OSObjectPtr<os_transaction_t> m_processLifecycleAssertion;

    String m_uaid;
    HashMap<String, String> m_channelToTopic;

    // Messages handed to the daemon that the server still holds a copy of, keyed by the
    // receipt that will acknowledge them. Dropped wholesale on disconnect: the server
    // replays everything unacknowledged after the next hello, so the old receipts name
    // deliveries that are about to arrive again.
    struct UnacknowledgedMessage {
        String channelID;
        RetainPtr<id> version;
    };
    HashMap<PushMessageReceipt, UnacknowledgedMessage> m_unacknowledgedMessages;
    PushMessageReceipt m_lastPushMessageReceipt { noPushMessageReceipt };

    Deque<PendingSubscribe> m_pendingSubscribes;
    Deque<PendingUnsubscribe> m_pendingUnsubscribes;
    HashMap<String, InflightRegister> m_inflightRegisters;
    HashMap<String, InflightUnregister> m_inflightUnregisters;

    unsigned m_consecutiveConnectionFailures { 0 };
    RunLoop::Timer m_reconnectTimer;
    RunLoop::Timer m_connectionAttemptTimer;
    RunLoop::Timer m_keepAliveTimer;
    MonotonicTime m_lastActivityTime;
    bool m_sentKeepAlivePing { false };

    Vector<String> m_enabledTopics;
    Vector<String> m_ignoredTopics;
    Vector<String> m_opportunisticTopics;
    Vector<String> m_nonWakingTopics;
};

} // namespace WebPushD

#endif // USE(MOZILLA_PUSH_SERVICE)
