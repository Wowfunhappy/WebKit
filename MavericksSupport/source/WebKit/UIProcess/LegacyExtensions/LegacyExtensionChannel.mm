#import "config.h"
#import "LegacyExtensionChannel.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <wtf/BlockPtr.h>
#import <wtf/HashMap.h>
#import <wtf/Lock.h>
#import <wtf/NeverDestroyed.h>
#import <wtf/OSObjectPtr.h>
#import <wtf/RetainPtr.h>
#import <wtf/RunLoop.h>
#import <wtf/cf/VectorCF.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringBuilder.h>
#import <wtf/text/WTFString.h>

namespace WebKit::LegacyExtensions {

// Message ports in the login session's bootstrap namespace: the hub's by a fixed name, each satellite's by
// its process identifier. A hub's start is announced to the session.
static constexpr auto hubPortName = "WebKit.LegacyExtensions.Hub"_s;
static constexpr auto hubDidStartNotification = "WebKit.LegacyExtensions.HubDidStart"_s;
// A send, and a satellite's wait for the hub's welcome, end only when the peer takes the message or exits.
static constexpr CFTimeInterval untilPeerExits = 1e9;
// The run loop mode a satellite waits for the hub's welcome in, which no other source runs in.
static constexpr auto helloReplyMode = "WebKit.LegacyExtensions.Hello"_s;

// The far end of a channel: its port, a queue its messages are sent on in order, and the source that
// watches its process exit on the main queue.
struct Peer {
    RetainPtr<CFMessagePortRef> port;
    OSObjectPtr<dispatch_queue_t> queue;
    OSObjectPtr<dispatch_source_t> exitSource;
};

static Peer makePeer(CFMessagePortRef port, pid_t pid, Function<void()>&& didExit)
{
    Peer peer;
    peer.port = port;
    peer.queue = adoptOSObject(dispatch_queue_create("WebKit.LegacyExtensions.Send", DISPATCH_QUEUE_SERIAL));
    peer.exitSource = adoptOSObject(dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue()));
    dispatch_source_set_event_handler(peer.exitSource.get(), makeBlockPtr(WTF::move(didExit)).get());
    dispatch_resume(peer.exitSource.get());
    return peer;
}

static void cancel(Peer& peer)
{
    if (peer.exitSource)
        dispatch_source_cancel(peer.exitSource.get());
}

static RetainPtr<CFDataRef> encode(const String& json)
{
    auto utf8 = json.utf8();
    auto bytes = byteCast<UInt8>(utf8.span());
    return adoptCF(CFDataCreate(kCFAllocatorDefault, bytes.data(), bytes.size()));
}

static void send(const RetainPtr<CFMessagePortRef>& port, const OSObjectPtr<dispatch_queue_t>& queue, const JSON::Object& message)
{
    dispatch_async(queue.get(), makeBlockPtr([port, data = encode(message.toJSONString())] {
        CFMessagePortSendRequest(port.get(), 0, data.get(), untilPeerExits, 0, nullptr, nullptr);
    }).get());
}

static RefPtr<JSON::Object> parse(CFDataRef data)
{
    if (!data)
        return nullptr;
    auto value = JSON::Value::parseJSON(String::fromUTF8(span(data)));
    return value ? value->asObject() : nullptr;
}

static RetainPtr<CFMessagePortRef> createLocalPort(const String& name, CFMessagePortCallBack callBack)
{
    Boolean shouldFreeInfo = false;
    return adoptCF(CFMessagePortCreateLocal(kCFAllocatorDefault, name.createCFString().get(), callBack, nullptr, &shouldFreeInfo));
}

// The hub. Its port receives on a queue of its own, which answers hellos; everything else goes on to the
// main run loop in order.

struct Satellite {
    uint64_t number { 0 };
    Peer peer;
};

struct Hub {
    RetainPtr<CFMessagePortRef> port;
    OSObjectPtr<dispatch_queue_t> receiveQueue;
    Lock lock;
    HashMap<pid_t, Satellite> satellites WTF_GUARDED_BY_LOCK(lock);
    uint64_t nextNumber WTF_GUARDED_BY_LOCK(lock) { 1 };
    // A JSON array of the messages a satellite's welcome carries.
    String welcomeMessages WTF_GUARDED_BY_LOCK(lock) { "[]"_s };
    Function<void(uint64_t, Ref<JSON::Object>&&)> receive;
    Function<void(uint64_t)> satelliteDidGoAway;
};

