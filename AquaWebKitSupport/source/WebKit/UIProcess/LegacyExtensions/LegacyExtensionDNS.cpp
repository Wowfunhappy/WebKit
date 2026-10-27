#include "config.h"
#include "LegacyExtensionDNS.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/URL.h>
#include <wtf/WorkQueue.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>

namespace WebKit::LegacyExtensions {

namespace {

struct Lookup {
    CString hostname;
    bool canonicalName { false };
    bool disableIPv4 { false };
    bool disableIPv6 { false };
    bool offline { false };
    bool allowNameCollisions { false };
};

struct Answer {
    Vector<String> addresses;
    String canonicalName;
    String error;
};

} // namespace

static constexpr auto unknownHost = "NS_ERROR_UNKNOWN_HOST"_s;

static String addressString(const struct addrinfo& result)
{
    char buffer[INET6_ADDRSTRLEN] { };
    if (result.ai_family == AF_INET && inet_ntop(AF_INET, &reinterpret_cast<const struct sockaddr_in*>(result.ai_addr)->sin_addr, buffer, sizeof(buffer)))
        return String::fromLatin1(buffer);
    if (result.ai_family == AF_INET6 && inet_ntop(AF_INET6, &reinterpret_cast<const struct sockaddr_in6*>(result.ai_addr)->sin6_addr, buffer, sizeof(buffer)))
        return String::fromLatin1(buffer);
    return { };
}

// nsHostResolver answers an IP address literal itself, whose canonical name is the literal, and an offline
// lookup from its cache alone, which here is no cache: the system resolver keeps the only one. Any other
// lookup is GetAddrInfo.cpp's native one: PR_GetAddrInfoByName with AI_ADDRCONFIG, which NSPR leaves out
// for localhost, and AI_CANONNAME for a canonical name, falling back to the host name; IPv4 records dropped
// after an unspecified-family lookup when IPv4 is disabled; and ICANN's name-collision address 127.0.53.53
// dropped unless collisions are allowed.
static Answer resolve(const Lookup& lookup)
{
    Answer answer;
    struct addrinfo hints { };
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST;

    struct addrinfo* results = nullptr;
    if (!getaddrinfo(lookup.hostname.data(), nullptr, &hints, &results) && results) {
        if (auto address = addressString(*results); !address.isNull()) {
            answer.addresses.append(WTF::move(address));
            answer.canonicalName = String::fromUTF8(lookup.hostname.span());
        } else
            answer.error = unknownHost;
        freeaddrinfo(results);
        return answer;
    }
    if (lookup.offline) {
        answer.error = "NS_ERROR_OFFLINE"_s;
        return answer;
    }

    hints.ai_family = lookup.disableIPv6 ? AF_INET : AF_UNSPEC;
    hints.ai_flags = lookup.canonicalName ? AI_CANONNAME : 0;
    if (strcmp(lookup.hostname.data(), "localhost"))
        hints.ai_flags |= AI_ADDRCONFIG;
    results = nullptr;
    if (getaddrinfo(lookup.hostname.data(), nullptr, &hints, &results) || !results) {
        answer.error = unknownHost;
        return answer;
    }

    for (auto* result = results; result; result = result->ai_next) {
        if (answer.canonicalName.isNull() && result->ai_canonname && *result->ai_canonname)
            answer.canonicalName = String::fromUTF8(result->ai_canonname);
        if (result->ai_family == AF_INET) {
            if (lookup.disableIPv4 && !lookup.disableIPv6)
                continue;
            if (!lookup.allowNameCollisions && reinterpret_cast<struct sockaddr_in*>(result->ai_addr)->sin_addr.s_addr == htonl(0x7f003535))
                continue;
        }
        auto address = addressString(*result);
        if (!address.isNull() && !answer.addresses.contains(address))
            answer.addresses.append(WTF::move(address));
    }
    freeaddrinfo(results);

    if (answer.addresses.isEmpty()) {
        answer.error = unknownHost;
        return answer;
    }
    if (answer.canonicalName.isNull())
        answer.canonicalName = String::fromUTF8(lookup.hostname.span());
    return answer;
}

void resolveHostname(const String& hostname, const Vector<String>& flags, bool prefetchDisabled, CompletionHandler<void(Expected<Ref<JSON::Object>, String>&&)>&& completionHandler)
{
    // nsDNSService::AsyncResolveInternal refuses a speculative lookup while prefetching is disabled.
    if (prefetchDisabled && flags.contains("speculate"_s))
        return completionHandler(makeUnexpected(String { "NS_ERROR_DNS_LOOKUP_QUEUE_FULL"_s }));

    // PreprocessHostname: a name that is not ASCII is looked up by its ACE form.
    String asciiHostname = hostname;
    if (!hostname.containsOnlyASCII()) {
        URL url { makeString("http://"_s, hostname, '/') };
        asciiHostname = url.isValid() ? url.host().toString() : String { };
    }
    if (asciiHostname.isEmpty())
        return completionHandler(makeUnexpected(String { unknownHost }));

    Lookup lookup;
    lookup.hostname = asciiHostname.utf8();
    lookup.canonicalName = flags.contains("canonical_name"_s);
    lookup.disableIPv4 = flags.contains("disable_ipv4"_s);
    lookup.disableIPv6 = flags.contains("disable_ipv6"_s);
    lookup.offline = flags.contains("offline"_s);
    lookup.allowNameCollisions = flags.contains("allow_name_collisions"_s);

    static NeverDestroyed<Ref<ConcurrentWorkQueue>> queue { ConcurrentWorkQueue::create("org.webkit.LegacyExtensionDNS"_s) };
    queue.get()->dispatch([lookup = WTF::move(lookup), completionHandler = WTF::move(completionHandler)]() mutable {
        auto answer = resolve(lookup);
        RunLoop::mainSingleton().dispatch([addresses = crossThreadCopy(WTF::move(answer.addresses)), canonicalName = crossThreadCopy(WTF::move(answer.canonicalName)), error = crossThreadCopy(WTF::move(answer.error)), wantsCanonicalName = lookup.canonicalName, completionHandler = WTF::move(completionHandler)]() mutable {
            if (!error.isNull())
                return completionHandler(makeUnexpected(WTF::move(error)));
            auto record = JSON::Object::create();
            auto addressArray = JSON::Array::create();
            for (auto& address : addresses)
                addressArray->pushString(address);
            record->setArray("addresses"_s, WTF::move(addressArray));
            if (wantsCanonicalName)
                record->setString("canonicalName"_s, canonicalName);
            record->setBoolean("isTRR"_s, false);
            completionHandler(WTF::move(record));
        });
    });
}

} // namespace WebKit::LegacyExtensions
