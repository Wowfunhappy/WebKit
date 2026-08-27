// MAVERICKS_BACKPORT: see WidevineCdmImage.h.
//
// Three passes stand between the module Google publishes and one 10.9's dyld will load. Each works
// only on load commands, segment names and the fixup streams, and each measures the image and this
// host rather than assume anything about either, so a module that cannot be handled fails by name.
//
// 1. Chained fixups (the linker default from macOS 12) become the classic LC_DYLD_INFO_ONLY
//    rebase and bind opcodes 10.9 understands. LC_DYLD_CHAINED_FIXUPS carries the LC_REQ_DYLD
//    bit, which makes an unknown command fatal rather than ignored, so an unconverted image is
//    refused outright by dyld.
// 2. __DATA_CONST becomes __DATA. 10.9 predates that segment, and its Objective-C runtime looks
//    for __objc_imageinfo in __DATA alone: with the metadata somewhere it does not look, it skips
//    the image entirely, leaving the selector references pointing at method-name strings, and the
//    first message send into the module aborts.
// 3. Imports this host cannot resolve are bound against a gap library instead. One absent,
//    unimported load command is repointed at that library and the remaining absent ones are
//    aliased onto libSystem: dyld drops a missing library from its ordinal array, which would
//    renumber every later ordinal the bind opcodes name.

#include "config.h"
#include "WidevineCdmImage.h"

#if PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)

#include <mach-o/fat.h>
#include <mach-o/fixup-chains.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <wtf/FileSystem.h>
#include <wtf/MappedFileData.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringHash.h>

