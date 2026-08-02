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

// MAVERICKS_BACKPORT: new file; see MozillaPushServiceConnection.h. Protocol reference:
// https://mozilla-push-service.readthedocs.io/en/latest/design/ plus Firefox's
// dom/push/PushServiceWebSocket.sys.mjs, and verified live against
// push.services.mozilla.com (hello/register/unregister/notification/ack, including
// stored-message replay after reconnect).

#import "config.h"
#import "MozillaPushServiceConnection.h"

#if USE(MOZILLA_PUSH_SERVICE)

#import "Logging.h"
#import <wtf/FileSystem.h>
#import <wtf/RunLoop.h>
#import <wtf/URL.h>
#import <wtf/UUID.h>
#import <wtf/cocoa/TypeCastsCocoa.h>
#import <wtf/text/Base64.h>
#import <wtf/text/WTFString.h>

static NSString * const mozillaPushErrorDomain = @"MozillaPushServiceErrorDomain";
static NSString * const defaultServerURLString = @"wss://push.services.mozilla.com/";

// A middlebox on the path (the VM's transparent proxy) reaps idle TLS connections after
// roughly a minute, and a reaped connection stays ESTABLISHED locally while delivering
// nothing — verified by pushes that arrived only after the next reconnect replayed them.
// So: probe an idle socket with the legacy `{}` JSON ping (answered in kind) once a
// minute, count any traffic including ping/pong control frames as life, and declare the
// socket dead when even the probe goes unanswered.
static const Seconds keepAliveCheckInterval = 30_s;
static const Seconds idleIntervalBeforePing = 60_s;
static const Seconds idleIntervalBeforeReconnect = 150_s;

static const Seconds connectionAttemptTimeout = 30_s;
static const Seconds requestTimeout = 30_s;

@interface MozillaPushServiceConnectionSocketDelegate : NSObject <MozillaPushWebSocketDelegate> {
@public
    WeakPtr<WebPushD::MozillaPushServiceConnection> _connection;
}
@end

@implementation MozillaPushServiceConnectionSocketDelegate

- (void)webSocketDidOpen:(MozillaPushWebSocket *)webSocket
{
    if (RefPtr connection = _connection.get())
        connection->socketDidOpen();
}

- (void)webSocket:(MozillaPushWebSocket *)webSocket didReceiveMessage:(NSString *)message
{
    if (RefPtr connection = _connection.get())
        connection->socketDidReceiveMessage(message);
}

- (void)webSocket:(MozillaPushWebSocket *)webSocket didCloseWithError:(NSError *)error
{
    if (RefPtr connection = _connection.get())
        connection->socketDidClose(error);
}

- (void)webSocketDidReceiveControlFrame:(MozillaPushWebSocket *)webSocket
{
    if (RefPtr connection = _connection.get())
        connection->socketDidObserveActivity();
}

@end

namespace WebPushD {
using namespace WebCore;

static NSError *pushServiceError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:mozillaPushErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message }];
}

Ref<MozillaPushServiceConnection> MozillaPushServiceConnection::create(const String& storageDirectory)
{
    return adoptRef(*new MozillaPushServiceConnection(storageDirectory));
}

MozillaPushServiceConnection::MozillaPushServiceConnection(const String& storageDirectory)
    : m_storageDirectory(storageDirectory)
    , m_reconnectTimer(RunLoop::mainSingleton(), "MozillaPushServiceConnection::ReconnectTimer"_s, [this] { connectIfNeeded(); })
    , m_connectionAttemptTimer(RunLoop::mainSingleton(), "MozillaPushServiceConnection::ConnectionAttemptTimer"_s, [this] { connectionAttemptTimedOut(); })
    , m_keepAliveTimer(RunLoop::mainSingleton(), "MozillaPushServiceConnection::KeepAliveTimer"_s, [this] { keepAliveTimerFired(); })
{
    // An override lets a local autopush instance stand in for Mozilla's during testing,
    // like Firefox's dom.push.serverURL pref.
    const char* serverOverride = getenv("WEBKIT_MOZILLA_PUSH_SERVER_URL");
    m_serverURLString = serverOverride && *serverOverride ? String::fromUTF8(serverOverride) : String(defaultServerURLString);

    m_socketDelegate = adoptNS([[MozillaPushServiceConnectionSocketDelegate alloc] init]);
    m_socketDelegate.get()->_connection = WeakPtr { *this };

    loadPersistentState();
}

