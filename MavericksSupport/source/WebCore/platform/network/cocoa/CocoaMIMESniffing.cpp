/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */
#include "config.h"
#include "CocoaMIMESniffing.h"

#include "MIMESniffer.h"
#include "MIMETypeRegistry.h"
#include "ParsedContentType.h"
#include <wtf/ASCIICType.h>
#include <wtf/StdLibExtras.h>

namespace WebCore {
namespace MIMESniffer {

// https://mimesniff.spec.whatwg.org/ sections 6.1, 6.4 and 7.
static String suppliedHTTPMIMEType(const String& contentType)
{
    auto parsed = ParsedContentType::create(contentType);
    return parsed ? parsed->mimeType().convertToASCIILowercase() : emptyString();
}

static bool unknownHTTPMIMEType(const String& type)
{
    return type.isEmpty() || type == "unknown/unknown"_s || type == "application/unknown"_s || type == "*/*"_s;
}

static bool checkForMislabeledBinary(const String& contentType)
{
    return contentType == "text/plain"_s || contentType == "text/plain; charset=ISO-8859-1"_s
        || contentType == "text/plain; charset=iso-8859-1"_s || contentType == "text/plain; charset=UTF-8"_s;
}

bool needsHTTPContentSniffing(const String& contentType, bool noSniff)
{
    auto type = suppliedHTTPMIMEType(contentType);
    if (unknownHTTPMIMEType(type))
        return true;
    if (noSniff || type == "text/html"_s || type == "text/xml"_s || type == "application/xml"_s || type.endsWith("+xml"_s))
        return false;
    return checkForMislabeledBinary(contentType) || type.startsWith("image/"_s) || type.startsWith("audio/"_s) || type.startsWith("video/"_s) || type == "application/ogg"_s;
}

template<size_t N> static bool beginsWithBytes(std::span<const uint8_t> bytes, const char (&prefix)[N])
{
    return bytes.size() >= N - 1 && !memcmp(bytes.data(), prefix, N - 1);
}

static String sniffHTTPImage(std::span<const uint8_t> bytes)
{
    if (beginsWithBytes(bytes, "\0\0\1\0") || beginsWithBytes(bytes, "\0\0\2\0"))
        return "image/x-icon"_s;
    if (beginsWithBytes(bytes, "BM"))
        return "image/bmp"_s;
    if (beginsWithBytes(bytes, "GIF87a") || beginsWithBytes(bytes, "GIF89a"))
        return "image/gif"_s;
    if (bytes.size() >= 14 && beginsWithBytes(bytes, "RIFF") && beginsWithBytes(bytes.subspan(8), "WEBPVP"))
        return "image/webp"_s;
    if (beginsWithBytes(bytes, "\x89PNG\r\n\x1a\n"))
        return "image/png"_s;
    if (beginsWithBytes(bytes, "\xff\xd8\xff"))
        return "image/jpeg"_s;
    return emptyString();
}

static String distinguishTextFromBinary(std::span<const uint8_t> bytes)
{
    if (beginsWithBytes(bytes, "\xfe\xff") || beginsWithBytes(bytes, "\xff\xfe") || beginsWithBytes(bytes, "\xef\xbb\xbf"))
        return "text/plain"_s;
    for (auto byte : bytes) {
        if (byte <= 8 || byte == 11 || (byte >= 14 && byte <= 26) || (byte >= 28 && byte <= 31))
            return "application/octet-stream"_s;
    }
    return "text/plain"_s;
}

String computeHTTPMIMEType(std::span<const uint8_t> bytes, const String& contentType, bool noSniff)
{
    auto supplied = suppliedHTTPMIMEType(contentType);
    if (!unknownHTTPMIMEType(supplied)) {
        if (!needsHTTPContentSniffing(contentType, noSniff))
            return supplied;
        if (checkForMislabeledBinary(contentType))
            return distinguishTextFromBinary(bytes);
        if (supplied.startsWith("image/"_s) && MIMETypeRegistry::isSupportedImageMIMEType(supplied)) {
            auto image = sniffHTTPImage(bytes);
            if (!image.isEmpty())
                return image;
        }
        if (supplied.startsWith("audio/"_s) || supplied.startsWith("video/"_s) || supplied == "application/ogg"_s) {
            auto media = getMIMETypeFromContent(bytes);
            if (!media.isEmpty())
                return media;
        }
        return supplied;
    }
    if (!noSniff) {
        auto trimmed = bytes;
        while (!trimmed.empty() && (trimmed[0] == 9 || trimmed[0] == 10 || trimmed[0] == 12 || trimmed[0] == 13 || trimmed[0] == 32))
            trimmed = trimmed.subspan(1);
        for (auto tag : { "<!DOCTYPE HTML"_s, "<HTML"_s, "<HEAD"_s, "<SCRIPT"_s, "<IFRAME"_s, "<H1"_s, "<DIV"_s, "<FONT"_s, "<TABLE"_s, "<A"_s, "<STYLE"_s, "<TITLE"_s, "<B"_s, "<BODY"_s, "<BR"_s, "<P"_s }) {
            if (trimmed.size() <= tag.length() || (trimmed[tag.length()] != ' ' && trimmed[tag.length()] != '>'))
                continue;
            bool matches = true;
            for (size_t i = 0; i < tag.length(); ++i)
                matches &= toASCIIUpper(trimmed[i]) == tag[i];
            if (matches)
                return "text/html"_s;
        }
        if (beginsWithBytes(trimmed, "<!--"))
            return "text/html"_s;
        if (beginsWithBytes(trimmed, "<?xml"))
            return "text/xml"_s;
        if (beginsWithBytes(bytes, "%PDF-"))
            return "application/pdf"_s;
    }
    if (beginsWithBytes(bytes, "%!PS-Adobe-"))
        return "application/postscript"_s;
    if (beginsWithBytes(bytes, "\xfe\xff") || beginsWithBytes(bytes, "\xff\xfe") || beginsWithBytes(bytes, "\xef\xbb\xbf"))
        return "text/plain"_s;
    if (auto image = sniffHTTPImage(bytes); !image.isEmpty())
        return image;
    if (auto media = getMIMETypeFromContent(bytes); !media.isEmpty())
        return media;
    if (beginsWithBytes(bytes, "\x1f\x8b\x08"))
        return "application/x-gzip"_s;
    if (beginsWithBytes(bytes, "PK\3\4"))
        return "application/zip"_s;
    if (beginsWithBytes(bytes, "Rar!\x1a\7\0"))
        return "application/x-rar-compressed"_s;
    return distinguishTextFromBinary(bytes);
}

} // namespace MIMESniffer
} // namespace WebCore
