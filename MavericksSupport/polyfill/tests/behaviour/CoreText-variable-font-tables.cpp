// Table-level regressions for the software variable-font instancer. Include the
// implementation so this standalone test can exercise its internal parsers without
// exporting private APIs or requiring an installed font. Fixtures contain ordinary
// OpenType records; expected deltas, selected lookups and preserved payloads are
// specified independently of the parser and repacker.
#include "../../polyfills/c/VariableFontInstancer.cpp"

#include <cstdlib>
#include <initializer_list>

namespace TableTests {

using Bytes = std::vector<uint8_t>;
unsigned checks;
unsigned failures;

void check(bool value, const char* description)
{
    ++checks;
    std::printf("  %s: %s\n", value ? "PASS" : "FAIL", description);
    failures += !value;
}

void requireRange(const Bytes& bytes, size_t offset, size_t length)
{
    if (offset > bytes.size() || length > bytes.size() - offset) {
        std::fprintf(stderr, "Invalid test fixture/output read at %zu + %zu (size %zu)\n", offset, length, bytes.size());
        std::exit(1);
    }
}

void append16(Bytes& bytes, uint16_t value)
{
    bytes.push_back(value >> 8);
    bytes.push_back(value);
}

void append32(Bytes& bytes, uint32_t value)
{
    append16(bytes, value >> 16);
    append16(bytes, value);
}

void put16(Bytes& bytes, size_t offset, uint16_t value)
{
    requireRange(bytes, offset, 2);
    bytes[offset] = value >> 8;
    bytes[offset + 1] = value;
}

void put32(Bytes& bytes, size_t offset, uint32_t value)
{
    requireRange(bytes, offset, 4);
    put16(bytes, offset, value >> 16);
    put16(bytes, offset + 2, value);
}

uint16_t read16(const Bytes& bytes, size_t offset)
{
    requireRange(bytes, offset, 2);
    return (uint16_t(bytes[offset]) << 8) | bytes[offset + 1];
}

uint32_t read32(const Bytes& bytes, size_t offset)
{
    return (uint32_t(read16(bytes, offset)) << 16) | read16(bytes, offset + 2);
}

Bytes words(std::initializer_list<uint16_t> values)
{
    Bytes bytes;
    for (auto value : values)
        append16(bytes, value);
    return bytes;
}

bool equalSlice(const Bytes& bytes, size_t offset, const Bytes& expected)
{
    return offset <= bytes.size() && expected.size() <= bytes.size() - offset
        && std::equal(expected.begin(), expected.end(), bytes.begin() + offset);
}

// One axis, two regions, one data subtable and two rows. At coordinate 0.5,
// the regions have weights 0.5 and 1 respectively. Row values are deliberately
// signed and the long-word case cannot be represented by an int16_t.
Bytes variationStore(bool longWords = false)
{
    Bytes bytes;
    append16(bytes, 1);
    append32(bytes, 12);
    append16(bytes, 1);
    append32(bytes, 28);
    append16(bytes, 1);
    append16(bytes, 2);
    for (auto peak : { 16384, 8192 }) {
        append16(bytes, 0);
        append16(bytes, peak);
        append16(bytes, 16384);
    }
    append16(bytes, 2);
    append16(bytes, longWords ? 0x8001 : 1);
    append16(bytes, 2);
    append16(bytes, 0);
    append16(bytes, 1);
    if (longWords) {
        append32(bytes, 100000);
        append16(bytes, uint16_t(-300));
        append32(bytes, uint32_t(-200000));
        append16(bytes, 300);
    } else {
        append16(bytes, 100);
        bytes.push_back(uint8_t(-20));
        append16(bytes, uint16_t(-200));
        bytes.push_back(30);
    }
    return bytes;
}

bool initializedStore(const Bytes& bytes)
{
    ItemVariationStore store(Reader(bytes.data(), bytes.size()));
    return store.initialize({ 0.5f });
}

std::optional<double> storeDelta(const Bytes& bytes, uint32_t index)
{
    ItemVariationStore store(Reader(bytes.data(), bytes.size()));
    if (!store.initialize({ 0.5f }))
        return std::nullopt;
    return store.delta(index);
}

void testVariationStore()
{
    const auto valid = variationStore();
    check(storeDelta(valid, 0) == 30, "short and signed-byte deltas use both region weights");
    check(storeDelta(valid, 1) == -70, "inner index selects the complete second row");
    check(storeDelta(variationStore(true), 0) == 49700, "LONG_WORDS decodes int32 and negative int16 columns");
    check(storeDelta(variationStore(true), 1) == -99700, "LONG_WORDS preserves negative int32 values");
    check(storeDelta(valid, 0xFFFFFFFF) == 0, "NO_VARIATION_INDEX sentinel has zero delta");
    check(!storeDelta(valid, 0x10000), "outer index outside data-offset array is rejected");
    check(!storeDelta(valid, 2), "inner index outside item rows is rejected");
    auto bytes = valid;
    put32(bytes, 8, 0);
    check(storeDelta(bytes, 0xFFFF) == 0, "NULL data subtable denotes no variation for any inner index");
    check(!storeDelta(bytes, 0x10000), "NULL subtable does not authorize an invalid outer index");

    bytes = valid; bytes.resize(7);
    check(!initializedStore(bytes), "truncated ItemVariationStore header is rejected");
    bytes = valid; put16(bytes, 0, 2);
    check(!initializedStore(bytes), "unknown ItemVariationStore format is rejected");
    bytes = valid; put16(bytes, 6, 100);
    check(!initializedStore(bytes), "truncated data-offset array is rejected");
    bytes = valid; put32(bytes, 2, 0);
    check(!initializedStore(bytes), "NULL variation-region list is rejected");
    bytes = valid; put32(bytes, 2, bytes.size() + 1);
    check(!initializedStore(bytes), "variation-region offset beyond store is rejected");
    bytes = valid; put16(bytes, 12, 2);
    check(!initializedStore(bytes), "region axis count must match normalized coordinates");
    bytes = valid; put16(bytes, 14, 0x8000);
    check(!initializedStore(bytes), "reserved high bit in region count is rejected");
    bytes = valid; bytes.resize(27);
    check(!initializedStore(bytes), "truncated final region-axis triple is rejected");
    bytes = valid; put32(bytes, 8, bytes.size() + 1);
    check(!storeDelta(bytes, 0), "data subtable offset beyond store is rejected");
    bytes = valid; put32(bytes, 8, bytes.size() - 1);
    check(!storeDelta(bytes, 0), "truncated data subtable header is rejected");
    bytes = valid; put16(bytes, 30, 3);
    check(!storeDelta(bytes, 0), "word-delta count cannot exceed region-index count");
    bytes = valid; bytes.resize(37);
    check(!storeDelta(bytes, 0), "truncated region-index array is rejected");
    bytes = valid; bytes.pop_back();
    check(!storeDelta(bytes, 0), "incomplete later row rejects the subtable even when selecting row zero");
    bytes = valid; put16(bytes, 36, 2);
    check(!storeDelta(bytes, 0), "out-of-range region index is rejected");
    bytes = variationStore(true); bytes.pop_back();
    check(!storeDelta(bytes, 1), "truncated long-word row is rejected");
}

using MetricRecord = std::pair<uint32_t, uint32_t>;

Bytes metricTable(std::initializer_list<MetricRecord> records, uint16_t recordSize = 8)
{
    Bytes bytes = words({ 1, 0, 0, recordSize, uint16_t(records.size()), uint16_t(12 + recordSize * records.size()) });
    for (auto record : records) {
        append32(bytes, record.first);
        append32(bytes, record.second);
        bytes.resize(bytes.size() + recordSize - 8, 0xA5);
    }
    auto store = variationStore();
    bytes.insert(bytes.end(), store.begin(), store.end());
    return bytes;
}

bool parseMetrics(const Bytes& bytes, std::map<uint32_t, double>& deltas)
{
    ParsedSfnt sfnt;
    sfnt.whole = Reader(bytes.data(), bytes.size());
    sfnt.tables.push_back({ tagFor('M', 'V', 'A', 'R'), 0, uint32_t(bytes.size()) });
    return metricVariations(sfnt, { 0.5f }, deltas);
}

bool parseMetrics(const Bytes& bytes)
{
    std::map<uint32_t, double> deltas;
    return parseMetrics(bytes, deltas);
}

void testMetrics()
{
    constexpr auto hasc = tagFor('h', 'a', 's', 'c');
    constexpr auto hdsc = tagFor('h', 'd', 's', 'c');
    constexpr auto hcla = tagFor('h', 'c', 'l', 'a');
    constexpr auto os2 = tagFor('O', 'S', '/', '2');
    const auto valid = metricTable({ { hasc, 0 }, { hdsc, 1 } });
    std::map<uint32_t, double> deltas;
    check(parseMetrics(valid, deltas) && deltas.size() == 2 && deltas[hasc] == 30 && deltas[hdsc] == -70,
        "MVAR records select their own variation rows");
    check(parseMetrics(metricTable({ { hasc, 0 }, { hdsc, 1 } }, 12)), "MVAR honors extended value-record stride");
    check(parseMetrics(metricTable({ { hasc, 0xFFFFFFFF } })), "MVAR accepts the no-variation sentinel");
    auto bytes = metricTable({ { hasc, 0xFFFF } });
    put32(bytes, read16(bytes, 10) + 8, 0);
    check(parseMetrics(bytes), "MVAR accepts an indexed NULL data subtable");
    check(parseMetrics(metricTable({ { tagFor('z', 'z', 'z', 'z'), 0x10000 } })), "unknown MVAR tags are ignored without reading their indices");
    check(!parseMetrics(metricTable({ { hasc, 0x10000 } })), "known MVAR tag rejects an invalid variation index");
    check(!parseMetrics(metricTable({ { hasc, 0 }, { hasc, 1 } })), "duplicate known MVAR tags are rejected");
    bytes = valid; bytes.resize(11);
    check(!parseMetrics(bytes), "truncated MVAR header is rejected");
    bytes = valid; put16(bytes, 0, 2);
    check(!parseMetrics(bytes), "unsupported MVAR major version is rejected");
    bytes = valid; put16(bytes, 6, 7);
    check(!parseMetrics(bytes), "undersized MVAR record stride is rejected");
    bytes = valid; put16(bytes, 8, 100);
    check(!parseMetrics(bytes), "truncated MVAR record array is rejected");
    bytes = valid; put16(bytes, 10, 0);
    check(!parseMetrics(bytes), "nonempty MVAR requires a variation store");
    bytes = valid; put16(bytes, 10, bytes.size() + 1);
    check(!parseMetrics(bytes), "MVAR store offset beyond table is rejected");
    bytes = valid; put16(bytes, read16(bytes, 10), 2);
    check(!parseMetrics(bytes), "MVAR propagates malformed variation-store rejection");
    bytes = words({ 1, 0, 0, 8, 0, 0 });
    check(parseMetrics(bytes), "empty MVAR permits a NULL variation store");

    auto applyValue = [&](uint32_t tag, size_t offset, uint16_t original, double delta, uint16_t expected) {
        Bytes table(90);
        put16(table, offset, original);
        return applyMetricVariations(os2, table, { { tag, delta } }) && read16(table, offset) == expected;
    };
    auto rejectValue = [&](uint32_t tag, size_t offset, uint16_t original, double delta) {
        Bytes table(90);
        put16(table, offset, original);
        return !applyMetricVariations(os2, table, { { tag, delta } }) && read16(table, offset) == original;
    };
    check(applyValue(hasc, 68, 32766, 1, 32767), "signed metric reaches upper representable endpoint");
    check(applyValue(hasc, 68, uint16_t(-32767), -1, uint16_t(-32768)), "signed metric reaches lower representable endpoint");
    check(rejectValue(hasc, 68, 32767, 1), "signed metric positive overflow is rejected without wrapping");
    check(rejectValue(hasc, 68, uint16_t(-32768), -1), "signed metric negative overflow is rejected without wrapping");
    check(applyValue(hcla, 74, 65534, 1, 65535), "unsigned clipping metric reaches 65535");
    check(applyValue(hcla, 74, 1, -1, 0), "unsigned clipping metric reaches zero");
    check(rejectValue(hcla, 74, 65535, 1), "unsigned metric positive overflow is rejected without wrapping");
    check(rejectValue(hcla, 74, 0, -1), "unsigned metric underflow is rejected without wrapping");
    check(applyValue(hasc, 68, 100, 0.5, 101), "positive half-unit metric delta rounds upward");
    check(applyValue(hasc, 68, 100, -0.5, 100), "negative half-unit metric delta rounds toward positive infinity");
    bytes.resize(69);
    check(!applyMetricVariations(os2, bytes, { { hasc, 1 } }), "metric field truncated at its final byte is rejected");
    bytes = words({ 1, 2, 20, 3, 65535, 15 });
    check(applyMetricVariations(tagFor('g', 'a', 's', 'p'), bytes,
              { { tagFor('g', 's', 'p', '0'), 2 }, { tagFor('g', 's', 'p', '1'), 1000 } })
            && read16(bytes, 4) == 22 && read16(bytes, 8) == 65535 && read16(bytes, 6) == 3 && read16(bytes, 10) == 15,
        "gasp varies finite range limits while preserving flags and the final sentinel");
    bytes.pop_back();
    check(!applyMetricVariations(tagFor('g', 'a', 's', 'p'), bytes, { }), "truncated gasp range array is rejected");
}

struct Feature {
    uint32_t tag;
    std::vector<uint16_t> lookups;
    Bytes parameters;
};

size_t appendFeature(Bytes& bytes, const Feature& feature)
{
    size_t start = bytes.size();
    append16(bytes, 0);
    append16(bytes, feature.lookups.size());
    for (auto lookup : feature.lookups)
        append16(bytes, lookup);
    if (!feature.parameters.empty()) {
        // A real relative offset, with padding: preservation cannot depend on the
        // parameter block immediately following the lookup-index array.
        bytes.insert(bytes.end(), 6, 0xA5);
        put16(bytes, start, bytes.size() - start);
        bytes.insert(bytes.end(), feature.parameters.begin(), feature.parameters.end());
    }
    return start;
}

struct Condition {
    uint16_t axis { 0 };
    int16_t minimum { 0 };
    int16_t maximum { 16384 };
    uint16_t format { 1 };
};

struct VariationRecord {
    std::vector<Condition> conditions { { } };
    bool nullConditions { false };
    bool noSubstitution { false };
    uint32_t substitutionVersion { 0x00010000 };
    std::vector<std::pair<uint16_t, Feature>> alternates;
};

struct RecordLocation {
    size_t conditions { 0 };
    size_t substitution { 0 };
    std::vector<size_t> conditionTables;
    std::vector<size_t> alternateFields;
    std::vector<size_t> alternateTables;
};

struct Layout {
    Bytes bytes;
    size_t scripts;
    size_t features;
    size_t lookups;
    size_t variations;
    Bytes lookupPayload;
    std::vector<RecordLocation> records;
};

Layout makeLayout(const std::vector<Feature>& features, const std::vector<VariationRecord>& records, bool farAlternates = false)
{
    Layout result;
    auto& bytes = result.bytes;
    bytes = { 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    result.scripts = bytes.size();
    put16(bytes, 4, result.scripts);
    append16(bytes, 2);
    append32(bytes, tagFor('D', 'F', 'L', 'T'));
    append16(bytes, 14);
    append32(bytes, tagFor('l', 'a', 't', 'n'));
    append16(bytes, 18);
    append16(bytes, 0); // DFLT has no default or named language system.
    append16(bytes, 0);
    size_t latin = bytes.size();
    append16(bytes, 10);
    append16(bytes, 1);
    append32(bytes, tagFor('T', 'R', 'K', ' '));
    size_t turkishOffset = bytes.size();
    append16(bytes, 0);
    append16(bytes, 0); // Default LangSys: lookupOrder is reserved.
    append16(bytes, 0xFFFF);
    append16(bytes, features.size() > 1 ? 2 : 1);
    if (features.size() > 1)
        append16(bytes, features.size() - 1);
    append16(bytes, 0);
    put16(bytes, turkishOffset, bytes.size() - latin);
    append16(bytes, 0);
    append16(bytes, features.size() > 1 ? 1 : 0);
    append16(bytes, 1);
    append16(bytes, 0);

    result.features = bytes.size();
    put16(bytes, 6, result.features);
    append16(bytes, features.size());
    for (const auto& feature : features) {
        append32(bytes, feature.tag);
        append16(bytes, 0);
    }
    for (size_t i = 0; i < features.size(); ++i) {
        size_t offset = appendFeature(bytes, features[i]);
        put16(bytes, result.features + 2 + i * 6 + 4, offset - result.features);
    }

    result.lookups = bytes.size();
    put16(bytes, 8, result.lookups);
    append16(bytes, 3);
    for (unsigned i = 0; i < 3; ++i)
        append16(bytes, 8 + i * 20);
    for (unsigned i = 0; i < 3; ++i) {
        // GSUB SingleSubst lookup with one coverage glyph and a distinctive delta.
        auto lookup = words({ 1, 0, 1, 8, 1, 6, uint16_t(i + 1), 1, 1, uint16_t(40 + i) });
        bytes.insert(bytes.end(), lookup.begin(), lookup.end());
    }
    result.lookupPayload.assign(bytes.begin() + result.lookups, bytes.end());
    result.variations = bytes.size();
    put32(bytes, 10, result.variations);
    append32(bytes, 0x00010000);
    append32(bytes, records.size());
    bytes.resize(bytes.size() + records.size() * 8);
    result.records.resize(records.size());
    for (size_t i = 0; i < records.size(); ++i) {
        const auto& record = records[i];
        auto& location = result.records[i];
        if (!record.nullConditions) {
            location.conditions = bytes.size();
            put32(bytes, result.variations + 8 + i * 8, location.conditions - result.variations);
            append16(bytes, record.conditions.size());
            bytes.resize(bytes.size() + record.conditions.size() * 4);
            for (size_t c = 0; c < record.conditions.size(); ++c) {
                location.conditionTables.push_back(bytes.size());
                put32(bytes, location.conditions + 2 + c * 4, bytes.size() - location.conditions);
                const auto& condition = record.conditions[c];
                append16(bytes, condition.format);
                append16(bytes, condition.axis);
                append16(bytes, condition.minimum);
                append16(bytes, condition.maximum);
            }
        }
        if (record.noSubstitution)
            continue;
        location.substitution = bytes.size();
        put32(bytes, result.variations + 12 + i * 8, location.substitution - result.variations);
        append32(bytes, record.substitutionVersion);
        append16(bytes, record.alternates.size());
        for (const auto& alternate : record.alternates) {
            append16(bytes, alternate.first);
            location.alternateFields.push_back(bytes.size());
            append32(bytes, 0);
        }
        for (size_t a = 0; a < record.alternates.size(); ++a) {
            if (farAlternates && bytes.size() < 70000)
                bytes.resize(70000, 0);
            size_t alternate = appendFeature(bytes, record.alternates[a].second);
            location.alternateTables.push_back(alternate);
            put32(bytes, location.alternateFields[a], alternate - location.substitution);
        }
    }
    return result;
}

Feature plainFeature(uint16_t lookup)
{
    return { tagFor('r', 'l', 'i', 'g'), { lookup }, { } };
}

VariationRecord selects(uint16_t lookup)
{
    VariationRecord record;
    record.alternates.push_back({ 0, plainFeature(lookup) });
    return record;
}

void checkSelection(Layout layout, const std::vector<float>& coordinates, uint16_t expected, const char* description)
{
    bool success = instanceLayoutFeatures(layout.bytes, coordinates);
    if (success) {
        size_t features = read16(layout.bytes, 6);
        size_t feature = features + read16(layout.bytes, features + 6);
        success = read32(layout.bytes, 0) == 0x00010000 && read16(layout.bytes, feature + 2) == 1
            && read16(layout.bytes, feature + 4) == expected;
    }
    check(success, description);
}

void testFeatureSelection()
{
    const std::vector<Feature> features { plainFeature(0) };
    checkSelection(makeLayout(features, { selects(1), selects(2) }), { 0.5f }, 1, "only the first matching FeatureVariations record is selected");
    auto first = selects(1);
    first.conditions = { { 0, 0, 12288 }, { 1, 0, 4096 } };
    auto fallback = selects(2);
    fallback.nullConditions = true;
    checkSelection(makeLayout(features, { first, fallback }), { 0.5f, 0.5f }, 2, "conditions within a set are ANDed");
    checkSelection(makeLayout(features, { first, fallback }), { 0.5f, 0.25f }, 1, "all matching conditions select the record");
    first.conditions = { { 0, 4096, 12288 } };
    checkSelection(makeLayout(features, { first }), { 0.25f }, 1, "condition lower bound is inclusive");
    checkSelection(makeLayout(features, { first }), { 0.75f }, 1, "condition upper bound is inclusive");
    checkSelection(makeLayout(features, { first }), { 0.0f }, 0, "unmatched conditions preserve the original feature");
    first.conditions = { { 0, 0, 16384, 42 } };
    checkSelection(makeLayout(features, { first, fallback }), { 0.5f }, 2, "unknown condition format makes that record nonmatching");
    first.conditions = { { 2, 0, 16384 } };
    checkSelection(makeLayout(features, { first, fallback }), { 0.5f }, 2, "invalid axis index makes that record nonmatching");
    first = selects(1);
    first.substitutionVersion = 0x00020000;
    checkSelection(makeLayout(features, { first, fallback }), { 0.5f }, 2, "unsupported substitution version permits a later matching record");
    first = selects(1);
    first.nullConditions = true;
    checkSelection(makeLayout(features, { first }), { -1.0f }, 1, "NULL condition set is universal");
    first.nullConditions = false;
    first.conditions.clear();
    checkSelection(makeLayout(features, { first }), { -1.0f }, 1, "empty condition set is universal");
    first.noSubstitution = true;
    checkSelection(makeLayout(features, { first, fallback }), { 0.5f }, 0, "matching NULL substitution ends selection without falling through");
    first.noSubstitution = false;
    first.alternates.clear();
    checkSelection(makeLayout(features, { first, fallback }), { 0.5f }, 0, "matching empty substitution ends selection without falling through");

    auto layout = makeLayout(features, { selects(1) });
    put32(layout.bytes, 10, 0);
    checkSelection(layout, { 0.5f }, 0, "NULL FeatureVariations pointer preserves the original feature");
    layout = makeLayout(features, { selects(1) });
    put32(layout.bytes, layout.variations, 0x00020000);
    checkSelection(layout, { 0.5f }, 0, "unsupported FeatureVariations version preserves original features");

    layout = makeLayout(features, { selects(1) });
    layout.bytes.pop_back();
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "truncated selected alternate lookup array is rejected");
    layout = makeLayout(features, { selects(3) });
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "selected alternate cannot reference a nonexistent lookup");
    layout = makeLayout(features, { selects(1) });
    put32(layout.bytes, layout.records[0].alternateFields[0], 0);
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "NULL alternate feature offset is rejected");
    layout = makeLayout(features, { selects(1) });
    put32(layout.bytes, layout.records[0].alternateFields[0], layout.bytes.size());
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "alternate feature offset beyond its table is rejected");
    layout = makeLayout(features, { selects(1) });
    put16(layout.bytes, layout.records[0].alternateFields[0] - 2, 1);
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "substitution feature index outside FeatureList is rejected");
    first = selects(1);
    first.alternates.push_back({ 0, plainFeature(2) });
    layout = makeLayout(features, { first });
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "duplicate feature substitution indices are rejected");
    layout = makeLayout(features, { selects(1) });
    put32(layout.bytes, layout.records[0].conditions + 2, layout.bytes.size());
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "condition-table offset beyond the table is rejected");
    layout = makeLayout(features, { selects(1) });
    layout.bytes.resize(layout.records[0].conditionTables[0] + 7);
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "truncated format-one condition is rejected");
    layout = makeLayout(features, { selects(1) });
    put32(layout.bytes, layout.variations + 4, 1000);
    check(!instanceLayoutFeatures(layout.bytes, { 0.5f }), "truncated FeatureVariations record array is rejected");
}

