/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlProxyConfiguration.h"

#include "CocoaCurlProxyResolver.h"
#include <CFNetwork/CFNetwork.h>
#include <arpa/inet.h>
#include <wtf/JSONValues.h>
#include <wtf/Lock.h>
#include <wtf/MainThread.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>

namespace WebCore {

CocoaCurlProxyServer CocoaCurlProxyServer::isolatedCopy() const
{
    return { type, host.isolatedCopy(), port, username.isolatedCopy(), password.isolatedCopy(), authorizationHeader.isolatedCopy(), isolationKey.isolatedCopy(), failoverTimeout };
}

CocoaCurlProxyFilterResult CocoaCurlProxyFilterResult::isolatedCopy() const
{
    CocoaCurlProxyFilterResult copy;
    for (auto& entry : entries)
        copy.entries.append(entry ? std::optional { entry->isolatedCopy() } : std::nullopt);
    return copy;
}

// Firefox's ProxyInfoData.createProxyInfoFromData: a Direct entry returns the route the result acts on when that
// route has a proxy, and is a direct connection otherwise.
CocoaCurlProxyRoute applyCocoaCurlProxyFilterResults(const Vector<CocoaCurlProxyFilterResult>& results, CocoaCurlProxyRoute&& route)
{
    for (auto& result : results) {
        CocoaCurlProxyRoute next;
        bool ended = false;
        for (auto& entry : result.entries) {
            if (!entry) {
                ended = true;
                break;
            }
            if (entry->type == CocoaCurlProxyServer::Type::Direct) {
                if (route.isEmpty())
                    next.append(*entry);
                else
                    next.appendVector(route);
                ended = true;
                break;
            }
            next.append(*entry);
        }
        if (!ended)
            next.appendVector(route);
        route = WTF::move(next);
    }
    return WTF::move(route);
}

static std::optional<CocoaCurlProxyServer> serverFromJSON(const JSON::Object& object)
{
    auto scheme = object.getString("scheme"_s);
    auto host = object.getString("host"_s);
    auto port = object.getInteger("port"_s);
    if (host.isEmpty() || !port || *port <= 0 || *port > 65535)
        return std::nullopt;
    CocoaCurlProxyServer server;
    if (scheme.isNull() || scheme == "http"_s)
        server.type = CocoaCurlProxyServer::Type::HTTP;
    else if (scheme == "https"_s)
        server.type = CocoaCurlProxyServer::Type::HTTPS;
    else if (scheme == "socks4"_s)
        server.type = CocoaCurlProxyServer::Type::SOCKS4;
    else if (scheme == "socks5"_s)
        server.type = CocoaCurlProxyServer::Type::SOCKS5Hostname;
    else
        return std::nullopt;
    server.host = host;
    server.port = *port;
    return server;
}

RefPtr<CocoaCurlProxyConfiguration> CocoaCurlProxyConfiguration::create(const String& json)
{
    auto value = JSON::Value::parseJSON(json);
    RefPtr object = value ? value->asObject() : nullptr;
    if (!object)
        return nullptr;
    RefPtr configuration = adoptRef(*new CocoaCurlProxyConfiguration);
    auto mode = object->getString("mode"_s);
    if (mode == "direct"_s)
        configuration->m_mode = Mode::Direct;
    else if (mode == "auto_detect"_s)
        configuration->m_mode = Mode::AutoDetect;
    else if (mode == "pac_script"_s)
        configuration->m_mode = Mode::PACScript;
    else if (mode == "fixed_servers"_s)
        configuration->m_mode = Mode::FixedServers;
    else if (mode == "system"_s)
        configuration->m_mode = Mode::System;
    else
        return nullptr;

    if (configuration->m_mode == Mode::FixedServers) {
        RefPtr rules = object->getObject("rules"_s);
        if (!rules)
            return nullptr;
        auto server = [&](ASCIILiteral name, std::optional<CocoaCurlProxyServer>& slot) {
            RefPtr serverObject = rules->getObject(name);
            if (!serverObject)
                return true;
            slot = serverFromJSON(*serverObject);
            return !!slot;
        };
        if (!server("singleProxy"_s, configuration->m_singleProxy) || !server("proxyForHttp"_s, configuration->m_httpProxy)
            || !server("proxyForHttps"_s, configuration->m_httpsProxy) || !server("proxyForFtp"_s, configuration->m_ftpProxy)
            || !server("fallbackProxy"_s, configuration->m_fallbackProxy))
            return nullptr;
        if (RefPtr bypassList = rules->getArray("bypassList"_s)) {
            // Chromium's ProxyBypassRules::ParseFromString skips a rule it cannot parse.
            for (auto& entry : *bypassList) {
                if (auto rule = parseBypassRule(entry->asString()))
                    configuration->m_bypassRules.append(WTF::move(*rule));
            }
        }
    }

    if (configuration->m_mode == Mode::PACScript) {
        RefPtr pacScript = object->getObject("pacScript"_s);
        if (!pacScript)
            return nullptr;
        configuration->m_pacData = pacScript->getString("data"_s);
        configuration->m_pacURL = pacScript->getString("url"_s);
        configuration->m_mandatory = pacScript->getBoolean("mandatory"_s).value_or(false);
        if (configuration->m_pacData.isEmpty() && configuration->m_pacURL.isEmpty())
            return nullptr;
    }
    return configuration;
}

static Lock currentConfigurationLock;

static RefPtr<CocoaCurlProxyConfiguration>& currentConfiguration() WTF_REQUIRES_LOCK(currentConfigurationLock)
{
    static NeverDestroyed<RefPtr<CocoaCurlProxyConfiguration>> configuration;
    return configuration.get();
}

RefPtr<CocoaCurlProxyConfiguration> CocoaCurlProxyConfiguration::current()
{
    Locker locker { currentConfigurationLock };
    return currentConfiguration();
}

void CocoaCurlProxyConfiguration::setCurrent(RefPtr<CocoaCurlProxyConfiguration>&& configuration)
{
    Locker locker { currentConfigurationLock };
    currentConfiguration() = WTF::move(configuration);
}

static CocoaCurlProxyConfiguration::ErrorObserver& errorObserver()
{
    ASSERT(isMainThread());
    static NeverDestroyed<CocoaCurlProxyConfiguration::ErrorObserver> observer;
    return observer.get();
}

void CocoaCurlProxyConfiguration::setErrorObserver(ErrorObserver&& observer)
{
    errorObserver() = WTF::move(observer);
}

void CocoaCurlProxyConfiguration::reportError(bool fatal, ASCIILiteral error, const String& details)
{
    callOnMainThread([fatal, error, details = details.isolatedCopy()] {
        if (auto& observer = errorObserver())
            observer(fatal, String { error }, details);
    });
}

// A host as Chromium compares it: lower case, an IPv6 literal without its brackets.
static String bareHost(const URL& url)
{
    auto host = url.host().convertToASCIILowercase();
    if (host.startsWith('[') && host.endsWith(']'))
        return host.substring(1, host.length() - 2);
    return host;
}

static std::optional<Vector<uint8_t>> ipAddress(const String& literal)
{
    auto utf8 = literal.utf8();
    in_addr address4;
    if (inet_pton(AF_INET, utf8.data(), &address4) == 1)
        return Vector<uint8_t> { std::span { reinterpret_cast<const uint8_t*>(&address4), sizeof(address4) } };
    in6_addr address6;
    if (inet_pton(AF_INET6, utf8.data(), &address6) == 1)
        return Vector<uint8_t> { std::span { reinterpret_cast<const uint8_t*>(&address6), sizeof(address6) } };
    return std::nullopt;
}

static constexpr std::array<uint8_t, 12> ipv4MappedPrefix { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

static Vector<uint8_t> unmapped(Vector<uint8_t>&& address)
{
    if (address.size() == 16 && std::equal(ipv4MappedPrefix.begin(), ipv4MappedPrefix.end(), address.begin()))
        return Vector<uint8_t> { address.span().subspan(12) };
    return WTF::move(address);
}

static Vector<uint8_t> mapped(const Vector<uint8_t>& address)
{
    Vector<uint8_t> result { std::span { ipv4MappedPrefix } };
    result.appendVector(address);
    return result;
}

// Chromium's IPAddressMatchesPrefix: an IPv4 address and an IPv6 prefix, or the reverse, compare in IPv4-mapped form.
static bool matchesPrefix(Vector<uint8_t>&& address, Vector<uint8_t>&& prefix, unsigned prefixLength)
{
    if (address.size() != prefix.size()) {
        if (address.size() == 4)
            address = mapped(address);
        else {
            prefix = mapped(prefix);
            prefixLength += 96;
        }
    }
    if (prefixLength > address.size() * 8)
        return false;
    for (unsigned bit = 0; bit < prefixLength; ++bit) {
        uint8_t mask = 0x80 >> (bit % 8);
        if ((address[bit / 8] & mask) != (prefix[bit / 8] & mask))
            return false;
    }
    return true;
}

// Chromium's MatchPattern: `*` matches any run of characters and `?` any one.
static bool matchesPattern(StringView text, StringView pattern)
{
    size_t textIndex = 0;
    size_t patternIndex = 0;
    std::optional<size_t> star;
    size_t starText = 0;
    while (textIndex < text.length()) {
        if (patternIndex < pattern.length() && pattern[patternIndex] == '*') {
            star = patternIndex++;
            starText = textIndex;
        } else if (patternIndex < pattern.length() && (pattern[patternIndex] == '?' || pattern[patternIndex] == text[textIndex])) {
            ++patternIndex;
            ++textIndex;
        } else if (star) {
            patternIndex = *star + 1;
            textIndex = ++starText;
        } else
            return false;
    }
    while (patternIndex < pattern.length() && pattern[patternIndex] == '*')
        ++patternIndex;
    return patternIndex == pattern.length();
}

// Chromium's implicit bypass rules: localhost, loopback and link-local addresses.
static bool matchesImplicitRules(const URL& url)
{
    auto host = bareHost(url);
    if (host == "localhost"_s || host == "localhost."_s || host.endsWith(".localhost"_s) || host.endsWith(".localhost."_s))
        return true;
    auto address = ipAddress(host);
    if (!address)
        return false;
    auto bytes = unmapped(WTF::move(*address));
    if (bytes.size() == 4)
        return bytes[0] == 127 || (bytes[0] == 169 && bytes[1] == 254);
    static constexpr std::array<uint8_t, 16> loopback { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    return std::equal(loopback.begin(), loopback.end(), bytes.begin()) || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
}

// Chromium's ProxyBypassRules::ParseRule.
auto CocoaCurlProxyConfiguration::parseBypassRule(const String& rawRule) -> std::optional<BypassRule>
{
    auto raw = rawRule.trim(isASCIIWhitespace<char16_t>);
    BypassRule rule;
    if (raw == "<local>"_s) {
        rule.kind = BypassRule::Kind::Local;
        return rule;
    }
    if (raw == "<-loopback>"_s) {
        rule.kind = BypassRule::Kind::SubtractImplicit;
        return rule;
    }
    if (size_t schemeEnd = raw.find("://"_s); schemeEnd != notFound) {
        rule.scheme = raw.left(schemeEnd).convertToASCIILowercase();
        if (rule.scheme.isEmpty())
            return std::nullopt;
        raw = raw.substring(schemeEnd + 3);
    }
    if (raw.isEmpty())
        return std::nullopt;

    if (size_t slash = raw.find('/'); slash != notFound) {
        auto address = ipAddress(raw.left(slash));
        auto prefixLength = parseInteger<unsigned>(StringView(raw).substring(slash + 1));
        if (!address || !prefixLength || *prefixLength > address->size() * 8)
            return std::nullopt;
        rule.kind = BypassRule::Kind::IPRange;
        rule.address = WTF::move(*address);
        rule.prefixLength = *prefixLength;
        return rule;
    }

    // An IP literal, with its port, compares in canonical form.
    String host = raw;
    std::optional<uint16_t> port;
    if (raw.startsWith('[')) {
        size_t close = raw.find(']');
        if (close == notFound)
            return std::nullopt;
        host = raw.substring(1, close - 1);
        if (close + 1 < raw.length()) {
            if (raw[close + 1] != ':')
                return std::nullopt;
            port = parseInteger<uint16_t>(StringView(raw).substring(close + 2));
            if (!port)
                return std::nullopt;
        }
    } else if (size_t colon = raw.reverseFind(':'); colon != notFound && raw.find(':') == colon) {
        port = parseInteger<uint16_t>(StringView(raw).substring(colon + 1));
        if (!port)
            return std::nullopt;
        host = raw.left(colon);
    }
    if (auto address = ipAddress(host)) {
        std::array<char, INET6_ADDRSTRLEN> buffer { };
        inet_ntop(address->size() == 4 ? AF_INET : AF_INET6, address->span().data(), buffer.data(), buffer.size());
        rule.hostPattern = String::fromLatin1(buffer.data());
        rule.port = port;
        return rule;
    }
    if (raw.startsWith('[') || (raw.find(':') != raw.reverseFind(':')))
        return std::nullopt;
    if (host.startsWith('.'))
        host = makeString('*', host);
    rule.hostPattern = host.convertToASCIILowercase();
    rule.port = port;
    return rule;
}

bool CocoaCurlProxyConfiguration::ruleMatches(const BypassRule& rule, const URL& url)
{
    if (!rule.scheme.isEmpty() && !url.protocolIs(rule.scheme))
        return false;
    auto host = bareHost(url);
    switch (rule.kind) {
    case BypassRule::Kind::Local:
        return !host.contains('.') && !ipAddress(host);
    case BypassRule::Kind::SubtractImplicit:
        return false;
    case BypassRule::Kind::IPRange: {
        auto address = ipAddress(host);
        return address && matchesPrefix(WTF::move(*address), Vector<uint8_t> { rule.address }, rule.prefixLength);
    }
    case BypassRule::Kind::Hostname:
        if (rule.port && url.port().value_or(defaultPortForProtocol(url.protocol()).value_or(0)) != *rule.port)
            return false;
        if (auto address = ipAddress(host)) {
            std::array<char, INET6_ADDRSTRLEN> buffer { };
            inet_ntop(address->size() == 4 ? AF_INET : AF_INET6, address->span().data(), buffer.data(), buffer.size());
            host = String::fromLatin1(buffer.data());
        }
        return matchesPattern(host, rule.hostPattern);
    }
    return false;
}

// The first rule that matches decides; with none, the implicit rules do, which <-loopback> turns off.
bool CocoaCurlProxyConfiguration::bypasses(const URL& url) const
{
    for (auto& rule : m_bypassRules) {
        if (rule.kind == BypassRule::Kind::SubtractImplicit) {
            if (matchesImplicitRules(url))
                return false;
            continue;
        }
        if (ruleMatches(rule, url))
            return true;
    }
    return matchesImplicitRules(url);
}

// Chromium's ProxyConfig::ProxyRules: a single proxy for every URL, or one by scheme, WebSocket schemes taking
// their HTTP counterparts', with the fallback proxy for a scheme that has none.
CocoaCurlProxyRoute CocoaCurlProxyConfiguration::fixedRoute(const URL& url) const
{
    if (bypasses(url))
        return { };
    auto route = [](const std::optional<CocoaCurlProxyServer>& server) -> CocoaCurlProxyRoute {
        if (!server)
            return { };
        return { server->isolatedCopy() };
    };
    if (m_singleProxy)
        return route(m_singleProxy);
    const std::optional<CocoaCurlProxyServer>* server = nullptr;
    if (url.protocolIs("http"_s) || url.protocolIs("ws"_s))
        server = &m_httpProxy;
    else if (url.protocolIs("https"_s) || url.protocolIs("wss"_s))
        server = &m_httpsProxy;
    else if (url.protocolIs("ftp"_s))
        server = &m_ftpProxy;
    return route(server && *server ? *server : m_fallbackProxy);
}

RetainPtr<CFDictionaryRef> CocoaCurlProxyConfiguration::autoDiscoverySettings() const
{
    int enabled = 1;
    auto one = adoptCF(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &enabled));
    auto settings = adoptCF(CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFDictionarySetValue(settings.get(), kCFNetworkProxiesProxyAutoDiscoveryEnable, one.get());
    return settings;
}

RetainPtr<CFDictionaryRef> CocoaCurlProxyConfiguration::autoConfigurationProxy() const
{
    auto proxy = adoptCF(CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    if (!m_pacData.isEmpty()) {
        CFDictionarySetValue(proxy.get(), kCFProxyTypeKey, kCFProxyTypeAutoConfigurationJavaScript);
        CFDictionarySetValue(proxy.get(), kCFProxyAutoConfigurationJavaScriptKey, m_pacData.createCFString().get());
    } else {
        CFDictionarySetValue(proxy.get(), kCFProxyTypeKey, kCFProxyTypeAutoConfigurationURL);
        // Loads on several threads read the configuration, so its strings are read in place, never copied.
        auto url = adoptCF(CFURLCreateWithString(kCFAllocatorDefault, m_pacURL.createCFString().get(), nullptr));
        if (url)
            CFDictionarySetValue(proxy.get(), kCFProxyAutoConfigurationURLKey, url.get());
    }
    return proxy;
}

// A route CFNetwork answers with: an HTTP proxy for kCFProxyTypeHTTP and kCFProxyTypeHTTPS (the proxy for https:
// URLs), a SOCKS proxy that resolves the host, or a direct connection.
static std::optional<CocoaCurlProxyServer> serverFromCFProxy(CFDictionaryRef proxy)
{
    auto type = static_cast<CFStringRef>(CFDictionaryGetValue(proxy, kCFProxyTypeKey));
    if (!type)
        return std::nullopt;
    CocoaCurlProxyServer server;
    if (CFEqual(type, kCFProxyTypeNone))
        return server;
    if (CFEqual(type, kCFProxyTypeHTTP) || CFEqual(type, kCFProxyTypeHTTPS))
        server.type = CocoaCurlProxyServer::Type::HTTP;
    else if (CFEqual(type, kCFProxyTypeSOCKS))
        server.type = CocoaCurlProxyServer::Type::SOCKS5Hostname;
    else
        return std::nullopt;
    auto host = static_cast<CFStringRef>(CFDictionaryGetValue(proxy, kCFProxyHostNameKey));
    auto port = static_cast<CFNumberRef>(CFDictionaryGetValue(proxy, kCFProxyPortNumberKey));
    int portNumber = 0;
    if (!host || CFGetTypeID(host) != CFStringGetTypeID() || !port || CFGetTypeID(port) != CFNumberGetTypeID() || !CFNumberGetValue(port, kCFNumberIntType, &portNumber) || portNumber <= 0 || portNumber > 65535)
        return std::nullopt;
    server.host = host;
    server.port = portNumber;
    auto user = CFDictionaryGetValue(proxy, kCFProxyUsernameKey);
    auto password = CFDictionaryGetValue(proxy, kCFProxyPasswordKey);
    if (user && CFGetTypeID(user) == CFStringGetTypeID())
        server.username = static_cast<CFStringRef>(user);
    if (password && CFGetTypeID(password) == CFStringGetTypeID())
        server.password = static_cast<CFStringRef>(password);
    return server;
}

Ref<CocoaCurlRouteResolver> CocoaCurlRouteResolver::create(const URL& url, CFDictionaryRef configuredSettings, const Vector<CocoaCurlProxyFilterResult>& filterResults, Completion&& completion)
{
    bool hasConfiguredSettings = configuredSettings && CFDictionaryGetCount(configuredSettings);
    RefPtr configuration = hasConfiguredSettings ? nullptr : CocoaCurlProxyConfiguration::current();
    if (configuration && configuration->mode() == CocoaCurlProxyConfiguration::Mode::System)
        configuration = nullptr;
    return adoptRef(*new CocoaCurlRouteResolver(url, configuredSettings, filterResults, WTF::move(configuration), WTF::move(completion)));
}

// The routes CFNetwork answers with, in its order: a load tries each when the connection to the one before it fails,
// as CFNetwork's own connections do. An entry of a type curl has no proxy for is passed over.
static CocoaCurlProxyRoute routeFromCFProxies(CFArrayRef proxies)
{
    CocoaCurlProxyRoute route;
    for (CFIndex index = 0; proxies && index < CFArrayGetCount(proxies); ++index) {
        if (auto server = serverFromCFProxy(static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(proxies, index))))
            route.append(WTF::move(*server));
    }
    return route;
}

CocoaCurlRouteResolver::CocoaCurlRouteResolver(const URL& url, CFDictionaryRef configuredSettings, const Vector<CocoaCurlProxyFilterResult>& filterResults, RefPtr<CocoaCurlProxyConfiguration>&& configuration, Completion&& completion)
    : m_url(url)
    , m_configuredSettings(configuredSettings)
    , m_filterResults(filterResults)
    , m_configuration(WTF::move(configuration))
    , m_completion(WTF::move(completion))
{
}

CocoaCurlRouteResolver::~CocoaCurlRouteResolver()
{
    cancel();
}

void CocoaCurlRouteResolver::cancel()
{
    if (RefPtr resolver = std::exchange(m_resolver, nullptr))
        resolver->cancel();
    m_completion = nullptr;
}

void CocoaCurlRouteResolver::finish(Expected<CocoaCurlProxyRoute, String>&& route)
{
    Ref protectedThis { *this };
    m_resolver = nullptr;
    auto completion = std::exchange(m_completion, nullptr);
    if (!completion)
        return;
    if (!route)
        return completion(WTF::move(route));
    completion(applyCocoaCurlProxyFilterResults(m_filterResults, WTF::move(*route)));
}

void CocoaCurlRouteResolver::start()
{
    using Mode = CocoaCurlProxyConfiguration::Mode;
    if (!m_configuration) {
        m_resolver = CocoaCurlProxyResolver::createForRoutes(m_url, m_configuredSettings.get(), [protectedThis = Ref { *this }](RetainPtr<CFArrayRef>&& proxies, const String& error) {
            if (!error.isEmpty())
                return protectedThis->finish(makeUnexpected(error));
            auto route = routeFromCFProxies(proxies.get());
            if (route.isEmpty())
                return protectedThis->finish(makeUnexpected("System proxy resolution returned no route"_s));
            protectedThis->finish(WTF::move(route));
        });
        m_resolver->start();
        return;
    }
    switch (m_configuration->mode()) {
    case Mode::System:
        ASSERT_NOT_REACHED();
        [[fallthrough]];
    case Mode::Direct:
        return finish(CocoaCurlProxyRoute { });
    case Mode::FixedServers:
        return finish(m_configuration->fixedRoute(m_url));
    case Mode::AutoDetect:
    case Mode::PACScript:
        break;
    }
    if (m_configuration->bypasses(m_url))
        return finish(CocoaCurlProxyRoute { });
    // A script that fails leaves the load direct, unless the configuration makes it mandatory.
    auto completion = [protectedThis = Ref { *this }](RetainPtr<CFArrayRef>&& proxies, const String& error) {
        if (!error.isEmpty() || !proxies) {
            if (protectedThis->m_configuration->isMandatory())
                return protectedThis->finish(makeUnexpected("net::ERR_MANDATORY_PROXY_CONFIGURATION_FAILED"_s));
            CocoaCurlProxyConfiguration::reportError(false, "net::ERR_PAC_SCRIPT_FAILED"_s, error);
            return protectedThis->finish(CocoaCurlProxyRoute { });
        }
        protectedThis->finish(routeFromCFProxies(proxies.get()));
    };
    if (m_configuration->mode() == Mode::AutoDetect)
        m_resolver = CocoaCurlProxyResolver::createForRoutes(m_url, m_configuration->autoDiscoverySettings().get(), WTF::move(completion));
    else
        m_resolver = CocoaCurlProxyResolver::createForAutoConfiguration(m_url, m_configuration->autoConfigurationProxy().get(), WTF::move(completion));
    m_resolver->start();
}

bool CocoaCurlRouteResolver::applyCredentials(CURL* handle, const String& user, const String& password)
{
    bool none = user.isEmpty() && password.isEmpty();
    return curl_easy_setopt(handle, CURLOPT_PROXYUSERNAME, none ? nullptr : user.utf8().data()) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_PROXYPASSWORD, none ? nullptr : password.utf8().data()) == CURLE_OK;
}

bool CocoaCurlRouteResolver::apply(CURL* easy, const CocoaCurlProxyServer& server, curl_slist*& headers)
{
    curl_slist_free_all(std::exchange(headers, nullptr));
    if (curl_easy_setopt(easy, CURLOPT_PROXYHEADER, nullptr) != CURLE_OK)
        return false;
    if (server.type == CocoaCurlProxyServer::Type::Direct)
        return curl_easy_setopt(easy, CURLOPT_PROXY, "") == CURLE_OK && curl_easy_setopt(easy, CURLOPT_NOPROXY, "*") == CURLE_OK;
    long curlType = CURLPROXY_HTTP;
    ASCIILiteral scheme = "http://"_s;
    switch (server.type) {
    case CocoaCurlProxyServer::Type::Direct:
    case CocoaCurlProxyServer::Type::HTTP:
        break;
    case CocoaCurlProxyServer::Type::HTTPS:
        curlType = CURLPROXY_HTTPS;
        scheme = "https://"_s;
        break;
    case CocoaCurlProxyServer::Type::SOCKS4:
        curlType = CURLPROXY_SOCKS4;
        scheme = "socks4://"_s;
        break;
    case CocoaCurlProxyServer::Type::SOCKS4A:
        curlType = CURLPROXY_SOCKS4A;
        scheme = "socks4a://"_s;
        break;
    case CocoaCurlProxyServer::Type::SOCKS5:
        curlType = CURLPROXY_SOCKS5;
        scheme = "socks5://"_s;
        break;
    case CocoaCurlProxyServer::Type::SOCKS5Hostname:
        curlType = CURLPROXY_SOCKS5_HOSTNAME;
        scheme = "socks5h://"_s;
        break;
    }
    bool bracketed = server.host.contains(':');
    auto proxyURL = makeString(scheme, bracketed ? "["_s : ""_s, server.host, bracketed ? "]"_s : ""_s);
    if (!server.authorizationHeader.isEmpty()) {
        headers = curl_slist_append(nullptr, makeString("Proxy-Authorization: "_s, server.authorizationHeader).utf8().data());
        if (!headers || curl_easy_setopt(easy, CURLOPT_PROXYHEADER, headers) != CURLE_OK)
            return false;
    }
    // The proxy's certificate is evaluated natively in the handshake (isProxyHandshake), as the origin's is: curl
    // loads no CA store for it and leaves the hostname to SecPolicyCreateSSL.
    return curl_easy_setopt(easy, CURLOPT_PROXY, proxyURL.utf8().data()) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXYPORT, static_cast<long>(server.port)) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXYTYPE, curlType) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_NOPROXY, "") == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXY_SSL_VERIFYPEER, 1L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXY_SSL_VERIFYHOST, 0L) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXY_CAINFO, nullptr) == CURLE_OK
        && curl_easy_setopt(easy, CURLOPT_PROXY_CAPATH, nullptr) == CURLE_OK;
}

bool CocoaCurlRouteResolver::isProxyHandshake(CURL* easy)
{
    long connectCode = 0;
    return curl_easy_getinfo(easy, CURLINFO_HTTP_CONNECTCODE, &connectCode) == CURLE_OK && connectCode / 100 != 2;
}

URL CocoaCurlRouteResolver::tlsURL(const CocoaCurlProxyServer& server)
{
    bool bracketed = server.host.contains(':');
    return URL { makeString("https://"_s, bracketed ? "["_s : ""_s, server.host, bracketed ? "]"_s : ""_s, ':', server.port, '/') };
}

} // namespace WebCore