namespace WebCore {

namespace {

static constexpr auto libSystemPath = "/usr/lib/libSystem.B.dylib"_s;
static constexpr auto dataConstSegmentName = "__DATA_CONST";

struct DylibCommand {
    size_t commandOffset { 0 };
    uint32_t commandSize { 0 };
    uint32_t pathOffset { 0 };
    String path;
};

uint64_t readULEB(std::span<const uint8_t> stream, size_t& position)
{
    uint64_t result = 0;
    unsigned shift = 0;
    while (position < stream.size()) {
        uint8_t byte = stream[position++];
        result |= static_cast<uint64_t>(byte & 0x7f) << shift;
        shift += 7;
        if (!(byte & 0x80))
            break;
    }
    return result;
}

inline std::span<const uint8_t> spanOf(const Vector<uint8_t>& image) { return image.span(); }
inline std::span<const uint8_t> spanOf(std::span<const uint8_t> image) { return image; }

template<typename T, typename Bytes> const T* structureAt(const Bytes& image, size_t offset, size_t count = 1)
{
    auto bytes = spanOf(image);
    if (offset > bytes.size() || (bytes.size() - offset) / sizeof(T) < count)
        return nullptr;
    return reinterpret_cast<const T*>(bytes.subspan(offset).data());
}

template<typename T> T* mutableStructureAt(Vector<uint8_t>& image, size_t offset, size_t count = 1)
{
    if (offset > image.size() || (image.size() - offset) / sizeof(T) < count)
        return nullptr;
    return reinterpret_cast<T*>(image.mutableSpan().subspan(offset).data());
}

// Calls |handler| with the offset of each load command of the image at |imageOffset|. It stops at
// the first command the header does not fully contain, which every caller treats as truncated.
template<typename Bytes, typename Handler> bool forEachLoadCommandFrom(const Bytes& image, size_t imageOffset, Handler&& handler)
{
    auto* header = structureAt<mach_header_64>(image, imageOffset);
    if (!header)
        return false;

    size_t offset = imageOffset + sizeof(mach_header_64);
    size_t commandsEnd = offset + header->sizeofcmds;
    if (commandsEnd > image.size())
        return false;

    for (uint32_t i = 0; i < header->ncmds; ++i) {
        auto* command = structureAt<load_command>(image, offset);
        if (!command || command->cmdsize < sizeof(load_command) || offset + command->cmdsize > commandsEnd)
            return false;
        handler(offset, command->cmd, command->cmdsize);
        offset += command->cmdsize;
    }
    return true;
}

template<typename Handler> bool forEachLoadCommand(const Vector<uint8_t>& image, Handler&& handler)
{
    return forEachLoadCommandFrom(image, 0, WTF::move(handler));
}

// The x86_64 Mach-O inside a file, which for everything 10.9 ships on disk is one slice of a
// universal file. Nothing without that slice is a library this host binds against.
std::optional<size_t> machOSliceOffset(const Vector<uint8_t>& file)
{
    auto* header = structureAt<fat_header>(file, 0);
    if (!header)
        return std::nullopt;
    if (header->magic != FAT_MAGIC && header->magic != FAT_CIGAM) {
        auto* thin = structureAt<mach_header_64>(file, 0);
        return thin && thin->magic == MH_MAGIC_64 ? std::make_optional<size_t>(0) : std::nullopt;
    }

    bool swapped = header->magic == FAT_CIGAM;
    auto count = swapped ? OSSwapInt32(header->nfat_arch) : header->nfat_arch;
    auto* architectures = structureAt<fat_arch>(file, sizeof(fat_header), count);
    if (!architectures)
        return std::nullopt;

    for (uint32_t i = 0; i < count; ++i) {
        auto cpuType = swapped ? OSSwapInt32(architectures[i].cputype) : architectures[i].cputype;
        auto offset = swapped ? OSSwapInt32(architectures[i].offset) : architectures[i].offset;
        auto* slice = structureAt<mach_header_64>(file, offset);
        if (cpuType == CPU_TYPE_X86_64 && slice && slice->magic == MH_MAGIC_64)
            return offset;
    }
    return std::nullopt;
}

// The export trie of the image at |imageOffset|: the table dyld resolves a two-level import
// against, holding what the image defines and what it re-exports.
template<typename Bytes> std::optional<std::span<const uint8_t>> exportTrie(const Bytes& image, size_t imageOffset = 0)
{
    std::optional<std::span<const uint8_t>> trie;
    forEachLoadCommandFrom(image, imageOffset, [&](size_t offset, uint32_t command, uint32_t) {
        if (command != LC_DYLD_INFO && command != LC_DYLD_INFO_ONLY)
            return;
        auto* info = structureAt<dyld_info_command>(image, offset);
        if (!info || !info->export_size)
            return;
        size_t exportOffset = imageOffset + info->export_off;
        if (exportOffset > image.size() || image.size() - exportOffset < info->export_size)
            return;
        trie = spanOf(image).subspan(exportOffset, info->export_size);
    });
    return trie;
}

// Every symbol an export trie spells. Each node holds the terminal information for the name
// spelled by the edges taken to reach it, and a name can be spelled across a node and an empty
// edge, so the whole trie is walked rather than one path through it.
HashSet<String> trieSymbols(std::span<const uint8_t> trie)
{
    HashSet<String> symbols;

    struct Node {
        size_t position { 0 };
        String prefix;
    };
    Vector<Node> pending;
    pending.append(Node { 0, emptyString() });

    // A malformed trie can point back at itself, so each node position is walked once. The root
    // is at zero, so zero is a key like any other.
    HashSet<size_t, DefaultHash<size_t>, WTF::UnsignedWithZeroKeyHashTraits<size_t>> visited;
    while (!pending.isEmpty()) {
        auto node = pending.takeLast();
        if (node.position >= trie.size())
            continue;
        if (!visited.add(node.position).isNewEntry)
            continue;

        size_t position = node.position;
        uint64_t terminalSize = readULEB(trie, position);
        if (terminalSize && !node.prefix.isEmpty())
            symbols.add(node.prefix);

        size_t children = position + terminalSize;
        if (children >= trie.size())
            continue;
        uint8_t childCount = trie[children++];

        for (uint8_t i = 0; i < childCount; ++i) {
            size_t edgeStart = children;
            while (children < trie.size() && trie[children])
                ++children;
            if (children >= trie.size())
                break;
            auto edge = trie.subspan(edgeStart, children - edgeStart);
            ++children;
            uint64_t child = readULEB(trie, children);
            pending.append(Node { static_cast<size_t>(child), makeString(node.prefix, String::fromUTF8(edge)) });
        }
    }
    return symbols;
}

template<typename Bytes> String pathOfDylibCommand(const Bytes& image, size_t commandOffset, uint32_t commandSize, uint32_t& pathOffsetOut)
{
    auto* command = structureAt<dylib_command>(image, commandOffset);
    if (!command)
        return { };
    pathOffsetOut = command->dylib.name.offset;
    if (pathOffsetOut >= commandSize)
        return { };
    auto path = spanOf(image).subspan(commandOffset + pathOffsetOut, commandSize - pathOffsetOut);
    size_t length = 0;
    while (length < path.size() && path[length])
        ++length;
    return String::fromUTF8(path.first(length));
}

// The libraries in the order dyld numbers them: a bind opcode names one by its position here.
Vector<DylibCommand> dylibCommands(const Vector<uint8_t>& image)
{
    Vector<DylibCommand> libraries;
    forEachLoadCommand(image, [&](size_t offset, uint32_t command, uint32_t commandSize) {
        switch (command) {
        case LC_LOAD_DYLIB:
        case LC_LOAD_WEAK_DYLIB:
        case LC_REEXPORT_DYLIB:
        case LC_LOAD_UPWARD_DYLIB:
        case LC_LAZY_LOAD_DYLIB: {
            uint32_t pathOffset = 0;
            auto path = pathOfDylibCommand(image, offset, commandSize, pathOffset);
            libraries.append(DylibCommand { offset, commandSize, pathOffset, WTF::move(path) });
            break;
        }
        default:
            break;
        }
    });
    return libraries;
}

// Writes |path| over a library command's path, and clears the version the command demands of it:
// the numbers belong to the library the command names, so they go with the name. A command with
// no room for the path is left alone and reported.
bool repointDylibCommand(Vector<uint8_t>& image, const DylibCommand& library, const String& path)
{
    auto utf8 = path.utf8();
    if (library.commandSize - library.pathOffset <= utf8.length())
        return false;

    auto* command = mutableStructureAt<dylib_command>(image, library.commandOffset);
    command->dylib.current_version = 0;
    command->dylib.compatibility_version = 0;

    auto destination = image.mutableSpan().subspan(library.commandOffset + library.pathOffset, library.commandSize - library.pathOffset);
    memcpySpan(destination, utf8.span());
    zeroSpan(destination.subspan(utf8.length()));
    return true;
}

// ------------------------------------------------------------------------------------------
// Chained fixups -> LC_DYLD_INFO_ONLY

struct OpcodeStream {
    Vector<uint8_t> bytes;