bool featureMatches(const Bytes& bytes, size_t index, const Feature& expected)
{
    size_t list = read16(bytes, 6);
    if (index >= read16(bytes, list) || read32(bytes, list + 2 + index * 6) != expected.tag)
        return false;
    size_t feature = list + read16(bytes, list + 6 + index * 6);
    if (read16(bytes, feature + 2) != expected.lookups.size())
        return false;
    for (size_t i = 0; i < expected.lookups.size(); ++i) {
        if (read16(bytes, feature + 4 + i * 2) != expected.lookups[i])
            return false;
    }
    uint16_t parameterOffset = read16(bytes, feature);
    return expected.parameters.empty() ? !parameterOffset : parameterOffset && equalSlice(bytes, feature + parameterOffset, expected.parameters);
}

void testLargeAlternate()
{
    Bytes cvParameters = words({ 0, 256, 257, 258, 2, 259, 2 });
    cvParameters.insert(cvParameters.end(), { 0, 0, 0x41, 1, 0xF6, 0 }); // U+0041, U+1F600.
    const Feature cv { tagFor('c', 'v', '0', '1'), { 2, 0 }, cvParameters };
    const Feature size { tagFor('s', 'i', 'z', 'e'), { }, words({ 120, 1, 260, 100, 140 }) };
    const Feature stylistic { tagFor('s', 's', '0', '1'), { 0, 2, 1 }, words({ 0, 261 }) };
    const Feature unchanged { tagFor('r', 'l', 'i', 'g'), { 2, 1 }, { } };
    std::vector<Feature> original { cv, unchanged, size, stylistic };
    original[0].lookups = { 0 };
    original[3].lookups = { 1 };
    put16(original[0].parameters, 2, 280);
    put16(original[2].parameters, 4, 281);
    put16(original[3].parameters, 2, 282);
    VariationRecord record;
    record.nullConditions = true;
    record.alternates = { { 0, cv }, { 2, size }, { 3, stylistic } };
    auto layout = makeLayout(original, { record }, true);
    check(layout.records[0].alternateTables[0] - layout.features > 65535, "large fixture requires Offset32-to-Offset16 repacking");
    bool success = instanceLayoutFeatures(layout.bytes, { 0.5f });
    check(success, "valid far alternate features are representable by repacking");
    if (!success)
        return;
    const auto& bytes = layout.bytes;
    check(read32(bytes, 0) == 0x00010000, "repacked layout is a static version-one table");
    check(read16(bytes, read16(bytes, 6)) == 4, "repacking retains every feature record");
    check(featureMatches(bytes, 0, cv), "cv01 preserves alternate lookup order and variable-length character parameters");
    check(featureMatches(bytes, 1, unchanged), "repacking retains an unsubstituted original feature");
    check(featureMatches(bytes, 2, size), "size preserves zero lookups and all five alternate parameter fields");
    check(featureMatches(bytes, 3, stylistic), "ss01 preserves alternate lookup order and UI name parameters");
    size_t scripts = read16(bytes, 4);
    check(read16(bytes, scripts) == 2 && read32(bytes, scripts + 2) == tagFor('D', 'F', 'L', 'T')
            && read32(bytes, scripts + 8) == tagFor('l', 'a', 't', 'n'),
        "repacking preserves ScriptList tags and ordering");
    size_t defaultScript = scripts + read16(bytes, scripts + 6);
    check(read16(bytes, defaultScript) == 0 && read16(bytes, defaultScript + 2) == 0,
        "script without default or named language systems remains empty");
    size_t latin = scripts + read16(bytes, scripts + 12);
    check(read16(bytes, latin + 2) == 1 && read32(bytes, latin + 4) == tagFor('T', 'R', 'K', ' '),
        "repacking preserves the named language record");
    size_t defaultLanguage = latin + read16(bytes, latin);
    size_t turkish = latin + read16(bytes, latin + 8);
    check(equalSlice(bytes, defaultLanguage, words({ 0, 0xFFFF, 2, 3, 0 })),
        "default LangSys preserves required-feature sentinel and ordered feature indices");
    check(equalSlice(bytes, turkish, words({ 0, 1, 1, 0 })),
        "named LangSys preserves its required feature and feature index");
    check(equalSlice(bytes, read16(bytes, 8), layout.lookupPayload),
        "LookupList retains offsets, lookup bodies, coverage glyphs and substitution deltas");

    auto malformed = makeLayout(original, { record }, true);
    malformed.bytes.pop_back();
    check(!instanceLayoutFeatures(malformed.bytes, { 0.5f }), "repacking rejects a truncated registered parameter block");
    malformed = makeLayout(original, { record }, true);
    size_t cvTable = malformed.records[0].alternateTables[0];
    put16(malformed.bytes, cvTable + read16(malformed.bytes, cvTable) + 12, 0xFFFF);
    check(!instanceLayoutFeatures(malformed.bytes, { 0.5f }), "cv parameter character count cannot run beyond the table");
}

