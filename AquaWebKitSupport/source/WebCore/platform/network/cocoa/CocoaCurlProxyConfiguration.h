/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#pragma once

// The routes a browser's proxy settings give a curl load in place of the system's, as Chromium's ProxyConfig and
// Firefox's proxy filters choose them, and the errors those routes meet.
//
// A process holds one configuration, as upstream's CurlContext holds its CurlProxySettings: the proxy.settings
// value of the Safari 7 extension that controls it, or none, which leaves every load to the system resolver
// (CocoaCurlProxyResolver). A load also carries the results of the proxy filters that answered for its request
// (Firefox's proxy.onRequest), which act on the route the configuration or the system gives it.

#include <CoreFoundation/CoreFoundation.h>
#include <curl/curl.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Expected.h>
#include <wtf/Function.h>
#include <wtf/RefCounted.h>
#include <wtf/RetainPtr.h>
#include <wtf/Seconds.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class CocoaCurlProxyResolver;

// One way to the network. Direct connects to the origin itself; in a filter result it stands for the route the
// result acts on, as Firefox's "direct" ProxyInfo returns the default proxy information. An HTTPS proxy is an HTTP
// proxy reached over TLS.
struct CocoaCurlProxyServer {
    enum class Type : uint8_t { Direct, HTTP, HTTPS, SOCKS4, SOCKS4A, SOCKS5, SOCKS5Hostname };
    Type type { Type::Direct };
    String host;
    uint16_t port { 0 };
    // SOCKS credentials, and the system's for a proxy whose settings carry them.
    String username;
    String password;
    // The Proxy-Authorization field an HTTP or HTTPS proxy receives with each request and CONNECT.
    String authorizationHeader;
    // Connections through the server are shared only by loads with the same key.
    String isolationKey;
    // How long a connection to the server may take while a later server of the route waits to be tried; the
    // transport's own limit when zero.
    Seconds failoverTimeout;

    WEBCORE_EXPORT CocoaCurlProxyServer isolatedCopy() const;
    bool operator==(const CocoaCurlProxyServer&) const = default;
};

// The servers a load tries in turn, each when the connection to the one before it fails. An empty route is a
// direct connection.
using CocoaCurlProxyRoute = Vector<CocoaCurlProxyServer>;

// What one proxy filter answered for a request: servers in failover order, in which a Direct server stands for
// the route the answer acts on, and so does the end of the list; a null entry ends the route there.
struct CocoaCurlProxyFilterResult {
    Vector<std::optional<CocoaCurlProxyServer>> entries;

    WEBCORE_EXPORT CocoaCurlProxyFilterResult isolatedCopy() const;
};

// The route the filter results make of a request's route, each acting on the route the previous one made.
WEBCORE_EXPORT CocoaCurlProxyRoute applyCocoaCurlProxyFilterResults(const Vector<CocoaCurlProxyFilterResult>&, CocoaCurlProxyRoute&&);

// Chromium's ProxyConfig, in the shape of the proxy.settings value: `mode` is direct, auto_detect, pac_script,
// fixed_servers or system; `rules` holds singleProxy, or proxyForHttp, proxyForHttps and proxyForFtp with
// fallbackProxy, each a { scheme, host, port } server, and bypassList; `pacScript` holds the script's `data` or
// `url`, and `mandatory`.
class CocoaCurlProxyConfiguration final : public ThreadSafeRefCounted<CocoaCurlProxyConfiguration> {
public:
    enum class Mode : uint8_t { Direct, AutoDetect, PACScript, FixedServers, System };

    // Null for a value that is not a valid ProxyConfig.
    WEBCORE_EXPORT static RefPtr<CocoaCurlProxyConfiguration> create(const String& json);

    // The process's configuration. Loads that start afterwards take its routes.
    WEBCORE_EXPORT static RefPtr<CocoaCurlProxyConfiguration> current();
    WEBCORE_EXPORT static void setCurrent(RefPtr<CocoaCurlProxyConfiguration>&&);

    // A failure of a proxy route, as Chromium's proxy.onProxyError reports it: `fatal` when the load failed with
    // it, `error` the network error's name and `details` its description. The observer runs on the main thread.
    using ErrorObserver = Function<void(bool fatal, const String& error, const String& details)>;
    WEBCORE_EXPORT static void setErrorObserver(ErrorObserver&&);
    WEBCORE_EXPORT static void reportError(bool fatal, ASCIILiteral error, const String& details);