MozillaPushServiceConnection::~MozillaPushServiceConnection()
{
    disconnectSocket();
}

// MARK: - Socket lifecycle

void MozillaPushServiceConnection::connectIfNeeded()
{
    ASSERT(RunLoop::isMain());

    if (m_state != State::Disconnected)
        return;

    URL serverURL { m_serverURLString };
    bool useTLS = !serverURL.protocolIs("ws"_s);
    NSInteger port = serverURL.port() ? *serverURL.port() : (useTLS ? 443 : 80);
    String path = serverURL.path().isEmpty() ? "/"_s : serverURL.path().toString();
    if (serverURL.host().isEmpty()) {
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: invalid push server URL %{public}s", m_serverURLString.utf8().data());
        // Queued subscribe/unsubscribe requests can never proceed against an unusable
        // URL; without this they hang their page promises forever.
        failInflightAndPendingRequests(pushServiceError(9, @"Push server URL is invalid"));
        return;
    }

    RELEASE_LOG(Push, "MozillaPushServiceConnection: connecting to %{public}s (attempt %u)", m_serverURLString.utf8().data(), m_consecutiveConnectionFailures + 1);

    m_state = State::Connecting;
    m_socket = adoptNS([[MozillaPushWebSocket alloc] initWithHost:serverURL.host().createNSString().get() port:port path:path.createNSString().get() useTLS:useTLS delegate:m_socketDelegate.get()]);
    [m_socket open];
    m_connectionAttemptTimer.startOneShot(connectionAttemptTimeout);
}

void MozillaPushServiceConnection::disconnectSocket()
{
    m_connectionAttemptTimer.stop();
    m_keepAliveTimer.stop();
    if (m_socket) {
        [m_socket invalidate];
        m_socket = nil;
    }
    m_state = State::Disconnected;
}

void MozillaPushServiceConnection::connectionAttemptTimedOut()
{
    RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: connection attempt timed out");
    disconnectSocket();
    failInflightAndPendingRequests(pushServiceError(1, @"Timed out connecting to push service"));
    scheduleReconnect();
}

void MozillaPushServiceConnection::scheduleReconnect()
{
    // Delivery only matters while subscriptions (or requests) exist; otherwise stay off
    // the network and let the next subscribe trigger a connection.
    if (m_channelToTopic.isEmpty() && m_enabledTopics.isEmpty() && m_pendingSubscribes.isEmpty() && m_pendingUnsubscribes.isEmpty())
        return;

    if (m_consecutiveConnectionFailures < 31)
        m_consecutiveConnectionFailures++;
    Seconds baseDelay = std::min(10_s * (1 << std::min(m_consecutiveConnectionFailures - 1, 7u)), 900_s);
    // Jitter by up to 25% to avoid thundering-herd reconnects.
    Seconds delay = baseDelay + baseDelay * (arc4random_uniform(250) / 1000.0);
    RELEASE_LOG(Push, "MozillaPushServiceConnection: reconnecting in %.0f seconds", delay.seconds());
    m_reconnectTimer.startOneShot(delay);
}

void MozillaPushServiceConnection::socketDidOpen()
{
    ASSERT(RunLoop::isMain());
    m_lastActivityTime = MonotonicTime::now();
    sendHello();
}

void MozillaPushServiceConnection::socketDidObserveActivity()
{
    ASSERT(RunLoop::isMain());
    m_lastActivityTime = MonotonicTime::now();
    m_sentKeepAlivePing = false;
}