static Hub& hub()
{
    static NeverDestroyed<Hub> hub;
    return hub;
}

static bool isConnected(uint64_t number)
{
    auto& hub = LegacyExtensions::hub();
    Locker locker { hub.lock };
    for (auto& satellite : hub.satellites.values()) {
        if (satellite.number == number)
            return true;
    }
    return false;
}

static void satelliteDidExit(pid_t pid)
{
    auto& hub = LegacyExtensions::hub();
    uint64_t number = 0;
    {
        Locker locker { hub.lock };
        auto satellite = hub.satellites.take(pid);
        cancel(satellite.peer);
        number = satellite.number;
    }
    if (number)
        hub.satelliteDidGoAway(number);
}

static CFDataRef hubDidReceive(CFMessagePortRef, SInt32, CFDataRef data, void*)
{
    auto& hub = LegacyExtensions::hub();
    RefPtr message = parse(data);
    auto pid = message ? message->getInteger("from"_s) : std::nullopt;
    if (!pid || *pid <= 0)
        return nullptr;

    if (message->getString("t"_s) == "hello"_s) {
        RetainPtr port = adoptCF(CFMessagePortCreateRemote(kCFAllocatorDefault, message->getString("port"_s).createCFString().get()));
        if (!port)
            return nullptr;
        uint64_t number = 0;
        uint64_t previousNumber = 0;
        String welcomeMessages;
        {
            Locker locker { hub.lock };
            auto previous = hub.satellites.take(*pid);
            cancel(previous.peer);
            previousNumber = previous.number;
            number = hub.nextNumber++;
            hub.satellites.set(*pid, Satellite { number, makePeer(port.get(), *pid, [pid = *pid] { satelliteDidExit(pid); }) });
            welcomeMessages = hub.welcomeMessages.isolatedCopy();
        }
        if (previousNumber) {
            RunLoop::mainSingleton().dispatch([previousNumber] {
                LegacyExtensions::hub().satelliteDidGoAway(previousNumber);
            });
        }
        return encode(makeString("{\"t\":\"welcome\",\"satellite\":"_s, number, ",\"hub\":"_s, getpid(), ",\"messages\":"_s, welcomeMessages, '}')).leakRef();
    }

    uint64_t number = 0;
    {
        Locker locker { hub.lock };
        auto iterator = hub.satellites.find(*pid);
        if (iterator != hub.satellites.end())
            number = iterator->value.number;
    }
    if (!number)
        return nullptr;
    RunLoop::mainSingleton().dispatch([number, message = WTF::move(message)]() mutable {
        if (isConnected(number))
            LegacyExtensions::hub().receive(number, message.releaseNonNull());
    });
    return nullptr;
}

void startHub(Function<void(uint64_t, Ref<JSON::Object>&&)>&& receive, Function<void(uint64_t)>&& satelliteDidGoAway)
{
    auto& hub = LegacyExtensions::hub();
    if (hub.port)
        return;
    RetainPtr port = createLocalPort(hubPortName, hubDidReceive);
    if (!port)
        return;
    hub.receive = WTF::move(receive);
    hub.satelliteDidGoAway = WTF::move(satelliteDidGoAway);
    hub.receiveQueue = adoptOSObject(dispatch_queue_create("WebKit.LegacyExtensions.Hub", DISPATCH_QUEUE_SERIAL));
    CFMessagePortSetDispatchQueue(port.get(), hub.receiveQueue.get());
    hub.port = WTF::move(port);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), hubDidStartNotification.createCFString().get(), nullptr, nullptr, true);
}

void setWelcomeMessages(Vector<Ref<JSON::Object>>&& messages)
{
    auto array = JSON::Array::create();
    for (auto& message : messages)
        array->pushObject(WTF::move(message));
    auto& hub = LegacyExtensions::hub();
    Locker locker { hub.lock };
    hub.welcomeMessages = array->toJSONString().isolatedCopy();
}

void sendToSatellite(uint64_t number, const JSON::Object& message)
{
    RetainPtr<CFMessagePortRef> port;
    OSObjectPtr<dispatch_queue_t> queue;
    {
        auto& hub = LegacyExtensions::hub();
        Locker locker { hub.lock };
        for (auto& satellite : hub.satellites.values()) {
            if (satellite.number == number) {
                port = satellite.peer.port;
                queue = satellite.peer.queue;
            }
        }
    }
    if (port)
        send(port, queue, message);
}