    Mode mode() const { return m_mode; }
    // A load to the URL takes no proxy: an implicit bypass rule or the bypass list names it.
    bool bypasses(const URL&) const;
    // The route of a fixed_servers configuration, which the bypass rules apply to.
    CocoaCurlProxyRoute fixedRoute(const URL&) const;
    // The CFNetwork proxy settings that discover the auto_detect configuration's script.
    RetainPtr<CFDictionaryRef> autoDiscoverySettings() const;
    // The proxy auto-configuration entry that runs the pac_script configuration's script.
    RetainPtr<CFDictionaryRef> autoConfigurationProxy() const;
    bool isMandatory() const { return m_mandatory; }

private:
    CocoaCurlProxyConfiguration() = default;

    struct BypassRule {
        enum class Kind : uint8_t { Local, SubtractImplicit, Hostname, IPRange };
        Kind kind { Kind::Hostname };
        String scheme;
        String hostPattern;
        std::optional<uint16_t> port;
        Vector<uint8_t> address;
        unsigned prefixLength { 0 };
    };
    static std::optional<BypassRule> parseBypassRule(const String&);
    static bool ruleMatches(const BypassRule&, const URL&);

    Mode m_mode { Mode::System };
    std::optional<CocoaCurlProxyServer> m_singleProxy;
    std::optional<CocoaCurlProxyServer> m_httpProxy;
    std::optional<CocoaCurlProxyServer> m_httpsProxy;
    std::optional<CocoaCurlProxyServer> m_ftpProxy;
    std::optional<CocoaCurlProxyServer> m_fallbackProxy;
    Vector<BypassRule> m_bypassRules;
    String m_pacData;
    String m_pacURL;
    bool m_mandatory { false };
};

// The route of a load: the process's configuration's, or, with none or a `system` one, every route the system
// resolver answers with (CocoaCurlProxyResolver), in its order; the load's filter results act on it. A load
// whose configured settings name its proxies takes those in place of a configuration, as a browser's command-line
// proxy outranks an extension's.
class WEBCORE_EXPORT CocoaCurlRouteResolver final : public RefCounted<CocoaCurlRouteResolver> {
public:
    using Completion = CompletionHandler<void(Expected<CocoaCurlProxyRoute, String>&&)>;
    static Ref<CocoaCurlRouteResolver> create(const URL&, CFDictionaryRef configuredSettings, const Vector<CocoaCurlProxyFilterResult>&, Completion&&);
    ~CocoaCurlRouteResolver();
    void start();
    void cancel();

    // Sets the server's route on the handle; `headers` takes the list that carries the Proxy-Authorization field,
    // which the handle uses until it is freed. An HTTPS proxy's TLS is the handle's CURLOPT_SSL_CTX_FUNCTION's, as
    // the origin's is: the function tells the two handshakes apart with isProxyHandshake.
    static bool apply(CURL*, const CocoaCurlProxyServer&, curl_slist*& headers);
    // Sets the credentials the handle offers its proxy. curl takes an empty string for a credential, which a SOCKS5
    // proxy is then offered username/password authentication with, so a user and password both empty set none.
    static bool applyCredentials(CURL*, const String& user, const String& password);
    // Whether the handshake whose SSL_CTX the handle's CURLOPT_SSL_CTX_FUNCTION receives is the proxy's, for a
    // handle that apply() routed through an HTTPS proxy. curl hands both handshakes to the one function
    // (vtls/openssl.c, data->set.ssl.fsslctx), the proxy's first; the origin's begins only once the CONNECT
    // tunnel stands, after a 2xx answer that CURLINFO_HTTP_CONNECTCODE reports.
    static bool isProxyHandshake(CURL*);
    // The URL whose host the proxy's certificate is evaluated for.
    static URL tlsURL(const CocoaCurlProxyServer&);

private:
    CocoaCurlRouteResolver(const URL&, CFDictionaryRef, const Vector<CocoaCurlProxyFilterResult>&, RefPtr<CocoaCurlProxyConfiguration>&&, Completion&&);
    void finish(Expected<CocoaCurlProxyRoute, String>&&);

    URL m_url;
    RetainPtr<CFDictionaryRef> m_configuredSettings;
    Vector<CocoaCurlProxyFilterResult> m_filterResults;
    RefPtr<CocoaCurlProxyConfiguration> m_configuration;
    RefPtr<CocoaCurlProxyResolver> m_resolver;
    Completion m_completion;
};

} // namespace WebCore
