// Validator for the legacy (non-extended) metamorphosis table 'mort' this OS's shaper
// (TAATMorphSubtableMort) reads.
//
// mort is version 0x00010000 and a chain count, then a chain of variable-length chains; each chain is a
// 12-byte header (defaultFlags u32, chainLength u32, nFeatureEntries u16, nSubtables u16), an array of
// 12-byte feature entries, and nSubtables subtables. Each subtable is an 8-byte header (length u16,
// coverage u16, subFeatureFlags u32) and a body whose kind the coverage low three bits name: 0
// rearrangement, 1 contextual, 2 ligature, 4 noncontextual, 5 insertion. A state-machine body starts with
// {stateSize u16 (= class count), classTableOffset u16, stateArrayOffset u16, entryTableOffset u16}, all
// relative to the body. The class table is {firstGlyph u16, nGlyphs u16, class u8[nGlyphs]}: FetchClass
// returns class[glyph - firstGlyph], a byte 0..255 not bounded by stateSize. The state array is bytes,
// a state is a body-relative byte offset, this OS reads the entry index at body[state + class], and an
// entry is {newStateOffset u16 (body-relative), flags u16}. SetComponent is 0x8000, the ligature-action
// offset is flags & 0x3fff, and the component-stack cap is 15.
//
// As in morx, this OS reads the class array, state rows, entries and action records against the enclosing
// mort TABLE (TAATMorphChainMort::NextChain 0x62ca5/0x62cb5 -> SetChain 0x4c734, bounds at 0x288/0x290),
// not the subtable; a read that leaves the table stops the machine. Two crafted inputs crash it:
//   - Class array overrun. FetchClass (0x4d7f0) reads class[4 + glyph - firstGlyph] with no end check, so
//     a class table whose array runs past the table reads up to 65535 bytes out of bounds.
//   - DoLigatureAction (0x4d8a4). It reads a component with a SIGNED index (movslq 0x100, 0x4d980;
//     stack[index] at 0x4d98b) it never lower-bounds, so a PerformAction reached with an empty stack
//     reads stack[-1]; and it fills a 16-entry output buffer at -0x130 with a counter at -0x144 (from -1)
//     bumped on every store-or-last action record (0x4da4b-0x4da70), so the 17th store overwrites the
//     stack canary at -0x30. An action whose low 30 bits are zero skips the stack read entirely (testl
//     $0x3fffffff at 0x4d966) and the loop ends only on a record that both has nonzero offset bits and
//     the sign bit set.
// The class array is bounds-checked for every state-machine kind; the stack underflow and buffer overflow
// are decided for the ligature kind by walking the state graph over (state, stackEmpty) and the class
// values the class table can actually return. Because SetComponent makes the index non-negative and the
// per-record pop is floored at 0, only the empty-stack case matters, so the walk carries one empty bit.

#include "ots_aat.h"

#include <unordered_set>
#include <vector>