void MozillaPushServiceConnection::socketDidClose(NSError *error)
{
    ASSERT(RunLoop::isMain());

    bool wasConnecting = m_state == State::Connecting;
    if (error)
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: socket closed with error: %{public}s", error.localizedDescription.UTF8String);
    else
        RELEASE_LOG(Push, "MozillaPushServiceConnection: socket closed");

    disconnectSocket();

    if (wasConnecting) {
        // The service is unreachable; give waiting subscribe/unsubscribe callers a
        // prompt failure rather than an open-ended hang.
        failInflightAndPendingRequests(pushServiceError(2, @"Could not connect to push service"));
    } else {
        NSError *interrupted = pushServiceError(3, @"Connection to push service was interrupted");
        auto inflightRegisters = std::exchange(m_inflightRegisters, { });
        for (auto& entry : inflightRegisters.values())
            entry.handler(nil, interrupted);
        auto inflightUnregisters = std::exchange(m_inflightUnregisters, { });
        for (auto& entry : inflightUnregisters.values())
            entry.handler(false, interrupted);
    }

    scheduleReconnect();
}

void MozillaPushServiceConnection::keepAliveTimerFired()
{
    if (m_state != State::Connected)
        return;

    Seconds idle = MonotonicTime::now() - m_lastActivityTime;
    if (idle >= idleIntervalBeforeReconnect && m_sentKeepAlivePing) {
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: connection is unresponsive; reconnecting");
        disconnectSocket();
        scheduleReconnect();
        return;
    }
    if (idle >= idleIntervalBeforePing && !m_sentKeepAlivePing) {
        // The legacy autopush ping: an empty JSON object, answered in kind.
        [m_socket sendMessage:@"{}"];
        m_sentKeepAlivePing = true;
    }
}

// MARK: - Protocol

void MozillaPushServiceConnection::sendJSONMessage(NSDictionary *message)
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (!data) {
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: could not serialize message: %{public}s", error.localizedDescription.UTF8String);
        return;
    }
    [m_socket sendMessage:adoptNS([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]).get()];
}

void MozillaPushServiceConnection::sendHello()
{
    auto channelIDs = adoptNS([[NSMutableArray alloc] init]);
    for (auto& channelID : m_channelToTopic.keys())
        [channelIDs addObject:channelID.createNSString().get()];

    sendJSONMessage(@{
        @"messageType": @"hello",
        @"uaid": m_uaid.isNull() ? @"" : m_uaid.createNSString().get(),
        @"channelIDs": channelIDs.get(),
        @"use_webpush": @YES,
    });
}

void MozillaPushServiceConnection::socketDidReceiveMessage(NSString *message)
{
    ASSERT(RunLoop::isMain());
    m_lastActivityTime = MonotonicTime::now();
    m_sentKeepAlivePing = false;

    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: dropping non-dictionary message");
        return;
    }
    NSDictionary *reply = parsed;

    NSString *messageType = dynamic_objc_cast<NSString>(reply[@"messageType"]);
    if (!messageType.length) {
        // The reply to a legacy `{}` keepalive ping; the activity bump above is all it's for.
        return;
    }

    if ([messageType isEqualToString:@"hello"])
        handleHelloReply(reply);
    else if ([messageType isEqualToString:@"register"])
        handleRegisterReply(reply);
    else if ([messageType isEqualToString:@"unregister"])
        handleUnregisterReply(reply);
    else if ([messageType isEqualToString:@"notification"])
        handleNotification(reply);
    else if ([messageType isEqualToString:@"broadcast"]) {
        // Firefox-specific settings broadcasts; not subscribed to any, nothing to do.
    } else
        RELEASE_LOG(Push, "MozillaPushServiceConnection: ignoring message of type %{public}s", messageType.UTF8String);
}

