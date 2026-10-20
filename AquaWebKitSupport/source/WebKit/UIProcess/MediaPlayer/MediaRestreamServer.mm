#import "config.h"
#import "MediaRestreamServer.h"
#import "MediaRestreamRTSP.h"
#import <wtf/UUID.h>
#import <wtf/glib/GUniquePtr.h>
#import <glib.h>

#import "MediaRestreamSessionMessages.h"
#import "PageClient.h"
#import "ProcessThrottler.h"
#import <Carbon/Carbon.h>
#import <wtf/MainThread.h>
#import <wtf/MonotonicTime.h>
#import <wtf/WorkQueue.h>
#import <wtf/ASCIICType.h>
#import <vector>
#import "MessageSenderInlines.h"
#import "SharedBufferReference.h"
#import "WebPageProxy.h"
#import "WebProcessProxy.h"
#import <AppKit/AppKit.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <sys/socket.h>
#import <unistd.h>
#import <charconv>
#import <map>
#import <cmath>
#import <atomic>
#import <wtf/JSONValues.h>
#import <set>
#import <string>
#import <wtf/NeverDestroyed.h>
#import <wtf/text/MakeString.h>
#import <wtf/text/StringBuilder.h>

@interface AquaMediaPlayerApplicationObserver : NSObject {
    WTF::Function<void()> _changed;
}
- (instancetype)initWithCallback:(WTF::Function<void()>&&)callback;
@end

@implementation AquaMediaPlayerApplicationObserver
- (instancetype)initWithCallback:(WTF::Function<void()>&&)callback
{
    if (!(self = [super init]))
        return nil;
    _changed = WTF::move(callback);
    [[NSWorkspace sharedWorkspace] addObserver:self forKeyPath:@"runningApplications" options:0 context:nullptr];
    return self;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    _changed();
}
- (void)dealloc
{
    [[NSWorkspace sharedWorkspace] removeObserver:self forKeyPath:@"runningApplications"];
    [super dealloc];
}
@end

namespace WebKit {

static RetainPtr<NSAppleEventDescriptor> objectSpecifier(DescType desiredClass, NSAppleEventDescriptor* container, DescType form, NSAppleEventDescriptor* key)
{
    auto record = [NSAppleEventDescriptor recordDescriptor];
    [record setDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:desiredClass] forKeyword:keyAEDesiredClass];
    [record setDescriptor:container ?: [NSAppleEventDescriptor nullDescriptor] forKeyword:keyAEContainer];
    [record setDescriptor:[NSAppleEventDescriptor descriptorWithEnumCode:form] forKeyword:keyAEKeyForm];
    [record setDescriptor:key forKeyword:keyAEKeyData];
    return [record coerceToDescriptorType:typeObjectSpecifier];
}

static SInt32 appleEventTimeout(std::optional<MonotonicTime> deadline)
{
    if (!deadline)
        return 60;
    return std::clamp<SInt32>(std::ceil((*deadline - MonotonicTime::now()).seconds() * 60), 0, 30 * 60);
}

static RetainPtr<NSAppleEventDescriptor> movieProperty(pid_t pid, NSAppleEventDescriptor* object, DescType property, std::optional<MonotonicTime> deadline = std::nullopt, OSStatus* resultError = nullptr)
{
    if (deadline && MonotonicTime::now() >= *deadline) {
        if (resultError)
            *resultError = errAETimeout;
        return nullptr;
    }
    auto specifier = objectSpecifier(typeProperty, object, formPropertyID, [NSAppleEventDescriptor descriptorWithTypeCode:property]);
    auto target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];
    auto event = [NSAppleEventDescriptor appleEventWithEventClass:kAECoreSuite eventID:kAEGetData targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    [event setParamDescriptor:specifier.get() forKeyword:keyDirectObject];
    AppleEvent reply { typeNull, nullptr };
    auto error = AESendMessage(event.aeDesc, &reply, kAEWaitReply | kAENeverInteract, appleEventTimeout(deadline));
    auto result = adoptNS([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&reply]);
    auto replyError = [result paramDescriptorForKeyword:keyErrorNumber].int32Value;
    if (resultError)
        *resultError = error ? error : replyError;
    if (error || replyError)
        return nullptr;
    return [result paramDescriptorForKeyword:keyDirectObject];
}

struct PlayerAdapter {
    DescType position;
    DescType duration;
    DescType rate;
    DescType playClass;
    DescType playCommand;
    DescType pauseClass;
    DescType pauseCommand;
};

static std::optional<PlayerAdapter> playerAdapter(const String& json)
{
    if (json.length() > 512)
        return std::nullopt;
    auto value = JSON::Value::parseJSON(json);
    auto object = value ? value->asObject() : nullptr;
    if (!object || object->size() != 5)
        return std::nullopt;
    auto code = [](const String& string, unsigned offset) -> DescType {
        DescType result = 0;
        for (unsigned i = offset; i < offset + 4; ++i) {
            auto c = string[i];
            if (c < 32 || c > 126)
                return 0;
            result = (result << 8) | c;
        }
        return result;
    };
    auto position = object->getString("position"_s);
    auto duration = object->getString("duration"_s);
    auto rate = object->getString("rate"_s);
    auto play = object->getString("play"_s);
    auto pause = object->getString("pause"_s);
    if (position.length() != 4 || duration.length() != 4 || rate.length() != 4 || play.length() != 8 || pause.length() != 8)
        return std::nullopt;
    PlayerAdapter adapter { code(position, 0), code(duration, 0), code(rate, 0), code(play, 0), code(play, 4), code(pause, 0), code(pause, 4) };
    if (!adapter.position || !adapter.duration || !adapter.rate || !adapter.playClass || !adapter.playCommand || !adapter.pauseClass || !adapter.pauseCommand)
        return std::nullopt;
    return adapter;
}

static RetainPtr<NSAppleEventDescriptor> movieDocument(int32_t identifier)
{
    auto window = objectSpecifier(cWindow, nil, formUniqueID, [NSAppleEventDescriptor descriptorWithInt32:identifier]);
    return objectSpecifier(typeProperty, window.get(), formPropertyID, [NSAppleEventDescriptor descriptorWithTypeCode:'docu']);
}

static bool movieCommand(pid_t pid, NSAppleEventDescriptor* object, DescType eventClass, DescType command, NSAppleEventDescriptor* value = nil, std::optional<MonotonicTime> deadline = std::nullopt)
{
    if (deadline && MonotonicTime::now() >= *deadline)
        return false;
    auto target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];
    auto event = [NSAppleEventDescriptor appleEventWithEventClass:eventClass eventID:command targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    [event setParamDescriptor:object forKeyword:keyDirectObject];
    if (value)
        [event setParamDescriptor:value forKeyword:keyAEData];
    AppleEvent reply { typeNull, nullptr };
    auto error = AESendMessage(event.aeDesc, &reply, kAEWaitReply | kAENeverInteract, appleEventTimeout(deadline));
    auto result = adoptNS([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&reply]);
    return !error && ![result paramDescriptorForKeyword:keyErrorNumber].int32Value;
}

static std::optional<double> movieNumber(pid_t pid, NSAppleEventDescriptor* document, DescType property, std::optional<MonotonicTime> deadline = std::nullopt)
{
    auto value = movieProperty(pid, document, property, deadline);
    auto number = [value coerceToDescriptorType:typeIEEE64BitFloatingPoint];
    double result;
    if (!number || AEGetDescData(number.aeDesc, &result, sizeof(result)) != noErr || std::isnan(result))
        return std::nullopt;
    return result;
}