namespace {

const uint16_t kSetComponent = 0x8000;
const uint16_t kLigActionOffsetMask = 0x3fff;
// DoLigatureAction's output buffer holds 16 entries; the 17th store-or-last record overflows it.
const int kOutputSlots = 16;
// An action stores (bumping the buffer) when it has nonzero offset bits and either top bit set
// (unsigned action >= 0x40000000, 0x4da2d). The loop ends only on a record with nonzero offset bits and
// the sign bit; a zero-offset record (action & 0x3fffffff == 0) skips the stack read and never ends it.
const uint32_t kOffsetBits = 0x3fffffffu;
const uint32_t kStoreMask = 0xC0000000u;
const uint32_t kLastAction = 0x80000000u;

const int kPerformEmptyStack = -2;
const int kPerformOverflow = -3;

// The class table's header, resolved and bounds-checked against the whole table. The array class[nGlyphs]
// starts at classBase + 4; FetchClass reads any index below nGlyphs, so the array must lie inside the
// table. Returns firstGlyph/nGlyphs and the array base on success.
bool readClassTable(const uint8_t *table, size_t length, uint64_t dataOffset, uint16_t classTableOffset,
    uint16_t &firstGlyph, uint16_t &nGlyphs, uint64_t &arrayBase)
{
    uint64_t classBase = dataOffset + classTableOffset;
    if (!wk_aat_read16(table, length, classBase, &firstGlyph)
        || !wk_aat_read16(table, length, classBase + 2, &nGlyphs))
        return false;
    arrayBase = classBase + 4;
    if (arrayBase + nGlyphs > length)
        return false;   // FetchClass would read past the table
    return true;
}

// The class values this subtable's class table can yield, deduplicated into `classes`. class is used
// unclamped as body[state+class], so bytes of stateSize or more are walked too.
void collectClassValues(const uint8_t *table, uint64_t arrayBase, uint16_t nGlyphs,
    std::vector<uint32_t> &classes)
{
    // FetchClass (0x4d7b8) returns class 1 for a glyph outside the class table and class 2 for the
    // deleted-glyph marker 0xFFFF; for a covered glyph it returns the raw array byte (0x4d7f0). A covered
    // glyph is any glyph in [firstGlyph, firstGlyph + nGlyphs), and a run can carry any glyph id there
    // once an earlier action has substituted one, so every array byte is reachable. Collect them all,
    // plus the reserved boundary classes (0 end of text, 1 out of bounds, 2 deleted glyph, 3 end of line).
    bool present[256] = { false };
    present[0] = present[1] = present[2] = present[3] = true;
    for (uint32_t i = 0; i < nGlyphs; ++i)
        present[table[arrayBase + i]] = true;
    for (uint32_t v = 0; v < 256; ++v)
        if (present[v])
            classes.push_back(v);
}

// Walk one PerformAction's ligature-action list, mirroring DoLigatureAction: records are 4 bytes apart
// starting at dataOffset + ligActionOffset (a byte offset); a record with nonzero offset bits reads
// stack[C] (so C must be >= 0) and stores when either top bit is set; every record pops C, floored at 0;
// the list ends on a record with nonzero offset bits and the sign bit, or when a read leaves the table.
// `depth` is -1 (empty) or 0 (non-empty collapses to 0). Returns the depth after (-1 or 0), or a fault.
int simulatePerform(const uint8_t *table, size_t length, uint64_t recordBase, int depth, uint64_t &steps,
    uint64_t stepBudget)
{
    int stores = 0;
    for (uint64_t step = 0;; ++step) {
        if (++steps > stepBudget)
            return kPerformOverflow;
        uint64_t recordPos = recordBase + step * 4;
        uint32_t action = 0;
        if (recordPos + 4 > length || !wk_aat_read32(table, length, static_cast<size_t>(recordPos), &action))
            break;
        bool offsetNonzero = (action & kOffsetBits) != 0;
        if (offsetNonzero) {
            if (depth < 0)
                return kPerformEmptyStack;
            if (action & kStoreMask) {
                if (++stores > kOutputSlots)
                    return kPerformOverflow;
            }
        }
        depth = (depth <= 0) ? 0 : depth - 1;   // a zero-offset record still pops, floored at 0
        if (offsetNonzero && (action & kLastAction))
            break;
    }
    return depth;
}

bool ligatureComponentStackSafe(const uint8_t *table, size_t length, uint64_t dataOffset)
{
    uint16_t stateSize = 0, classTableOffset = 0, stateArrayOffset = 0, entryTableOffset = 0;
    if (!wk_aat_read16(table, length, dataOffset, &stateSize)
        || !wk_aat_read16(table, length, dataOffset + 2, &classTableOffset)
        || !wk_aat_read16(table, length, dataOffset + 4, &stateArrayOffset)
        || !wk_aat_read16(table, length, dataOffset + 6, &entryTableOffset))
        return false;
    uint32_t nClasses = stateSize;
    if (nClasses < 1)
        return false;
    uint64_t entryTable = dataOffset + entryTableOffset;
    if (entryTable > length)
        return false;

    uint16_t firstGlyph = 0, nGlyphs = 0;
    uint64_t arrayBase = 0;
    if (!readClassTable(table, length, dataOffset, classTableOffset, firstGlyph, nGlyphs, arrayBase))
        return false;
    std::vector<uint32_t> classes;
    collectClassValues(table, arrayBase, nGlyphs, classes);
    if (classes.empty())
        return true;

    // A cell is one byte at dataOffset + state + class; the body holds at most cellCount = length -
    // dataOffset distinct cells, and a newState whose row starts past the body ends its path. `cellSeen`
    // records, per stack-empty bit, which cells have been resolved, so each cell's entry and action list
    // are read at most twice however many (state, class) pairs address it -- the work is bounded by the
    // distinct cells read, 2 * cellCount <= length.
    //
    // A well-formed state table reserves classes 0..3, so stateSize >= 4 and every class the table yields
    // is a byte in [0, stateSize); a state then reads exactly its stateSize-wide row, and the whole walk
    // reads each cell at most once per stack-empty bit, so the transitions a real table drives are bounded
    // by the distinct cells: 2 * cellCount. A class byte of stateSize or more (which only a crafted class
    // table produces) makes a state stride into other rows and revisit cells, so a walk that runs past
    // 2 * cellCount transitions is reading cells it has already resolved -- the table is malformed rather
    // than one this OS could shape, and it is dropped. The bound is the body extent itself, no constant.
    uint64_t cellCount = (dataOffset < length) ? (length - dataOffset) : 0;
    const uint64_t stepBudget = 2ull * cellCount + 2ull * classes.size() + 1;

    std::vector<uint8_t> cellSeen(static_cast<size_t>(cellCount), 0);   // bit0 empty, bit1 non-empty
    // A cell is state*2 + (stackEmpty ? 0 : 1); state is a body-relative u16, so the key fits in 32 bits.
    std::unordered_set<uint32_t> visited;
    std::vector<uint32_t> queue;
    auto enqueue = [&](uint32_t state, bool empty) {
        uint32_t code = (state << 1) | (empty ? 0u : 1u);
        if (visited.insert(code).second)
            queue.push_back(code);
    };

    enqueue(stateArrayOffset, true);
    enqueue(static_cast<uint32_t>(stateArrayOffset + nClasses) & 0xFFFF, true);
    uint64_t steps = 0;
    for (size_t head = 0; head < queue.size(); ++head) {
        uint32_t state = queue[head] >> 1;
        bool empty = (queue[head] & 1u) == 0;
        uint8_t seenBit = empty ? 1u : 2u;
        for (uint32_t ci = 0; ci < classes.size(); ++ci) {
            if (++steps > stepBudget)
                return false;   // more transitions than the table's dimensions allow; drop it
            uint64_t cell = static_cast<uint64_t>(state) + classes[ci];
            if (cell >= cellCount)
                continue;   // the cell lies past the body; no transition
            if (cellSeen[static_cast<size_t>(cell)] & seenBit)
                continue;   // this cell already resolved for this stack-empty bit; successor enqueued
            cellSeen[static_cast<size_t>(cell)] |= seenBit;
            uint8_t entryIndex = table[dataOffset + cell];
            uint64_t entryPos = entryTable + static_cast<uint64_t>(entryIndex) * 4;
            uint16_t newStateOffset = 0, flags = 0;
            if (entryPos + 4 > length
                || !wk_aat_read16(table, length, static_cast<size_t>(entryPos), &newStateOffset)
                || !wk_aat_read16(table, length, static_cast<size_t>(entryPos + 2), &flags))
                continue;   // the entry read leaves the table; no transition
            bool setComponent = (flags & kSetComponent) != 0;
            uint16_t ligActionOffset = flags & kLigActionOffsetMask;
            bool outEmpty;
            if (ligActionOffset != 0) {
                int start = (setComponent || !empty) ? 0 : -1;
                int res = simulatePerform(table, length, dataOffset + ligActionOffset, start, steps, stepBudget);
                if (res < -1)
                    return false;   // reaches an empty stack or overruns the output buffer
                outEmpty = (res == -1);
            } else {
                outEmpty = setComponent ? false : empty;
            }
            enqueue(newStateOffset, outEmpty);
        }
    }
    return true;
}

// Every state-machine kind reads the class table through FetchClass, so its array must stay in the table.
bool validateStateMachine(const uint8_t *table, size_t length, uint64_t dataOffset, uint32_t kind)
{
    uint16_t stateSize = 0, classTableOffset = 0;
    if (!wk_aat_read16(table, length, dataOffset, &stateSize)
        || !wk_aat_read16(table, length, dataOffset + 2, &classTableOffset))
        return false;
    uint16_t firstGlyph = 0, nGlyphs = 0;
    uint64_t arrayBase = 0;
    if (!readClassTable(table, length, dataOffset, classTableOffset, firstGlyph, nGlyphs, arrayBase))
        return false;
    if (kind == 2)
        return ligatureComponentStackSafe(table, length, dataOffset);
    return true;
}

bool validateSubtableBody(const uint8_t *table, size_t length, uint64_t dataOffset, uint64_t dataEnd,
    uint32_t kind)
{
    if (dataOffset > dataEnd || dataEnd > length)
        return false;
    switch (kind) {
    case 0:
    case 1:
    case 2:
    case 5:
        return validateStateMachine(table, length, dataOffset, kind);
    default:
        return true;
    }
}

} // namespace

