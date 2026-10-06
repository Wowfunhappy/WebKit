// Validator for the extended glyph-metamorphosis table 'morx' this OS's shaper (TAATMorphTableMorx)
// reads.
//
// morx is a version word and a chain count, then a chain of variable-length chains; each chain is a
// 16-byte header (defaultFlags, chainLength, nFeatureEntries, nSubtables), an array of 12-byte feature
// entries, and nSubtables subtables. Each subtable is a 12-byte header (length, coverage,
// subFeatureFlags) and a body whose kind the coverage low byte names: 0 rearrangement, 1 contextual,
// 2 ligature, 4 noncontextual, 5 insertion. Kinds 0/1/2/5 are extended state machines sharing the
// 16-byte STXHeader (nClasses, classTableOffset, stateArrayOffset, entryTableOffset, all u32); the
// state array is nClasses u16 entry indices per state, and an entry is {newState u16, flags u16,
// ligActionIndex u16}. Kind 4 is a bare SFNTLookupTable.
//
// This OS reads every state row, entry and ligature-action record against the enclosing morx TABLE, not
// the subtable: TAATMorphChainMorx::NextChain hands SetChain (0xd253/0xd25a) the iterator's table bounds
// (0xd1a9/0xd1b9), stored at 0x288/0x290 and used for every read in DoLigatureSubtable (0x47524/0x4753c)
// and DoLigatureAction (0x47871/0x47882). A read that leaves the table stops the machine, so it is safe;
// a read that lands anywhere inside the table is performed with whatever bytes are there. The model
// therefore bounds every read by the whole table (length) and treats an out-of-table read as a dead end.
//
// Two crafted inputs crash TAATMorphSubtableMorx::DoLigatureAction and are what this validator rejects:
//   - Component-stack underflow. It reads a component with a SIGNED index (movslq 0x800, 0x4789a;
//     stack[index] at 0x478a5) it never lower-bounds, so a PerformAction reached with an empty stack
//     reads stack[-1]. SetComponent increments the index and DoLigatureAction decrements it once per
//     record, floored at 0 by the high-water reload (0x47abb), so the index is negative only when a
//     PerformAction is reached with no SetComponent on the path -- a reachability property of the graph.
//   - Output-buffer overflow. It fills a 128 x 16-byte buffer at -0x830(%rbp) and bumps a counter at
//     -0x880 (from -1) on every store-or-last action record (0x47993-0x479be) with no cap; the 129th
//     store overwrites the stack canary at -0x30 and aborts in ___stack_chk_fail.
// Both are decided by walking the state graph over (state, stack-empty?), the class values the lookup can
// actually return (class is used unclamped in state*nClasses+class, 0x47500-0x47516), and, at each
// PerformAction, the whole ligature-action list to its real end. Because a SetComponent push makes the
// index non-negative and the per-record pop is floored at 0, the exact component depth never matters --
// only whether the stack is empty on entry to a PerformAction -- so the walk carries one empty bit.

#include "ots_aat.h"
#include "ots_aat_lookup.h"

#include <unordered_set>
#include <vector>

