/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlTransfer.h"
#include "CocoaCurlClientHello.h"
#include "CocoaCurlProxyResolver.h"
#include "BlobRegistryImpl.h"
#include "PlatformStrategies.h"
#include "HTTPParsers.h"
#include "ResourceError.h"
#include "SharedBuffer.h"
#include <Foundation/Foundation.h>
#include <wtf/text/MakeString.h>
#include <wtf/FileHandle.h>
#include <wtf/FileSystem.h>
#include <wtf/WorkQueue.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/text/StringToIntegerConversion.h>
#include <cerrno>
#include <cmath>

// preserve Cocoa's preferred HTTP language; NSLocale's full fallback list is not the wire preference.
extern "C" CFStringRef _CFNetworkCopyPreferredLanguageCode(void);

// curl framing, upload streams and TLS are independent of a Cocoa loader's policy client.
// CFNetwork's native conversion preserves FormDataStreamCFNet's { domain: 0, error: -43 }.
extern "C" CFErrorRef _CFErrorCreateWithStreamError(CFAllocatorRef, CFStreamError*);

namespace WebCore {
static std::optional<uint64_t> cocoaCurlUploadElementLength(const FormDataElement&, int& failureErrno);

// The language tag in the shape a browser sends it: the region subtag in capitals, and the
// language alone behind it as the next acceptable match.
static String cocoaCurlAcceptLanguage(const String& preferred)
{
    auto subtags = preferred.split('-');
    if (subtags.size() < 2)
        return preferred;
    if (subtags.last().length() == 2)
        subtags.last() = subtags.last().convertToASCIIUppercase();
    return makeString(makeStringByJoining(subtags, "-"_s), ","_s, subtags.first(), ";q=0.9"_s);
}

Ref<CocoaCurlUploadBody> CocoaCurlUploadBody::create(FormData& data, BlobRegistryImpl* registry)
{
    ASSERT(isMainThread());
    return adoptRef(*new CocoaCurlUploadBody(data, registry));
}

CocoaCurlUploadBody::CocoaCurlUploadBody(FormData& data, BlobRegistryImpl* registry)
    : m_data(data.isolatedCopy())
{
    if (data.containsBlobElement()) {
        if (!registry && hasPlatformStrategies())
            registry = blobRegistry()->blobRegistryImpl();
        for (auto& element : data.elements()) {
            if (auto* blob = std::get_if<FormDataElement::EncodedBlobData>(&element.data); blob && (!registry || !registry->blobDataFromURL(blob->url))) {
                m_error = "The upload references a blob that no longer exists"_s;
                return;
            }
        }
        m_data = m_data->resolveBlobReferences(registry);
    }
    m_preparation.emplace(m_data->prepareForUpload());
    for (auto& element : m_data->elements()) {
        auto length = cocoaCurlUploadElementLength(element, m_errorCode);
        if (!length || *length > static_cast<uint64_t>(std::numeric_limits<curl_off_t>::max()) - m_length) {
            m_error = "The upload contains an unreadable or inconsistent file range"_s;
            return;
        }
        m_elementLengths.append(*length);
        m_length += *length;
    }
}

CocoaCurlUploadBody::~CocoaCurlUploadBody() = default;

Ref<CocoaCurlTransfer> CocoaCurlTransfer::create(CocoaCurlScheduler& scheduler, CocoaCurlTransferClient& client, CocoaCurlTransferOptions&& options)
{
    return adoptRef(*new CocoaCurlTransfer(scheduler, client, WTF::move(options)));
}

CocoaCurlTransfer::CocoaCurlTransfer(CocoaCurlScheduler& scheduler, CocoaCurlTransferClient& client, CocoaCurlTransferOptions&& options)
    : m_scheduler(scheduler)
    , m_client(&client)
    , m_options(WTF::move(options))
    , m_timer(m_scheduler->runLoop(), "Cocoa curl transfer timeout"_s, this, &CocoaCurlTransfer::timeout)
    , m_timeout(m_options.request.timeoutInterval() ? m_options.request.timeoutInterval() : ResourceRequest::defaultTimeoutInterval())
{
    m_metrics.responseBodyBytesReceived = 0;
    m_metrics.responseBodyDecodedSize = 0;
    m_metrics.additionalNetworkLoadMetricsForWebInspector = AdditionalNetworkLoadMetricsForWebInspector::create();
}

CocoaCurlTransfer::~CocoaCurlTransfer()
{
    ASSERT(m_scheduler->runLoop().isCurrent());
    ASSERT(!m_running);
    closeUpload();
    if (m_proxyResolver)
        m_proxyResolver->cancel();
    if (m_easy)
        curl_easy_cleanup(m_easy);
    curl_slist_free_all(m_headers);
}

void CocoaCurlTransfer::closeUpload()
{
    m_uploadFile = { };
    m_uploadElement = 0;
    m_uploadElementOffset = 0;
    m_uploadElementLength = 0;
}

bool CocoaCurlTransfer::openUpload()
{
    closeUpload();
    return !m_options.upload || m_options.upload->error().isEmpty();
}

size_t CocoaCurlTransfer::readCallback(char* data, size_t size, size_t count, void* context)
{
    auto& transfer = *static_cast<CocoaCurlTransfer*>(context);
    if (!transfer.m_running)
        return CURL_READFUNC_ABORT;
    if (!transfer.m_options.upload)
        return 0;
    auto abortUpload = [&](ASCIILiteral reason, int failureErrno = 0) -> size_t {
        transfer.m_uploadError = reason;
        transfer.m_uploadErrorCode = failureErrno;
        return CURL_READFUNC_ABORT;
    };
    auto& elements = transfer.m_options.upload->data().elements();
    std::span<uint8_t> output { reinterpret_cast<uint8_t*>(data), size * count };
    while (transfer.m_uploadElement < elements.size()) {
        auto& element = elements[transfer.m_uploadElement];
        size_t read = 0;
        if (auto* bytes = std::get_if<Vector<uint8_t>>(&element.data)) {
            read = std::min<uint64_t>(output.size(), bytes->size() - transfer.m_uploadElementOffset);
            if (read)
                memcpy(output.data(), bytes->span().data() + transfer.m_uploadElementOffset, read);
            transfer.m_uploadElementLength = bytes->size();
        } else if (auto* file = std::get_if<FormDataElement::EncodedFileData>(&element.data)) {
            if (!transfer.m_uploadFile) {
                if (!file->fileModificationTimeMatchesExpectation())
                    return abortUpload("The upload file changed after it was selected"_s);
                errno = 0;
                transfer.m_uploadFile = FileSystem::openFile(file->filename, FileSystem::FileOpenMode::Read);
                auto length = transfer.m_uploadFile ? transfer.m_uploadFile.size() : std::nullopt;
                if (!length || file->fileStart < 0 || static_cast<uint64_t>(file->fileStart) > *length)
                    return abortUpload("The upload file is missing or its byte range is unavailable"_s, errno);
                transfer.m_uploadElementLength = transfer.m_options.upload->elementLength(transfer.m_uploadElement);
                if (transfer.m_uploadElementLength > *length - file->fileStart || transfer.m_uploadFile.seek(file->fileStart, FileSystem::FileSeekOrigin::Beginning) != static_cast<uint64_t>(file->fileStart))
                    return abortUpload("The upload file cannot supply the selected byte range"_s, errno);
            }
            auto requested = std::min<uint64_t>(output.size(), transfer.m_uploadElementLength - transfer.m_uploadElementOffset);
            errno = 0;
            auto result = transfer.m_uploadFile.read(output.first(requested));
            if (!result || (!*result && requested))
                return abortUpload("The upload file became unreadable or ended before its declared length"_s, errno);
            read = *result;
        } else
            return abortUpload("The upload contains an unresolved body element"_s);
        transfer.m_uploadElementOffset += read;
        if (transfer.m_uploadElementOffset == transfer.m_uploadElementLength) {
            ++transfer.m_uploadElement;
            transfer.m_uploadElementOffset = 0;
            transfer.m_uploadElementLength = 0;
            transfer.m_uploadFile = { };
        }
        if (read) {
            transfer.activity();
            return read;
        }
    }
    return 0;
}

int CocoaCurlTransfer::seekCallback(void* context, curl_off_t offset, int origin)
{
    if (origin != SEEK_SET || offset)
        return CURL_SEEKFUNC_CANTSEEK;
    return static_cast<CocoaCurlTransfer*>(context)->openUpload() ? CURL_SEEKFUNC_OK : CURL_SEEKFUNC_FAIL;
}

int CocoaCurlTransfer::progressCallback(void* context, curl_off_t, curl_off_t, curl_off_t total, curl_off_t uploaded)
{
    auto& transfer = *static_cast<CocoaCurlTransfer*>(context);
    if (!transfer.m_running)
        return 1;
    if (std::exchange(transfer.m_uploaded, uploaded) != static_cast<uint64_t>(uploaded)) {
        transfer.activity();
        transfer.m_scheduler->runLoop().dispatch([transfer = Ref { transfer }, uploaded, total] {
            if (!transfer->m_cancelled) {
                if (RefPtr client = transfer->m_client)
                    client->curlSentData(uploaded, total);
            }
        });
    }
    return 0;
}

bool CocoaCurlTransfer::setup()
{
    auto& request = m_options.request;
    if (!request.url().isValid() || !request.url().protocolIsInHTTPFamily() || !isValidHTTPToken(request.httpMethod()))
        return false;
    m_easy = curl_easy_init();
    if (!m_easy)
        return false;
    auto appendHeader = [&](const CString& field) {
        auto* list = curl_slist_append(m_headers, field.data());
        if (!list)
            return false;
        m_headers = list;
        return true;
    };
    bool carriesPriority = false;
    for (auto& field : request.httpHeaderFields()) {
        if (!isValidHTTPToken(field.key) || !isValidHTTPHeaderValue(field.value))
            return false;
        if (equalLettersIgnoringASCIICase(field.key, "cookie"_s) && !field.value.isEmpty())
            continue;
        // Safari 7's framework, which it injects into the WebProcess, sets DNT from the Privacy
        // checkbox that drives this port's advanced privacy protections; the browser this WebKit
        // reports itself as has no such field.
        if (equalLettersIgnoringASCIICase(field.key, "dnt"_s))
            continue;
        carriesPriority |= equalLettersIgnoringASCIICase(field.key, "priority"_s);
        if (!appendHeader(makeString(field.key, field.value.isEmpty() ? ";"_s : ": "_s, field.value).latin1()))
            return false;
    }
    if (!request.hasHTTPHeaderField(HTTPHeaderName::ContentType) && !appendHeader(CString("Content-Type:")))
        return false;
    if (!request.hasHTTPHeaderField(HTTPHeaderName::AcceptLanguage)) {
        auto preferredLanguage = adoptCF(_CFNetworkCopyPreferredLanguageCode());
        String language = cocoaCurlAcceptLanguage(String(preferredLanguage.get()));
        if (!language.isEmpty() && !appendHeader(makeString("Accept-Language: "_s, language).utf8()))
            return false;
    }
    // The RFC 9218 signal Safari sends on a document navigation, which is the one urgency this
    // port has a capture of; requests with another destination carry none.
    if (!carriesPriority && request.httpHeaderField(HTTPHeaderName::SecFetchDest) == "document"_s
        && !appendHeader(CString("Priority: u=0, i")))
        return false;
    // Carried in the request's own header list, so it reaches the wire last, in the position
    // a browser puts it.
    if (!request.hasHTTPHeaderField(HTTPHeaderName::AcceptEncoding) && !appendHeader(CString("Accept-Encoding: " COCOA_CURL_ACCEPT_ENCODING)))
        return false;
#define CURL_SET(option, value) do { if (curl_easy_setopt(m_easy, option, value) != CURLE_OK) return false; } while (false)
    CURL_SET(CURLOPT_URL, request.url().string().utf8().data());
    CURL_SET(CURLOPT_PROTOCOLS_STR, "http,https");
    CURL_SET(CURLOPT_FOLLOWLOCATION, 0L);
    CURL_SET(CURLOPT_HTTPAUTH, m_options.authentication);
    CURL_SET(CURLOPT_USERNAME, m_options.user.utf8().data());
    CURL_SET(CURLOPT_PASSWORD, m_options.password.utf8().data());
    CURL_SET(CURLOPT_PROXYAUTH, m_options.proxyAuthentication);
    CURL_SET(CURLOPT_PROXYUSERNAME, m_options.proxyUser.utf8().data());
    CURL_SET(CURLOPT_PROXYPASSWORD, m_options.proxyPassword.utf8().data());
    CURL_SET(CURLOPT_NOSIGNAL, 1L);
    // As upstream's CurlHandle::enableHttp does: let ALPN pick the version, and wait for a connection
    // whose protocol is known rather than opening another one that cannot be multiplexed on.
    if (m_options.request.url().protocolIs("https"_s)) {
        CURL_SET(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_NONE);
        CURL_SET(CURLOPT_PIPEWAIT, 1L);
    } else
        CURL_SET(CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    CURL_SET(CURLOPT_HTTP09_ALLOWED, 0L);
    CURL_SET(CURLOPT_SUPPRESS_CONNECT_HEADERS, 0L);
    CURL_SET(CURLOPT_ACCEPT_ENCODING, COCOA_CURL_ACCEPT_ENCODING);
    CURL_SET(CURLOPT_HTTP_CONTENT_DECODING, m_options.decodeContent ? 1L : 0L);
    CURL_SET(CURLOPT_SSL_VERIFYPEER, 1L);
    // SecPolicyCreateSSL validates the host and applies native trust decisions.
    CURL_SET(CURLOPT_SSL_VERIFYHOST, 0L);
    CURL_SET(CURLOPT_CAINFO, nullptr);
    CURL_SET(CURLOPT_CAPATH, nullptr);
    CURL_SET(CURLOPT_SSL_CTX_FUNCTION, sslContextCallback);
    CURL_SET(CURLOPT_SSL_CTX_DATA, this);
    CURL_SET(CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
    CURL_SET(CURLOPT_ERRORBUFFER, m_errorBuffer.data());
    // A NULL CURLOPT_COOKIE is the only value for which curl sends no Cookie field at all; an
    // empty string produces an empty one.
    auto cookieField = request.httpHeaderField(HTTPHeaderName::Cookie);
    CURL_SET(CURLOPT_COOKIE, cookieField.isEmpty() ? nullptr : cookieField.latin1().data());
    CURL_SET(CURLOPT_HTTPHEADER, m_headers);
    CURL_SET(CURLOPT_HEADERFUNCTION, headerCallback);
    CURL_SET(CURLOPT_HEADERDATA, this);
    // Each pause hands one receive buffer to the client; a large buffer keeps the pauses few.
    CURL_SET(CURLOPT_BUFFERSIZE, 512L * 1024);
    CURL_SET(CURLOPT_WRITEFUNCTION, dataCallback);
    CURL_SET(CURLOPT_WRITEDATA, this);
    CURL_SET(CURLOPT_XFERINFOFUNCTION, progressCallback);
    CURL_SET(CURLOPT_XFERINFODATA, this);
    CURL_SET(CURLOPT_NOPROGRESS, 0L);
    CURL_SET(CURLOPT_PRIVATE, this);
    if (!m_options.boundInterface.isEmpty())
        CURL_SET(CURLOPT_INTERFACE, m_options.boundInterface.utf8().data());
    if (m_options.upload) {
        if (!m_options.upload->error().isEmpty()) {
            m_uploadError = m_options.upload->error().isolatedCopy();
            m_uploadErrorCode = m_options.upload->errorCode();
            return false;
        }
        auto length = m_options.upload->length();
        uint64_t size = length;
        if (!openUpload()) {
            m_uploadError = "Could not open the request body stream"_s;
            return false;
        }
        CURL_SET(CURLOPT_READFUNCTION, readCallback);
        CURL_SET(CURLOPT_READDATA, this);
        CURL_SET(CURLOPT_SEEKFUNCTION, seekCallback);
        CURL_SET(CURLOPT_SEEKDATA, this);
        if (request.httpMethod() == "POST"_s) {
            CURL_SET(CURLOPT_POST, 1L);
            CURL_SET(CURLOPT_POSTFIELDSIZE_LARGE, static_cast<curl_off_t>(size));
        } else {
            CURL_SET(CURLOPT_UPLOAD, 1L);
            CURL_SET(CURLOPT_INFILESIZE_LARGE, static_cast<curl_off_t>(size));
        }
    } else if (request.httpMethod() == "POST"_s) {
        CURL_SET(CURLOPT_POST, 1L);
        CURL_SET(CURLOPT_POSTFIELDSIZE_LARGE, static_cast<curl_off_t>(0));
    }
    if (request.httpMethod() == "HEAD"_s)
        CURL_SET(CURLOPT_NOBODY, 1L);
    CURL_SET(CURLOPT_CUSTOMREQUEST, request.httpMethod().utf8().data());
    if (m_options.preconnect)
        CURL_SET(CURLOPT_CONNECT_ONLY, CURL_CONNECT_ONLY_REUSABLE);
#undef CURL_SET
    return true;
}

void CocoaCurlTransfer::start()
{
    ASSERT(m_scheduler->runLoop().isCurrent());
    if (m_running || m_complete)
        return;
    m_running = true;
    m_started = m_metrics.fetchStart = MonotonicTime::now();
    if (!setup()) {
        finish(m_uploadError.isEmpty() ? NSURLErrorCannotLoadFromNetwork : NSURLErrorUnknown, m_uploadError.isEmpty() ? "Could not initialize the HTTP transfer"_s : m_uploadError);
        return;
    }
    // PAC resolution is part of the request inactivity timeout.
    activity();
    m_proxyResolver = CocoaCurlProxyResolver::create(m_options.request.url(), m_options.proxySettings.get(), [transfer = Ref { *this }](RetainPtr<CFDictionaryRef>&& proxy, const String& error) {
        if (!transfer->m_running)
            return;
        if (!error.isEmpty()) {
            transfer->finish(NSURLErrorCannotFindHost, error);
            return;
        }
        bool routeResolved = CocoaCurlProxyResolver::apply(transfer->m_easy, proxy.get(), transfer->m_response.proxyHost, transfer->m_response.proxyPort);
        auto& options = transfer->m_options;
        bool credentialsMatchRoute = options.proxyCredentialHost == transfer->m_response.proxyHost && options.proxyCredentialPort == transfer->m_response.proxyPort;
        bool credentialsApplied = routeResolved && CocoaCurlProxyResolver::applyCredentials(transfer->m_easy, proxy.get(), credentialsMatchRoute ? options.proxyAuthentication : CURLAUTH_NONE, credentialsMatchRoute ? options.proxyUser : emptyString(), credentialsMatchRoute ? options.proxyPassword : emptyString());
        transfer->m_started = MonotonicTime::now();
        if (!credentialsApplied || !transfer->m_scheduler->add(transfer.get())) {
            transfer->finish(NSURLErrorCannotConnectToHost, "Could not start the resolved proxy route"_s);
            return;
        }
        transfer->activity();
    });
    m_proxyResolver->start();
}

void CocoaCurlTransfer::setPriority(ResourceLoadPriority priority)
{
    m_options.request.setPriority(priority);
}

void CocoaCurlTransfer::setDefersLoading(bool deferred)
{
    m_deferred = deferred;
    if (!deferred && !m_clientInteractions && m_running)
        resumeTransfer();
}

void CocoaCurlTransfer::activity()
{
    if (m_running && !m_clientInteractions && !m_deferred && m_timeout > 0_s && std::isfinite(m_timeout.seconds()))
        m_timer.startOneShot(m_timeout);
}

void CocoaCurlTransfer::timeout()
{
    finish(NSURLErrorTimedOut, "Request timed out waiting for network activity"_s);
}

CURLcode CocoaCurlTransfer::sslContextCallback(CURL*, void* context, void* data)
{
    auto& transfer = *static_cast<CocoaCurlTransfer*>(data);
    transfer.m_tls = std::make_shared<CocoaCurlTLSState>();
    auto& state = *transfer.m_tls;
    state.url = transfer.m_options.request.url();
    state.acceptedChain = transfer.m_options.acceptedCertificateChain;
    state.allowedTrust = transfer.m_options.allowedServerTrust;
    // keychain access is an asynchronous native operation; no SSL handle crosses into its work queue.
    state.requestSignature = [weakTransfer = WeakPtr { transfer }](SecKeyAlgorithm algorithm, RetainPtr<CFDataRef>&& data) {
        RefPtr transfer = weakTransfer.get();
        RefPtr client = transfer ? transfer->m_client : nullptr;
        if (!transfer || !transfer->m_running || !client || !transfer->m_tls->privateKey)
            return false;
        ++transfer->m_clientInteractions;
        transfer->m_timer.stop();
        RetainPtr key = transfer->m_tls->privateKey;
        static NeverDestroyed<Ref<ConcurrentWorkQueue>> signingQueue = ConcurrentWorkQueue::create("Cocoa keychain signing"_s);
        signingQueue.get()->dispatch([client = WTF::move(client), transfer = WTF::move(transfer), key = WTF::move(key), algorithm = retainPtr(algorithm), data = WTF::move(data)]() mutable {
            CFErrorRef rawError = nullptr;
            auto signature = adoptCF(SecKeyCreateSignature(key.get(), algorithm.get(), data.get(), &rawError));
            auto error = adoptCF(rawError);
            Ref worker { transfer->m_scheduler->runLoop() };
            worker->dispatch([client = WTF::move(client), transfer = WTF::move(transfer), signature = WTF::move(signature), error = WTF::move(error)]() mutable {
                --transfer->m_clientInteractions;
                if (!transfer->m_running)
                    return;
                transfer->m_tls->signature = WTF::move(signature);
                transfer->m_tls->signingError = WTF::move(error);
                transfer->m_tls->signingComplete = true;
                transfer->resumeTransfer();
            });
        });
        return true;
    };
    state.requestVerification = [weakTransfer = WeakPtr { transfer }](std::unique_ptr<CocoaCurlTLSVerification>&& verification) {
        RefPtr transfer = weakTransfer.get();
        RefPtr client = transfer ? transfer->m_client : nullptr;
        if (!transfer || !transfer->m_running || !client)
            return false;
        ++transfer->m_clientInteractions;
        transfer->m_timer.stop();
        static NeverDestroyed<Ref<ConcurrentWorkQueue>> trustQueue = ConcurrentWorkQueue::create("Cocoa certificate verification"_s);
        // Keep the bridge (and therefore its session worker) alive through cancellation. Both client and transfer references return to the curl worker for release.
        trustQueue.get()->dispatch([client = WTF::move(client), transfer = WTF::move(transfer), verification = WTF::move(verification)]() mutable {
            verification->evaluate();
            Ref worker { transfer->m_scheduler->runLoop() };
            worker->dispatch([client = WTF::move(client), transfer = WTF::move(transfer), verification = WTF::move(verification)]() mutable {
                --transfer->m_clientInteractions;
                if (!transfer->m_running)
                    return;
                verification->apply(*transfer->m_tls);
                transfer->resumeTransfer();
            });
        });
        return true;
    };
    state.requestIdentity = [weakTransfer = WeakPtr { transfer }](SSL* ssl) {
        RefPtr transfer = weakTransfer.get();
        if (!transfer || !transfer->m_running)
            return false;
        ++transfer->m_clientInteractions;
        transfer->m_timer.stop();
        auto authorities = CocoaCurlTLSState::certificateAuthorities(ssl);
        transfer->m_scheduler->runLoop().dispatch([transfer = WTF::move(transfer), authorities = WTF::move(authorities)] {
            RefPtr client = transfer->m_running ? transfer->m_client : nullptr;
            if (!client) {
                --transfer->m_clientInteractions;
                if (transfer->m_running)
                    transfer->cancel();
                return;
            }
            client->curlRequestedIdentity(authorities.get(), [transfer](RetainPtr<SecIdentityRef>&& identity, RetainPtr<CFArrayRef>&& chain) {
                ASSERT(transfer->m_scheduler->runLoop().isCurrent());
                --transfer->m_clientInteractions;
                if (!transfer->m_running)
                    return;
                transfer->m_tls->identity = WTF::move(identity);
                transfer->m_tls->clientCertificates = (NSArray *)chain.get();
                transfer->m_tls->identityAnswered = true;
                transfer->resumeTransfer();
            });
        });
        return true;
    };
    return CocoaCurlTLSState::install(static_cast<SSL_CTX*>(context), transfer.m_tls);
}

void CocoaCurlTransfer::updateTLS()
{
    if (!m_easy)
        return;
    curl_tlssessioninfo* session = nullptr;
    if (curl_easy_getinfo(m_easy, CURLINFO_TLS_SSL_PTR, &session) == CURLE_OK && session && session->internals) {
        if (auto state = CocoaCurlTLSState::fromSSL(static_cast<SSL*>(session->internals)))
            m_tls = WTF::move(state);
    }
    // capture live connection details before curl detaches a completed easy handle.
    updateMetrics();
}

size_t CocoaCurlTransfer::headerCallback(char* data, size_t size, size_t count, void* context)
{
    return static_cast<CocoaCurlTransfer*>(context)->header({ data, size * count });
}

size_t CocoaCurlTransfer::dataCallback(char* data, size_t size, size_t count, void* context)
{
    return static_cast<CocoaCurlTransfer*>(context)->data({ data, size * count });
}

size_t CocoaCurlTransfer::invalidResponse(ASCIILiteral reason)
{
    m_invalidResponse = reason;
    return CURL_WRITEFUNC_ERROR;
}

size_t CocoaCurlTransfer::header(std::span<const char> bytes)
{
    activity();
    if (std::exchange(m_acknowledgeHeader, false))
        return bytes.size();
    String line(bytes);
    if (!line.endsWith("\r\n"_s))
        return invalidResponse("Invalid HTTP field delimiter"_s);
    line = line.left(line.length() - 2);
    if (line.startsWith("HTTP/"_s)) {
        auto space = line.find(' ');
        auto code = space == notFound ? std::nullopt : parseInteger<int>(StringView(line).substring(space + 1, 3));
        if (!code || *code < 100 || *code > 999)
            return invalidResponse("Invalid HTTP status line"_s);
        m_status = *code;
        m_version = line.left(space);
        m_statusText = extractReasonPhraseFromHTTPStatusLine(line);
        m_responseHeaders = { };
        m_finalHeaders = false;
        return bytes.size();
    }
    if (m_finalHeaders)
        return bytes.size();
    if (line.isEmpty()) {
        long origin = 0, tunnel = 0;
        curl_easy_getinfo(m_easy, CURLINFO_RESPONSE_CODE, &origin);
        curl_easy_getinfo(m_easy, CURLINFO_HTTP_CONNECTCODE, &tunnel);
        // CONNECT fields belong to the proxy exchange, before origin TLS trust exists.
        if (!origin && tunnel == m_status) {
            m_setCookies.clear();
            if (m_status >= 200 && m_status < 300)
                return bytes.size();
        }
        if (!m_status)
            return invalidResponse("Missing HTTP status"_s);
        auto type = m_responseHeaders.get(HTTPHeaderName::ContentType);
        curl_off_t length = -1;
        curl_easy_getinfo(m_easy, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &length);
        auto contentEncoding = m_responseHeaders.get(HTTPHeaderName::ContentEncoding);
        if (m_options.decodeContent && !contentEncoding.isEmpty() && !equalLettersIgnoringASCIICase(contentEncoding, "identity"_s))
            length = -1;
        ResourceResponse response(URL { m_options.request.url() }, extractMIMETypeFromMediaType(type).convertToASCIILowercase(), length, extractCharsetFromMediaType(type).toString());
        response.setHTTPStatusCode(m_status);
        response.setHTTPStatusText(String(m_statusText));
        response.setHTTPVersion(String(m_version));
        response.setHTTPHeaderFields(WTF::move(m_responseHeaders));
        response.setSource(ResourceResponse::Source::Network);
        updateTLS();
        if (m_tls && m_tls->trust)
            response.setCertificateInfo(CertificateInfo(retainPtr(m_tls->trust.get())));
        if (m_status < 200) {
            if (!m_metrics.firstInterimResponseStart)
                m_metrics.firstInterimResponseStart = MonotonicTime::now();
            if (m_status == 101)
                return invalidResponse("Unexpected protocol upgrade in an HTTP transfer"_s);
            m_setCookies.clear();
            m_scheduler->runLoop().dispatch([transfer = Ref { *this }, response = WTF::move(response)]() mutable {
                if (transfer->m_running) {
                    if (RefPtr client = transfer->m_client)
                        client->curlReceivedInformationalResponse(WTF::move(response));
                }
            });
            return bytes.size();
        }
        m_response.response = WTF::move(response);
        m_metrics.responseStart = MonotonicTime::now();
        m_finalHeaders = true;
        if (!m_setCookies.isEmpty()) {
            // suspend every cookie-bearing response section,
            // including libcurl's internal authentication exchanges, until the
            // owning native jar supplies the next request's Cookie field.
            ++m_clientInteractions;
            m_timer.stop();
            m_scheduler->runLoop().dispatch([transfer = Ref { *this }, cookies = std::exchange(m_setCookies, { })]() mutable {
                RefPtr client = transfer->m_running ? transfer->m_client : nullptr;
                if (!client) {
                    --transfer->m_clientInteractions;
                    if (transfer->m_running)
                        transfer->cancel();
                    return;
                }
                client->curlReceivedCookies(WTF::move(cookies), [transfer](std::optional<String>&& cookie) {
                    --transfer->m_clientInteractions;
                    if (!transfer->m_running)
                        return;
                    if (cookie && (!isValidHTTPHeaderValue(*cookie) || curl_easy_setopt(transfer->m_easy, CURLOPT_COOKIE, cookie->isEmpty() ? nullptr : cookie->latin1().data()) != CURLE_OK)) {
                        transfer->finish(NSURLErrorCannotLoadFromNetwork, "Could not update the outgoing cookie field"_s);
                        return;
                    }
                    transfer->m_acknowledgeHeader = true;
                    transfer->resumeTransfer();
                });
            });
            return CURL_WRITEFUNC_PAUSE;
        }
        return bytes.size();
    }
    auto colon = line.find(':');
    if (colon == notFound)
        return invalidResponse("Invalid HTTP header field"_s);
    auto name = line.left(colon);
    auto value = line.substring(colon + 1).trim([](auto c) { return c == ' ' || c == '\t'; });
    if (!isValidHTTPToken(name) || !isValidHTTPHeaderValue(value))
        return invalidResponse("Invalid HTTP header name or value"_s);
    if (equalLettersIgnoringASCIICase(name, "set-cookie"_s))
        m_setCookies.append(value);
    if (equalLettersIgnoringASCIICase(name, "content-type"_s))
        m_responseHeaders.set(name, value);
    else if (!equalLettersIgnoringASCIICase(name, "strict-transport-security"_s) || !m_responseHeaders.contains(name))
        m_responseHeaders.add(name, value);
    return bytes.size();
}

size_t CocoaCurlTransfer::data(std::span<const char> bytes)
{
    activity();
    // libcurl coalesces decoded output in its pause buffer. A
    // replay can include both the delivered prefix and previously unseen bytes.
    // Keep the prefix until this complete callback buffer can be acknowledged.
    if (bytes.size() <= m_deliveredDataBytes) {
        m_deliveredDataBytes -= bytes.size();
        return bytes.size();
    }
    if (m_deferred)
        return CURL_WRITEFUNC_PAUSE;
    m_data = SharedBuffer::create(asBytes(bytes.subspan(m_deliveredDataBytes)));
    ++m_clientInteractions;
    m_timer.stop();
    m_scheduler->runLoop().dispatch([transfer = Ref { *this }] {
        --transfer->m_clientInteractions;
        if (!transfer->m_running)
            return;
        if (!transfer->m_publishedResponse)
            transfer->publishResponse();
        else
            transfer->deliverData();
    });
    return CURL_WRITEFUNC_PAUSE;
}

void CocoaCurlTransfer::publishResponse()
{
    if (m_publishedResponse || !m_running)
        return;
    m_publishedResponse = true;
    RefPtr client = m_client;
    if (!client) {
        cancel();
        return;
    }
    ++m_clientInteractions;
    m_timer.stop();
    updateMetrics();
    m_response.metrics = m_metrics;
    curl_easy_getinfo(m_easy, CURLINFO_HTTPAUTH_AVAIL, &m_response.authentication);
    curl_easy_getinfo(m_easy, CURLINFO_PROXYAUTH_AVAIL, &m_response.proxyAuthentication);
    client->curlReceivedResponse(CocoaCurlTransferResponse(m_response), [transfer = Ref { *this }] {
        --transfer->m_clientInteractions;
        if (!transfer->m_running)
            return;
        if (transfer->m_data)
            transfer->deliverData();
        else
            transfer->resumeTransfer();
    });
}

void CocoaCurlTransfer::deliverData()
{
    if (!m_running || m_deferred || !m_data)
        return;
    RefPtr client = m_client;
    if (!client) {
        cancel();
        return;
    }
    Ref data = m_data.releaseNonNull();
    m_metrics.responseBodyDecodedSize += data->size();
    ++m_clientInteractions;
    client->curlReceivedData(data.get(), [transfer = Ref { *this }, size = data->size()] {
        --transfer->m_clientInteractions;
        if (!transfer->m_running)
            return;
        transfer->m_deliveredDataBytes += size;
        transfer->resumeTransfer();
    });
}

void CocoaCurlTransfer::resumeTransfer()
{
    if (!m_running || m_deferred || m_clientInteractions)
        return;
    activity();
    if (m_data) {
        deliverData();
        return;
    }
    if (m_result) {
        curlDidComplete(*m_result);
        return;
    }
    m_scheduler->unpause(*this);
}

// libcurl's declared length must describe the actual readable byte ranges, including empty files.
static std::optional<uint64_t> cocoaCurlUploadElementLength(const FormDataElement& element, int& failureErrno)
{
    if (auto* bytes = std::get_if<Vector<uint8_t>>(&element.data))
        return bytes->size();
    if (auto* file = std::get_if<FormDataElement::EncodedFileData>(&element.data)) {
        if (file->fileStart < 0 || !file->fileModificationTimeMatchesExpectation())
            return std::nullopt;
        errno = 0;
        auto handle = FileSystem::openFile(file->filename, FileSystem::FileOpenMode::Read);
        if (!handle)
            failureErrno = errno;
        auto size = handle ? handle.size() : std::nullopt;
        if (!size || static_cast<uint64_t>(file->fileStart) > *size)
            return std::nullopt;
        auto remaining = *size - file->fileStart;
        if (file->fileLength == BlobDataItem::toEndOfFile)
            return remaining;
        if (file->fileLength < 0 || static_cast<uint64_t>(file->fileLength) > remaining)
            return std::nullopt;
        return file->fileLength;
    }
    return std::nullopt;
}

std::optional<uint64_t> cocoaCurlUploadLength(const FormData& data)
{
    uint64_t total = 0;
    for (auto& element : data.elements()) {
        int ignored = 0;
        auto length = cocoaCurlUploadElementLength(element, ignored);
        if (!length || *length > static_cast<uint64_t>(std::numeric_limits<curl_off_t>::max()) - total)
            return std::nullopt;
        total += *length;
    }
    return total;
}

// A resumed file is a single representation, including its validators and declared range end.
bool validateCocoaCurlResumeResponse(const ResourceResponse& response, uint64_t offset, const String& validator)
{
    if (response.httpStatusCode() == 200)
        return true;
    if (response.httpStatusCode() != 206)
        return false;
    auto& range = response.contentRange();
    auto encoding = response.httpHeaderField(HTTPHeaderName::ContentEncoding);
    if (!range.isValid() || range.firstBytePosition() != offset || (!encoding.isEmpty() && !equalIgnoringASCIICase(encoding, "identity"_s)))
        return false;
    if (validator.startsWith('"')) {
        auto etag = response.httpHeaderField(HTTPHeaderName::ETag);
        if (!etag.isEmpty() && etag != validator)
            return false;
    } else {
        auto modified = response.httpHeaderField(HTTPHeaderName::LastModified);
        if (!modified.isEmpty()) {
            auto original = parseHTTPDate(validator);
            auto current = parseHTTPDate(modified);
            if (!original || !current || *original != *current)
                return false;
        }
    }
    return true;
}

bool validateCocoaCurlCompletedResume(const ResourceResponse& response, uint64_t fileLength)
{
    if (response.httpStatusCode() != 206)
        return true;
    auto& range = response.contentRange();
    return range.isValid() && fileLength == static_cast<uint64_t>(range.lastBytePosition()) + 1
        && (range.instanceLength() == ParsedContentRange::unknownLength || fileLength == static_cast<uint64_t>(range.instanceLength()));
}

void collectCocoaCurlMetrics(CURL* easy, const ResourceRequest& request, MonotonicTime started, bool isProxy, NetworkLoadMetrics& metrics)
{
    if (!easy)
        return;
    curl_off_t dns = 0, connected = 0, tls = 0, uploaded = 0, downloaded = 0;
    curl_easy_getinfo(easy, CURLINFO_NAMELOOKUP_TIME_T, &dns);
    curl_easy_getinfo(easy, CURLINFO_CONNECT_TIME_T, &connected);
    curl_easy_getinfo(easy, CURLINFO_APPCONNECT_TIME_T, &tls);
    if (dns) {
        metrics.domainLookupStart = started;
        metrics.domainLookupEnd = started + Seconds::fromMicroseconds(dns);
    }
    if (connected) {
        metrics.connectStart = started + Seconds::fromMicroseconds(dns);
        metrics.connectEnd = started + Seconds::fromMicroseconds(tls ? tls : connected);
    }
    if (tls)
        metrics.secureConnectionStart = started + Seconds::fromMicroseconds(connected);
    curl_off_t ready = 0;
    curl_easy_getinfo(easy, CURLINFO_PRETRANSFER_TIME_T, &ready);
    if (ready)
        metrics.requestStart = started + Seconds::fromMicroseconds(ready);
    curl_easy_getinfo(easy, CURLINFO_SIZE_UPLOAD_T, &uploaded);
    curl_easy_getinfo(easy, CURLINFO_SIZE_DOWNLOAD_T, &downloaded);
    auto& extended = *metrics.additionalNetworkLoadMetricsForWebInspector;
    long requestSize = 0, headerSize = 0, connections = 0;
    curl_easy_getinfo(easy, CURLINFO_REQUEST_SIZE, &requestSize);
    curl_easy_getinfo(easy, CURLINFO_HEADER_SIZE, &headerSize);
    curl_easy_getinfo(easy, CURLINFO_NUM_CONNECTS, &connections);
    metrics.isReusedConnection = !connections && !!metrics.responseStart;
    extended.requestHeaderBytesSent = requestSize;
    extended.responseHeaderBytesReceived = headerSize;
    extended.requestHeaders = request.httpHeaderFields();
    extended.isProxyConnection = isProxy;
    auto priority = request.priority();
    extended.priority = priority <= ResourceLoadPriority::Low ? NetworkLoadPriority::Low : priority >= ResourceLoadPriority::High ? NetworkLoadPriority::High : NetworkLoadPriority::Medium;
    char* address = nullptr;
    curl_easy_getinfo(easy, CURLINFO_PRIMARY_IP, &address);
    extended.remoteAddress = address ? String::fromUTF8(address) : emptyString();
    curl_off_t connectionIdentifier = -1;
    if (curl_easy_getinfo(easy, CURLINFO_CONN_ID, &connectionIdentifier) == CURLE_OK && connectionIdentifier >= 0)
        extended.connectionIdentifier = String::number(connectionIdentifier);
    curl_tlssessioninfo* tlsSession = nullptr;
    if (curl_easy_getinfo(easy, CURLINFO_TLS_SSL_PTR, &tlsSession) == CURLE_OK && tlsSession && tlsSession->internals) {
        auto* ssl = static_cast<SSL*>(tlsSession->internals);
        extended.tlsProtocol = String::fromUTF8(SSL_get_version(ssl));
        extended.tlsCipher = String::fromUTF8(SSL_get_cipher_name(ssl));
    }
    metrics.additionalNetworkLoadMetricsForWebInspector->requestBodyBytesSent = uploaded;
    metrics.responseBodyBytesReceived = downloaded;
    long version = 0;
    curl_easy_getinfo(easy, CURLINFO_HTTP_VERSION, &version);
    metrics.protocol = version == CURL_HTTP_VERSION_2_0 ? "h2"_s : version == CURL_HTTP_VERSION_1_0 ? "http/1.0"_s : version == CURL_HTTP_VERSION_1_1 ? "http/1.1"_s : emptyString();
}

void CocoaCurlTransfer::updateMetrics()
{
    collectCocoaCurlMetrics(m_easy, m_options.request, m_started, !m_response.proxyHost.isEmpty(), m_metrics);
}

void CocoaCurlTransfer::curlDidComplete(CURLcode result)
{
    if (!m_running)
        return;
    m_result = result;
    updateTLS();
    updateMetrics();
    if (!m_uploadError.isEmpty()) {
        finish(NSURLErrorUnknown, m_uploadError);
        return;
    }
    if (!m_invalidResponse.isEmpty()) {
        finish(NSURLErrorCannotParseResponse, m_invalidResponse);
        return;
    }
    if (!m_publishedResponse && m_finalHeaders && (result == CURLE_OK || m_status == 401 || m_status == 407)) {
        ++m_clientInteractions;
        m_timer.stop();
        m_scheduler->runLoop().dispatch([transfer = Ref { *this }] { --transfer->m_clientInteractions; transfer->publishResponse(); });
        return;
    }
    if (result == CURLE_OK) {
        if (m_clientInteractions || m_deferred || m_data)
            return;
        finish(m_finalHeaders || m_options.preconnect ? 0 : NSURLErrorBadServerResponse, "Missing HTTP response"_s);
        return;
    }
    int code = NSURLErrorUnknown;
    if (result == CURLE_OPERATION_TIMEDOUT)
        code = NSURLErrorTimedOut;
    else if (result == CURLE_COULDNT_CONNECT)
        code = NSURLErrorCannotConnectToHost;
    else if (result == CURLE_COULDNT_RESOLVE_HOST || result == CURLE_COULDNT_RESOLVE_PROXY)
        code = NSURLErrorCannotFindHost;
    else if (result == CURLE_PEER_FAILED_VERIFICATION)
        code = NSURLErrorServerCertificateUntrusted;
    else if (result == CURLE_SSL_CLIENTCERT)
        code = NSURLErrorClientCertificateRequired;
    else if (result == CURLE_SSL_CONNECT_ERROR)
        code = NSURLErrorSecureConnectionFailed;
    else if (result == CURLE_LOGIN_DENIED || result == CURLE_AUTH_ERROR)
        code = NSURLErrorUserAuthenticationRequired;
    else if (result == CURLE_READ_ERROR)
        code = NSURLErrorCannotOpenFile;
    else if (result == CURLE_RECV_ERROR || result == CURLE_SEND_ERROR || result == CURLE_GOT_NOTHING || result == CURLE_PARTIAL_FILE)
        code = NSURLErrorNetworkConnectionLost;
    // TLS alerts distinguish a missing/rejected client identity from a transport disconnect.
    if (m_tls && m_tls->receivedAlert == SSL_AD_CERTIFICATE_REQUIRED)
        code = NSURLErrorClientCertificateRequired;
    else if (m_tls && m_tls->identity) {
        switch (m_tls->receivedAlert) {
        case SSL_AD_BAD_CERTIFICATE:
        case SSL_AD_UNSUPPORTED_CERTIFICATE:
        case SSL_AD_CERTIFICATE_REVOKED:
        case SSL_AD_CERTIFICATE_EXPIRED:
        case SSL_AD_CERTIFICATE_UNKNOWN:
        case SSL_AD_UNKNOWN_CA:
        case SSL_AD_ACCESS_DENIED:
            code = NSURLErrorClientCertificateRejected;
            break;
        }
    }
    finish(code, String::fromUTF8(m_errorBuffer[0] ? m_errorBuffer.data() : curl_easy_strerror(result)));
}

void CocoaCurlTransfer::curlDidFail()
{
    finish(NSURLErrorUnknown, "curl multi scheduler failed"_s);
}

void CocoaCurlTransfer::cancel()
{
    m_cancelled = true;
    if (!m_complete)
        finish(NSURLErrorCancelled, "Load cancelled"_s);
}

void CocoaCurlTransfer::invalidateClient()
{
    m_client = nullptr;
    cancel();
}

void CocoaCurlTransfer::finish(int code, const String& message)
{
    ASSERT(m_scheduler->runLoop().isCurrent());
    Ref protectedThis { *this };
    if (std::exchange(m_complete, true))
        return;
    m_running = false;
    updateTLS();
    updateMetrics();
    m_timer.stop();
    m_scheduler->remove(m_easy);
    if (m_proxyResolver)
        m_proxyResolver->cancel();
    closeUpload();
    m_data = nullptr;
    m_metrics.responseEnd = MonotonicTime::now();
    m_metrics.markComplete();
    ResourceError error;
    if (code) {
        auto userInfo = adoptNS([@{
            NSURLErrorFailingURLStringErrorKey: m_options.request.url().string().createNSString().get(),
            NSLocalizedDescriptionKey: message.createNSString().get()
        } mutableCopy]);
        if (auto url = m_options.request.url().createNSURL())
            userInfo.get()[NSURLErrorFailingURLErrorKey] = url.get();
        NSString *domain = NSURLErrorDomain;
        if (!m_uploadError.isEmpty()) {
            CFStreamError streamError { 0, -43 }; // FormDataStreamCFNet's fileNotFoundError.
            auto underlying = adoptCF(_CFErrorCreateWithStreamError(kCFAllocatorDefault, &streamError));
            userInfo.get()[NSUnderlyingErrorKey] = (NSError *)underlying.get();
            // Measured against stock on this host: a body stream carries its own failure out, so a
            // POSIX one arrives in that domain with its errno (ENOENT for a missing file, EISDIR for a
            // directory), while FormDataStreamCFNet's own open failure, CFStreamError { 0, -43 },
            // arrives as NSURLErrorUnknown. The callers pass the second; an errno refines it.
            if (m_uploadErrorCode) {
                domain = NSPOSIXErrorDomain;
                code = m_uploadErrorCode;
            }
        } else if (m_result && *m_result != CURLE_OK)
            userInfo.get()[NSUnderlyingErrorKey] = [NSError errorWithDomain:@"libcurl" code:*m_result userInfo:@{ NSLocalizedDescriptionKey: @(curl_easy_strerror(*m_result)) }];
        if (m_tls && m_tls->signingError)
            userInfo.get()[NSUnderlyingErrorKey] = (id)m_tls->signingError.get();
        if (m_tls && m_tls->trust)
            userInfo.get()[NSURLErrorFailingURLPeerTrustErrorKey] = (id)m_tls->trust.get();
        error = ResourceError([NSError errorWithDomain:domain code:code userInfo:userInfo.get()]);
    }
    m_scheduler->runLoop().dispatch([transfer = Ref { *this }, error = WTF::move(error)] {
        if (RefPtr client = transfer->m_client)
            client->curlCompleted(error, transfer->m_metrics);
    });
}
} // namespace WebCore