bool wk_aat_validate_mort(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    (void)facts;   // mort bounds every read against the table; it needs no sibling-table facts
    uint32_t version = 0;
    if (!wk_aat_read32(table, length, 0, &version) || version != 0x00010000u)
        return false;
    uint32_t nChains = 0;
    if (!wk_aat_read32(table, length, 4, &nChains))
        return false;
    if (static_cast<uint64_t>(nChains) * 12 > length)
        return false;

    uint64_t cursor = 8;
    for (uint32_t c = 0; c < nChains; ++c) {
        uint32_t defaultFlags = 0, chainLength = 0;
        uint16_t nFeatureEntries = 0, nSubtables = 0;
        if (!wk_aat_read32(table, length, cursor, &defaultFlags)
            || !wk_aat_read32(table, length, cursor + 4, &chainLength)
            || !wk_aat_read16(table, length, cursor + 8, &nFeatureEntries)
            || !wk_aat_read16(table, length, cursor + 10, &nSubtables))
            break;
        (void)defaultFlags;
        if (chainLength < 12)
            break;
        uint64_t chainEnd = cursor + chainLength;
        if (chainEnd < cursor || chainEnd > length)
            break;
        uint64_t sub = cursor + 12 + static_cast<uint64_t>(nFeatureEntries) * 12;
        if (sub < cursor || sub > chainEnd)
            break;
        for (uint16_t s = 0; s < nSubtables; ++s) {
            uint16_t subLength = 0, coverage = 0;
            uint32_t subFeatureFlags = 0;
            if (!wk_aat_read16(table, length, sub, &subLength)
                || !wk_aat_read16(table, length, sub + 2, &coverage)
                || !wk_aat_read32(table, length, sub + 4, &subFeatureFlags))
                break;
            (void)subFeatureFlags;
            if (subLength < 8)
                break;
            uint64_t next = sub + subLength;
            if (next < sub || next > chainEnd)
                break;
            uint32_t kind = coverage & 0x7u;
            if (!validateSubtableBody(table, length, sub + 8, next, kind))
                return false;
            sub = next;
        }
        cursor = chainEnd;
    }
    return true;
}