static bool setMovieNumber(pid_t pid, NSAppleEventDescriptor* document, DescType property, double number, std::optional<MonotonicTime> deadline = std::nullopt)
{
    auto target = objectSpecifier(typeProperty, document, formPropertyID, [NSAppleEventDescriptor descriptorWithTypeCode:property]);
    auto value = [NSAppleEventDescriptor descriptorWithDescriptorType:typeIEEE64BitFloatingPoint bytes:&number length:sizeof(number)];
    return movieCommand(pid, target.get(), kAECoreSuite, kAESetData, value, deadline);
}

struct MovieWindow {
    int32_t identifier;
    std::string url;
    bool known { true };
    std::optional<double> position;
    std::optional<double> duration;
    std::optional<double> rate;
};

struct MovieWindowLookup {
    bool succeeded { false };
    std::optional<MovieWindow> window;
};

static MovieWindowLookup movieWindow(pid_t pid, int32_t identifier, const std::optional<PlayerAdapter>& adapter)
{
    @autoreleasepool {
        auto window = objectSpecifier(cWindow, nil, formUniqueID, [NSAppleEventDescriptor descriptorWithInt32:identifier]);
        OSStatus error = noErr;
        auto document = movieProperty(pid, window.get(), 'docu', std::nullopt, &error);
        if (error == errAENoSuchObject || (document && document.get().descriptorType == typeType && document.get().typeCodeValue == cMissingValue))
            return { true, std::nullopt };
        if (error || !document)
            return { };

        MovieWindow result { identifier, { }, false };
        auto file = movieProperty(pid, document.get(), 'file');
        if (file && file.get().descriptorType == typeFileURL) {
            NSData* data = file.get().data;
            result.url.assign(static_cast<const char*>(data.bytes), data.length);
            result.known = true;
        }
        if (adapter) {
            result.position = movieNumber(pid, document.get(), adapter->position);
            result.duration = movieNumber(pid, document.get(), adapter->duration);
            result.rate = movieNumber(pid, document.get(), adapter->rate);
        }
        return { true, WTF::move(result) };
    }
}

static std::optional<std::vector<MovieWindow>> movieWindows(pid_t pid, const std::optional<PlayerAdapter>& adapter, std::optional<MonotonicTime> deadline = std::nullopt)
{
    @autoreleasepool {
        DescType all = kAEAll;
        auto windows = objectSpecifier(cWindow, nil, formAbsolutePosition, [NSAppleEventDescriptor descriptorWithDescriptorType:typeAbsoluteOrdinal bytes:&all length:sizeof(all)]);
        auto identifiers = movieProperty(pid, windows.get(), pID, deadline);
        if (!identifiers || identifiers.get().descriptorType != typeAEList)
            return std::nullopt;
        std::vector<MovieWindow> result;
        for (NSInteger index = 1; index <= identifiers.get().numberOfItems; ++index) {
            auto identifier = [identifiers descriptorAtIndex:index].int32Value;
            auto window = objectSpecifier(cWindow, nil, formUniqueID, [NSAppleEventDescriptor descriptorWithInt32:identifier]);
            auto document = objectSpecifier(typeProperty, window.get(), formPropertyID, [NSAppleEventDescriptor descriptorWithTypeCode:'docu']);
            auto file = movieProperty(pid, document.get(), 'file', deadline);
            if (!file || file.get().descriptorType != typeFileURL) {
                auto contents = movieProperty(pid, window.get(), 'docu', deadline);
                bool noDocument = contents && contents.get().descriptorType == typeType && contents.get().typeCodeValue == cMissingValue;
                result.push_back({ identifier, { }, noDocument });
                continue;
            }
            NSData* data = file.get().data;
            auto position = adapter ? movieNumber(pid, document.get(), adapter->position, deadline) : std::nullopt;
            auto duration = adapter ? movieNumber(pid, document.get(), adapter->duration, deadline) : std::nullopt;
            auto rate = adapter ? movieNumber(pid, document.get(), adapter->rate, deadline) : std::nullopt;
            result.push_back({ identifier, std::string(static_cast<const char*>(data.bytes), data.length), true, position, duration, rate });
        }
        return result;
    }
}

