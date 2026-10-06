/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaCurlContentDecoder.h"

#include "ResourceResponse.h"
#include <brotli/decode.h>
#include <wtf/ASCIICType.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>
#include <zlib.h>
#include <zstd.h>

namespace WebCore {

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
// and the extension is gz or tgz.
static bool cfnetworkLeavesGzipArchiveEncoded(const ResourceResponse& response)
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

enum class ContentCoding : uint8_t { Gzip, Deflate, Brotli, Zstandard };

static std::optional<ContentCoding> contentCoding(StringView name)
{
    if (equalLettersIgnoringASCIICase(name, "gzip"_s) || equalLettersIgnoringASCIICase(name, "x-gzip"_s))
        return ContentCoding::Gzip;
    if (equalLettersIgnoringASCIICase(name, "deflate"_s))
        return ContentCoding::Deflate;
    if (equalLettersIgnoringASCIICase(name, "br"_s))
        return ContentCoding::Brotli;
    if (equalLettersIgnoringASCIICase(name, "zstd"_s))
        return ContentCoding::Zstandard;
    return std::nullopt;
}

static constexpr size_t outputChunkSize = 16384;

// One coding's decoder. It keeps the input it has not used yet, and each call decodes as much as fits.
class CodingDecoder {
public:
    virtual ~CodingDecoder() = default;
    void append(std::span<const uint8_t> bytes)
    {
        m_input.removeAt(0, std::exchange(m_offset, 0));
        m_input.append(bytes);
    }
    // Appends at most limit - output.size() decoded bytes to output; false when the input cannot be
    // decoded.
    virtual bool decode(Vector<uint8_t>& output, size_t limit) = 0;
    virtual bool isComplete() const = 0;

protected:
    std::span<const uint8_t> input() const { return m_input.subspan(m_offset); }
    void consume(size_t length) { m_offset += length; }

private:
    Vector<uint8_t> m_input;
    size_t m_offset { 0 };
};

// Raw deflate, for the gzip and zlib framings.
class InflateStream {
public:
    InflateStream()
    {
        m_initialized = inflateInit2(&m_stream, -15) == Z_OK;
    }
    ~InflateStream()
    {
        if (m_initialized)
            inflateEnd(&m_stream);
    }
    bool reset()
    {
        m_hasPendingOutput = false;
        return inflateReset(&m_stream) == Z_OK;
    }
    // Output zlib holds back because the last call filled its limit.
    bool hasPendingOutput() const { return m_hasPendingOutput; }
    enum class Result : uint8_t { Continue, Ended, Failed };
    // Decodes from the front of input, reporting how much it consumed.
    Result inflate(std::span<const uint8_t> input, size_t& consumed, Vector<uint8_t>& output, size_t limit)
    {
        consumed = 0;
        if (!m_initialized)
            return Result::Failed;
        m_stream.next_in = const_cast<Bytef*>(input.data());
        m_stream.avail_in = input.size();
        uint8_t chunk[outputChunkSize];
        auto result = Result::Continue;
        m_hasPendingOutput = false;
        while (output.size() < limit) {
            size_t room = std::min(sizeof(chunk), limit - output.size());
            m_stream.next_out = chunk;
            m_stream.avail_out = room;
            int status = ::inflate(&m_stream, Z_NO_FLUSH);
            size_t produced = room - m_stream.avail_out;
            output.append(std::span<const uint8_t> { chunk, produced });
            if (status == Z_STREAM_END) {
                result = Result::Ended;
                break;
            }
            if (status != Z_OK && status != Z_BUF_ERROR) {
                result = Result::Failed;
                break;
            }
            if (m_stream.avail_out) {
                // zlib used all the input it could and has nothing more to write.
                break;
            }
            m_hasPendingOutput = output.size() >= limit;
        }
        consumed = input.size() - m_stream.avail_in;
        return result;
    }

private:
    z_stream m_stream { };
    bool m_initialized { false };
    bool m_hasPendingOutput { false };
};

// The length of the gzip member header at the front of bytes (RFC 1952), 0 while more bytes are needed,
// or nullopt when the bytes are not a deflate-compressed gzip member.
static std::optional<size_t> gzipHeaderLength(std::span<const uint8_t> bytes)
{
    if ((bytes.size() >= 1 && bytes[0] != 0x1f) || (bytes.size() >= 2 && bytes[1] != 0x8b) || (bytes.size() >= 3 && bytes[2] != 8))
        return std::nullopt;
    if (bytes.size() < 10)
        return 0;
    uint8_t flags = bytes[3];
    size_t length = 10;
    if (flags & 0x04) {
        if (bytes.size() < length + 2)
            return 0;
        length += 2 + (bytes[length] | (bytes[length + 1] << 8));
    }
    for (uint8_t zeroTerminated : { 0x08, 0x10 }) {
        if (!(flags & zeroTerminated))
            continue;
        while (true) {
            if (bytes.size() <= length)
                return 0;
            if (!bytes[length++])
                break;
        }
    }
    if (flags & 0x02)
        length += 2;
    return bytes.size() < length ? std::optional<size_t> { 0 } : length;
}

// A gzip body's members may be concatenated, and each is complete when its deflate stream ends: the
// eight trailer bytes go unchecked, and bytes after a trailer that do not begin another member are
// ignored.
class GzipDecoder final : public CodingDecoder {
    WTF_MAKE_TZONE_ALLOCATED(GzipDecoder);
public:
    bool decode(Vector<uint8_t>& output, size_t limit) final
    {
        while (output.size() < limit) {
            auto bytes = input();
            switch (m_state) {
            case State::Header: {
                if (bytes.empty())
                    return true;
                auto length = gzipHeaderLength(bytes);
                if (!length) {
                    if (m_inFirstMember)
                        return false;
                    m_state = State::Ignored;
                    break;
                }
                if (!*length)
                    return true;
                consume(*length);
                m_state = State::Inflating;
                break;
            }
            case State::Inflating: {
                if (bytes.empty() && !m_stream.hasPendingOutput())
                    return true;
                size_t consumed = 0;
                auto result = m_stream.inflate(bytes, consumed, output, limit);
                consume(consumed);
                if (result == InflateStream::Result::Failed)
                    return false;
                if (result == InflateStream::Result::Ended) {
                    if (!m_stream.reset())
                        return false;
                    m_inFirstMember = false;
                    m_trailerBytesLeft = 8;
                    m_state = State::Trailer;
                } else if (consumed == bytes.size() && !m_stream.hasPendingOutput())
                    return true;
                break;
            }
            case State::Trailer: {
                if (bytes.empty())
                    return true;
                size_t skipped = std::min(m_trailerBytesLeft, bytes.size());
                consume(skipped);
                m_trailerBytesLeft -= skipped;
                if (!m_trailerBytesLeft)
                    m_state = State::Header;
                break;
            }
            case State::Ignored:
                consume(bytes.size());
                return true;
            }
        }
        return true;
    }
    bool isComplete() const final
    {
        if (m_state == State::Inflating)
            return false;
        return !m_inFirstMember || m_state != State::Header || input().empty();
    }

private:
    enum class State : uint8_t { Header, Inflating, Trailer, Ignored };
    InflateStream m_stream;
    State m_state { State::Header };
    size_t m_trailerBytesLeft { 0 };
    bool m_inFirstMember { true };
};

// deflate is the zlib format, or raw deflate when the body does not begin with a zlib header. The
// stream is complete when its deflate data ends; the Adler-32 that follows is checked when all of it
// arrives.
class DeflateDecoder final : public CodingDecoder {
    WTF_MAKE_TZONE_ALLOCATED(DeflateDecoder);
public:
    bool decode(Vector<uint8_t>& output, size_t limit) final
    {
        while (output.size() < limit) {
            auto bytes = input();
            switch (m_state) {
            case State::Header: {
                if (bytes.size() < 2)
                    return true;
                uint8_t method = bytes[0];
                uint8_t flags = bytes[1];
                m_hasZlibHeader = (method & 0x0f) == 8 && (method >> 4) <= 7 && !(flags & 0x20) && !(((method << 8) | flags) % 31);
                if (m_hasZlibHeader)
                    consume(2);
                m_state = State::Inflating;
                break;
            }
            case State::Inflating: {
                if (bytes.empty() && !m_stream.hasPendingOutput())
                    return true;
                size_t outputStart = output.size();
                size_t consumed = 0;
                auto result = m_stream.inflate(bytes, consumed, output, limit);
                consume(consumed);
                // adler32 takes a null buffer as a request for its initial value.
                if (output.size() > outputStart)
                    m_adler = adler32(m_adler, output.subspan(outputStart).data(), output.size() - outputStart);
                if (result == InflateStream::Result::Failed)
                    return false;
                if (result == InflateStream::Result::Ended)
                    m_state = m_hasZlibHeader ? State::Checksum : State::Ended;
                else if (consumed == bytes.size() && !m_stream.hasPendingOutput())
                    return true;
                break;
            }
            case State::Checksum: {
                if (bytes.size() < 4)
                    return true;
                uint32_t expected = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
                if (expected != m_adler)
                    return false;
                consume(4);
                m_state = State::Ended;
                break;
            }
            case State::Ended:
                consume(bytes.size());
                return true;
            }
        }
        return true;
    }
    bool isComplete() const final
    {
        return (m_state == State::Header && input().empty()) || m_state == State::Checksum || m_state == State::Ended;
    }

private:
    enum class State : uint8_t { Header, Inflating, Checksum, Ended };
    InflateStream m_stream;
    State m_state { State::Header };
    uLong m_adler { adler32(0, nullptr, 0) };
    bool m_hasZlibHeader { false };
};

class BrotliCodingDecoder final : public CodingDecoder {
    WTF_MAKE_TZONE_ALLOCATED(BrotliCodingDecoder);
public:
    BrotliCodingDecoder()
        : m_state(BrotliDecoderCreateInstance(nullptr, nullptr, nullptr))
    {
    }
    ~BrotliCodingDecoder()
    {
        if (m_state)
            BrotliDecoderDestroyInstance(m_state);
    }
    bool decode(Vector<uint8_t>& output, size_t limit) final
    {
        if (!m_state)
            return false;
        auto bytes = input();
        if (!bytes.empty())
            m_sawInput = true;
        size_t availableIn = bytes.size();
        const uint8_t* nextIn = bytes.data();
        uint8_t chunk[outputChunkSize];
        bool ok = true;
        while (output.size() < limit && !m_finished) {
            size_t room = std::min(sizeof(chunk), limit - output.size());
            size_t availableOut = room;
            uint8_t* nextOut = chunk;
            auto result = BrotliDecoderDecompressStream(m_state, &availableIn, &nextIn, &availableOut, &nextOut, nullptr);
            output.append(std::span<const uint8_t> { chunk, room - availableOut });
            if (result == BROTLI_DECODER_RESULT_ERROR) {
                ok = false;
                break;
            }
            if (result == BROTLI_DECODER_RESULT_SUCCESS)
                m_finished = true;
            if (result == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT)
                break;
        }
        consume(bytes.size() - availableIn);
        if (m_finished)
            consume(input().size());
        return ok;
    }
    bool isComplete() const final { return !m_sawInput || m_finished; }

private:
    BrotliDecoderState* m_state;
    bool m_sawInput { false };
    bool m_finished { false };
};

class ZstandardDecoder final : public CodingDecoder {
    WTF_MAKE_TZONE_ALLOCATED(ZstandardDecoder);
public:
    ZstandardDecoder()
        : m_stream(ZSTD_createDStream())
    {
    }
    ~ZstandardDecoder()
    {
        if (m_stream)
            ZSTD_freeDStream(m_stream);
    }
    bool decode(Vector<uint8_t>& output, size_t limit) final
    {
        if (!m_stream)
            return false;
        auto bytes = input();
        ZSTD_inBuffer in { bytes.data(), bytes.size(), 0 };
        uint8_t chunk[outputChunkSize];
        bool ok = true;
        while (output.size() < limit && (in.pos < in.size || m_hasPendingOutput)) {
            size_t room = std::min(sizeof(chunk), limit - output.size());
            ZSTD_outBuffer out { chunk, room, 0 };
            size_t result = ZSTD_decompressStream(m_stream, &out, &in);
            if (ZSTD_isError(result)) {
                ok = false;
                break;
            }
            output.append(std::span<const uint8_t> { chunk, out.pos });
            m_frameComplete = !result;
            m_hasPendingOutput = out.pos == out.size;
            if (!out.pos && in.pos == in.size)
                break;
        }
        consume(in.pos);
        return ok;
    }
    bool isComplete() const final { return m_frameComplete; }

private:
    ZSTD_DStream* m_stream;
    bool m_frameComplete { true };
    bool m_hasPendingOutput { false };
};

class ContentDecoderChain final : public CocoaCurlContentDecoder {
    WTF_MAKE_TZONE_ALLOCATED(ContentDecoderChain);
public:
    explicit ContentDecoderChain(Vector<std::unique_ptr<CodingDecoder>>&& stages)
        : m_stages(WTF::move(stages))
    {
    }
    void append(std::span<const uint8_t> bytes) final
    {
        m_stages.first()->append(bytes);
    }
    // Each stage takes a chunk of the previous stage's output whenever its own input runs out.
    std::optional<Vector<uint8_t>> read(size_t limit) final
    {
        Vector<uint8_t> output;
        size_t last = m_stages.size() - 1;
        while (output.size() < limit) {
            size_t before = output.size();
            if (!m_stages[last]->decode(output, limit))
                return std::nullopt;
            if (output.size() > before)
                continue;
            // Refill the last stage from the nearest stage that still produces output.
            size_t stage = last;
            while (stage) {
                Vector<uint8_t> chunk;
                if (!m_stages[stage - 1]->decode(chunk, outputChunkSize))
                    return std::nullopt;
                if (!chunk.isEmpty()) {
                    m_stages[stage]->append(chunk.span());
                    break;
                }
                --stage;
            }
            if (!stage)
                return output;
        }
        return output;
    }
    bool isComplete() const final
    {
        for (auto& stage : m_stages) {
            if (!stage->isComplete())
                return false;
        }
        return true;
    }

private:
    Vector<std::unique_ptr<CodingDecoder>> m_stages;
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(GzipDecoder);
WTF_MAKE_TZONE_ALLOCATED_IMPL(DeflateDecoder);
WTF_MAKE_TZONE_ALLOCATED_IMPL(BrotliCodingDecoder);
WTF_MAKE_TZONE_ALLOCATED_IMPL(ZstandardDecoder);
WTF_MAKE_TZONE_ALLOCATED_IMPL(ContentDecoderChain);

std::unique_ptr<CocoaCurlContentDecoder> CocoaCurlContentDecoder::create(const ResourceResponse& response, ContentEncodingSniffingPolicy policy)
{
    auto contentEncoding = response.httpHeaderField(HTTPHeaderName::ContentEncoding);
    Vector<ContentCoding> codings;
    for (auto element : StringView { contentEncoding }.split(',')) {
        auto name = element.trim(isASCIIWhitespaceWithoutFF<char16_t>);
        if (name.isEmpty() || equalLettersIgnoringASCIICase(name, "identity"_s))
            continue;
        auto coding = contentCoding(name);
        if (!coding)
            return nullptr;
        codings.append(*coding);
    }
    if (codings.isEmpty())
        return nullptr;
    if (policy == ContentEncodingSniffingPolicy::Default && cfnetworkLeavesGzipArchiveEncoded(response))
        return nullptr;

    // The codings were applied in the order listed, so the decoders run in reverse.
    Vector<std::unique_ptr<CodingDecoder>> stages;
    for (size_t i = codings.size(); i--;) {
        switch (codings[i]) {
        case ContentCoding::Gzip:
            stages.append(makeUnique<GzipDecoder>());
            break;
        case ContentCoding::Deflate:
            stages.append(makeUnique<DeflateDecoder>());
            break;
        case ContentCoding::Brotli:
            stages.append(makeUnique<BrotliCodingDecoder>());
            break;
        case ContentCoding::Zstandard:
            stages.append(makeUnique<ZstandardDecoder>());
            break;
        }
    }
    return makeUnique<ContentDecoderChain>(WTF::move(stages));
}

} // namespace WebCore
