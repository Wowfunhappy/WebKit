// MAVERICKS_BACKPORT: see CFNetworkSuppressedGzipDecoder.h.

#include "config.h"
#include "CFNetworkSuppressedGzipDecoder.h"

#include "ResourceResponse.h"
#include <wtf/ASCIICType.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(CFNetworkSuppressedGzipDecoder);

static bool hasGzipArchiveExtension(StringView filename)
{
    auto dot = filename.reverseFind('.');
    if (dot == notFound || !dot)
        return false;
    auto extension = filename.substring(dot + 1);
    return equalLettersIgnoringASCIICase(extension, "gz"_s) || equalLettersIgnoringASCIICase(extension, "tgz"_s);
}

static String percentDecoded(StringView value)
{
    Vector<char16_t> characters;
    characters.reserveInitialCapacity(value.length());
    for (unsigned i = 0; i < value.length(); ++i) {
        if (value[i] == '%' && i + 2 < value.length() && isASCIIHexDigit(value[i + 1]) && isASCIIHexDigit(value[i + 2])) {
            characters.append(toASCIIHexValue(value[i + 1], value[i + 2]));
            i += 2;
            continue;
        }
        characters.append(value[i]);
    }
    return String::adopt(WTF::move(characters));
}

// The filename CFNetwork takes from a Content-Disposition header: parameters are separated by
// semicolons outside double quotes, the name "filename" matches case-insensitively at the start of a
// parameter, and the RFC 5987 extended form -- an asterisk directly after the name, then
// charset'language'percent-encoded-value with charset UTF-8 or ISO-8859-1 -- wins over the plain form
// wherever the two appear. The first of each form is the one that counts, and an empty value counts as
// no filename at all.
static String contentDispositionFilename(StringView header)
{
    String plain;
    String extended;
    unsigned parameterStart = 0;
    bool inQuotes = false;
    for (unsigned i = 0; i <= header.length(); ++i) {
        if (i < header.length()) {
            if (header[i] == '"')
                inQuotes = !inQuotes;
            if (header[i] != ';' || inQuotes)
                continue;
        }
        auto parameter = header.substring(parameterStart, i - parameterStart).trim(isASCIIWhitespaceWithoutFF<char16_t>);
        parameterStart = i + 1;
        if (!parameter.startsWithIgnoringASCIICase("filename"_s))
            continue;

        auto rest = parameter.substring(8);
        bool isExtended = !rest.isEmpty() && rest[0] == '*';
        if (isExtended)
            rest = rest.substring(1);
        rest = rest.trim(isASCIIWhitespaceWithoutFF<char16_t>);
        if (rest.isEmpty() || rest[0] != '=')
            continue;
        auto value = rest.substring(1).trim(isASCIIWhitespaceWithoutFF<char16_t>);

        if (isExtended) {
            if (!extended.isEmpty())
                continue;
            auto charsetEnd = value.find('\'');
            if (charsetEnd == notFound || !charsetEnd)
                continue;
            auto charset = value.left(charsetEnd);
            if (!equalLettersIgnoringASCIICase(charset, "utf-8"_s) && !equalLettersIgnoringASCIICase(charset, "iso-8859-1"_s))
                continue;
            auto languageEnd = value.find('\'', charsetEnd + 1);
            if (languageEnd == notFound)
                continue;
            extended = percentDecoded(value.substring(languageEnd + 1));
            continue;
        }

        if (!plain.isEmpty())
            continue;
        if (value.length() > 1 && value[0] == '"' && value[value.length() - 1] == '"')
            value = value.substring(1, value.length() - 2);
        plain = value.toString();
    }
    return !extended.isEmpty() ? extended : plain;
}

