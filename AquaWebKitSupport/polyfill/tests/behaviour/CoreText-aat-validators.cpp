// The AAT-table validators wk_ots_sanitize_font runs before a downloaded font reaches this OS's shaper
// (polyfills/c/ots_aat_*.cpp). Each keeps a table whose reads stay inside it and drops one that would
// leave it. Two halves: every AAT table in the fonts this system installs is kept, and a table edited so
// an offset runs past its end, an index runs past an array, or a baseline value reaches 32 is dropped.
//
// The small tables below are real ones (ankr from DevanagariSangamMN, bsln from AquaKana, prop from
// Al Tarikh, trak from Apple Chancery, feat from Apple Symbols); lcar, opbd and just are minimal
// hand-built tables. The probe links libpolyfill.a, so the validators are the archive's.
#include "ots_aat.h"

#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <string>
#include <vector>

namespace {

int failures;

void check(bool ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

bool noSiblingTables(const wk_aat_font_facts &, uint32_t, const uint8_t **, size_t *)
{
    return false;
}

wk_aat_font_facts factsWithGlyphs(uint32_t numGlyphs)
{
    wk_aat_font_facts facts {};
    facts.numGlyphs = numGlyphs;
    facts.unitsPerEm = 1000;
    facts.ok = true;
    facts.findTable = noSiblingTables;
    return facts;
}

struct OneSiblingTable {
    uint32_t tag;
    const uint8_t *data;
    size_t length;
};

bool findOneSibling(const wk_aat_font_facts &facts, uint32_t tag, const uint8_t **data, size_t *length)
{
    const OneSiblingTable *table = static_cast<const OneSiblingTable *>(facts.sfnt);
    if (!table || table->tag != tag)
        return false;
    *data = table->data;
    *length = table->length;
    return true;
}

wk_aat_font_facts factsWithSibling(uint32_t numGlyphs, const OneSiblingTable &table)
{
    wk_aat_font_facts facts = factsWithGlyphs(numGlyphs);
    facts.findTable = findOneSibling;
    facts.sfnt = &table;
    return facts;
}

typedef bool (*Validator)(const uint8_t *, size_t, const wk_aat_font_facts &);

bool keeps(Validator validate, const std::vector<uint8_t> &table, uint32_t numGlyphs)
{
    return validate(table.data(), table.size(), factsWithGlyphs(numGlyphs));
}

std::vector<uint8_t> edited(const std::vector<uint8_t> &table, size_t offset, uint16_t value)
{
    std::vector<uint8_t> copy = table;
    copy[offset] = static_cast<uint8_t>(value >> 8);
    copy[offset + 1] = static_cast<uint8_t>(value);
    return copy;
}

std::vector<uint8_t> edited32(const std::vector<uint8_t> &table, size_t offset, uint32_t value)
{
    std::vector<uint8_t> copy = table;
    copy[offset] = static_cast<uint8_t>(value >> 24);
    copy[offset + 1] = static_cast<uint8_t>(value >> 16);
    copy[offset + 2] = static_cast<uint8_t>(value >> 8);
    copy[offset + 3] = static_cast<uint8_t>(value);
    return copy;
}

const uint8_t kAnkr[] = {
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x0c,0x00,0x00,0x00,0x24,0x00,0x06,0x00,0x04,
    0x00,0x02,0x00,0x08,0x00,0x01,0x00,0x00,0x00,0x8e,0x00,0x00,0x01,0xf7,0x00,0x08,
    0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x01,0x02,0x35,0x04,0x5e,0x00,0x00,0x00,0x01,
    0xfe,0xd2,0x04,0x5e,
};
const uint8_t kBsln[] = {
    0x00,0x01,0x00,0x00,0x00,0x01,0x00,0x02,0x00,0x00,0x01,0x2c,0xff,0x74,0x02,0xde,
    0x01,0x14,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x02,0x00,0x06,0x00,0x02,0x00,0x0c,
    0x00,0x01,0x00,0x00,0x01,0x44,0x00,0x03,0x00,0x00,0xff,0xff,0xff,0xff,0x00,0x00,
};
const uint8_t kProp[] = {
    0x00,0x01,0x00,0x00,0x00,0x01,0x00,0x02,0x00,0x02,0x00,0x06,0x00,0x0c,0x00,0x30,
    0x00,0x03,0x00,0x18,0x00,0x2c,0x00,0x2c,0x80,0x02,0x00,0x4a,0x00,0x49,0x00,0x07,
    0x00,0x4c,0x00,0x4b,0x80,0x02,0x00,0x66,0x00,0x66,0x80,0x02,0x00,0x6c,0x00,0x6c,
    0x00,0x0a,0x00,0x98,0x00,0x98,0x00,0x07,0x00,0xa3,0x00,0x9a,0x00,0x06,0x00,0xc8,
    0x00,0xc8,0x80,0x02,0x00,0xdc,0x00,0xd5,0x80,0x02,0x00,0xfa,0x00,0xfa,0x80,0x02,
    0x01,0x10,0x01,0x04,0x00,0x06,0x01,0x1b,0x01,0x1a,0x80,0x02,0xff,0xff,0xff,0xff,
    0x00,0x00,
};
const uint8_t kTrak[] = {
    0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x0c,0x00,0x00,0x00,0x00,0x00,0x02,0x00,0x07,
    0x00,0x00,0x00,0x24,0xff,0xff,0x00,0x00,0x01,0x2e,0x00,0x40,0x00,0x00,0x00,0x00,
    0x01,0x2f,0x00,0x4e,0x00,0x05,0x00,0x00,0x00,0x06,0x00,0x00,0x00,0x0c,0x00,0x00,
    0x00,0x12,0x00,0x00,0x00,0x24,0x00,0x00,0x00,0x48,0x00,0x00,0x00,0x49,0x00,0x00,
    0x00,0x28,0x00,0x28,0x00,0x00,0xff,0xd8,0xff,0xb0,0xff,0x88,0xff,0x88,0x00,0x32,
    0x00,0x32,0x00,0x00,0xff,0xe7,0xff,0xce,0xff,0xce,0xff,0xce,
};
const uint8_t kFeat[] = {
    0x00,0x01,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x11,0x00,0x02,
    0x00,0x00,0x00,0x18,0x80,0x00,0x01,0x01,0x00,0x00,0x01,0x00,0x00,0x01,0x01,0x02,
};

// lcar format 0: a format-6 lookup mapping glyph 5 to the caret list at offset 22 (two carets).
const uint8_t kLcar[] = {
    0x00,0x01,0x00,0x00, 0x00,0x00,
    0x00,0x06, 0x00,0x04, 0x00,0x01, 0x00,0x04, 0x00,0x00, 0x00,0x00,
    0x00,0x05, 0x00,0x16,
    0x00,0x02, 0x00,0x64, 0x00,0xc8,
};

// opbd format 0: a format-4 lookup whose one segment (glyphs 5-6) points at a two-entry value array at
// offset 24; both values point at the eight bytes of side values at offset 28.
const uint8_t kOpbd[] = {
    0x00,0x01,0x00,0x00, 0x00,0x00,
    0x00,0x04, 0x00,0x06, 0x00,0x01, 0x00,0x06, 0x00,0x00, 0x00,0x00,
    0x00,0x06, 0x00,0x05, 0x00,0x18,
    0x00,0x1c, 0x00,0x1c,
    0x00,0x0a, 0x00,0x00, 0xff,0xf6, 0x00,0x00,
};

// just 1.0 with a horizontal JustDirectionTable header at offset 10 and no vertical one.
const uint8_t kJust[] = {
    0x00,0x01,0x00,0x00, 0x00,0x00, 0x00,0x0a, 0x00,0x00,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
};

const uint8_t kKerxOrdered[] = {
    0x00,0x02,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x22, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x01, 0x00,0x00,0x00,0x06, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
    0x00,0x01,0x00,0x02,0xff,0xf6,
};

// Format 2 with one glyph in each format-8 class lookup and one kerning value.
const uint8_t kKerxOffsetArray[] = {
    0x00,0x02,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x2e, 0x00,0x00,0x00,0x02, 0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x02, 0x00,0x00,0x00,0x1c, 0x00,0x00,0x00,0x24, 0x00,0x00,0x00,0x2c,
    0x00,0x08,0x00,0x00,0x00,0x01,0x00,0x00,
    0x00,0x08,0x00,0x00,0x00,0x01,0x00,0x00,
    0xff,0xf6,
};

// Format 1 with four classes, two states, one entry and no kerning action.
const uint8_t kKerxState[] = {
    0x00,0x02,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x40, 0x00,0x00,0x00,0x01, 0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x04, 0x00,0x00,0x00,0x14, 0x00,0x00,0x00,0x1c, 0x00,0x00,0x00,0x2c,
    0x00,0x00,0x00,0x32,
    0x00,0x08,0x00,0x00,0x00,0x01,0x00,0x01,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0xff,0xff, 0x00,0x00,
};

// Format 4 anchor action 0 uses point 0 for both glyphs.
const uint8_t kKerxAnchor[] = {
    0x00,0x02,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x42, 0x00,0x00,0x00,0x04, 0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x04, 0x00,0x00,0x00,0x14, 0x00,0x00,0x00,0x1c, 0x00,0x00,0x00,0x2c,
    0x40,0x00,0x00,0x32,
    0x00,0x08,0x00,0x00,0x00,0x01,0x00,0x01,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
};

const uint8_t kKerxInert6[] = {
    0x00,0x02,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x22, 0x00,0x00,0x00,0x06, 0x00,0x00,0x00,0x00,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
};

const uint8_t kOnePointAnkr[] = {
    0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x0c, 0x00,0x00,0x00,0x14,
    0x00,0x08,0x00,0x00,0x00,0x01,0x00,0x00,
    0x00,0x00,0x00,0x01,0x00,0x0a,0x00,0x14,
};

const uint8_t kKernOrdered[] = {
    0x00,0x01,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x16, 0x00,0x00,0x00,0x00,
    0x00,0x01,0x00,0x06,0x00,0x00,0x00,0x00, 0x00,0x01,0x00,0x02,0xff,0xf6,
};

const uint8_t kKernOffsetArray[] = {
    0x00,0x01,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x1e, 0x00,0x02,0x00,0x00,
    0x00,0x02,0x00,0x10,0x00,0x16,0x00,0x1c,
    0x00,0x00,0x00,0x01,0x00,0x1c,
    0x00,0x00,0x00,0x01,0x00,0x00,
    0xff,0xf6,
};

const uint8_t kKernIndexArray[] = {
    0x00,0x01,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x14, 0x00,0x03,0x00,0x00,
    0x00,0x01,0x01,0x01,0x01,0x00, 0xff,0xf6, 0x00,0x00,0x00,0x00,
};

const uint8_t kKernState[] = {
    0x00,0x01,0x00,0x00, 0x00,0x00,0x00,0x01,
    0x00,0x00,0x00,0x26, 0x00,0x01,0x00,0x00,
    0x00,0x04,0x00,0x0a,0x00,0x10,0x00,0x18,0x00,0x1c,
    0x00,0x00,0x00,0x01,0x01,0x00,
    0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
    0x00,0x10,0x00,0x00, 0x00,0x00,
};

std::vector<uint8_t> bytes(const uint8_t *data, size_t size) { return std::vector<uint8_t>(data, data + size); }

uint16_t be16(const std::vector<uint8_t> &d, size_t o) { return static_cast<uint16_t>((d[o] << 8) | d[o + 1]); }
uint32_t be32(const std::vector<uint8_t> &d, size_t o)
{
    return (static_cast<uint32_t>(d[o]) << 24) | (static_cast<uint32_t>(d[o + 1]) << 16) | (static_cast<uint32_t>(d[o + 2]) << 8) | d[o + 3];
}

struct Sweep {
    unsigned kept = 0;
    unsigned dropped = 0;
    unsigned unexpected = 0;
    unsigned kerxKept = 0;
    unsigned kernKept = 0;
    unsigned kerxDropped = 0;
    unsigned kernDropped = 0;
};

struct FontView {
    const std::vector<uint8_t> *data;
    size_t base;
};

bool findFontTable(const wk_aat_font_facts &facts, uint32_t tag, const uint8_t **data, size_t *length)
{
    const FontView *font = static_cast<const FontView *>(facts.sfnt);
    if (!font || font->base + 12 > font->data->size())
        return false;
    uint16_t count = be16(*font->data, font->base + 4);
    if (font->base + 12 + static_cast<uint64_t>(count) * 16 > font->data->size())
        return false;
    for (uint16_t i = 0; i < count; ++i) {
        size_t record = font->base + 12 + static_cast<size_t>(i) * 16;
        if (be32(*font->data, record) != tag)
            continue;
        uint32_t offset = be32(*font->data, record + 8);
        uint32_t tableLength = be32(*font->data, record + 12);
        if (static_cast<uint64_t>(offset) + tableLength > font->data->size())
            return false;
        *data = font->data->data() + offset;
        *length = tableLength;
        return true;
    }
    return false;
}

// Runs every validator over one sfnt at `base`. A prop whose version compares signed above 0x00030000
// is one this OS's prop reader rejects itself, so the validator drops it too; every other table is kept.
void sweepFont(const std::vector<uint8_t> &d, size_t base, const std::string &path, Sweep &sweep)
{
    if (base + 12 > d.size())
        return;
    uint16_t count = be16(d, base + 4);
    if (base + 12 + static_cast<uint64_t>(count) * 16 > d.size())
        return;
    uint32_t numGlyphs = 0;
    for (uint16_t i = 0; i < count; ++i) {
        size_t r = base + 12 + i * 16;
        if (be32(d, r) == 0x6d617870 && be32(d, r + 8) + 6ull <= d.size())
            numGlyphs = be16(d, be32(d, r + 8) + 4);
    }
    FontView font { &d, base };
    wk_aat_font_facts facts = factsWithGlyphs(numGlyphs);
    facts.findTable = findFontTable;
    facts.sfnt = &font;
    static const struct { uint32_t tag; Validator validate; } kTables[] = {
        { 0x6b657278, wk_aat_validate_kerx }, { 0x6b65726e, wk_aat_validate_kern },
        { 0x66656174, wk_aat_validate_feat }, { 0x616e6b72, wk_aat_validate_ankr },
        { 0x7472616b, wk_aat_validate_trak }, { 0x6a757374, wk_aat_validate_just },
        { 0x6f706264, wk_aat_validate_opbd }, { 0x70726f70, wk_aat_validate_prop },
        { 0x6c636172, wk_aat_validate_lcar }, { 0x62736c6e, wk_aat_validate_bsln },
    };
    for (uint16_t i = 0; i < count; ++i) {
        size_t r = base + 12 + i * 16;
        uint32_t tag = be32(d, r), offset = be32(d, r + 8), length = be32(d, r + 12);
        if (static_cast<uint64_t>(offset) + length > d.size())
            continue;
        for (const auto &entry : kTables) {
            if (entry.tag != tag)
                continue;
            // A Windows-format kern (u16 version 0) is OTS's to sanitize; only Apple kern 1.0 comes here.
            if (tag == 0x6b65726e && (length < 4 || be32(d, offset) != 0x00010000))
                continue;
            bool kept = entry.validate(d.data() + offset, length, facts);
            bool expectDrop = tag == 0x70726f70 && length >= 4 && static_cast<int32_t>(be32(d, offset)) > 0x00030000;
            (kept ? sweep.kept : sweep.dropped)++;
            if (kept && tag == 0x6b657278)
                sweep.kerxKept++;
            if (kept && tag == 0x6b65726e)
                sweep.kernKept++;
            if (!kept && tag == 0x6b657278)
                sweep.kerxDropped++;
            if (!kept && tag == 0x6b65726e)
                sweep.kernDropped++;
            if (kept == expectDrop) {
                sweep.unexpected++;
                printf("  unexpected %s of '%c%c%c%c' in %s\n", kept ? "keep" : "drop", tag >> 24, tag >> 16 & 0xff,
                    tag >> 8 & 0xff, tag & 0xff, path.c_str());
            }
        }
    }
}

void sweepDirectory(const std::string &dir, Sweep &sweep)
{
    DIR *handle = opendir(dir.c_str());
    if (!handle)
        return;
    while (dirent *entry = readdir(handle)) {
        std::string name = entry->d_name;
        size_t dot = name.rfind('.');
        if (dot == std::string::npos)
            continue;
        std::string ext = name.substr(dot);
        if (ext != ".ttf" && ext != ".otf" && ext != ".ttc" && ext != ".dfont")
            continue;
        std::string path = dir + "/" + name;
        FILE *file = fopen(path.c_str(), "rb");
        if (!file)
            continue;
        std::vector<uint8_t> d;
        uint8_t chunk[65536];
        size_t got;
        while ((got = fread(chunk, 1, sizeof chunk, file)))
            d.insert(d.end(), chunk, chunk + got);
        fclose(file);
        if (d.size() < 12)
            continue;
        if (ext == ".dfont") {
            if (d.size() < 16)
                continue;
            uint64_t dataOffset = be32(d, 0), mapOffset = be32(d, 4);
            uint64_t dataEnd = dataOffset + be32(d, 8), mapEnd = mapOffset + be32(d, 12);
            if (dataEnd > d.size() || mapEnd > d.size() || mapOffset + 28 > mapEnd)
                continue;
            uint64_t typeList = mapOffset + be16(d, mapOffset + 24);
            if (typeList + 2 > mapEnd)
                continue;
            uint16_t encodedTypeCount = be16(d, typeList);
            uint64_t typeCount = encodedTypeCount == 0xFFFF ? 0 : static_cast<uint64_t>(encodedTypeCount) + 1;
            if (typeCount * 8 > mapEnd - typeList - 2)
                continue;
            for (uint64_t type = 0; type < typeCount; ++type) {
                uint64_t record = typeList + 2 + type * 8;
                if (be32(d, record) != 0x73666e74)
                    continue;
                uint16_t encodedResourceCount = be16(d, record + 4);
                uint64_t resourceCount = encodedResourceCount == 0xFFFF ? 0 : static_cast<uint64_t>(encodedResourceCount) + 1;
                uint64_t references = typeList + be16(d, record + 6);
                if (references > mapEnd || resourceCount * 12 > mapEnd - references)
                    continue;
                for (uint64_t resource = 0; resource < resourceCount; ++resource) {
                    uint64_t reference = references + resource * 12;
                    uint64_t resourceRecord = dataOffset + (be32(d, reference + 4) & 0x00FFFFFFu);
                    if (resourceRecord > dataEnd || dataEnd - resourceRecord < 4)
                        continue;
                    uint64_t fontLength = be32(d, resourceRecord);
                    uint64_t fontStart = resourceRecord + 4;
                    if (fontLength > dataEnd - fontStart)
                        continue;
                    std::vector<uint8_t> font(d.begin() + fontStart, d.begin() + fontStart + fontLength);
                    sweepFont(font, 0, path, sweep);
                }
            }
        } else if (be32(d, 0) == 0x74746366) {
            uint32_t fonts = be32(d, 8);
            for (uint32_t k = 0; k < fonts && 16 + static_cast<uint64_t>(k) * 4 <= d.size(); ++k)
                sweepFont(d, be32(d, 12 + k * 4), path, sweep);
        } else
            sweepFont(d, 0, path, sweep);
    }
    closedir(handle);
}

} // namespace

int main()
{
    printf("CoreText-aat-validators:\n");

    Sweep sweep;
    sweepDirectory("/System/Library/Fonts", sweep);
    sweepDirectory("/Library/Fonts", sweep);
    printf("  system AAT tables: %u kept, %u dropped\n", sweep.kept, sweep.dropped);
    printf("  installed kerx tables: %u kept, %u dropped\n", sweep.kerxKept, sweep.kerxDropped);
    printf("  installed Apple kern tables: %u kept, %u dropped\n", sweep.kernKept, sweep.kernDropped);
    check(sweep.kept > 0, "the installed fonts carry AAT tables to validate");
    check(!sweep.unexpected, "every installed AAT table is kept (bar a prop this OS rejects itself)");
    check(sweep.kerxKept > 0, "every installed kerx table is kept");
    check(sweep.kernKept > 0, "every installed Apple-format kern table is kept");

    auto kerxOrdered = bytes(kKerxOrdered, sizeof kKerxOrdered);
    check(keeps(wk_aat_validate_kerx, kerxOrdered, 16), "a well-formed kerx format 0 is kept");
    check(!keeps(wk_aat_validate_kerx, edited32(kerxOrdered, 20, 2), 16), "a kerx pair count running past the subtable is dropped");

    auto kerxOffsetArray = bytes(kKerxOffsetArray, sizeof kKerxOffsetArray);
    check(keeps(wk_aat_validate_kerx, kerxOffsetArray, 1), "a well-formed kerx format 2 is kept");
    check(!keeps(wk_aat_validate_kerx, edited32(kerxOffsetArray, 24, 0x100), 1), "a kerx class-table offset past the subtable is dropped");

    auto kerxState = bytes(kKerxState, sizeof kKerxState);
    check(keeps(wk_aat_validate_kerx, kerxState, 1), "a well-formed kerx format 1 is kept");
    check(!keeps(wk_aat_validate_kerx, edited(kerxState, 48, 1), 1), "a kerx state entry index past the entry array is dropped");
    check(!keeps(wk_aat_validate_kerx, edited(kerxState, 64, 2), 1), "a kerx new-state index past the state array is dropped");

    auto kerxAnchor = bytes(kKerxAnchor, sizeof kKerxAnchor);
    OneSiblingTable onePointAnkr { 0x616e6b72, kOnePointAnkr, sizeof kOnePointAnkr };
    check(wk_aat_validate_kerx(kerxAnchor.data(), kerxAnchor.size(), factsWithSibling(1, onePointAnkr)),
        "a kerx format-4 anchor action within the ankr point array is kept");
    auto badKerxAnchor = edited(kerxAnchor, 72, 1);
    check(!wk_aat_validate_kerx(badKerxAnchor.data(), badKerxAnchor.size(), factsWithSibling(1, onePointAnkr)),
        "a kerx format-4 anchor index past the ankr point count is dropped");

    check(keeps(wk_aat_validate_kerx, bytes(kKerxInert6, sizeof kKerxInert6), 1),
        "a kerx format 6 this OS treats as inert is kept");

    auto kernOrdered = bytes(kKernOrdered, sizeof kKernOrdered);
    check(keeps(wk_aat_validate_kern, kernOrdered, 16), "a well-formed Apple kern format 0 is kept");
    check(!keeps(wk_aat_validate_kern, edited(kernOrdered, 16, 2), 16), "an Apple kern pair count running past the subtable is dropped");

    auto kernOffsetArray = bytes(kKernOffsetArray, sizeof kKernOffsetArray);
    check(keeps(wk_aat_validate_kern, kernOffsetArray, 1), "a well-formed Apple kern format 2 is kept");
    check(!keeps(wk_aat_validate_kern, edited(kernOffsetArray, 18, 0x100), 1), "an Apple kern class-table offset past the subtable is dropped");
    check(!keeps(wk_aat_validate_kern, edited(kernOffsetArray, 26, 10), 1), "an Apple kern class count running past the subtable is dropped");

    auto kernIndexArray = bytes(kKernIndexArray, sizeof kKernIndexArray);
    check(keeps(wk_aat_validate_kern, kernIndexArray, 1), "a well-formed Apple kern format 3 is kept");
    auto badKernIndex = kernIndexArray;
    badKernIndex[26] = 1;
    check(!keeps(wk_aat_validate_kern, badKernIndex, 1), "an Apple kern value index past the value array is dropped");

    auto kernState = bytes(kKernState, sizeof kKernState);
    check(keeps(wk_aat_validate_kern, kernState, 1), "a well-formed Apple kern format 1 is kept");
    check(!keeps(wk_aat_validate_kern, edited(kernState, 32, 0x0100), 1), "an Apple kern state entry index past the entry array is dropped");
    check(!keeps(wk_aat_validate_kern, edited(kernState, 40, 0x0018), 1), "an Apple kern new-state offset past the state array is dropped");
    check(!keeps(wk_aat_validate_kern, std::vector<uint8_t> { 0,0,0,0,0,0,0,0 }, 1), "a Microsoft-format kern does not enter the Apple validator");

    auto ankr = bytes(kAnkr, sizeof kAnkr);
    check(keeps(wk_aat_validate_ankr, ankr, 636), "a real ankr is kept");
    auto ankrLookupPastEnd = ankr;
    ankrLookupPastEnd[6] = 0x01; ankrLookupPastEnd[7] = 0x00;
    check(!keeps(wk_aat_validate_ankr, ankrLookupPastEnd, 636), "an ankr lookup offset past the table end is dropped");

    auto bsln = bytes(kBsln, sizeof kBsln);
    check(keeps(wk_aat_validate_bsln, bsln, 20815), "a real bsln is kept");
    check(keeps(wk_aat_validate_bsln, edited(bsln, 6, 31), 20815), "a bsln default baseline of 31 is kept");
    check(!keeps(wk_aat_validate_bsln, edited(bsln, 6, 32), 20815), "a bsln default baseline of 32 is dropped");
    check(!keeps(wk_aat_validate_bsln, edited(bsln, 88, 32), 20815), "a bsln per-glyph baseline value of 32 is dropped");

    auto prop = bytes(kProp, sizeof kProp);
    check(keeps(wk_aat_validate_prop, prop, 294), "a real prop is kept");
    check(!keeps(wk_aat_validate_prop, edited(prop, 12, 0x0100), 294), "a prop lookup whose segment array runs past the end is dropped");
    check(!keeps(wk_aat_validate_prop, edited(prop, 4, 2), 294), "a prop of a format this OS does not read is dropped");

    auto trak = bytes(kTrak, sizeof kTrak);
    check(keeps(wk_aat_validate_trak, trak, 1058), "a real trak is kept");
    check(!keeps(wk_aat_validate_trak, edited(trak, 6, 0x0100), 1058), "a trak direction offset past the table end is dropped");
    check(!keeps(wk_aat_validate_trak, edited(trak, 26, 0x0058), 1058), "a trak per-size value array running past the end is dropped");

    auto feat = bytes(kFeat, sizeof kFeat);
    check(keeps(wk_aat_validate_feat, feat, 1000), "a real feat is kept");
    check(!keeps(wk_aat_validate_feat, edited(feat, 4, 0x0010), 1000), "a feat record count running past the end is dropped");
    check(!keeps(wk_aat_validate_feat, edited(feat, 16, 0x0100), 1000), "a feat setting table past the table end is dropped");

    auto lcar = bytes(kLcar, sizeof kLcar);
    check(keeps(wk_aat_validate_lcar, lcar, 16), "a well-formed lcar is kept");
    check(!keeps(wk_aat_validate_lcar, edited(lcar, 20, 0x0100), 16), "an lcar caret-list offset past the table end is dropped");
    check(!keeps(wk_aat_validate_lcar, edited(lcar, 22, 0x0010), 16), "an lcar caret count running past the end is dropped");

    auto opbd = bytes(kOpbd, sizeof kOpbd);
    check(keeps(wk_aat_validate_opbd, opbd, 16), "a well-formed opbd with a format-4 lookup is kept");
    check(!keeps(wk_aat_validate_opbd, edited(opbd, 22, 0x0022), 16), "a format-4 segment whose value array runs past the end is dropped");
    check(keeps(wk_aat_validate_opbd, edited(opbd, 6, 10), 16), "a lookup of a format this OS treats as empty keeps the table");

    auto just = bytes(kJust, sizeof kJust);
    check(keeps(wk_aat_validate_just, just, 16), "a well-formed just is kept");
    check(!keeps(wk_aat_validate_just, edited(just, 6, 0x000b), 16), "a just direction table running past the end is dropped");

    if (failures) {
        printf("CoreText-aat-validators: %d FAILED\n", failures);
        return 1;
    }
    printf("CoreText-aat-validators: ok\n");
    return 0;
}