    void byte(uint8_t value) { bytes.append(value); }
    void uleb(uint64_t value)
    {
        do {
            uint8_t chunk = value & 0x7f;
            value >>= 7;
            bytes.append(value ? (chunk | 0x80) : chunk);
        } while (value);
    }
    void sleb(int64_t value)
    {
        bool more = true;
        while (more) {
            uint8_t chunk = value & 0x7f;
            value >>= 7;
            if ((!value && !(chunk & 0x40)) || (value == -1 && (chunk & 0x40)))
                more = false;
            bytes.append(more ? (chunk | 0x80) : chunk);
        }
    }
    void string(const char* value)
    {
        while (*value)
            bytes.append(static_cast<uint8_t>(*value++));
        bytes.append(0);
    }
};

struct ChainedImport {
    int libraryOrdinal { 0 };
    bool isWeak { false };
    int64_t addend { 0 };
    const char* name { nullptr };
};

Expected<Vector<ChainedImport>, String> chainedImports(const Vector<uint8_t>& image, size_t fixupsOffset, const dyld_chained_fixups_header& fixups)
{
    auto symbolPool = image.span().subspan(std::min<size_t>(fixupsOffset + fixups.symbols_offset, image.size()));
    auto symbolName = [&](uint32_t nameOffset) -> const char* {
        if (nameOffset >= symbolPool.size())
            return nullptr;
        auto name = symbolPool.subspan(nameOffset);
        for (auto character : name) {
            if (!character)
                return reinterpret_cast<const char*>(name.data());
        }
        return nullptr;
    };
    auto signedOrdinal = [](uint32_t ordinal) {
        return ordinal > 127 ? static_cast<int>(ordinal) - 256 : static_cast<int>(ordinal);
    };

    Vector<ChainedImport> imports;
    imports.reserveInitialCapacity(fixups.imports_count);
    for (uint32_t i = 0; i < fixups.imports_count; ++i) {
        ChainedImport import;
        uint32_t nameOffset = 0;
        switch (fixups.imports_format) {
        case DYLD_CHAINED_IMPORT: {
            auto* entry = structureAt<dyld_chained_import>(image, fixupsOffset + fixups.imports_offset + i * sizeof(dyld_chained_import));
            if (!entry)
                return makeUnexpected("the chained fixups import table runs past the end of the file"_s);
            import.libraryOrdinal = signedOrdinal(entry->lib_ordinal);
            import.isWeak = entry->weak_import;
            nameOffset = entry->name_offset;
            break;
        }
        case DYLD_CHAINED_IMPORT_ADDEND: {
            auto* entry = structureAt<dyld_chained_import_addend>(image, fixupsOffset + fixups.imports_offset + i * sizeof(dyld_chained_import_addend));
            if (!entry)
                return makeUnexpected("the chained fixups import table runs past the end of the file"_s);
            import.libraryOrdinal = signedOrdinal(entry->lib_ordinal);
            import.isWeak = entry->weak_import;
            import.addend = entry->addend;
            nameOffset = entry->name_offset;
            break;
        }
        case DYLD_CHAINED_IMPORT_ADDEND64: {
            auto* entry = structureAt<dyld_chained_import_addend64>(image, fixupsOffset + fixups.imports_offset + i * sizeof(dyld_chained_import_addend64));
            if (!entry)
                return makeUnexpected("the chained fixups import table runs past the end of the file"_s);
            import.libraryOrdinal = static_cast<int16_t>(entry->lib_ordinal);
            import.isWeak = entry->weak_import;
            import.addend = static_cast<int64_t>(entry->addend);
            nameOffset = entry->name_offset;
            break;
        }
        default:
            return makeUnexpected(makeString("the module uses chained fixups import format "_s, fixups.imports_format));
        }

        import.name = symbolName(nameOffset);
        if (!import.name)
            return makeUnexpected("a chained fixups import names a symbol outside the symbol pool"_s);
        imports.append(import);
    }
    return imports;
}

Expected<void, String> convertChainedFixups(Vector<uint8_t>& image)
{
    size_t fixupsCommandOffset = 0;
    size_t exportsTrieCommandOffset = 0;
    size_t buildVersionCommandOffset = 0;
    bool hasDyldInfo = false;
    Vector<size_t> segmentCommandOffsets;
    uint64_t textSegmentAddress = 0;
    bool commandsAreSound = forEachLoadCommand(image, [&](size_t offset, uint32_t command, uint32_t) {
        switch (command) {
        case LC_SEGMENT_64: {
            auto* segment = structureAt<segment_command_64>(image, offset);
            if (!segment)
                return;
            if (!strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)))
                textSegmentAddress = segment->vmaddr;
            segmentCommandOffsets.append(offset);
            break;
        }
        case LC_DYLD_CHAINED_FIXUPS:
            fixupsCommandOffset = offset;
            break;
        case LC_DYLD_EXPORTS_TRIE:
            exportsTrieCommandOffset = offset;
            break;
        case LC_BUILD_VERSION:
            buildVersionCommandOffset = offset;
            break;
        case LC_DYLD_INFO_ONLY:
            hasDyldInfo = true;
            break;
        default:
            break;
        }
    });
    if (!commandsAreSound)
        return makeUnexpected("the module's load commands run past the end of the file"_s);

    // Classic binding already: the module is what 10.9's dyld reads natively.
    if (!fixupsCommandOffset) {
        if (hasDyldInfo)
            return { };
        return makeUnexpected("the module has neither chained fixups nor LC_DYLD_INFO_ONLY"_s);
    }