struct MediaRestreamServer::Impl {
    struct Handoff {
        Ref<WebPageProxy> page;
        WeakPtr<WebProcessProxy> process;
        uint64_t identifier;
        Ref<PageClient> client;
        Ref<ProcessThrottler::Activity> activity;
        String ticket;
        String extensionKey;
        MonotonicTime deadline;
    };
    std::vector<Handoff> handoffs;
    struct Cleanup {
        RetainPtr<NSRunningApplication> application;
        pid_t pid;
        std::string url;
        std::vector<int32_t> previousWindows;
        std::optional<int32_t> window;
        bool busy { false };
        bool finished { false };
        CompletionHandler<void(bool, bool)> completion;
        WeakPtr<WebProcessProxy> process;
        uint64_t identifier { 0 };
        std::optional<MonotonicTime> deadline;
    };
    std::vector<std::shared_ptr<Cleanup>> cleanups;
    struct UnconfirmedDirect {
        RetainPtr<NSRunningApplication> application;
        pid_t pid;
        std::string url;
    };
    std::vector<UnconfirmedDirect> unconfirmedDirect;
    struct Opening {
        CompletionHandler<void(Expected<URL, String>&&)> completion;
        URL url;
        double position;
        double rate;
        bool paused;
        bool direct;
        bool uniqueURL;
        MonotonicTime deadline { MonotonicTime::now() + 30_s };
        std::vector<int32_t> previousWindows;
        bool busy { false };
        std::atomic<bool> sent { false };
        bool rejected { false };
        std::atomic<bool> acknowledgedDocument { false };
    };
    struct Session {
        Ref<WebPageProxy> page;
        WeakPtr<WebProcessProxy> process;
        uint64_t identifier;
        Ref<PageClient> client;
        Ref<ProcessThrottler::Activity> activity;
        std::string url;
        std::string playlistName;
        String suppliedPlaylist;
        std::shared_ptr<MediaRestreamRTSP> rtsp;
        uint64_t controlRevision { 0 };
        std::optional<int32_t> window;
        pid_t playerPID { 0 };
        bool tracksMovie { false };
        bool capturesMedia { false };
        std::optional<PlayerAdapter> adapter;
        std::optional<double> position;
        std::shared_ptr<Opening> opening;
        std::shared_ptr<Cleanup> cleanup;
        std::shared_ptr<std::atomic<bool>> cancelled { std::make_shared<std::atomic<bool>>(false) };
        RetainPtr<NSRunningApplication> application;
    };
    struct Client : std::enable_shared_from_this<Client> {
        Impl& server;
        int socket;
        dispatch_source_t reader { nullptr };
        dispatch_source_t writer { nullptr };
        std::string input;
        std::string output;
        size_t sent { 0 };
        bool busy { false };
        bool closeAfterResponse { false };
        bool closed { false };
        WeakPtr<WebProcessProxy> pendingProcess;
        uint64_t pendingSession { 0 };
        uint64_t pendingRequest { 0 };
        Client(Impl& server, int socket) : server(server), socket(socket) { }
        void close()
        {
            if (std::exchange(closed, true))
                return;
            auto protect = shared_from_this();
            if (pendingRequest) {
                if (RefPtr process = pendingProcess.get())
                    process->send(Messages::MediaRestreamSession::Cancel(pendingSession, pendingRequest), 0);
                pendingRequest = 0;
                pendingProcess = nullptr;
            }
            if (writer) {
                dispatch_source_cancel(writer);
                dispatch_release(writer);
                writer = nullptr;
            }
            if (reader) {
                dispatch_source_cancel(reader);
                dispatch_release(reader);
                reader = nullptr;
            }
            server.clients.erase(socket);
        }
        void start()
        {
            std::weak_ptr<Client> weak = shared_from_this();
            reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socket, 0, dispatch_get_main_queue());
            int descriptor = socket;
            dispatch_source_set_cancel_handler(reader, ^{ ::close(descriptor); });
            dispatch_source_set_event_handler(reader, ^{
                auto client = weak.lock();
                if (!client || client->closed)
                    return;
                char buffer[8192];
                auto size = recv(client->socket, buffer, sizeof(buffer), 0);
                if (size <= 0) {
                    if (!size || (errno != EAGAIN && errno != EINTR))
                        client->close();
                    return;
                }
                client->input.append(buffer, size);
                if (client->input.size() > 16384)
                    return client->close();
                client->parse();
            });
            dispatch_resume(reader);
        }
        void write()
        {
            while (sent < output.size()) {
                auto amount = send(socket, output.data() + sent, output.size() - sent, 0);
                if (amount < 0 && errno == EINTR)
                    continue;
                if (amount < 0 && errno == EAGAIN)
                    break;
                if (amount <= 0)
                    return close();
                sent += amount;
            }
            if (sent < output.size()) {
                if (!writer) {
                    std::weak_ptr<Client> weak = shared_from_this();
                    writer = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, socket, 0, dispatch_get_main_queue());
                    dispatch_source_set_event_handler(writer, ^{
                        if (auto client = weak.lock(); client && !client->closed)
                            client->write();
                    });
                    dispatch_resume(writer);
                }
                return;
            }
            if (writer) {
                dispatch_source_cancel(writer);
                dispatch_release(writer);
                writer = nullptr;
            }
            output.clear();
            sent = 0;
            busy = false;
            if (closeAfterResponse)
                return close();
            parse();
        }
        static std::optional<uint64_t> number(std::string_view text)
        {
            uint64_t result;
            auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
            if (parsed.ec != std::errc() || parsed.ptr != text.data() + text.size())
                return std::nullopt;
            return result;
        }
        void reply(int status, std::span<const uint8_t> bytes, const char* type, bool head, const std::string& range)
        {
            if (closed)
                return;
            uint64_t start = 0;
            uint64_t end = bytes.size();
            std::string extra;
            if (status == 200 && !head && !range.empty()) {
                bool valid = range.starts_with("bytes=") && range.find(',') == std::string::npos;
                auto dash = range.find('-', 6);
                valid &= dash != std::string::npos;
                if (valid) {
                    auto left = std::string_view(range).substr(6, dash - 6);
                    auto right = std::string_view(range).substr(dash + 1);
                    auto first = number(left);
                    auto last = number(right);
                    if (left.empty() && last && *last)
                        start = bytes.size() - std::min<uint64_t>(bytes.size(), *last);
                    else if (first && (right.empty() || last)) {
                        start = *first;
                        if (last)
                            end = *last >= bytes.size() ? bytes.size() : *last + 1;
                    } else
                        valid = false;
                    valid &= start < end && end <= bytes.size();
                }
                status = valid ? 206 : 416;
                extra = valid ? "Content-Range: bytes " + std::to_string(start) + "-" + std::to_string(end - 1) + "/" + std::to_string(bytes.size()) + "\r\n"
                    : "Content-Range: bytes */" + std::to_string(bytes.size()) + "\r\n";
            }
            if (status != 200 && status != 206)
                start = end = 0;
            if (status == 405)
                extra += "Allow: GET, HEAD\r\n";
            const char* reason = status == 200 ? "OK" : status == 206 ? "Partial Content" : status == 416 ? "Range Not Satisfiable" : status == 405 ? "Method Not Allowed" : "Not Found";
            output = "HTTP/1.1 " + std::to_string(status) + " " + reason + "\r\nContent-Type: " + type + "\r\nContent-Length: " + std::to_string(end - start)
                + "\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: " + (closeAfterResponse ? "close" : "keep-alive") + "\r\n" + extra + "\r\n";
            if (!head && end > start)
                output.append(reinterpret_cast<const char*>(bytes.data() + start), end - start);
            write();
        }
        void parse()
        {
            if (busy || closed)
                return;
            auto end = input.find("\r\n\r\n");
            if (end == std::string::npos)
                return;
            auto request = input.substr(0, end + 2);
            input.erase(0, end + 4);
            busy = true;
            auto requestLineEnd = request.find("\r\n");
            auto firstSpace = request.find(' ');
            auto lastSpace = request.find(' ', firstSpace + 1);
            if (firstSpace == std::string::npos || lastSpace == std::string::npos)
                return close();
            if (requestLineEnd == std::string::npos || request.substr(lastSpace + 1, requestLineEnd - lastSpace - 1) != "HTTP/1.1")
                return close();
            auto method = request.substr(0, firstSpace);
            auto path = request.substr(firstSpace + 1, lastSpace - firstSpace - 1);
            bool head = method == "HEAD";
            closeAfterResponse = false;
            std::string range;
            bool haveHost = false;
            bool haveRange = false;
            bool haveLength = false;
            auto line = request.find("\r\n") + 2;
            while (line < request.size()) {
                auto next = request.find("\r\n", line);
                auto colon = request.find(':', line);
                if (colon == std::string::npos || colon >= next)
                    return close();
                auto name = request.substr(line, colon - line);
                for (auto& c : name)
                    c = toASCIILower(c);
                auto value = request.substr(colon + 1, next - colon - 1);
                while (!value.empty() && (value.front() == ' ' || value.front() == '\t'))
                    value.erase(0, 1);
                while (!value.empty() && (value.back() == ' ' || value.back() == '\t'))
                    value.pop_back();
                if (name == "host") {
                    if (haveHost || value != "127.0.0.1:" + std::to_string(server.port))
                        return close();
                    haveHost = true;
                }
                if (name == "range") {
                    if (std::exchange(haveRange, true))
                        return close();
                    range = value;
                }
                if (name == "connection") {
                    for (auto& c : value)
                        c = toASCIILower(c);
                    size_t start = 0;
                    while (start < value.size()) {
                        auto end = value.find(',', start);
                        if (end == std::string::npos)
                            end = value.size();
                        auto token = value.substr(start, end - start);
                        auto first = token.find_first_not_of(" \t");
                        auto last = token.find_last_not_of(" \t");
                        if (first == std::string::npos)
                            return close();
                        closeAfterResponse |= token.substr(first, last - first + 1) == "close";
                        start = end + 1;
                    }
                }
                if (name == "transfer-encoding" || (name == "content-length" && (std::exchange(haveLength, true) || value != "0")))
                    return close();
                line = next + 2;
            }
            if (!haveHost)
                return close();
            if (method != "GET" && !head)
                return reply(405, { }, "text/plain", head, { });
            auto slash = path.find('/', 1);
            if (path.empty() || path[0] != '/' || slash == std::string::npos)
                return reply(404, { }, "text/plain", head, { });
            auto found = server.sessions.find(path.substr(1, slash - 1));
            if (found == server.sessions.end())
                return reply(404, { }, "text/plain", head, { });
            auto session = found->second;
            RefPtr process = session->process.get();
            if (!process || !process->hasConnection()) {
                server.remove(session);
                return reply(404, { }, "text/plain", head, { });
            }
            auto resource = path.substr(slash + 1);
            bool namedPlaylist = !session->playlistName.empty() && resource == session->playlistName;
            if (namedPlaylist)
                resource = "index.m3u8";
            if (!session->suppliedPlaylist.isEmpty()) {
                if (resource != "index.m3u8")
                    return reply(404, { }, "text/plain", head, { });
                auto data = session->suppliedPlaylist.utf8();
                return reply(200, byteCast<uint8_t>(data.span()), "application/vnd.apple.mpegurl", head, range);
            }
            auto client = shared_from_this();
            if (resource == "index.m3u8" || resource == "media.m3u8" || (resource.starts_with("sub-") && (resource.ends_with(".m3u8") || resource.ends_with(".vtt")))) {
                process->sendWithAsyncReply(Messages::MediaRestreamSession::Playlist(session->identifier, String::fromUTF8(resource)), [client, session, head, range, namedPlaylist, vtt = resource.ends_with(".vtt")](String&& playlist) {
                    if (playlist.isEmpty())
                        return client->reply(404, { }, "text/plain", head, { });
                    if (namedPlaylist) {
                        StringBuilder rebased;
                        for (auto line : playlist.splitAllowingEmptyEntries('\n')) {
                            if (!line.isEmpty() && !line.startsWith('#'))
                                rebased.append("../"_s);
                            rebased.append(makeStringByReplacingAll(line, "URI=\""_s, "URI=\"../"_s), '\n');
                        }
                        playlist = rebased.toString();
                    }
                    auto data = playlist.utf8();
                    client->reply(200, byteCast<uint8_t>(data.span()), vtt ? "text/vtt; charset=utf-8" : "application/vnd.apple.mpegurl", head, range);
                }, 0);
                return;
            }
            if (!resource.ends_with(".ts"))
                return reply(404, { }, "text/plain", head, { });
            auto index = number(std::string_view(resource).substr(0, resource.size() - 3));
            if (!index)
                return reply(404, { }, "text/plain", head, { });
            pendingProcess = *process;
            pendingSession = session->identifier;
            pendingRequest = server.nextRequest++;
            process->sendWithAsyncReply(Messages::MediaRestreamSession::Segment(session->identifier, pendingRequest, *index), [client, session, head, range](std::optional<IPC::SharedBufferReference>&& data) {
                client->pendingRequest = 0;
                client->pendingProcess = nullptr;
                if (!data)
                    return client->reply(404, { }, "text/plain", head, { });
                client->reply(200, data->span(), "video/mp2t", head, range);
            }, 0);
        }
    };
    RetainPtr<AquaMediaPlayerApplicationObserver> applicationObserver;
    dispatch_source_t monitor { nullptr };
    Ref<WorkQueue> monitorQueue { WorkQueue::create("External player lifecycle"_s) };
    bool querying { false };
    dispatch_source_t listener { nullptr };
    uint16_t port { 0 };
    uint64_t nextRequest { 1 };
    std::map<std::string, std::shared_ptr<Session>> sessions;
    std::map<int, std::shared_ptr<Client>> clients;
    std::set<const WebPageProxy*> detachedPages;

    void stopUnusedResources()
    {
        if (sessions.empty() && listener) {
            while (!clients.empty())
                clients.begin()->second->close();
            dispatch_source_cancel(listener);
            dispatch_release(listener);
            listener = nullptr;
            port = 0;
        }
        if (sessions.empty() && cleanups.empty() && monitor) {
            dispatch_source_cancel(monitor);
            dispatch_release(monitor);
            monitor = nullptr;
        }
    }

    void ensureMonitor()
    {
        if (monitor)
            return;
        monitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(monitor, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        auto* server = this;
        dispatch_source_set_event_handler(monitor, ^{ server->checkMovies(); });
        dispatch_resume(monitor);
    }

    void checkCleanups()
    {
        for (auto& cleanup : cleanups) {
            if (cleanup->completion && cleanup->deadline && MonotonicTime::now() >= *cleanup->deadline)
                cleanup->completion(false, false);
            if (std::exchange(cleanup->busy, true))
                continue;
            auto acquired = cleanup->window;
            monitorQueue->dispatch([this, cleanup, acquired]() mutable {
                bool finished = false;
                @autoreleasepool {
                    if (cleanup->application.get().terminated)
                        finished = true;
                    else if (auto movies = movieWindows(cleanup->pid, std::nullopt)) {
                        auto matches = [&](auto& movie) {
                            if (acquired)
                                return movie.identifier == *acquired;
                            return movie.known && movie.url == cleanup->url && std::find(cleanup->previousWindows.begin(), cleanup->previousWindows.end(), movie.identifier) == cleanup->previousWindows.end();
                        };
                        auto found = std::find_if(movies->begin(), movies->end(), matches);
                        if (!acquired && found != movies->end() && std::find_if(found + 1, movies->end(), matches) != movies->end())
                            found = movies->end();
                        if (found == movies->end())
                            finished = acquired.has_value();
                        else if (found->known) {
                            if (found->url != cleanup->url)
                                finished = true;
                            else {
                                acquired = found->identifier;
                                auto document = movieDocument(*acquired);
                                finished = movieCommand(cleanup->pid, document.get(), kAECoreSuite, kAEClose);
                            }
                        }
                    }
                }
                callOnMainThread([this, cleanup, acquired, finished] {
                    cleanup->busy = false;
                    if (acquired)
                        cleanup->window = acquired;
                    if (finished) {
                        cleanup->finished = true;
                        std::erase_if(unconfirmedDirect, [&](auto& item) { return item.pid == cleanup->pid && item.url == cleanup->url; });
                        std::erase(cleanups, cleanup);
                        if (cleanup->completion)
                            cleanup->completion(true, false);
                        stopUnusedResources();
                    }
                });
            });
        }
    }

    void queueCleanup(const std::shared_ptr<Session>& session, const std::shared_ptr<Opening>& opening)
    {
        if (opening && !opening->uniqueURL && opening->sent.load()) {
            auto matches = [&](auto& item) { return item.pid == session->playerPID && item.url == session->url; };
            if (session->window || opening->rejected)
                std::erase_if(unconfirmedDirect, matches);
            else if (std::none_of(unconfirmedDirect.begin(), unconfirmedDirect.end(), matches))
                unconfirmedDirect.push_back({ session->application, session->playerPID, session->url });
        }
        if (!session->tracksMovie || (!session->window && (!opening || (!opening->uniqueURL && !opening->acknowledgedDocument) || !opening->sent.load())))
            return;
        if (!session->cleanup) {
            session->cleanup = std::make_shared<Cleanup>(Cleanup { session->application, session->playerPID, session->url, opening ? opening->previousWindows : std::vector<int32_t> { }, session->window });
            cleanups.push_back(session->cleanup);
        } else {
            if (session->cleanup->finished)
                return;
            if (session->window)
                session->cleanup->window = session->window;
        }
        ensureMonitor();
        checkCleanups();
    }

    void finishOpening(std::shared_ptr<Session> session, Expected<URL, String>&& result)
    {
        auto opening = std::exchange(session->opening, nullptr);
        if (!opening || !opening->completion)
            return;
        if (!result) {
            queueCleanup(session, opening);
            remove(session, false);
            if (opening->direct && opening->sent.load() && !opening->rejected) {
                if (session->cleanup && !session->cleanup->finished && MonotonicTime::now() < opening->deadline) {
                    session->cleanup->deadline = opening->deadline;
                    session->cleanup->process = session->process;
                    session->cleanup->identifier = session->identifier;
                    session->cleanup->completion = [opening, error = result.error()](bool closed, bool cancelled) mutable {
                        opening->completion(makeUnexpected(cancelled ? "no-source"_s : closed ? WTF::move(error) : "application-start-uncertain"_s));
                    };
                    return;
                }
                if (!session->cleanup || !session->cleanup->finished)
                    result = makeUnexpected("application-start-uncertain"_s);
            }
        }
        opening->completion(WTF::move(result));
    }

    void startOpening(std::shared_ptr<Session> session, std::shared_ptr<Opening> opening)
    {
        monitorQueue->dispatch([this, session, opening] {
            bool opened = false;
            bool rejected = false;
            bool retry = false;
            std::optional<int32_t> acquired;
            String failure = "application-unavailable"_s;
            @autoreleasepool {
                pid_t pid = session->playerPID;
                auto previous = session->application.get().terminated ? std::nullopt : session->tracksMovie ? movieWindows(pid, std::nullopt, opening->deadline) : std::optional<std::vector<MovieWindow>> { std::vector<MovieWindow> { } };
                retry = !previous && !session->application.get().terminated;
                bool existing = previous && std::any_of(previous->begin(), previous->end(), [&](auto& movie) { return movie.known && movie.url == session->url; });
                if (existing)
                    failure = "application-busy"_s;
                if (previous && !existing && !session->cancelled->load() && MonotonicTime::now() < opening->deadline) {
                    for (auto& movie : *previous)
                        opening->previousWindows.push_back(movie.identifier);
                    auto target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];
                    auto event = [NSAppleEventDescriptor appleEventWithEventClass:session->tracksMovie ? kCoreEventClass : 'GURL' eventID:session->tracksMovie ? kAEOpenDocuments : 'GURL' targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
                    if (session->tracksMovie) {
                        auto files = [NSAppleEventDescriptor listDescriptor];
                        [files insertDescriptor:[NSAppleEventDescriptor descriptorWithDescriptorType:typeFileURL bytes:session->url.data() length:session->url.size()] atIndex:1];
                        [event setParamDescriptor:files forKeyword:keyDirectObject];
                    } else
                        [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:[NSString stringWithUTF8String:session->url.c_str()]] forKeyword:keyDirectObject];
                    AppleEvent reply { typeNull, nullptr };
                    opening->sent.store(true);
                    auto error = AESendMessage(event.aeDesc, &reply, kAEWaitReply | kAENeverInteract, appleEventTimeout(opening->deadline));
                    auto result = adoptNS([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&reply]);
                    rejected = !error && [result paramDescriptorForKeyword:keyErrorNumber].int32Value;
                    opened = !error && !rejected;
                    if (rejected)
                        failure = "unsupported-source"_s;
                    else if (error == errAETimeout)
                        failure = "application-timeout"_s;
                    if (opened && session->tracksMovie) {
                        auto documents = [result paramDescriptorForKeyword:keyDirectObject];
                        opening->acknowledgedDocument = documents.descriptorType == typeObjectSpecifier || (documents.descriptorType == typeAEList && documents.numberOfItems == 1 && [documents descriptorAtIndex:1].descriptorType == typeObjectSpecifier);
                        if (opening->acknowledgedDocument) {
                            if (auto movies = movieWindows(pid, std::nullopt, opening->deadline)) {
                                std::vector<int32_t> matches;
                                for (auto& movie : *movies) {
                                    if (movie.known && movie.url == session->url && std::find(opening->previousWindows.begin(), opening->previousWindows.end(), movie.identifier) == opening->previousWindows.end())
                                        matches.push_back(movie.identifier);
                                }
                                if (matches.size() == 1)
                                    acquired = matches.front();
                            }
                        }
                        if (!opening->uniqueURL && !opening->acknowledgedDocument) {
                            opened = false;
                            failure = "application-start-uncertain"_s;
                        }
                    }
                }
            }
            callOnMainThread([this, session, opening, opened, rejected, retry, acquired, errorMessage = WTF::move(failure)]() mutable {
                opening->busy = false;
                opening->rejected = rejected;
                session->window = acquired;
                if (session->cancelled->load()) {
                    queueCleanup(session, opening);
                    return;
                }
                if (MonotonicTime::now() >= opening->deadline) {
                    finishOpening(session, makeUnexpected("application-timeout"_s));
                    return;
                }
                if (retry)
                    return;
                if (!opened) {
                    finishOpening(session, makeUnexpected(WTF::move(errorMessage)));
                    return;
                }
                advanceOpening(session);
            });
        });
    }

    void advanceOpening(std::shared_ptr<Session> session)
    {
        auto opening = session->opening;
        if (!opening || std::exchange(opening->busy, true))
            return;
        if (!opening->sent.load())
            return startOpening(session, opening);
        auto acquired = session->window;
        monitorQueue->dispatch([this, session, opening, acquired]() mutable {
            String error;
            bool ready = false;
            @autoreleasepool {
                auto pid = session->playerPID;
                if (MonotonicTime::now() >= opening->deadline)
                    error = "application-timeout"_s;
                else if (session->application.get().terminated)
                    error = "application-unavailable"_s;
                else if (!session->tracksMovie)
                    ready = true;
                else if (auto movies = movieWindows(pid, std::nullopt, opening->deadline)) {
                    auto matches = [&](auto& movie) {
                        if (acquired)
                            return movie.identifier == *acquired;
                        return (opening->uniqueURL || opening->acknowledgedDocument) && movie.known && movie.url == session->url && std::find(opening->previousWindows.begin(), opening->previousWindows.end(), movie.identifier) == opening->previousWindows.end();
                    };
                    auto found = std::find_if(movies->begin(), movies->end(), matches);
                    if (!acquired && found != movies->end() && std::find_if(found + 1, movies->end(), matches) != movies->end())
                        found = movies->end();
                    if (found == movies->end()) {
                        if (acquired)
                            error = "no-source"_s;
                    } else if (found->known && found->url != session->url)
                        error = "no-source"_s;
                    else if (found->known) {
                        acquired = found->identifier;
                        auto document = movieDocument(*acquired);
                        auto& adapter = *session->adapter;
                        auto position = movieNumber(pid, document.get(), adapter.position, opening->deadline);
                        auto rate = movieNumber(pid, document.get(), adapter.rate, opening->deadline);
                        bool needsSeek = opening->direct && opening->position;
                        auto duration = needsSeek ? movieNumber(pid, document.get(), adapter.duration, opening->deadline) : std::nullopt;
                        bool canSeek = duration && std::isfinite(*duration) && opening->position <= *duration;
                        if (session->cancelled->load()) {
                            error = "no-source"_s;
                        } else if (position && std::isfinite(*position) && *position >= 0 && rate && std::isfinite(*rate) && (!needsSeek || canSeek)) {
                            ready = !needsSeek || setMovieNumber(pid, document.get(), adapter.position, opening->position, opening->deadline);
                            if (ready)
                                ready = setMovieNumber(pid, document.get(), adapter.rate, opening->direct ? opening->rate : 1, opening->deadline);
                            if (ready) {
                                bool paused = opening->direct && opening->paused;
                                ready = movieCommand(pid, document.get(), paused ? adapter.pauseClass : adapter.playClass, paused ? adapter.pauseCommand : adapter.playCommand, nil, opening->deadline);
                            }
                        }
                    }
                }
            }
            if (session->cancelled->load())
                error = "no-source"_s;
            else if (MonotonicTime::now() >= opening->deadline)
                error = "application-timeout"_s;
            callOnMainThread([this, session, opening, acquired, ready, error = WTF::move(error)]() mutable {
                opening->busy = false;
                session->window = acquired;
                if (session->cancelled->load()) {
                    queueCleanup(session, opening);
                    return;
                }
                if (MonotonicTime::now() >= opening->deadline)
                    error = "application-timeout"_s;
                if (!error.isEmpty())
                    finishOpening(session, makeUnexpected(WTF::move(error)));
                else if (ready)
                    finishOpening(session, URL { opening->url });
            });
        });
    }

    void checkMovies()
    {
        checkCleanups();
        std::vector<std::shared_ptr<Session>> pending;
        for (auto& [token, session] : sessions) {
            if (session->opening)
                pending.push_back(session);
        }
        for (auto& session : pending) {
            if (MonotonicTime::now() >= session->opening->deadline)
                finishOpening(session, makeUnexpected("application-timeout"_s));
            else
                advanceOpening(session);
        }
        if (querying || sessions.empty())
            return;
        std::vector<std::shared_ptr<Session>> owners;
        for (auto& [token, session] : sessions) {
            if (session->tracksMovie && session->window && !session->opening)
                owners.push_back(session);
        }
        if (owners.empty())
            return;
        querying = true;
        std::map<const Session*, uint64_t> revisions;
        for (auto& session : owners)
            revisions.emplace(session.get(), session->controlRevision);
        monitorQueue->dispatch([this, owners = WTF::move(owners), revisions = WTF::move(revisions)]() mutable {
            std::map<const Session*, MovieWindowLookup> results;
            for (auto& session : owners) {
                auto pid = session->playerPID;
                results.emplace(session.get(), session->application.get().terminated ? MovieWindowLookup { true, std::nullopt } : movieWindow(pid, *session->window, session->capturesMedia ? std::nullopt : session->adapter));
            }
            callOnMainThread([this, owners = WTF::move(owners), results = WTF::move(results), revisions = WTF::move(revisions)] {
                querying = false;
                std::vector<std::shared_ptr<Session>> ended;
                for (auto& [token, session] : sessions) {
                    auto found = results.find(session.get());
                    if (!session->window || found == results.end() || !found->second.succeeded || revisions.at(session.get()) != session->controlRevision)
                        continue;
                    if (!found->second.window || (found->second.window->known && found->second.window->url != session->url))
                        ended.push_back(session);
                    else if (found->second.window->position) {
                        session->position = found->second.window->position;
                        if (found->second.window->duration && found->second.window->rate) {
                            if (RefPtr process = session->process.get())
                                process->send(Messages::MediaRestreamSession::PlaybackState(session->identifier, *found->second.window->position, *found->second.window->duration, *found->second.window->rate), 0);
                        }
                    }
                }
                for (auto& session : ended)
                    remove(session);
            });
        });
    }

    bool listen()
    {
        if (listener)
            return true;
        int descriptor = socket(AF_INET, SOCK_STREAM, 0);
        if (descriptor < 0)
            return false;
        sockaddr_in address { };
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) || fcntl(descriptor, F_SETFL, O_NONBLOCK) || bind(descriptor, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || ::listen(descriptor, SOMAXCONN)) {
            ::close(descriptor);
            return false;
        }
        socklen_t size = sizeof(address);
        if (getsockname(descriptor, reinterpret_cast<sockaddr*>(&address), &size)) {
            ::close(descriptor);
            return false;
        }
        port = ntohs(address.sin_port);
        listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, descriptor, 0, dispatch_get_main_queue());
        dispatch_source_set_cancel_handler(listener, ^{ ::close(descriptor); });
        auto* server = this;
        dispatch_source_set_event_handler(listener, ^{
            int clientSocket;
            while ((clientSocket = accept(descriptor, nullptr, nullptr)) >= 0) {
                int yes = 1;
                setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
                if (fcntl(clientSocket, F_SETFD, FD_CLOEXEC) || fcntl(clientSocket, F_SETFL, O_NONBLOCK)) {
                    ::close(clientSocket);
                    continue;
                }
                auto client = std::make_shared<Client>(*server, clientSocket);
                server->clients.emplace(clientSocket, client);
                client->start();
            }
        });
        dispatch_resume(listener);
        return true;
    }
    bool ownsPage(const WebPageProxy& page) const
    {
        return std::any_of(handoffs.begin(), handoffs.end(), [&](auto& handoff) { return handoff.page.ptr() == &page; })
            || std::any_of(sessions.begin(), sessions.end(), [&](auto& entry) { return entry.second->page.ptr() == &page; });
    }

    void closeDetachedPageIfUnowned(WebPageProxy& page)
    {
        if (!ownsPage(page) && detachedPages.contains(&page)) {
            page.close();
            detachedPages.erase(&page);
        }
    }

    void remove(std::shared_ptr<Session> session, bool notifySource = true)
    {
        auto opening = std::exchange(session->opening, nullptr);
        queueCleanup(session, opening);
        session->cancelled->store(true);
        for (auto it = sessions.begin(); it != sessions.end();) {
            if (it->second == session)
                it = sessions.erase(it);
            else
                ++it;
        }
        if (RefPtr process = session->process.get(); process && notifySource)
            process->send(Messages::MediaRestreamSession::Stop(session->identifier, !detachedPages.contains(session->page.ptr()), session->position), 0);
        closeDetachedPageIfUnowned(session->page);
        stopUnusedResources();
        if (opening && opening->completion)
            opening->completion(makeUnexpected("no-source"_s));
    }
};