Vector<uint64_t> satellites()
{
    auto& hub = LegacyExtensions::hub();
    Locker locker { hub.lock };
    Vector<uint64_t> numbers;
    for (auto& satellite : hub.satellites.values())
        numbers.append(satellite.number);
    return numbers;
}

// A satellite. Its port receives on the main run loop.

struct SatelliteConnection {
    RetainPtr<CFMessagePortRef> port;
    std::optional<Peer> hub;
    Function<void(uint64_t)> didConnect;
    Function<void(Ref<JSON::Object>&&)> receive;
    Function<void()> hubDidGoAway;
};

static SatelliteConnection& satelliteConnection()
{
    static NeverDestroyed<SatelliteConnection> connection;
    return connection;
}

static String satellitePortName()
{
    return makeString("WebKit.LegacyExtensions.Satellite."_s, getpid());
}

static void hubDidExit()
{
    auto& connection = satelliteConnection();
    if (!connection.hub)
        return;
    cancel(*connection.hub);
    connection.hub = std::nullopt;
    connection.hubDidGoAway();
}

// The hub answers a satellite's hello with its welcome: the satellite's number and the messages the
// satellite needs before its pages load, which it acts on before the hello returns.
static void connectToHub()
{
    auto& connection = satelliteConnection();
    if (connection.hub)
        return;
    RetainPtr port = adoptCF(CFMessagePortCreateRemote(kCFAllocatorDefault, hubPortName.createCFString().get()));
    if (!port)
        return;
    auto hello = JSON::Object::create();
    hello->setString("t"_s, "hello"_s);
    hello->setInteger("from"_s, getpid());
    hello->setString("port"_s, satellitePortName());
    CFDataRef replyData = nullptr;
    if (CFMessagePortSendRequest(port.get(), 0, encode(hello->toJSONString()).get(), untilPeerExits, untilPeerExits, helloReplyMode.createCFString().get(), &replyData) != kCFMessagePortSuccess)
        return;
    RetainPtr reply = adoptCF(replyData);
    RefPtr welcome = parse(reply.get());
    auto number = welcome ? welcome->getInteger("satellite"_s) : std::nullopt;
    auto hubPID = welcome ? welcome->getInteger("hub"_s) : std::nullopt;
    if (!number || !hubPID)
        return;
    connection.hub = makePeer(port.get(), *hubPID, [] { hubDidExit(); });
    connection.didConnect(*number);
    if (RefPtr messages = welcome->getArray("messages"_s)) {
        for (auto& value : *messages) {
            if (RefPtr message = value->asObject())
                connection.receive(message.releaseNonNull());
        }
    }
}

static CFDataRef satelliteDidReceive(CFMessagePortRef, SInt32, CFDataRef data, void*)
{
    auto& connection = satelliteConnection();
    RefPtr message = parse(data);
    if (message && connection.hub)
        connection.receive(message.releaseNonNull());
    return nullptr;
}

static void hubDidStart(CFNotificationCenterRef, void*, CFNotificationName, const void*, CFDictionaryRef)
{
    connectToHub();
}

void startSatellite(Function<void(uint64_t)>&& didConnect, Function<void(Ref<JSON::Object>&&)>&& receive, Function<void()>&& hubDidGoAway)
{
    auto& connection = satelliteConnection();
    if (connection.port)
        return;
    connection.port = createLocalPort(satellitePortName(), satelliteDidReceive);
    if (!connection.port)
        return;
    RetainPtr source = adoptCF(CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, connection.port.get(), 0));
    CFRunLoopAddSource(CFRunLoopGetMain(), source.get(), kCFRunLoopCommonModes);
    connection.didConnect = WTF::move(didConnect);
    connection.receive = WTF::move(receive);
    connection.hubDidGoAway = WTF::move(hubDidGoAway);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(), nullptr, hubDidStart, hubDidStartNotification.createCFString().get(), nullptr, CFNotificationSuspensionBehaviorDeliverImmediately);
    connectToHub();
}

void sendToHub(const JSON::Object& message)
{
    auto& connection = satelliteConnection();
    if (!connection.hub)
        return;
    Ref copy = JSON::Object::create();
    for (auto& [key, value] : message)
        copy->setValue(key, value.copyRef());
    copy->setInteger("from"_s, getpid());
    send(connection.hub->port, connection.hub->queue, copy.get());
}

} // namespace WebKit::LegacyExtensions
