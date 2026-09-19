// Shared contract for the per-table AAT validators wk_ots_sanitize_font runs (ots_font_parser.cpp).
// OTS models no AAT layout table, so each is passed through and reaches 10.9's shaper, which reads
// its state machines, class tables, lookup tables and action lists from offsets it does not bound.
// A validator reproduces the reads 10.9 performs and answers false when any of them would leave the
// table; a table that validates is kept, one that does not is dropped alone.
//
// Every read a validator makes is bounds-checked through the helpers below: the table base and length,
// numGlyphs, and any sibling table found through facts.findTable are the only trusted inputs. A
// validator must never dereference the table directly.
#ifndef WK_OTS_AAT_H
#define WK_OTS_AAT_H

#include <cstddef>
#include <cstdint>

struct wk_aat_font_facts;

// Bounds-checked lookup of a sibling table in the same (pass-1, OTS-sanitized) sfnt. Returns true and
// fills *outData/*outLength with that table's bytes when present; false when absent. The referenced
// bytes lie wholly inside the sfnt, so a validator can bound a cross-table index (e.g. a kerx format-4
// anchor index against the ankr point arrays, a morx feature flag against feat) against real limits.
typedef bool (*wk_aat_find_table)(const wk_aat_font_facts &facts, uint32_t tag,
                                  const uint8_t **outData, size_t *outLength);

// Facts read once from the sanitized sfnt, each read bounds-checked. `ok` is false when a required
// table (maxp) is absent or short, in which case the caller drops every AAT table without calling a
// validator. numGlyphs is maxp.numGlyphs (see computeFacts in ots_font_parser.cpp).
struct wk_aat_font_facts {
    uint32_t numGlyphs;
    uint16_t unitsPerEm;
    bool ok;
    wk_aat_find_table findTable;
    const void *sfnt;   // opaque cookie for findTable; validators do not read it
};

// Safe big-endian reads: return false and leave *out unset when [offset, offset+width) is not wholly
// inside [0, length). A validator ANDs these; the first out-of-bounds read fails the table.
inline bool wk_aat_read16(const uint8_t *base, size_t length, size_t offset, uint16_t *out)
{
    if (offset + 2 > length || offset + 2 < offset)
        return false;
    *out = static_cast<uint16_t>((base[offset] << 8) | base[offset + 1]);
    return true;
}

inline bool wk_aat_read32(const uint8_t *base, size_t length, size_t offset, uint32_t *out)
{
    if (offset + 4 > length || offset + 4 < offset)
        return false;
    *out = (static_cast<uint32_t>(base[offset]) << 24) | (static_cast<uint32_t>(base[offset + 1]) << 16)
        | (static_cast<uint32_t>(base[offset + 2]) << 8) | base[offset + 3];
    return true;
}

// One validator per AAT tag. table/length delimit that table's bytes within the sfnt; facts.ok is
// guaranteed true when a validator is called. true = keep (PASSTHRU), false = drop.
bool wk_aat_validate_morx(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_mort(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_kerx(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_kern(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_feat(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_ankr(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_trak(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_just(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_opbd(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_prop(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_lcar(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);
bool wk_aat_validate_bsln(const uint8_t *table, size_t length, const wk_aat_font_facts &facts);

#endif