MediaRestreamServer& MediaRestreamServer::singleton()
{
    static NeverDestroyed<MediaRestreamServer> server;
    return server;
}

MediaRestreamServer::MediaRestreamServer() : m_impl(std::make_unique<Impl>())
{
    auto* server = m_impl.get();
    server->applicationObserver = adoptNS([[AquaMediaPlayerApplicationObserver alloc] initWithCallback:[server] {
        callOnMainThread([server] {
            std::erase_if(server->unconfirmedDirect, [](auto& item) { return item.application.get().terminated; });
            std::vector<std::shared_ptr<Impl::Session>> ended;
            for (auto& [token, session] : server->sessions) {
                if (session->application.get().terminated)
                    ended.push_back(session);
            }
            for (auto& session : ended)
                server->remove(session);
        });
    }]);
}

void MediaRestreamServer::open(WebPageProxy& page, WebProcessProxy& process, uint64_t identifier, const String& bundleIdentifier, const URL& directURL, const String& playlist, const String& title, const String& adapterJSON, const String& captureCodec, double position, double rate, bool paused, CompletionHandler<void(Expected<URL, String>&&)>&& completion, std::shared_ptr<MediaRestreamRTSP> rtsp)
{
    if (!captureCodec.isEmpty() && !rtsp) {
        if ((captureCodec != "jpeg"_s && captureCodec != "utvideo"_s) || !directURL.isEmpty() || !playlist.isEmpty())
            return completion(makeUnexpected("unsupported-source"_s));
        process.sendWithAsyncReply(Messages::MediaRestreamSession::StreamDescription(identifier), [this, page = Ref { page }, process = Ref { process }, identifier, bundleIdentifier, directURL, playlist, title, adapterJSON, captureCodec, position, rate, paused, completion = WTF::move(completion)](String&& description) mutable {
            // Use one canonical escaped path for both the mount and receiver.
            // The general URL helper leaves punctuation that RTSP clients escape.
            GUniquePtr<char> escapedTitle(g_uri_escape_string((title.isEmpty() ? "stream"_s : title.left(1024)).utf8().data(), nullptr, FALSE));
            auto rtsp = MediaRestreamRTSP::create(description, makeString(UUID::createVersion4().toString(), '/', String::fromUTF8(escapedTitle.get())), [process = WeakPtr { process.get() }, identifier](bool video, MediaRestreamRTSP::Reply&& reply) {
                RefPtr liveProcess = process.get();
                if (!liveProcess)
                    return reply({ }, 0, 0, nullptr);
                liveProcess->sendWithAsyncReply(Messages::MediaRestreamSession::NextFrame(identifier, video), [reply = WTF::move(reply)](String&& caps, uint64_t time, uint64_t duration, std::optional<IPC::SharedBufferReference>&& data) mutable {
                    RefPtr<WebCore::SharedBuffer> buffer;
                    if (data)
                        buffer = WebCore::SharedBuffer::create(data->span());
                    reply(WTF::move(caps), time, duration, WTF::move(buffer));
                }, 0);
            });
            if (!rtsp)
                return completion(makeUnexpected("unsupported-source"_s));
            open(page, process, identifier, bundleIdentifier, directURL, playlist, title, adapterJSON, captureCodec, position, rate, paused, WTF::move(completion), WTF::move(rtsp));
        }, 0);
        return;
    }
    auto adapter = adapterJSON.isEmpty() ? std::nullopt : playerAdapter(adapterJSON);
    if ((!adapterJSON.isEmpty() && !adapter) || !std::isfinite(position) || position < 0 || !std::isfinite(rate) || rate <= 0)
        return completion(makeUnexpected("unsupported-source"_s));
    NSURL* applicationURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:bundleIdentifier.createNSString().get()];
    NSRunningApplication* application = applicationURL ? [[NSWorkspace sharedWorkspace] launchApplicationAtURL:applicationURL options:NSWorkspaceLaunchDefault configuration:@{} error:nil] : nil;
    if (!application || !page.pageClient())
        return completion(makeUnexpected("application-unavailable"_s));
    auto pid = application.processIdentifier;
    auto requestedURL = directURL.string().utf8();
    if (!directURL.isEmpty() && std::any_of(m_impl->unconfirmedDirect.begin(), m_impl->unconfirmedDirect.end(), [&](auto& item) { return item.pid == pid && item.url == requestedURL.data(); }))
        return completion(makeUnexpected("application-start-uncertain"_s));
    if (!directURL.isEmpty() && (std::any_of(m_impl->cleanups.begin(), m_impl->cleanups.end(), [&](auto& cleanup) { return cleanup->pid == pid && cleanup->url == requestedURL.data(); })
        || std::any_of(m_impl->sessions.begin(), m_impl->sessions.end(), [&](auto& entry) { return entry.second->opening && entry.second->playerPID == pid && entry.second->url == requestedURL.data(); })))
        return completion(makeUnexpected("application-busy"_s));
    bool localPlaylist = !rtsp && (directURL.isEmpty() || !playlist.isEmpty());
    if (localPlaylist && !m_impl->listen())
        return completion(makeUnexpected("application-unavailable"_s));
    unsigned char bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    constexpr char hex[] = "0123456789abcdef";
    std::string token;
    for (auto byte : bytes) {
        token += hex[byte >> 4];
        token += hex[byte & 15];
    }
    URL url = rtsp ? rtsp->url() : directURL;
    String playlistName;
    if (localPlaylist) {
        playlistName = "index.m3u8"_s;
        if (!title.isEmpty()) {
            auto name = title.left(1024);
            if (name == "."_s || name == ".."_s)
                name = "Video"_s;
            playlistName = makeString("title/"_s, encodeWithURLEscapeSequences(makeStringByReplacingAll(name, '%', "%25"_s)));
        }
        url = URL { makeString("http://127.0.0.1:"_s, m_impl->port, '/', String::fromUTF8(token), '/', playlistName) };
    }
    auto session = std::make_shared<Impl::Session>(Impl::Session { Ref { page }, WeakPtr { process }, identifier, Ref { *page.pageClient() }, process.throttler().backgroundActivity("External media playback"_s), url.string().utf8().data() });
    session->rtsp = WTF::move(rtsp);
    session->suppliedPlaylist = playlist;
    session->playlistName = localPlaylist && !title.isEmpty() ? playlistName.utf8().data() : "";
    session->application = application;
    session->playerPID = application.processIdentifier;
    session->adapter = adapter;
    session->tracksMovie = adapter.has_value();
    session->capturesMedia = directURL.isEmpty();
    m_impl->sessions.emplace(token, session);
    auto opening = std::shared_ptr<Impl::Opening>(new Impl::Opening { WTF::move(completion), url, position, rate, paused, !directURL.isEmpty(), url != directURL });
    session->opening = opening;
    m_impl->ensureMonitor();
    m_impl->advanceOpening(session);
}