void MozillaPushServiceConnection::handleHelloReply(NSDictionary *reply)
{
    NSInteger status = dynamic_objc_cast<NSNumber>(reply[@"status"]).integerValue;
    NSString *uaid = dynamic_objc_cast<NSString>(reply[@"uaid"]);
    if (status != 200 || !uaid.length) {
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: hello failed with status %ld", (long)status);
        disconnectSocket();
        failInflightAndPendingRequests(pushServiceError(4, @"Push service rejected the handshake"));
        scheduleReconnect();
        return;
    }

    String newUaid { uaid };
    if (newUaid != m_uaid) {
        // A fresh uaid means the server dropped every channel this client had. Clearing
        // the map here and reporting the new "public token" below lets PushService purge
        // the now-dead subscriptions from its database.
        RELEASE_LOG(Push, "MozillaPushServiceConnection: server assigned new uaid; invalidating %u channels", m_channelToTopic.size());
        m_channelToTopic.clear();
        m_uaid = WTF::move(newUaid);
        savePersistentState();
    }

    m_state = State::Connected;
    m_consecutiveConnectionFailures = 0;
    m_connectionAttemptTimer.stop();
    m_lastActivityTime = MonotonicTime::now();
    m_sentKeepAlivePing = false;
    m_keepAliveTimer.startRepeating(keepAliveCheckInterval);

    RELEASE_LOG(Push, "MozillaPushServiceConnection: connected with uaid %{sensitive}s and %u channels", m_uaid.utf8().data(), m_channelToTopic.size());

    auto uaidBytes = m_uaid.utf8();
    didReceivePublicToken(Vector<uint8_t> { uaidBytes.span() });

    flushPendingRequests();
}

void MozillaPushServiceConnection::flushPendingRequests()
{
    auto pendingSubscribes = std::exchange(m_pendingSubscribes, { });
    while (!pendingSubscribes.isEmpty()) {
        auto request = pendingSubscribes.takeFirst();
        subscribe(request.topic, request.vapidPublicKey, WTF::move(request.handler));
    }

    auto pendingUnsubscribes = std::exchange(m_pendingUnsubscribes, { });
    while (!pendingUnsubscribes.isEmpty()) {
        auto request = pendingUnsubscribes.takeFirst();
        unsubscribe(request.topic, { }, WTF::move(request.handler));
    }
}

void MozillaPushServiceConnection::subscribe(const String& topic, const Vector<uint8_t>& vapidPublicKey, SubscribeHandler&& handler)
{
    ASSERT(RunLoop::isMain());

    if (m_state != State::Connected) {
        m_pendingSubscribes.append({ topic, vapidPublicKey, WTF::move(handler) });
        connectIfNeeded();
        return;
    }

    String channelID = WTF::UUID::createVersion4().toString();

    auto message = adoptNS([[NSMutableDictionary alloc] init]);
    [message setObject:@"register" forKey:@"messageType"];
    [message setObject:channelID.createNSString().get() forKey:@"channelID"];
    // Locks the endpoint to this application server key: pushes must carry a matching
    // VAPID JWT, and the server hands back a /wpush/v2/ endpoint.
    if (!vapidPublicKey.isEmpty())
        [message setObject:base64URLEncodeToString(vapidPublicKey.span()).createNSString().get() forKey:@"key"];

    auto timeoutTimer = makeUnique<RunLoop::Timer>(RunLoop::mainSingleton(), "MozillaPushServiceConnection::RegisterTimeout"_s, [this, weakThis = WeakPtr { *this }, channelID] {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;
        auto request = m_inflightRegisters.take(channelID);
        if (request.handler)
            request.handler(nil, pushServiceError(5, @"Timed out registering push channel"));
    });
    timeoutTimer->startOneShot(requestTimeout);
    m_inflightRegisters.set(channelID, InflightRegister { topic, WTF::move(handler), WTF::move(timeoutTimer) });

    sendJSONMessage(message.get());
}