    auto* fixupsCommand = structureAt<linkedit_data_command>(image, fixupsCommandOffset);
    auto* fixups = fixupsCommand ? structureAt<dyld_chained_fixups_header>(image, fixupsCommand->dataoff) : nullptr;
    auto* startsInImage = fixups ? structureAt<dyld_chained_starts_in_image>(image, fixupsCommand->dataoff + fixups->starts_offset) : nullptr;
    if (!startsInImage)
        return makeUnexpected("the chained fixups table runs past the end of the file"_s);

    auto imports = chainedImports(image, fixupsCommand->dataoff, *fixups);
    if (!imports)
        return makeUnexpected(imports.error());

    OpcodeStream rebases;
    OpcodeStream binds;
    rebases.byte(REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER);
    binds.byte(BIND_OPCODE_SET_TYPE_IMM | BIND_TYPE_POINTER);
    int64_t currentAddend = 0;

    for (uint32_t segmentIndex = 0; segmentIndex < startsInImage->seg_count; ++segmentIndex) {
        if (segmentIndex >= segmentCommandOffsets.size())
            return makeUnexpected("the chained fixups table names more segments than the module has"_s);
        // The opcodes that place a fixup carry the segment in the low nibble of the opcode byte.
        if (segmentIndex >= 16)
            return makeUnexpected("the module has more than 16 segments"_s);
        auto startsOffset = structureAt<uint32_t>(image, fixupsCommand->dataoff + fixups->starts_offset + offsetof(dyld_chained_starts_in_image, seg_info_offset) + segmentIndex * sizeof(uint32_t));
        if (!startsOffset)
            return makeUnexpected("the chained fixups segment table runs past the end of the file"_s);
        if (!*startsOffset)
            continue;

        auto* starts = structureAt<dyld_chained_starts_in_segment>(image, fixupsCommand->dataoff + fixups->starts_offset + *startsOffset);
        if (!starts)
            return makeUnexpected("a chained fixups segment record runs past the end of the file"_s);
        if (starts->pointer_format != DYLD_CHAINED_PTR_64 && starts->pointer_format != DYLD_CHAINED_PTR_64_OFFSET)
            return makeUnexpected(makeString("the module chains its fixups in pointer format "_s, starts->pointer_format));

        auto* segment = structureAt<segment_command_64>(image, segmentCommandOffsets[segmentIndex]);
        if (!segment)
            return makeUnexpected("the module's segment table runs past the end of the file"_s);
        for (uint16_t page = 0; page < starts->page_count; ++page) {
            auto* pageStart = structureAt<uint16_t>(image, fixupsCommand->dataoff + fixups->starts_offset + *startsOffset + offsetof(dyld_chained_starts_in_segment, page_start) + page * sizeof(uint16_t));
            if (!pageStart)
                return makeUnexpected("a chained fixups page table runs past the end of the file"_s);
            if (*pageStart == DYLD_CHAINED_PTR_START_NONE)
                continue;

            uint64_t offsetInSegment = static_cast<uint64_t>(page) * starts->page_size + *pageStart;
            while (true) {
                auto* slot = mutableStructureAt<uint64_t>(image, segment->fileoff + offsetInSegment);
                if (!slot)
                    return makeUnexpected("a chained fixup points past the end of the file"_s);

                uint64_t raw = *slot;
                bool isBind = raw >> 63;
                uint64_t next = ((raw >> 51) & 0xfff) * 4;

                if (isBind) {
                    uint32_t ordinal = raw & 0xffffff;
                    if (ordinal >= imports->size())
                        return makeUnexpected("a chained bind names an import the table does not have"_s);
                    auto& import = imports->at(ordinal);
                    int64_t addend = import.addend + static_cast<int64_t>((raw >> 24) & 0xff);

                    // 10.9's dyld knows three special ordinals: 0 (self), -1 (main executable) and
                    // -2 (flat lookup). It rejects -3, weak lookup, which is a flat lookup that
                    // tolerates an absent symbol -- exactly a flat lookup plus the weak-import flag.
                    int libraryOrdinal = import.libraryOrdinal;
                    bool isWeak = import.isWeak;
                    if (libraryOrdinal == BIND_SPECIAL_DYLIB_WEAK_LOOKUP) {
                        libraryOrdinal = BIND_SPECIAL_DYLIB_FLAT_LOOKUP;
                        isWeak = true;
                    }
                    if (libraryOrdinal < 0)
                        binds.byte(BIND_OPCODE_SET_DYLIB_SPECIAL_IMM | (libraryOrdinal & 0x0f));
                    else if (libraryOrdinal < 16)
                        binds.byte(BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | libraryOrdinal);
                    else {
                        binds.byte(BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB);
                        binds.uleb(libraryOrdinal);
                    }
                    binds.byte(BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | (isWeak ? BIND_SYMBOL_FLAGS_WEAK_IMPORT : 0));
                    binds.string(import.name);
                    if (addend != currentAddend) {
                        binds.byte(BIND_OPCODE_SET_ADDEND_SLEB);
                        binds.sleb(addend);
                        currentAddend = addend;
                    }
                    binds.byte(BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | segmentIndex);
                    binds.uleb(offsetInSegment);
                    binds.byte(BIND_OPCODE_DO_BIND);
                    *slot = 0;
                } else {
                    // A classic rebase adds the slide to whatever the slot holds, so both formats
                    // are stored as the unslid address the image was linked at. The two differ in
                    // what the 36-bit field holds -- an address, or an offset from the image base --
                    // and both put the pointer's top byte in high8.
                    uint64_t target = raw & 0xfffffffffULL;
                    uint64_t high8 = (raw >> 36) & 0xff;
                    if (starts->pointer_format == DYLD_CHAINED_PTR_64_OFFSET)
                        target += textSegmentAddress;
                    target |= high8 << 56;

                    rebases.byte(REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | segmentIndex);
                    rebases.uleb(offsetInSegment);
                    rebases.byte(REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1);
                    *slot = target;
                }

                if (!next)
                    break;
                offsetInSegment += next;
            }
        }
    }
    rebases.byte(REBASE_OPCODE_DONE);
    binds.byte(BIND_OPCODE_DONE);

