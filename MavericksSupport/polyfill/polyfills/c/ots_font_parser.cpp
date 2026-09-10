// The memory-safe font parser behind FPFontCreateMemorySafeFontsFromData and
// CTFontManagerCreateMemorySafeFontDescriptorFromData in CoreText.c, on OTS.
//
// OTS reads a sfnt into its own bounds-checked per-table structures and writes a fresh font out of
// them, so every table directory entry, offset and length in the result is a value OTS computed.
// A table OTS does not model is left out. Callers get NULL for a font it will not accept.

#include <CoreFoundation/CoreFoundation.h>
#include <opentype-sanitiser.h>
#include <cstring>

namespace {

// OTS asks the stream how much room it has before it decompresses a WOFF and refuses a font that
// would outgrow it; its own ExpandingMemoryStream answers with a caller-chosen limit the same way.
// A full CJK font runs to a few tens of megabytes.
const size_t maximumSanitizedFontSize = 64u * 1024u * 1024u;

// OTS lays a table directory down before it knows where the tables after it land, then seeks back to
// fill it in, so the sink needs random access rather than append. It is the CFData the caller returns,
// written in place.
class FontDataOTSStream final : public ots::OTSStream {
public:
    FontDataOTSStream() : m_data(CFDataCreateMutable(kCFAllocatorDefault, 0)) { }

    ~FontDataOTSStream() override
    {
        if (m_data)
            CFRelease(m_data);
    }

    CFDataRef copyData()
    {
        CFDataRef data = m_data;
        m_data = NULL;
        return data;
    }

private:
    size_t size() override { return maximumSanitizedFontSize; }

    bool WriteRaw(const void* data, size_t length) override
    {
        if (!m_data || length > maximumSanitizedFontSize - m_offset)
            return false;

        size_t end = m_offset + length;
        // CFDataSetLength zeroes what it adds, so a gap left by a seek past the end never carries
        // stray bytes into the font.
        if (end > static_cast<size_t>(CFDataGetLength(m_data))) {
            CFDataSetLength(m_data, static_cast<CFIndex>(end));
            if (static_cast<size_t>(CFDataGetLength(m_data)) < end)
                return false;
        }

        memcpy(CFDataGetMutableBytePtr(m_data) + m_offset, data, length);
        m_offset = end;
        return true;
    }

    bool Seek(off_t position) override
    {
        if (position < 0 || static_cast<uint64_t>(position) > maximumSanitizedFontSize)
            return false;
        m_offset = static_cast<size_t>(position);
        return true;
    }

    off_t Tell() const override { return static_cast<off_t>(m_offset); }

    CFMutableDataRef m_data;
    size_t m_offset = 0;
};

// Tables this OS renders that OTS carries no parser for, and so drops by default. Dropping them is
// not neutral: Apple Color Emoji sanitizes from 34MB to 70KB as its sbix strikes go, and an AAT font
// loses the morx table CoreText shapes it with, both silently. They are serialized unchanged, which
// is the limit of what this parser covers -- the guarantee is over the tables OTS models, and these
// bytes reach CoreText as they arrived.
//
// Each tag here was measured on this OS: sbix paints colour glyphs, and dropping morx changes advance
// widths. ankr, feat, mort and kerx come with morx, whose subtables reference ankr anchors and feat
// selectors. Tags this OS cannot draw are absent however colourful they are elsewhere -- it paints no
// OpenType-SVG and no COLRv0, and it refuses a CBDT/CBLC font outright, since those carry no outline
// table and CGFontCreateWithDataProvider returns null for one.
bool isTablePreservedForThisOS(uint32_t tag)
{
    switch (tag) {
    case OTS_TAG('s', 'b', 'i', 'x'):   // Apple colour bitmaps, which CoreText.c draws.
    case OTS_TAG('m', 'o', 'r', 'x'):   // AAT layout, which CoreText applies.
    case OTS_TAG('m', 'o', 'r', 't'):
    case OTS_TAG('k', 'e', 'r', 'x'):
    case OTS_TAG('f', 'e', 'a', 't'):
    case OTS_TAG('a', 'n', 'k', 'r'):
        return true;
    default:
        return false;
    }
}

class FontParserContext final : public ots::OTSContext {
private:
    ots::TableAction GetTableAction(uint32_t tag) override
    {
        return isTablePreservedForThisOS(tag) ? ots::TABLE_ACTION_PASSTHRU : ots::TABLE_ACTION_DEFAULT;
    }
};

} // namespace

// WOFF and WOFF2 wrap a sfnt. OTS unwraps both as it reads them -- ots.cc inflates a WOFF through
// zlib and a WOFF2 through the WOFF2 decoder before it looks at a table -- so an entry point handed a
// container asks this first and works on the sfnt inside.
extern "C" bool wk_font_data_is_woff(CFDataRef data)
{
    if (!data || CFDataGetLength(data) < 4)
        return false;
    const UInt8* signature = CFDataGetBytePtr(data);
    return (signature[0] == 'w' && signature[1] == 'O' && signature[2] == 'F'
        && (signature[3] == 'F' || signature[3] == '2'));
}

extern "C" CFDataRef wk_ots_sanitize_font(CFDataRef data)
{
    if (!data)
        return NULL;

    CFIndex length = CFDataGetLength(data);
    if (length <= 0)
        return NULL;

    FontDataOTSStream output;
    FontParserContext context;

    // The default index sanitizes every font in a collection and writes a collection back out, so a
    // caller matching a PostScript name still has all of them to choose from.
    if (!context.Process(&output, CFDataGetBytePtr(data), static_cast<size_t>(length)))
        return NULL;

    CFDataRef sanitized = output.copyData();
    if (sanitized && !CFDataGetLength(sanitized)) {
        CFRelease(sanitized);
        return NULL;
    }
    return sanitized;
}