void MozillaPushServiceConnection::handleRegisterReply(NSDictionary *reply)
{
    NSString *channelID = dynamic_objc_cast<NSString>(reply[@"channelID"]);
    if (!channelID.length)
        return;

    auto request = m_inflightRegisters.take(String { channelID });
    if (!request.handler) {
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: register reply for unknown channel");
        return;
    }

    NSInteger status = dynamic_objc_cast<NSNumber>(reply[@"status"]).integerValue;
    NSString *endpoint = dynamic_objc_cast<NSString>(reply[@"pushEndpoint"]);
    if (status != 200 || !endpoint.length) {
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: register failed with status %ld", (long)status);
        request.handler(nil, pushServiceError(status ? status : 6, @"Push service could not create a subscription"));
        return;
    }

    m_channelToTopic.set(String { channelID }, request.topic);
    savePersistentState();

    RELEASE_LOG(Push, "MozillaPushServiceConnection: registered channel for topic %{sensitive}s", request.topic.utf8().data());
    request.handler(endpoint, nil);
}

void MozillaPushServiceConnection::unsubscribe(const String& topic, const Vector<uint8_t>&, UnsubscribeHandler&& handler)
{
    ASSERT(RunLoop::isMain());

    String channelID;
    for (auto& entry : m_channelToTopic) {
        if (entry.value == topic) {
            channelID = entry.key;
            break;
        }
    }
    if (channelID.isNull()) {
        // No channel means the server already forgot this subscription (e.g. after a
        // uaid reset); the local record removal that prompted this call suffices.
        handler(true, nil);
        return;
    }

    if (m_state != State::Connected) {
        m_pendingUnsubscribes.append({ topic, WTF::move(handler) });
        connectIfNeeded();
        return;
    }

    auto timeoutTimer = makeUnique<RunLoop::Timer>(RunLoop::mainSingleton(), "MozillaPushServiceConnection::UnregisterTimeout"_s, [this, weakThis = WeakPtr { *this }, channelID] {
        RefPtr protectedThis = weakThis.get();
        if (!protectedThis)
            return;
        auto request = m_inflightUnregisters.take(channelID);
        if (request.handler)
            request.handler(false, pushServiceError(7, @"Timed out unregistering push channel"));
    });
    timeoutTimer->startOneShot(requestTimeout);
    m_inflightUnregisters.set(channelID, InflightUnregister { topic, WTF::move(handler), WTF::move(timeoutTimer) });

    // The channel is gone locally no matter how the server responds; a stale entry would
    // only resurrect on the next hello and get pruned again.
    m_channelToTopic.remove(channelID);
    savePersistentState();

    sendJSONMessage(@{
        @"messageType": @"unregister",
        @"channelID": channelID.createNSString().get(),
        @"code": @200,
    });
}

void MozillaPushServiceConnection::handleUnregisterReply(NSDictionary *reply)
{
    NSString *channelID = dynamic_objc_cast<NSString>(reply[@"channelID"]);
    if (!channelID.length)
        return;

    auto request = m_inflightUnregisters.take(String { channelID });
    if (!request.handler)
        return;

    NSInteger status = dynamic_objc_cast<NSNumber>(reply[@"status"]).integerValue;
    request.handler(status == 200, status == 200 ? nil : pushServiceError(status ? status : 8, @"Push service could not remove the subscription"));
}

// MARK: - Incoming pushes

// Extracts a parameter like `dh=...` or `salt=...` from an HTTP-style structured header
// value such as "dh=BNoRDbb84JGm8g5Z5CFxurSqsXWJ11ItfXEWYVLE85Y;p256ecdsa=BF92zdI...".
static String parameterFromHeaderValue(NSString *headerValue, const String& parameterName)
{
    for (NSString *segment in [headerValue componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";,"]]) {
        NSString *trimmed = [segment stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSRange equals = [trimmed rangeOfString:@"="];
        if (equals.location == NSNotFound)
            continue;
        if (String { [trimmed substringToIndex:equals.location] } != parameterName)
            continue;
        return String { [trimmed substringFromIndex:equals.location + 1] };
    }
    return String();
}