namespace {

// The largest class value the lookup can store (a u16), and so the size of the class-presence bitmap.
const uint64_t kMaxClasses = 0x10000;

// Extended-morx ligature entry flags (TAATMorphSubtableMorx::DoLigatureSubtable, 0x4765a/0x476a4).
const uint16_t kSetComponent = 0x8000;
const uint16_t kPerformAction = 0x2000;
// DoLigatureAction stores into a 128-entry output buffer; the 129th store-or-last record overflows it.
const int kOutputSlots = 128;
// An action record stores (and pushes onto the output buffer) when either top bit is set: the compare is
// unsigned `action >= 0x40000000` (0x47974). The sign bit alone ends the list (0x479c8).
const uint32_t kStoreMask = 0xC0000000u;
const uint32_t kLastAction = 0x80000000u;

// simulatePerform fault sentinels; every real depth it returns is >= -1.
const int kPerformEmptyStack = -2;   // a record would read stack[-1]
const int kPerformOverflow = -3;     // more than kOutputSlots store-or-last records

// The shared STXHeader for morx kinds 0/1/2/5. Confirms the class lookup, the state array's first row
// and the entry table lie inside the table, and bounds the class x state work. The class value is not
// range-checked here: the shaper forms state*nClasses+class and bounds only the resulting address.
bool validateStateHeader(const uint8_t *table, size_t length, uint64_t dataOffset, uint32_t numGlyphs)
{
    uint32_t nClasses = 0, classOffset = 0, stateOffset = 0, entryOffset = 0;
    if (!wk_aat_read32(table, length, dataOffset, &nClasses)
        || !wk_aat_read32(table, length, dataOffset + 4, &classOffset)
        || !wk_aat_read32(table, length, dataOffset + 8, &stateOffset)
        || !wk_aat_read32(table, length, dataOffset + 12, &entryOffset))
        return false;
    if (nClasses < 1 || nClasses > kMaxClasses)
        return false;
    uint64_t classBase = dataOffset + classOffset;
    if (classBase > length)
        return false;
    if (!wk_aat_validate_lookup(table, length, static_cast<size_t>(classBase), 2, numGlyphs,
            [](const wk_aat_lookup_entry &) { return true; }))
        return false;
    uint64_t stateBase = dataOffset + stateOffset;
    if (stateBase > length || stateBase + nClasses > length)
        return false;
    uint64_t entryBase = dataOffset + entryOffset;
    if (entryBase > length || entryBase + 6 > length)
        return false;
    return true;
}

// The class values this subtable's lookup can yield, gathered into `classes` (deduplicated). Includes the
// four reserved boundary classes (end of text 0, out of bounds 1, deleted glyph 2, end of line 3) the
// machine sees regardless of the lookup, plus every value the lookup stores for a covered glyph. class is
// used unclamped as state*nClasses+class, so values of nClasses or more must be walked too.
bool collectClassValues(const uint8_t *table, size_t length, uint64_t dataOffset, uint32_t numGlyphs,
    std::vector<uint32_t> &classes)
{
    uint32_t classOffset = 0;
    if (!wk_aat_read32(table, length, dataOffset + 4, &classOffset))
        return false;
    uint64_t classBase = dataOffset + classOffset;
    if (classBase > length)
        return false;
    std::vector<uint8_t> present(static_cast<size_t>(kMaxClasses), 0);
    present[0] = present[1] = present[2] = present[3] = 1;
    bool ok = wk_aat_validate_lookup(table, length, static_cast<size_t>(classBase), 2, numGlyphs,
        [&](const wk_aat_lookup_entry &e) {
            uint16_t value = 0;
            if (!wk_aat_read16(table, length, e.valueOffset, &value))
                return false;
            present[value] = 1;
            return true;
        });
    if (!ok)
        return false;
    for (uint32_t v = 0; v < kMaxClasses; ++v)
        if (present[v])
            classes.push_back(v);
    return true;
}

// Walk one PerformAction's ligature-action list from ligActionIndex, mirroring DoLigatureAction: one u32
// record at a time, 4 bytes apart, reading stack[C] each record (so C must be >= 0), storing on a
// store-or-last record, and decrementing C afterwards floored at 0. `depth` is -1 (empty) or 0 (a
// non-empty stack collapses to 0, since the pop floor keeps it there). Bounds the walk by the whole
// table. Returns the depth after the action (-1 or 0), or a fault sentinel.
int simulatePerform(const uint8_t *table, size_t length, uint64_t ligActionTable, uint16_t ligActionIndex,
    int depth, uint64_t &steps, uint64_t stepBudget)
{
    int stores = 0;
    for (uint64_t step = 0;; ++step) {
        if (++steps > stepBudget)
            return kPerformOverflow;   // pathological list length; drop rather than model further
        uint64_t recordPos = ligActionTable + (static_cast<uint64_t>(ligActionIndex) + step) * 4;
        uint32_t action = 0;
        if (recordPos + 4 > length || !wk_aat_read32(table, length, static_cast<size_t>(recordPos), &action))
            break;   // the read leaves the table; the machine stops here
        if (depth < 0)
            return kPerformEmptyStack;   // stack[depth] would read stack[-1]
        if (action & kStoreMask) {
            if (++stores > kOutputSlots)
                return kPerformOverflow;   // the store overruns the output buffer into the canary
        }
        depth = 0;   // one pop from 0, floored at 0
        if (action & kLastAction)
            break;
    }
    return depth;
}

// Kind 2 (ligature): no reachable state may perform a ligature action with an empty component stack or a
// list of more than 128 store-or-last records. Walk the state graph over (state, stackEmpty) from the
// start-of-text (0) and start-of-line (1) states with an empty stack, branching on every class value the
// lookup can return.
bool ligatureComponentStackSafe(const uint8_t *table, size_t length, uint64_t dataOffset)
{
    uint32_t nClasses = 0, stateOffset = 0, entryOffset = 0, ligActionOffset = 0;
    if (!wk_aat_read32(table, length, dataOffset, &nClasses)
        || !wk_aat_read32(table, length, dataOffset + 8, &stateOffset)
        || !wk_aat_read32(table, length, dataOffset + 12, &entryOffset)
        || !wk_aat_read32(table, length, dataOffset + 16, &ligActionOffset))
        return false;
    if (nClasses < 1 || nClasses > kMaxClasses)
        return false;
    uint64_t stateBase = dataOffset + stateOffset;
    uint64_t entryBase = dataOffset + entryOffset;
    uint64_t ligActionTable = dataOffset + ligActionOffset;
    if (stateBase > length || entryBase > length || ligActionTable > length)
        return false;

    std::vector<uint32_t> classes;
    if (!collectClassValues(table, length, dataOffset, /*numGlyphs*/ 0xFFFF, classes))
        return false;
    if (classes.empty())
        return true;

    // The state array runs from stateBase to the end of the table; a cell is a u16, so the extent holds at
    // most cellCount = (length - stateBase) / 2 distinct cells, and a newState whose row starts past the
    // extent ends its path. `cellSeen` records, per stack-empty bit, which cells have been resolved, so
    // each cell's entry and action list are read at most twice however many (state, class) pairs address
    // it -- the work is bounded by the distinct cells read, 2 * cellCount <= length.
    //
    // A well-formed state table reserves classes 0..3, so nClasses >= 4 and every class the lookup yields
    // lies in [0, nClasses); a state then reads exactly its nClasses-wide row, and the whole walk reads
    // each of the cellCount cells at most once per stack-empty bit. So the transitions a real table drives
    // are bounded by the distinct cells: 2 * cellCount. A class value of nClasses or more (which only a
    // crafted lookup produces) makes a state stride into other rows and revisit cells, so a walk that runs
    // past 2 * cellCount transitions is reading cells it has already resolved -- the table is malformed
    // rather than one this OS could shape, and it is dropped. The bound is the extent itself, no constant.
    uint64_t cellCount = (stateBase < length) ? (length - stateBase) / 2 : 0;
    const uint64_t stepBudget = 2ull * cellCount + 2ull * classes.size() + 1;

    std::vector<uint8_t> cellSeen(static_cast<size_t>(cellCount), 0);   // bit0 empty, bit1 non-empty
    // A cell is state*2 + (stackEmpty ? 0 : 1); state is a u16, so the key fits in 32 bits.
    std::unordered_set<uint32_t> visited;
    std::vector<uint32_t> queue;
    auto enqueue = [&](uint32_t state, bool empty) {
        uint32_t code = (state << 1) | (empty ? 0u : 1u);
        if (visited.insert(code).second)
            queue.push_back(code);
    };

    enqueue(0, true);
    enqueue(1, true);
    uint64_t steps = 0;
    for (size_t head = 0; head < queue.size(); ++head) {
        uint32_t state = queue[head] >> 1;
        bool empty = (queue[head] & 1u) == 0;
        uint8_t seenBit = empty ? 1u : 2u;
        for (uint32_t ci = 0; ci < classes.size(); ++ci) {
            if (++steps > stepBudget)
                return false;   // more transitions than the table's dimensions allow; drop it
            uint64_t cell = static_cast<uint64_t>(state) * nClasses + classes[ci];
            if (cell >= cellCount)
                continue;   // the cell lies past the state array's extent; no transition
            if (cellSeen[static_cast<size_t>(cell)] & seenBit)
                continue;   // this cell already resolved for this stack-empty bit; successor enqueued
            cellSeen[static_cast<size_t>(cell)] |= seenBit;
            uint16_t entryIndex = 0;
            if (!wk_aat_read16(table, length, static_cast<size_t>(stateBase + cell * 2), &entryIndex))
                continue;
            uint64_t entryPos = entryBase + static_cast<uint64_t>(entryIndex) * 6;
            uint16_t newState = 0, flags = 0, ligActionIndex = 0;
            if (entryPos + 6 > length
                || !wk_aat_read16(table, length, static_cast<size_t>(entryPos), &newState)
                || !wk_aat_read16(table, length, static_cast<size_t>(entryPos + 2), &flags)
                || !wk_aat_read16(table, length, static_cast<size_t>(entryPos + 4), &ligActionIndex))
                continue;   // the entry read leaves the table; no transition
            bool setComponent = (flags & kSetComponent) != 0;
            bool outEmpty;
            if (flags & kPerformAction) {
                int start = (setComponent || !empty) ? 0 : -1;
                int res = simulatePerform(table, length, ligActionTable, ligActionIndex, start, steps, stepBudget);
                if (res < -1)
                    return false;   // reaches an empty stack or overruns the output buffer
                outEmpty = (res == -1);   // an empty stack survives only an empty action list
            } else {
                outEmpty = setComponent ? false : empty;
            }
            enqueue(newState, outEmpty);
        }
    }
    return true;
}

bool validateLigature(const uint8_t *table, size_t length, uint64_t dataOffset, uint32_t numGlyphs)
{
    if (!validateStateHeader(table, length, dataOffset, numGlyphs))
        return false;
    uint32_t ligActionOffset = 0, componentOffset = 0, ligatureOffset = 0;
    if (!wk_aat_read32(table, length, dataOffset + 16, &ligActionOffset)
        || !wk_aat_read32(table, length, dataOffset + 20, &componentOffset)
        || !wk_aat_read32(table, length, dataOffset + 24, &ligatureOffset))
        return false;
    if (dataOffset + ligActionOffset + 4 > length || ligActionOffset == 0)
        return false;
    if (dataOffset + componentOffset + 2 > length || componentOffset == 0)
        return false;
    if (dataOffset + ligatureOffset + 2 > length || ligatureOffset == 0)
        return false;
    return ligatureComponentStackSafe(table, length, dataOffset);
}

bool validateNoncontextual(const uint8_t *table, size_t length, uint64_t dataOffset, uint32_t numGlyphs)
{
    return wk_aat_validate_lookup(table, length, static_cast<size_t>(dataOffset), 2, numGlyphs,
        [](const wk_aat_lookup_entry &) { return true; });
}

bool validateSubtable(const uint8_t *table, size_t length, uint64_t dataOffset, uint64_t dataEnd,
    uint32_t kind, uint32_t numGlyphs)
{
    if (dataOffset > dataEnd || dataEnd > length)
        return false;
    switch (kind) {
    case 0:
    case 1:
    case 5:
        return validateStateHeader(table, length, dataOffset, numGlyphs);
    case 2:
        return validateLigature(table, length, dataOffset, numGlyphs);
    case 4:
        return validateNoncontextual(table, length, dataOffset, numGlyphs);
    default:
        return true;
    }
}

} // namespace