void testPrecisionAndCache()
{
    LegacyVariableFontAxis axis;
    axis.tag = tagFor('w', 'g', 'h', 't');
    axis.minimumValue = 100;
    axis.defaultValue = 400;
    axis.maximumValue = 1000;
    axis.fixedMinimumValue = 100 << 16;
    axis.fixedDefaultValue = 400 << 16;
    axis.fixedMaximumValue = 1000 << 16;
    int32_t fixed = normalizedFixed(axis, 700.0144);
    check(fixed == 32770, "normalization rounds through font 16.16 coordinates before division");
    check(normalizedF2Dot14(fixed) == 8193.0f / 16384.0f, "F2DOT14 normalization retains the boundary-crossing rounded unit");

    const uint8_t source[] = { 0, 1, 0, 0 };
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, source, sizeof(source));
    int32_t tag = axis.tag;
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &tag);
    double first = 700.0144;
    double second = 700.01441;
    CFNumberRef firstValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &first);
    CFNumberRef secondValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &second);
    const void* keys[] = { key };
    const void* firstValues[] = { firstValue };
    const void* secondValues[] = { secondValue };
    CFDictionaryRef firstRequest = CFDictionaryCreate(kCFAllocatorDefault, keys, firstValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef secondRequest = CFDictionaryCreate(kCFAllocatorDefault, keys, secondValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    check(instanceCacheKey(data, firstRequest) != instanceCacheKey(data, secondRequest),
        "same-source requests with distinct precise axis values do not alias in the cache");
    check(instanceCacheKey(data, firstRequest) == instanceCacheKey(data, firstRequest), "identical requests retain a stable cache key");
    CFRelease(secondRequest);
    CFRelease(firstRequest);
    CFRelease(secondValue);
    CFRelease(firstValue);
    CFRelease(key);
    CFRelease(data);
}

} // namespace TableTests

int main()
{
    std::puts("CoreText variable-font table regressions");
    TableTests::testVariationStore();
    TableTests::testMetrics();
    TableTests::testFeatureSelection();
    TableTests::testLargeAlternate();
    TableTests::testPrecisionAndCache();
    std::printf("%u checks, %u failures\n", TableTests::checks, TableTests::failures);
    return TableTests::failures ? 1 : 0;
}