String MediaRestreamServer::prepareHandoff(WebPageProxy& page, WebProcessProxy& process, const String& extensionKey)
{
    if (!page.pageClient() || page.isClosed() || isDetached(page))
        return { };
    auto ticket = UUID::createVersion4().toString();
    m_impl->handoffs.push_back({ Ref { page }, WeakPtr { process }, 0, Ref { *page.pageClient() }, process.throttler().backgroundActivity("External media dispatch"_s), ticket, extensionKey, MonotonicTime::now() + 30_s });
    RunLoop::mainSingleton().dispatchAfter(30_s, [this, ticket, extensionKey] { cancelHandoff(ticket, extensionKey); });
    return ticket;
}

bool MediaRestreamServer::claimHandoff(WebPageProxy& page, WebProcessProxy& process, const String& ticket, const String& extensionKey, uint64_t request)
{
    auto found = std::find_if(m_impl->handoffs.begin(), m_impl->handoffs.end(), [&](auto& handoff) {
        return !ticket.isEmpty() && handoff.ticket == ticket && handoff.extensionKey == extensionKey && handoff.page.ptr() == &page
            && MonotonicTime::now() < handoff.deadline;
    });
    if (found == m_impl->handoffs.end())
        return false;
    if (!beginHandoff(page, process, request))
        return false;
    cancelHandoff(ticket, extensionKey);
    return true;
}