// 10.9 CFNetwork decodes Content-Encoding: gzip transparently unless the response looks like a gzip
// archive, in which case it delivers the compressed bytes with the Content-Encoding header still on the
// response. Its condition, in order: the first Content-Encoding element is gzip or x-gzip; then, if
// Content-Disposition carries a filename, that filename's extension alone decides; otherwise the
// Content-Type must start with application/octet-stream, application/x-gzip or application/x-tar and
// the final URL's last path component must carry the extension. Every comparison is case-insensitive
// and the extension is gz or tgz. Reproducing the condition is the only way to tell a suppressed body
// apart from a decoded one: the header is present either way, and a decoded body can still begin with
// the gzip magic.
bool CFNetworkSuppressedGzipDecoder::responseBodyIsStillGzipped(const ResourceResponse& response)
{
    auto contentEncoding = response.httpHeaderField(HTTPHeaderName::ContentEncoding);
    StringView encodings { contentEncoding };
    auto comma = encodings.find(',');
    auto firstEncoding = (comma == notFound ? encodings : encodings.left(comma)).trim(isASCIIWhitespaceWithoutFF<char16_t>);
    if (!equalLettersIgnoringASCIICase(firstEncoding, "gzip"_s) && !equalLettersIgnoringASCIICase(firstEncoding, "x-gzip"_s))
        return false;

    auto contentDisposition = response.httpHeaderField(HTTPHeaderName::ContentDisposition);
    auto filename = contentDispositionFilename(StringView { contentDisposition });
    if (!filename.isEmpty())
        return hasGzipArchiveExtension(filename);

    auto contentType = response.httpHeaderField(HTTPHeaderName::ContentType);
    auto mediaType = StringView { contentType }.trim(isASCIIWhitespaceWithoutFF<char16_t>);
    if (!mediaType.startsWithIgnoringASCIICase("application/octet-stream"_s)
        && !mediaType.startsWithIgnoringASCIICase("application/x-gzip"_s)
        && !mediaType.startsWithIgnoringASCIICase("application/x-tar"_s))
        return false;

    return hasGzipArchiveExtension(response.url().lastPathComponent());
}

CFNetworkSuppressedGzipDecoder::CFNetworkSuppressedGzipDecoder()
{
    m_stream.zalloc = Z_NULL;
    m_stream.zfree = Z_NULL;
    m_stream.opaque = Z_NULL;
    m_stream.next_in = Z_NULL;
    m_stream.avail_in = 0;
    // 15 window bits + 32 enables automatic gzip/zlib header detection.
    m_initialized = inflateInit2(&m_stream, 15 + 32) == Z_OK;
    m_failed = !m_initialized;
}

CFNetworkSuppressedGzipDecoder::~CFNetworkSuppressedGzipDecoder()
{
    if (m_initialized)
        inflateEnd(&m_stream);
}

std::optional<Vector<uint8_t>> CFNetworkSuppressedGzipDecoder::decode(std::span<const uint8_t> data)
{
    if (m_failed)
        return std::nullopt;

    m_sawInput = true;
    m_stream.next_in = const_cast<Bytef*>(data.data());
    m_stream.avail_in = data.size();

    Vector<uint8_t> decoded;
    uint8_t outputChunk[16384];
    while (m_stream.avail_in) {
        m_stream.next_out = outputChunk;
        m_stream.avail_out = sizeof(outputChunk);
        int result = inflate(&m_stream, Z_NO_FLUSH);
        if (size_t produced = sizeof(outputChunk) - m_stream.avail_out)
            decoded.append(std::span<const uint8_t> { outputChunk, produced });
        if (result == Z_STREAM_END) {
            // This member is complete; reset and keep draining so concatenated members all decode.
            m_inMember = false;
            if (inflateReset(&m_stream) != Z_OK) {
                m_failed = true;
                return std::nullopt;
            }
            continue;
        }
        // Z_BUF_ERROR means the stream needs more input than this chunk carries; zlib keeps its state,
        // so wait for the next one.
        if (result == Z_BUF_ERROR) {
            m_inMember = true;
            break;
        }
        if (result != Z_OK) {
            m_failed = true;
            return std::nullopt;
        }
        m_inMember = true;
    }
    return decoded;
}

} // namespace WebCore
