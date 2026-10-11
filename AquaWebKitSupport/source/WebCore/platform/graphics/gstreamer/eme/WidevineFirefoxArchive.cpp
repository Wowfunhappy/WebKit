#include "config.h"
#include "WidevineFirefoxArchive.h"

#include "WidevineCdmArchive.h"
#include "WidevineHostFiles.h"
#include <stdio.h>
#include <wtf/FileSystem.h>
#include <wtf/Scope.h>
#include <wtf/text/MakeString.h>

// Mavericks' libarchive 2 ABI. Apple ships the library without its headers in the SDK.
extern "C" {
struct archive;
struct archive_entry;
archive* archive_read_new();
int archive_read_support_compression_xz(archive*);
int archive_read_support_compression_bzip2(archive*);
int archive_read_support_format_raw(archive*);
int archive_read_open_memory(archive*, const void*, size_t);
int archive_read_next_header(archive*, archive_entry**);
ssize_t archive_read_data(archive*, void*, size_t);
int archive_read_finish(archive*);
}

namespace WebCore {

static std::optional<uint32_t> marInteger(std::span<const uint8_t> bytes, size_t offset)
{
    if (offset > bytes.size() || bytes.size() - offset < 4)
        return std::nullopt;
    return (uint32_t(bytes[offset]) << 24) | (uint32_t(bytes[offset + 1]) << 16)
        | (uint32_t(bytes[offset + 2]) << 8) | bytes[offset + 3];
}

static bool unpackFirefoxFile(std::span<const uint8_t> compressed, const String& path, size_t limit)
{
    auto* reader = archive_read_new();
    if (!reader)
        return false;
    auto finish = makeScopeExit([&] { archive_read_finish(reader); });
    if (archive_read_support_compression_xz(reader) || archive_read_support_compression_bzip2(reader)
        || archive_read_support_format_raw(reader) || archive_read_open_memory(reader, compressed.data(), compressed.size()))
        return false;
    archive_entry* entry = nullptr;
    if (archive_read_next_header(reader, &entry))
        return false;
    if (!FileSystem::makeAllDirectories(FileSystem::parentPath(path)))
        return false;
    auto* file = fopen(path.utf8().data(), "wb");
    if (!file)
        return false;
    auto close = makeScopeExit([&] { fclose(file); });
    std::array<uint8_t, 64 * KB> buffer;
    size_t size = 0;
    while (true) {
        auto count = archive_read_data(reader, buffer.data(), buffer.size());
        if (count < 0 || static_cast<size_t>(count) > limit - size)
            return false;
        if (!count)
            return size && !fflush(file);
        if (fwrite(buffer.data(), 1, count, file) != static_cast<size_t>(count))
            return false;
        size += count;
    }
}

Expected<void, String> extractWidevineFirefoxFiles(std::span<const uint8_t> bytes, const String& directory)
{
    auto index = marInteger(bytes, 4);
    if (bytes.size() < 8 || memcmp(bytes.data(), "MAR1", 4) || !index || *index < 8)
        return makeUnexpected("Firefox did not arrive as a MAR archive"_s);
    auto indexSize = marInteger(bytes, *index);
    if (!indexSize || *indexSize != bytes.size() - *index - 4)
        return makeUnexpected("the Firefox MAR index is truncated"_s);

    std::array<ASCIILiteral, 8> wanted {
        firefoxHostFiles[0].image, firefoxHostFiles[0].signature,
        firefoxHostFiles[1].image, firefoxHostFiles[1].signature,
        firefoxHostFiles[2].image, firefoxHostFiles[2].signature,
        firefoxApplicationInfo, "Contents/Resources/omni.ja"_s
    };
    std::array<bool, 8> found { };
    size_t position = *index + 4;
    while (position < bytes.size()) {
        auto offset = marInteger(bytes, position);
        auto size = marInteger(bytes, position + 4);
        if (!offset || !size || bytes.size() - position < 13 || *offset < 8 || *offset > *index || *size > *index - *offset)
            return makeUnexpected("a Firefox MAR member is out of bounds"_s);
        position += 12;
        size_t start = position;
        while (position < bytes.size() && bytes[position])
            ++position;
        if (position == bytes.size())
            return makeUnexpected("a Firefox MAR filename is unterminated"_s);
        auto name = String::fromUTF8(bytes.subspan(start, position++ - start));
        for (size_t i = 0; i < wanted.size(); ++i) {
            if (name != wanted[i])
                continue;
            if (found[i])
                return makeUnexpected(makeString("duplicate Firefox MAR member: "_s, name));
            auto path = FileSystem::pathByAppendingComponent(directory, wanted[i]);
            if (!unpackFirefoxFile(bytes.subspan(*offset, *size), path, i == 4 ? 1 * GB : 128 * MB))
                return makeUnexpected(makeString("cannot unpack Firefox MAR member: "_s, name));
            found[i] = true;
        }
    }
    for (size_t i = 0; i < wanted.size(); ++i) {
        if (!found[i])
            return makeUnexpected(makeString("Firefox MAR lacks "_s, wanted[i]));
    }
    auto omniPath = FileSystem::pathByAppendingComponent(directory, wanted[7]);
    auto omni = FileSystem::readEntireFile(omniPath);
    if (!omni)
        return makeUnexpected("cannot read Firefox omni.ja"_s);
    auto license = extractFirefoxLicense(omni->span());
    if (!license)
        return makeUnexpected(license.error());
    if (!FileSystem::overwriteEntireFile(FileSystem::pathByAppendingComponent(directory, firefoxLicense), license->span()))
        return makeUnexpected("cannot write Firefox license notices"_s);
    FileSystem::deleteFile(omniPath);
    return { };
}

} // namespace WebCore