    // The export trie survives the conversion: LC_DYLD_INFO_ONLY carries it in the same format,
    // at the same place in the file.
    uint32_t exportsOffset = 0;
    uint32_t exportsSize = 0;
    if (exportsTrieCommandOffset) {
        auto* exports = structureAt<linkedit_data_command>(image, exportsTrieCommandOffset);
        if (!exports)
            return makeUnexpected("the module's LC_DYLD_EXPORTS_TRIE is truncated"_s);
        exportsOffset = exports->dataoff;
        exportsSize = exports->datasize;
    }

    // The opcode streams go after everything the file already holds, and __LINKEDIT grows to cover
    // them: dyld reads a file range only through the segment that declares it.
    auto append = [&](const Vector<uint8_t>& bytes, uint32_t& offsetOut, uint32_t& sizeOut) {
        while (image.size() % 8)
            image.append(0);
        offsetOut = image.size();
        sizeOut = bytes.size();
        image.appendVector(bytes);
    };
    dyld_info_command dyldInfo { };
    dyldInfo.cmd = LC_DYLD_INFO_ONLY;
    dyldInfo.cmdsize = sizeof(dyld_info_command);
    dyldInfo.export_off = exportsOffset;
    dyldInfo.export_size = exportsSize;
    append(rebases.bytes, dyldInfo.rebase_off, dyldInfo.rebase_size);
    append(binds.bytes, dyldInfo.bind_off, dyldInfo.bind_size);

    auto* header = mutableStructureAt<mach_header_64>(image, 0);
    size_t commandsEnd = sizeof(mach_header_64) + header->sizeofcmds;

    // The commands the conversion replaces make room for the one it adds. LC_BUILD_VERSION goes
    // too: 10.9's dyld ignores it, and the space it frees is what LC_DYLD_INFO_ONLY needs.
    // Removing them last-first keeps each remaining offset where it was measured.
    Vector<size_t> commandsToRemove;
    for (size_t commandOffset : { fixupsCommandOffset, exportsTrieCommandOffset, buildVersionCommandOffset }) {
        if (commandOffset)
            commandsToRemove.append(commandOffset);
    }
    std::sort(commandsToRemove.begin(), commandsToRemove.end(), std::greater<size_t> { });
    for (size_t commandOffset : commandsToRemove) {
        auto* command = structureAt<load_command>(image, commandOffset);
        if (!command)
            continue;
        uint32_t commandSize = command->cmdsize;
        auto tail = image.mutableSpan().subspan(commandOffset + commandSize, commandsEnd - commandOffset - commandSize);
        memmoveSpan(image.mutableSpan().subspan(commandOffset, tail.size()), tail);
        commandsEnd -= commandSize;
        header->ncmds--;
        header->sizeofcmds -= commandSize;
    }

    // Load commands may only grow into the padding before the first section's contents.
    uint32_t firstSectionOffset = std::numeric_limits<uint32_t>::max();
    for (size_t segmentCommandOffset : segmentCommandOffsets) {
        auto* segment = structureAt<segment_command_64>(image, segmentCommandOffset);
        if (!segment)
            return makeUnexpected("the module's segment table runs past the end of the file"_s);
        for (uint32_t i = 0; i < segment->nsects; ++i) {
            auto* section = structureAt<section_64>(image, segmentCommandOffset + sizeof(segment_command_64) + i * sizeof(section_64));
            if (!section)
                return makeUnexpected("the module's section table runs past the end of the file"_s);
            if (section->offset)
                firstSectionOffset = std::min(firstSectionOffset, section->offset);
        }
    }
    if (firstSectionOffset == std::numeric_limits<uint32_t>::max())
        return makeUnexpected("the module has no sections"_s);
    if (commandsEnd + sizeof(dyld_info_command) > firstSectionOffset)
        return makeUnexpected("the module leaves no room for LC_DYLD_INFO_ONLY after its load commands"_s);

    memcpySpan(image.mutableSpan().subspan(commandsEnd, sizeof(dyldInfo)), asByteSpan(dyldInfo));
    header->ncmds++;
    header->sizeofcmds += sizeof(dyld_info_command);

    for (size_t segmentCommandOffset : segmentCommandOffsets) {
        auto* segment = mutableStructureAt<segment_command_64>(image, segmentCommandOffset);
        if (strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname)))
            continue;
        uint64_t fileSize = image.size() - segment->fileoff;
        if (fileSize > segment->filesize) {
            segment->filesize = fileSize;
            segment->vmsize = roundUpToMultipleOf<4096>(fileSize);
        }
        return { };
    }
    return makeUnexpected("the module has no __LINKEDIT segment"_s);
}

// ------------------------------------------------------------------------------------------
// __DATA_CONST -> __DATA

