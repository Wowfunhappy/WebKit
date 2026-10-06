#include "config.h"
#include "LegacyExtensionErrors.h"

#include "APIError.h"
#include <WebCore/ResourceError.h>

namespace WebKit::LegacyExtensions {

ASCIILiteral networkErrorName(const WebCore::ResourceError& error)
{
    if (error.domain() == API::Error::webKitPolicyErrorDomain()) {
        if (error.errorCode() == API::Error::Policy::FrameLoadBlockedByContentBlocker)
            return "net::ERR_BLOCKED_BY_CLIENT"_s;
        if (error.errorCode() == API::Error::Policy::FrameLoadInterruptedByPolicyChange)
            return "net::ERR_ABORTED"_s;
        if (error.errorCode() == API::Error::Policy::CannotUseRestrictedPort)
            return "net::ERR_UNSAFE_PORT"_s;
    }
    if (error.isCancellation())
        return "net::ERR_ABORTED"_s;
    if (error.isTimeout())
        return "net::ERR_TIMED_OUT"_s;
    if (error.domain() != "NSURLErrorDomain"_s)
        return "net::ERR_FAILED"_s;
    switch (error.errorCode()) {
    case -999: // NSURLErrorCancelled
        return "net::ERR_ABORTED"_s;
    case -1000: // NSURLErrorBadURL
        return "net::ERR_INVALID_URL"_s;
    case -1001: // NSURLErrorTimedOut
        return "net::ERR_TIMED_OUT"_s;
    case -1002: // NSURLErrorUnsupportedURL
        return "net::ERR_UNKNOWN_URL_SCHEME"_s;
    case -1003: // NSURLErrorCannotFindHost
    case -1006: // NSURLErrorDNSLookupFailed
        return "net::ERR_NAME_NOT_RESOLVED"_s;
    case -1004: // NSURLErrorCannotConnectToHost
        return "net::ERR_CONNECTION_REFUSED"_s;
    case -1005: // NSURLErrorNetworkConnectionLost
        return "net::ERR_CONNECTION_CLOSED"_s;
    case -1007: // NSURLErrorHTTPTooManyRedirects
        return "net::ERR_TOO_MANY_REDIRECTS"_s;
    case -1009: // NSURLErrorNotConnectedToInternet
        return "net::ERR_INTERNET_DISCONNECTED"_s;
    case -1011: // NSURLErrorBadServerResponse
    case -1017: // NSURLErrorCannotParseResponse
        return "net::ERR_INVALID_RESPONSE"_s;
    case -1100: // NSURLErrorFileDoesNotExist
        return "net::ERR_FILE_NOT_FOUND"_s;
    case -1200: // NSURLErrorSecureConnectionFailed
        return "net::ERR_SSL_PROTOCOL_ERROR"_s;
    case -1201: // NSURLErrorServerCertificateHasBadDate
    case -1204: // NSURLErrorServerCertificateNotYetValid
        return "net::ERR_CERT_DATE_INVALID"_s;
    case -1202: // NSURLErrorServerCertificateUntrusted
    case -1203: // NSURLErrorServerCertificateHasUnknownRoot
        return "net::ERR_CERT_AUTHORITY_INVALID"_s;
    default:
        return "net::ERR_FAILED"_s;
    }
}

} // namespace WebKit::LegacyExtensions