void MozillaPushServiceConnection::handleNotification(NSDictionary *reply)
{
    NSString *channelID = dynamic_objc_cast<NSString>(reply[@"channelID"]);
    id version = reply[@"version"];
    if (!channelID.length)
        return;

    // Deliveries are acked unconditionally: whether the message was handed on, dropped
    // for an ignored origin, or undecryptable, a redelivery would fare no better.
    sendAckForChannel(channelID, version);

    auto topicIterator = m_channelToTopic.find(String { channelID });
    if (topicIterator == m_channelToTopic.end()) {
        // The server remembers a channel this client no longer has; tell it to forget.
        RELEASE_LOG(Push, "MozillaPushServiceConnection: notification for unknown channel; unregistering it");
        sendJSONMessage(@{
            @"messageType": @"unregister",
            @"channelID": channelID,
            @"code": @200,
        });
        return;
    }
    const String& topic = topicIterator->value;

    // apsd filters ignored topics before they reach the daemon; autopush has no
    // server-side filter, so enforce the same policy at delivery.
    if (m_ignoredTopics.contains(topic)) {
        RELEASE_LOG(Push, "MozillaPushServiceConnection: dropping push for ignored topic");
        return;
    }

    // Recreate the flat dictionary apsd would deliver: `payload` is standard base64
    // ciphertext, `content_encoding` names the scheme, and legacy aesgcm carries the
    // sender key and salt out-of-band (base64url, straight from the headers).
    auto userInfo = adoptNS([[NSMutableDictionary alloc] init]);
    NSString *encodedData = dynamic_objc_cast<NSString>(reply[@"data"]);
    if (encodedData.length) {
        auto ciphertext = base64URLDecode(String { encodedData });
        if (!ciphertext) {
            RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: dropping push with undecodable payload");
            return;
        }

        NSDictionary *headers = dynamic_objc_cast<NSDictionary>(reply[@"headers"]);
        NSString *encoding = dynamic_objc_cast<NSString>(headers[@"encoding"]);
        // aes128gcm is self-describing (RFC 8188 binary header), so it is also the
        // sensible reading of a payload that arrives without headers.
        String contentEncoding = encoding.length ? String { encoding } : "aes128gcm"_s;

        [userInfo setObject:contentEncoding.createNSString().get() forKey:@"content_encoding"];
        [userInfo setObject:base64EncodeToString(ciphertext->span()).createNSString().get() forKey:@"payload"];

        if (contentEncoding == "aesgcm"_s) {
            String serverKey = parameterFromHeaderValue(dynamic_objc_cast<NSString>(headers[@"crypto_key"]), "dh"_s);
            String salt = parameterFromHeaderValue(dynamic_objc_cast<NSString>(headers[@"encryption"]), "salt"_s);
            if (serverKey.isEmpty() || salt.isEmpty()) {
                RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: dropping aesgcm push with missing crypto headers");
                return;
            }
            [userInfo setObject:serverKey.createNSString().get() forKey:@"as_publickey"];
            [userInfo setObject:salt.createNSString().get() forKey:@"as_salt"];
        }
    }

    didReceivePushMessage(topic.createNSString().get(), userInfo.get());
}

void MozillaPushServiceConnection::sendAckForChannel(NSString *channelID, id version)
{
    sendJSONMessage(@{
        @"messageType": @"ack",
        @"updates": @[ @{
            @"channelID": channelID,
            @"version": version ?: @"",
            @"code": @100,
        } ],
    });
}

// MARK: - Topic lists

void MozillaPushServiceConnection::setEnabledTopics(Vector<String>&& topics)
{
    m_enabledTopics = WTF::move(topics);
    // Topic lists follow every database change, so this doubles as the connect trigger
    // when the daemon starts with existing subscriptions.
    if (!m_enabledTopics.isEmpty() || !m_channelToTopic.isEmpty())
        connectIfNeeded();
}