void MediaRestreamServer::cancelHandoff(const String& ticket, const String& extensionKey)
{
    for (auto it = m_impl->handoffs.begin(); it != m_impl->handoffs.end(); ++it) {
        if (ticket.isEmpty() || it->ticket != ticket || it->extensionKey != extensionKey)
            continue;
        Ref client = it->client;
        Ref page = it->page;
        m_impl->handoffs.erase(it);
        m_impl->closeDetachedPageIfUnowned(page);
        return;
    }
}

void MediaRestreamServer::cancelPreparedHandoffs(const WebPageProxy& page)
{
    Vector<std::pair<String, String>> tickets;
    for (auto& handoff : m_impl->handoffs) {
        if (handoff.page.ptr() == &page && !handoff.ticket.isEmpty())
            tickets.append({ handoff.ticket, handoff.extensionKey });
    }
    for (auto& [ticket, extensionKey] : tickets)
        cancelHandoff(ticket, extensionKey);
}

void MediaRestreamServer::cancelPreparedHandoffs(const String& extensionKey)
{
    Vector<String> tickets;
    for (auto& handoff : m_impl->handoffs) {
        if (handoff.extensionKey == extensionKey && !handoff.ticket.isEmpty())
            tickets.append(handoff.ticket);
    }
    for (auto& ticket : tickets)
        cancelHandoff(ticket, extensionKey);
}