// 10.9 has no __DATA_CONST: dyld maps whatever segments an image declares, and the Objective-C
// runtime asks for __objc_imageinfo in __DATA. A module that keeps its Objective-C metadata in
// __DATA_CONST is therefore an image with no Objective-C content as far as that runtime can see,
// and it processes none of it -- the selector references keep pointing at __objc_methname strings
// and the first message send into the module aborts. Renaming the segment, and the sections that
// name it as their own, is what puts the metadata where the runtime looks.
void renameDataConstSegment(Vector<uint8_t>& image)
{
    Vector<size_t> segmentCommandOffsets;
    forEachLoadCommand(image, [&](size_t offset, uint32_t command, uint32_t) {
        if (command == LC_SEGMENT_64)
            segmentCommandOffsets.append(offset);
    });

    for (size_t commandOffset : segmentCommandOffsets) {
        auto* segment = mutableStructureAt<segment_command_64>(image, commandOffset);
        if (!segment || strncmp(segment->segname, dataConstSegmentName, sizeof(segment->segname)))
            continue;

        zeroSpan(std::span { segment->segname });
        memcpySpan(std::span { segment->segname }, unsafeSpan(SEG_DATA));
        for (uint32_t i = 0; i < segment->nsects; ++i) {
            auto* section = mutableStructureAt<section_64>(image, commandOffset + sizeof(segment_command_64) + i * sizeof(section_64));
            if (!section)
                return;
            zeroSpan(std::span { section->segname });
            memcpySpan(std::span { section->segname }, unsafeSpan(SEG_DATA));
        }
    }
}

// ------------------------------------------------------------------------------------------
// Imports this host cannot resolve

void skipSLEB(std::span<const uint8_t> stream, size_t& position)
{
    while (position < stream.size() && (stream[position++] & 0x80)) { }
}

// The external symbols a library defines, read from its own symbol table.
HashSet<String> definedSymbols(const Vector<uint8_t>& image, size_t sliceOffset = 0)
{
    HashSet<String> symbols;
    forEachLoadCommandFrom(image, sliceOffset, [&](size_t offset, uint32_t command, uint32_t) {
        if (command != LC_SYMTAB)
            return;
        auto* symtab = structureAt<symtab_command>(image, offset);
        if (!symtab)
            return;
        auto* entries = structureAt<nlist_64>(image, sliceOffset + symtab->symoff, symtab->nsyms);
        size_t stringsOffset = sliceOffset + symtab->stroff;
        if (!entries || stringsOffset > image.size() || image.size() - stringsOffset < symtab->strsize)
            return;
        auto strings = image.span().subspan(stringsOffset, symtab->strsize);
        for (uint32_t i = 0; i < symtab->nsyms; ++i) {
            auto& entry = entries[i];
            if (!(entry.n_type & N_EXT) || (entry.n_type & N_PEXT) || (entry.n_type & N_TYPE) == N_UNDF)
                continue;
            if (entry.n_un.n_strx >= strings.size())
                continue;
            auto name = strings.subspan(entry.n_un.n_strx);
            size_t length = 0;
            while (length < name.size() && name[length])
                ++length;
            symbols.add(String::fromUTF8(name.first(length)));
        }
    });
    return symbols;
}

// What this host resolves. dyld binds a two-level import against the library the record names
// and everything that library re-exports, and reads it from the file on disk, so that file is
// what is asked here: /usr/lib/libSystem.B.dylib defines 31 symbols of its own and re-exports the
// rest from /usr/lib/system, and an umbrella framework answers the same way. Every library 10.9
// ships is universal, so the x86_64 slice is located before any of it is read.
class HostLibraries {
public:
    // Whether |libraryPath| answers for |symbol| on this host. A library this host does not have
    // at all is not a missing symbol: the load commands are what handle those.
    bool provides(const String& symbol, const String& libraryPath)
    {
        if (!has(libraryPath))
            return true;
        HashSet<String> visited;
        return exports(symbol, libraryPath, visited);
    }

    // Whether this host has the library at all. A library it does not have is one dyld will not
    // find, which is what makes a load command a donor.
    bool has(const String& libraryPath)
    {
        return libraryFor(libraryPath).slice.has_value();
    }

private:
    struct Library {
        Vector<uint8_t> bytes;
        std::optional<size_t> slice;
        HashSet<String> symbols;
        Vector<String> reexports;
    };

    // The library's own table, then the libraries it re-exports, which is the order dyld resolves
    // them in. |visited| is what stops a re-export cycle.
    bool exports(const String& symbol, const String& libraryPath, HashSet<String>& visited)
    {
        if (!visited.add(libraryPath).isNewEntry)
            return false;

        // Copied out: reading a re-exported library inserts into the map this came from, which
        // moves the entry a reference would still be pointing at.
        Vector<String> reexports;
        {
            auto& library = libraryFor(libraryPath);
            if (!library.slice)
                return false;
            if (library.symbols.contains(symbol))
                return true;
            reexports = library.reexports;
        }

        for (auto& reexport : reexports) {
            if (exports(symbol, reexport, visited))
                return true;
        }
        return false;
    }