void MozillaPushServiceConnection::setTopicLists(TopicLists&& topicLists)
{
    setIgnoredTopics(WTF::move(topicLists.ignoredTopics));
    setOpportunisticTopics(WTF::move(topicLists.opportunisticTopics));
    setNonWakingTopics(WTF::move(topicLists.nonWakingTopics));
    setEnabledTopics(WTF::move(topicLists.enabledTopics));

    // Channels whose topic vanished from the database (subscription removed without an
    // unsubscribe round-trip, e.g. the silent-push penalty or a store wipe) are dead
    // weight on the server; unregister them.
    Vector<String> staleChannels;
    for (auto& entry : m_channelToTopic) {
        if (!m_enabledTopics.contains(entry.value) && !m_ignoredTopics.contains(entry.value))
            staleChannels.append(entry.key);
    }
    if (staleChannels.isEmpty())
        return;

    for (auto& channelID : staleChannels) {
        RELEASE_LOG(Push, "MozillaPushServiceConnection: unregistering channel with no matching subscription");
        m_channelToTopic.remove(channelID);
        if (m_state == State::Connected) {
            sendJSONMessage(@{
                @"messageType": @"unregister",
                @"channelID": channelID.createNSString().get(),
                @"code": @200,
            });
        }
        // A disconnected socket is fine: the channel is gone from the persisted list, so
        // the next hello omits it and a stray notification hits the unknown-channel path.
    }
    savePersistentState();
}

// MARK: - Failure propagation

void MozillaPushServiceConnection::failInflightAndPendingRequests(NSError *error)
{
    auto inflightRegisters = std::exchange(m_inflightRegisters, { });
    for (auto& entry : inflightRegisters.values())
        entry.handler(nil, error);

    auto inflightUnregisters = std::exchange(m_inflightUnregisters, { });
    for (auto& entry : inflightUnregisters.values())
        entry.handler(false, error);

    auto pendingSubscribes = std::exchange(m_pendingSubscribes, { });
    for (auto& entry : pendingSubscribes)
        entry.handler(nil, error);

    auto pendingUnsubscribes = std::exchange(m_pendingUnsubscribes, { });
    for (auto& entry : pendingUnsubscribes)
        entry.handler(false, error);
}

// MARK: - Persistence

String MozillaPushServiceConnection::persistentStatePath() const
{
    return FileSystem::pathByAppendingComponent(m_storageDirectory, "MozillaPushService.plist"_s);
}

void MozillaPushServiceConnection::loadPersistentState()
{
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:persistentStatePath().createNSString().get()];
    if (!state)
        return;

    NSString *serverURL = dynamic_objc_cast<NSString>(state[@"serverURL"]);
    if (String { serverURL } != m_serverURLString) {
        // State minted against a different push service is meaningless here.
        RELEASE_LOG(Push, "MozillaPushServiceConnection: discarding state from a different push server");
        return;
    }

    NSString *uaid = dynamic_objc_cast<NSString>(state[@"uaid"]);
    if (uaid.length)
        m_uaid = uaid;

    NSDictionary *channels = dynamic_objc_cast<NSDictionary>(state[@"channels"]);
    [channels enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *) {
        NSString *channelID = dynamic_objc_cast<NSString>(key);
        NSString *topic = dynamic_objc_cast<NSString>(value);
        if (channelID.length && topic.length)
            m_channelToTopic.set(String { channelID }, String { topic });
    }];
}

void MozillaPushServiceConnection::savePersistentState()
{
    FileSystem::makeAllDirectories(m_storageDirectory);

    auto channels = adoptNS([[NSMutableDictionary alloc] init]);
    for (auto& entry : m_channelToTopic)
        [channels setObject:entry.value.createNSString().get() forKey:entry.key.createNSString().get()];

    NSDictionary *state = @{
        @"serverURL": m_serverURLString.createNSString().get(),
        @"uaid": m_uaid.isNull() ? @"" : m_uaid.createNSString().get(),
        @"channels": channels.get(),
    };
    if (![state writeToFile:persistentStatePath().createNSString().get() atomically:YES])
        RELEASE_LOG_ERROR(Push, "MozillaPushServiceConnection: could not persist state to %{public}s", persistentStatePath().utf8().data());
}

} // namespace WebPushD

#endif // USE(MOZILLA_PUSH_SERVICE)