bool MediaRestreamServer::beginHandoff(WebPageProxy& page, WebProcessProxy& process, uint64_t identifier)
{
    if (!page.pageClient() || std::any_of(m_impl->handoffs.begin(), m_impl->handoffs.end(), [&](auto& item) { return item.process.get() == &process && item.identifier == identifier; }))
        return false;
    m_impl->handoffs.push_back({ Ref { page }, WeakPtr { process }, identifier, Ref { *page.pageClient() }, process.throttler().backgroundActivity("External media handoff"_s) });
    return true;
}

bool MediaRestreamServer::hasHandoff(const WebPageProxy& page, IPC::Connection& connection, uint64_t identifier) const
{
    return std::any_of(m_impl->handoffs.begin(), m_impl->handoffs.end(), [&](auto& item) {
        RefPtr process = item.process.get();
        return item.page.ptr() == &page && item.identifier == identifier && process && process->hasConnection(connection);
    });
}

void MediaRestreamServer::endHandoff(IPC::Connection& connection, uint64_t identifier)
{
    for (auto it = m_impl->handoffs.begin(); it != m_impl->handoffs.end(); ++it) {
        RefPtr process = it->process.get();
        if (it->identifier == identifier && process && process->hasConnection(connection)) {
            Ref client = it->client;
            Ref page = it->page;
            m_impl->handoffs.erase(it);
            m_impl->closeDetachedPageIfUnowned(page);
            return;
        }
    }
}