bool wk_aat_validate_morx(const uint8_t *table, size_t length, const wk_aat_font_facts &facts)
{
    uint16_t version = 0;
    if (!wk_aat_read16(table, length, 0, &version) || version < 2)
        return false;
    uint32_t nChains = 0;
    if (!wk_aat_read32(table, length, 4, &nChains))
        return false;
    if (static_cast<uint64_t>(nChains) * 16 > length)
        return false;

    uint64_t cursor = 8;
    for (uint32_t c = 0; c < nChains; ++c) {
        uint32_t defaultFlags = 0, chainLength = 0, nFeatureEntries = 0, nSubtables = 0;
        if (!wk_aat_read32(table, length, cursor, &defaultFlags)
            || !wk_aat_read32(table, length, cursor + 4, &chainLength)
            || !wk_aat_read32(table, length, cursor + 8, &nFeatureEntries)
            || !wk_aat_read32(table, length, cursor + 12, &nSubtables))
            break;
        (void)defaultFlags;
        if (chainLength < 16)
            break;
        uint64_t chainEnd = cursor + chainLength;
        if (chainEnd < cursor || chainEnd > length)
            break;
        uint64_t sub = cursor + 16 + static_cast<uint64_t>(nFeatureEntries) * 12;
        if (sub < cursor || sub > chainEnd)
            break;
        for (uint32_t s = 0; s < nSubtables; ++s) {
            uint32_t subLength = 0, coverage = 0, subFeatureFlags = 0;
            if (!wk_aat_read32(table, length, sub, &subLength)
                || !wk_aat_read32(table, length, sub + 4, &coverage)
                || !wk_aat_read32(table, length, sub + 8, &subFeatureFlags))
                break;
            (void)subFeatureFlags;
            if (subLength < 12)
                break;
            uint64_t next = sub + subLength;
            if (next < sub || next > chainEnd)
                break;
            uint32_t kind = coverage & 0xFFu;
            if (!validateSubtable(table, length, sub + 12, next, kind, facts.numGlyphs))
                return false;
            sub = next;
        }
        cursor = chainEnd;
    }
    return true;
}
