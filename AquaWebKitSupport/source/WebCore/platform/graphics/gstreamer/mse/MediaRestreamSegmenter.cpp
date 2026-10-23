#include "config.h"
#include "MediaRestreamSegmenter.h"
#include <set>

namespace WebCore {

std::optional<RestreamTransportInfo> MediaRestreamSegmenter::transportInfo(const SharedBuffer& buffer)
{
    auto bytes = buffer.span();
    if (bytes.empty() || bytes.size() % 188)
        return std::nullopt;
    RestreamTransportInfo result;
    std::map<unsigned, unsigned> previous;
    std::map<unsigned, Vector<uint8_t>> sections;
    std::set<unsigned> tablePIDs { 0 };
    for (size_t offset = 0; offset < bytes.size(); offset += 188) {
        auto packet = bytes.subspan(offset, 188);
        if (packet[0] != 0x47 || (packet[1] & 0x80) || (packet[3] & 0xc0))
            return std::nullopt;
        unsigned pid = ((packet[1] & 0x1f) << 8) | packet[2];
        if (pid == 0x1fff)
            continue;
        unsigned control = (packet[3] >> 4) & 3;
        if (!control)
            return std::nullopt;
        bool payload = control & 1;
        unsigned counter = packet[3] & 15;
        auto found = previous.find(pid);
        if (found != previous.end() && counter != ((found->second + payload) & 15))
            return std::nullopt;
        if (found == previous.end())
            result.bases.emplace(pid, (counter + 16 - payload) & 15);
        previous[pid] = counter;
        result.packets[pid] += payload;
        size_t begin = 4;
        if (control & 2)
            begin += 1 + packet[4];
        if (begin > 188 || (payload && begin == 188))
            return std::nullopt;
        if (!payload || !tablePIDs.contains(pid))
            continue;
        auto& section = sections[pid];
        if (packet[1] & 0x40) {
            begin += 1 + packet[begin];
            if (begin >= 188)
                return std::nullopt;
            section.clear();
        }
        if (section.isEmpty() && !(packet[1] & 0x40))
            return std::nullopt;
        section.append(packet.subspan(begin));
        if (section.size() < 3)
            continue;
        size_t length = 3 + ((section[1] & 15) << 8) + section[2];
        if (section.size() < length)
            continue;
        section.shrink(length);
        auto table = result.tables.find(pid);
        if (table != result.tables.end() && table->second != section)
            return std::nullopt;
        result.tables.insert_or_assign(pid, section);
        if (!pid) {
            if (section[0] || section.size() < 12)
                return std::nullopt;
            for (size_t i = 8; i + 4 <= section.size() - 4; i += 4) {
                if (section[i] || section[i + 1])
                    tablePIDs.insert(((section[i + 2] & 31) << 8) | section[i + 3]);
            }
        } else if (section[0] != 2)
            return std::nullopt;
    }
    if (tablePIDs.size() < 2 || result.tables.size() != tablePIDs.size())
        return std::nullopt;
    return result;
}

Ref<SharedBuffer> MediaRestreamSegmenter::withContinuity(const SharedBuffer& buffer, const RestreamCounters& offsets)
{
    Vector<uint8_t> bytes;
    bytes.append(buffer.span());
    for (size_t i = 0; i < bytes.size(); i += 188) {
        unsigned pid = ((bytes[i + 1] & 31) << 8) | bytes[i + 2];
        auto found = offsets.find(pid);
        if (found != offsets.end())
            bytes[i + 3] = (bytes[i + 3] & 0xf0) | ((bytes[i + 3] + found->second) & 15);
    }
    return SharedBuffer::create(WTF::move(bytes));
}

}