void MediaRestreamServer::control(IPC::Connection& connection, uint64_t identifier, const String& command, double value, CompletionHandler<void(bool)>&& completion)
{
    if (!std::isfinite(value) || (command != "play"_s && command != "pause"_s && command != "seek"_s && command != "rate"_s && command != "paused-rate"_s))
        return completion(false);
    for (auto& [token, session] : m_impl->sessions) {
        RefPtr process = session->process.get();
        if (session->identifier != identifier || !process || !process->hasConnection(connection) || session->opening || !session->window || !session->adapter || session->cancelled->load())
            continue;
        ++session->controlRevision;
        m_impl->monitorQueue->dispatch([session, command = command.isolatedCopy(), value, completion = WTF::move(completion)]() mutable {
            bool succeeded = false;
            @autoreleasepool {
                auto windows = !session->cancelled->load() && !session->application.get().terminated ? movieWindows(session->playerPID, std::nullopt) : std::nullopt;
                bool owned = windows && std::any_of(windows->begin(), windows->end(), [&](auto& window) {
                    return window.identifier == *session->window && window.known && window.url == session->url;
                });
                if (owned && !session->cancelled->load()) {
                    auto document = movieDocument(*session->window);
                    auto& adapter = *session->adapter;
                    auto pid = session->playerPID;
                    if (command == "seek"_s)
                        succeeded = value >= 0 && setMovieNumber(pid, document.get(), adapter.position, value);
                    else if (command == "pause"_s)
                        succeeded = movieCommand(pid, document.get(), adapter.pauseClass, adapter.pauseCommand);
                    else {
                        succeeded = command != "play"_s || movieCommand(pid, document.get(), adapter.playClass, adapter.playCommand);
                        if (succeeded)
                            succeeded = setMovieNumber(pid, document.get(), adapter.rate, value);
                        if (succeeded && command == "paused-rate"_s)
                            succeeded = movieCommand(pid, document.get(), adapter.pauseClass, adapter.pauseCommand);
                    }
                }
            }
            callOnMainThread([session, succeeded, completion = WTF::move(completion)]() mutable {
                completion(succeeded && !session->cancelled->load());
            });
        });
        return;
    }
    completion(false);
}

void MediaRestreamServer::activate(IPC::Connection& connection, uint64_t identifier, CompletionHandler<void(Expected<bool, String>&&)>&& completion)
{
    for (auto& [token, session] : m_impl->sessions) {
        RefPtr process = session->process.get();
        if (session->identifier != identifier || !process || !process->hasConnection(connection) || session->opening || session->cancelled->load() || session->application.get().terminated)
            continue;
        auto acquired = session->window;
        m_impl->monitorQueue->dispatch([session, acquired, completion = WTF::move(completion)]() mutable {
            Expected<bool, String> present { false };
            @autoreleasepool {
                auto application = session->application.get();
                if (application && !application.terminated) {
                    if (!session->tracksMovie)
                        present = true;
                    else if (acquired) {
                        auto windows = movieWindows(session->playerPID, std::nullopt);
                        if (!windows)
                            present = makeUnexpected("application-unavailable"_s);
                        else {
                            auto match = std::find_if(windows->begin(), windows->end(), [&](auto& window) { return window.identifier == *acquired; });
                            if (match != windows->end()) {
                                if (!match->known)
                                    present = makeUnexpected("application-unavailable"_s);
                                else
                                    present = match->url == session->url;
                            }
                        }
                    }
                }
            }
            callOnMainThread([session, acquired, present = WTF::move(present), completion = WTF::move(completion)]() mutable {
                if (session->cancelled->load() || session->opening || session->window != acquired || session->application.get().terminated)
                    return completion(false);
                if (present && *present)
                    [session->application activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                completion(WTF::move(present));
            });
        });
        return;
    }
    completion(false);
}

void MediaRestreamServer::end(IPC::Connection& connection, uint64_t identifier)
{
    for (auto& cleanup : m_impl->cleanups) {
        RefPtr process = cleanup->process.get();
        if (cleanup->completion && cleanup->identifier == identifier && process && process->hasConnection(connection))
            cleanup->completion(false, true);
    }
    for (auto& [token, session] : m_impl->sessions) {
        RefPtr process = session->process.get();
        if (session->identifier == identifier && process && process->hasConnection(connection)) {
            m_impl->remove(session);
            return;
        }
    }
}

bool MediaRestreamServer::ownsPage(const WebPageProxy& page) const
{
    return m_impl->ownsPage(page);
}

void MediaRestreamServer::processTerminated(WebProcessProxy& process)
{
    for (auto& cleanup : m_impl->cleanups) {
        if (cleanup->completion && cleanup->process.get() == &process)
            cleanup->completion(false, true);
    }
    std::vector<std::pair<Ref<PageClient>, Ref<WebPageProxy>>> pages;
    for (auto it = m_impl->handoffs.begin(); it != m_impl->handoffs.end();) {
        if (it->process.get() == &process) {
            pages.emplace_back(it->client.copyRef(), it->page.copyRef());
            it = m_impl->handoffs.erase(it);
        } else
            ++it;
    }
    for (auto& [client, page] : pages)
        m_impl->closeDetachedPageIfUnowned(page);
    std::vector<std::shared_ptr<Impl::Session>> ended;
    for (auto& [token, session] : m_impl->sessions) {
        if (session->process.get() == &process)
            ended.push_back(session);
    }
    for (auto& session : ended)
        m_impl->remove(session);
}

bool MediaRestreamServer::isDetached(const WebPageProxy& page) const
{
    return m_impl->detachedPages.contains(&page);
}

bool MediaRestreamServer::detachPage(WebPageProxy& page)
{
    return m_impl->detachedPages.insert(&page).second;
}
}