    const Library& libraryFor(const String& path)
    {
        return m_libraries.ensure(path, [&] {
            Library library;
            auto contents = FileSystem::readEntireFile(path);
            if (!contents)
                return library;
            library.bytes = WTF::move(*contents);
            library.slice = machOSliceOffset(library.bytes);
            if (!library.slice)
                return library;

            // The export trie is what dyld binds against; the symbol table answers for a library
            // built without one.
            if (auto trie = exportTrie(library.bytes, *library.slice))
                library.symbols = trieSymbols(*trie);
            if (library.symbols.isEmpty())
                library.symbols = definedSymbols(library.bytes, *library.slice);

            forEachLoadCommandFrom(library.bytes, *library.slice, [&](size_t offset, uint32_t command, uint32_t commandSize) {
                if (command != LC_REEXPORT_DYLIB)
                    return;
                uint32_t pathOffset = 0;
                auto reexport = pathOfDylibCommand(library.bytes, offset, commandSize, pathOffset);
                if (!reexport.isEmpty())
                    library.reexports.append(WTF::move(reexport));
            });
            return library;
        }).iterator->value;
    }

    HashMap<String, Library> m_libraries;
};

Expected<void, String> retargetImports(Vector<uint8_t>& image, const String& gapLibraryPath, const String& gapLibraryFilePath)
{
    auto libraries = dylibCommands(image);

    size_t symtabCommandOffset = 0;
    size_t dyldInfoCommandOffset = 0;
    forEachLoadCommand(image, [&](size_t offset, uint32_t command, uint32_t) {
        if (command == LC_SYMTAB)
            symtabCommandOffset = offset;
        else if (command == LC_DYLD_INFO_ONLY)
            dyldInfoCommandOffset = offset;
    });
    if (!symtabCommandOffset || !dyldInfoCommandOffset)
        return makeUnexpected("the module has no symbol table or no LC_DYLD_INFO_ONLY"_s);

    auto* symtab = structureAt<symtab_command>(image, symtabCommandOffset);
    if (!symtab)
        return makeUnexpected("the module's LC_SYMTAB is truncated"_s);
    auto* symbols = structureAt<nlist_64>(image, symtab->symoff, symtab->nsyms);
    if (!symbols || symtab->stroff > image.size() || image.size() - symtab->stroff < symtab->strsize)
        return makeUnexpected("the module's symbol table runs past the end of the file"_s);
    auto strings = image.span().subspan(symtab->stroff, symtab->strsize);

    auto symbolName = [&](const nlist_64& symbol) -> String {
        if (symbol.n_un.n_strx >= strings.size())
            return { };
        auto name = strings.subspan(symbol.n_un.n_strx);
        size_t length = 0;
        while (length < name.size() && name[length])
            ++length;
        return String::fromUTF8(name.first(length));
    };

    // Every import, asked of the library its own record names, and the ordinals in use.
    HostLibraries hostLibraries;
    HashSet<String> unresolvable;
    HashSet<unsigned> usedOrdinals;
    for (uint32_t i = 0; i < symtab->nsyms; ++i) {
        auto& symbol = symbols[i];
        if ((symbol.n_type & N_TYPE) != N_UNDF || symbol.n_value)
            continue;
        unsigned ordinal = GET_LIBRARY_ORDINAL(symbol.n_desc);
        // The census is of the load commands the module binds through, weakly or not, so it runs
        // before anything is skipped: a library bound through is never the gap library's donor.
        usedOrdinals.add(ordinal);
        // dyld binds an absent weak import to zero, so it does not need a gap implementation.
        if (symbol.n_desc & N_WEAK_REF)
            continue;
        if (!ordinal || ordinal > libraries.size())
            continue;
        auto name = symbolName(symbol);
        if (name.isEmpty() || name == "dyld_stub_binder"_s)
            continue;
        if (!hostLibraries.provides(name, libraries[ordinal - 1].path))
            unresolvable.add(name);
    }

    auto gapLibrary = FileSystem::readEntireFile(gapLibraryFilePath);
    if (!gapLibrary)
        return makeUnexpected(makeString("the gap library is missing: "_s, gapLibraryFilePath));
    auto gapSlice = machOSliceOffset(*gapLibrary);
    if (!gapSlice)
        return makeUnexpected(makeString("the gap library has no x86_64 slice: "_s, gapLibraryFilePath));
    auto provided = definedSymbols(*gapLibrary, *gapSlice);
    Vector<String> uncovered;
    for (auto& symbol : unresolvable) {
        if (!provided.contains(symbol))
            uncovered.append(symbol);
    }
    if (!uncovered.isEmpty()) {
        std::sort(uncovered.begin(), uncovered.end(), WTF::codePointCompareLessThan);
        return makeUnexpected(makeString("no gap implementation for: "_s, makeStringByJoining(uncovered, " "_s)));
    }

    // The donor: a library this host does not have and the module never binds through, with room
    // for the gap library's path. The lowest ordinal wins, so the rewritten ordinal still fits the
    // one-byte opcode form a chained-fixups conversion emits.
    std::optional<size_t> donorIndex;
    Vector<size_t> absentIndices;
    for (size_t i = 0; i < libraries.size(); ++i) {
        auto& library = libraries[i];
        if (!library.path.startsWith('/') || hostLibraries.has(library.path))
            continue;
        if (usedOrdinals.contains(i + 1))
            return makeUnexpected(makeString(library.path, " is absent on this host and the module imports from it"_s));
        absentIndices.append(i);
        if (!donorIndex && library.commandSize - library.pathOffset > gapLibraryPath.utf8().length())
            donorIndex = i;
    }
    if (!donorIndex)
        return makeUnexpected(makeString("no absent, unimported load command has room for "_s, gapLibraryPath));

    unsigned gapOrdinal = *donorIndex + 1;
    repointDylibCommand(image, libraries[*donorIndex], gapLibraryPath);
    for (size_t index : absentIndices) {
        if (index != *donorIndex && !repointDylibCommand(image, libraries[index], libSystemPath))
            return makeUnexpected(makeString(libraries[index].path, " is absent on this host and its load command has no room for "_s, libSystemPath));
    }

    // Point every bind of an unresolvable symbol at the gap library, at whatever width the stream
    // already spends on the ordinal: ld emits the ULEB form for ordinals above 15, and a
    // chained-fixups conversion emits the one-byte immediate form.
    auto retargetStream = [&](uint32_t streamOffset, uint32_t streamSize) -> Expected<void, String> {
        if (!streamSize)
            return { };
        if (streamOffset > image.size() || image.size() - streamOffset < streamSize)
            return makeUnexpected("a bind opcode stream runs past the end of the file"_s);

        auto stream = image.span().subspan(streamOffset, streamSize);
        size_t position = 0;
        size_t ordinalPosition = 0;
        size_t ordinalWidth = 0;
        String symbol;
        while (position < stream.size()) {
            size_t opcodePosition = position;
            uint8_t opcode = stream[position++] & BIND_OPCODE_MASK;
            switch (opcode) {
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM:
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM:
                ordinalPosition = opcodePosition;
                ordinalWidth = 1;
                break;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB:
                readULEB(stream, position);
                ordinalPosition = opcodePosition;
                ordinalWidth = position - opcodePosition;
                break;
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: {
                size_t start = position;
                while (position < stream.size() && stream[position])
                    ++position;
                symbol = String::fromUTF8(stream.subspan(start, position - start));
                ++position;
                break;
            }
            case BIND_OPCODE_SET_ADDEND_SLEB:
                skipSLEB(stream, position);
                break;
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
            case BIND_OPCODE_ADD_ADDR_ULEB:
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
                readULEB(stream, position);
                break;
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
                readULEB(stream, position);
                readULEB(stream, position);
                break;
            case BIND_OPCODE_DONE:
            case BIND_OPCODE_SET_TYPE_IMM:
            case BIND_OPCODE_DO_BIND:
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
                break;
            default:
                // An opcode this does not know is one whose operands it cannot step over, and the
                // rest of the stream would be read at the wrong offsets.
                return makeUnexpected(makeString("the bind opcode stream holds an opcode this cannot read: "_s, opcode));
            }

            bool bindsHere = opcode == BIND_OPCODE_DO_BIND || opcode == BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB
                || opcode == BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED || opcode == BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB;
            if (!bindsHere || !unresolvable.contains(symbol))
                continue;

            auto ordinalSlot = image.mutableSpan().subspan(streamOffset + ordinalPosition);
            if (ordinalWidth == 2 && gapOrdinal < 128) {
                ordinalSlot[0] = BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB;
                ordinalSlot[1] = gapOrdinal;
            } else if (ordinalWidth == 1 && gapOrdinal < 16)
                ordinalSlot[0] = BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | gapOrdinal;
            else
                return makeUnexpected(makeString(symbol, ": the stream spends "_s, ordinalWidth, " byte(s) on the library ordinal and the gap library is ordinal "_s, gapOrdinal));
        }
        return { };
    };

    auto* dyldInfo = structureAt<dyld_info_command>(image, dyldInfoCommandOffset);
    if (!dyldInfo)
        return makeUnexpected("the module's LC_DYLD_INFO_ONLY is truncated"_s);
    for (auto [offset, size] : { std::pair { dyldInfo->bind_off, dyldInfo->bind_size }, std::pair { dyldInfo->lazy_bind_off, dyldInfo->lazy_bind_size } }) {
        auto retargeted = retargetStream(offset, size);
        if (!retargeted)
            return retargeted;
    }

    // The symbol table's library ordinals say the same thing the opcodes do.
    auto* mutableSymbols = mutableStructureAt<nlist_64>(image, symtab->symoff, symtab->nsyms);
    for (uint32_t i = 0; i < symtab->nsyms; ++i) {
        auto& symbol = mutableSymbols[i];
        if ((symbol.n_type & N_TYPE) != N_UNDF || symbol.n_value)
            continue;
        if (unresolvable.contains(symbolName(symbol)))
            SET_LIBRARY_ORDINAL(symbol.n_desc, gapOrdinal);
    }

    // Nothing may be left for dyld to fail on: a library that is still absent takes its slot out
    // of the ordinal array and renumbers every later one. Read back from the image, which is what
    // the rewrites above changed.
    for (auto& library : dylibCommands(image)) {
        if (library.path.startsWith('/') && !hostLibraries.has(library.path))
            return makeUnexpected(makeString("the module still names a library this host does not have: "_s, library.path));
    }
    return { };
}

} // namespace

Expected<void, String> prepareWidevineCdmImage(Vector<uint8_t>& image, const String& gapLibraryPath, const String& gapLibraryFilePath)
{
    auto* header = structureAt<mach_header_64>(image, 0);
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_X86_64 || header->filetype != MH_DYLIB)
        return makeUnexpected("the module is not a 64-bit x86 Mach-O dylib"_s);

    auto converted = convertChainedFixups(image);
    if (!converted)
        return converted;
    renameDataConstSegment(image);
    return retargetImports(image, gapLibraryPath, gapLibraryFilePath);
}

} // namespace WebCore

#endif // PLATFORM(MAC) && ENABLE(ENCRYPTED_MEDIA) && USE(GSTREAMER)
