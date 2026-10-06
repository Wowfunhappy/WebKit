// Fuzzes ID3v2FrameParser: every input, and every de-unsynchronised copy the parser makes, ends at a PROT_NONE page,
// and the build traps on undefined behaviour. A build with -DID3V2_NEGATIVE_CONTROL reads the byte past each guarded
// input and must fault. Run from this directory:
//
//   CXX=../../toolchain/build/clang/bin/clang++
//   FLAGS="-std=c++20 -O1 -mmacosx-version-min=10.9 -isysroot <SDK> -I../../source/WebCore/platform/graphics/gstreamer \
//          -I. -fsanitize=undefined -fsanitize-trap=undefined -DID3V2_FUZZ_GUARDED_COPY"
//   $CXX $FLAGS -o fuzz fuzz.cpp ../../source/WebCore/platform/graphics/gstreamer/ID3v2FrameParser.cpp && ./fuzz 600000 seeds/*.bin
//   $CXX $FLAGS -DID3V2_NEGATIVE_CONTROL -o fuzz-negative fuzz.cpp ../../source/WebCore/platform/graphics/gstreamer/ID3v2FrameParser.cpp
//   ./fuzz-negative 100000 seeds/*.bin; echo $?   # nonzero
#include "ID3v2FrameParser.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <sys/mman.h>
#include <unistd.h>

// Places bytes so that they end at a PROT_NONE page: any read past the end faults.
static const uint8_t* guardedPlace(const uint8_t* source, size_t size)
{
    static void* region = nullptr;
    static size_t regionSize = 0;
    size_t page = static_cast<size_t>(getpagesize());
    size_t dataPages = (size + page - 1) / page;
    if (!dataPages)
        dataPages = 1;
    size_t total = (dataPages + 1) * page;
    if (region)
        munmap(region, regionSize);
    region = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (region == MAP_FAILED)
        abort();
    regionSize = total;
    uint8_t* guard = static_cast<uint8_t*>(region) + dataPages * page;
    if (mprotect(guard, page, PROT_NONE))
        abort();
    uint8_t* start = guard - size;
    if (size)
        memcpy(start, source, size);
    return start;
}

static std::vector<std::pair<void*, size_t>> ownedRegions;
static void releaseGuardedCopies()
{
    for (auto& region : ownedRegions)
        munmap(region.first, region.second);
    ownedRegions.clear();
}
const uint8_t* id3v2FuzzGuardedCopy(const uint8_t* source, size_t size)
{
    size_t page = static_cast<size_t>(getpagesize());
    size_t dataPages = size ? (size + page - 1) / page : 1;
    size_t total = (dataPages + 1) * page;
    void* region = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (region == MAP_FAILED)
        abort();
    ownedRegions.emplace_back(region, total);
    uint8_t* guard = static_cast<uint8_t*>(region) + dataPages * page;
    mprotect(guard, page, PROT_NONE);
    uint8_t* start = guard - size;
    if (size)
        memcpy(start, source, size);
    return start;
}

static uint64_t state = 0x9E3779B97F4A7C15ull;
static uint64_t next() { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state; }

static std::vector<uint8_t> synchsafe(uint32_t v) { return { uint8_t((v >> 21) & 0x7F), uint8_t((v >> 14) & 0x7F), uint8_t((v >> 7) & 0x7F), uint8_t(v & 0x7F) }; }
static std::vector<uint8_t> tag(uint8_t version, uint8_t flags, std::vector<uint8_t> body)
{
    std::vector<uint8_t> out = { 'I', 'D', '3', version, 0, flags };
    auto s = synchsafe(static_cast<uint32_t>(body.size()));
    out.insert(out.end(), s.begin(), s.end());
    out.insert(out.end(), body.begin(), body.end());
    return out;
}
static std::vector<uint8_t> frame(uint8_t version, const char* id, std::vector<uint8_t> payload, uint16_t flags = 0)
{
    std::vector<uint8_t> out(id, id + 4);
    uint32_t n = static_cast<uint32_t>(payload.size());
    if (version == 4) {
        auto s = synchsafe(n);
        out.insert(out.end(), s.begin(), s.end());
    } else {
        out.push_back(uint8_t(n >> 24)); out.push_back(uint8_t(n >> 16)); out.push_back(uint8_t(n >> 8)); out.push_back(uint8_t(n));
    }
    out.push_back(uint8_t(flags >> 8)); out.push_back(uint8_t(flags));
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}

int main(int argc, char** argv)
{
    std::vector<std::vector<uint8_t>> seeds;
    unsigned long iterations = strtoul(argv[1], nullptr, 10);
    for (int i = 2; i < argc; ++i) {
        std::ifstream file(argv[i], std::ios::binary);
        seeds.emplace_back(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
    }
    // Synthetic seeds covering v2.3 unsynchronisation, extended headers, UTF-16 text, and frame flags.
    auto body23 = frame(3, "TIT2", { 1, 0xFF, 0xFE, 'H', 0, 'i', 0, 0, 0 });
    auto geob = frame(3, "GEOB", { 1, 'a', '/', 'b', 0, 0xFF, 0xFE, 'n', 0, 0, 0, 0xFE, 0xFF, 0, 'd', 0, 0, 1, 2, 3 });
    body23.insert(body23.end(), geob.begin(), geob.end());
    body23.insert(body23.end(), { 0xFF, 0x00, 0xE0 });
    seeds.push_back(tag(3, 0x80, body23));
    std::vector<uint8_t> ext23 = { 0, 0, 0, 6, 0, 0, 0, 0, 0, 0 };
    auto txxx = frame(3, "TXXX", { 0, 'd', 0, 'v', 'a', 'l' });
    ext23.insert(ext23.end(), txxx.begin(), txxx.end());
    seeds.push_back(tag(3, 0x40, ext23));
    std::vector<uint8_t> body24;
    auto apic = frame(4, "APIC", { 0, 0, 0, 4, 3, 'i', 'm', 'g', 0, 3, 'x', 0, 0xFF, 0x00, 0xD8 }, 0x0003);
    auto priv = frame(4, "PRIV", { 'o', 'w', 'n', 0, 9, 9 }, 0x0040);
    auto comm = frame(4, "COMM", { 2, 'e', 'n', 'g', 0, 'c', 0, 0, 0xD8, 0x3D, 0xDE, 0x00 });
    body24.insert(body24.end(), apic.begin(), apic.end());
    body24.insert(body24.end(), priv.begin(), priv.end());
    body24.insert(body24.end(), comm.begin(), comm.end());
    body24.insert(body24.end(), 4, 0);
    seeds.push_back(tag(4, 0x00, body24));

    unsigned long totalFrames = 0;
    for (unsigned long iteration = 0; iteration < iterations; ++iteration) {
        std::vector<uint8_t> input = seeds[next() % seeds.size()];
        unsigned mutations = iteration < seeds.size() ? 0 : 1 + next() % 8;
        for (unsigned m = 0; m < mutations; ++m) {
            switch (next() % 7) {
            case 0: if (!input.empty()) input[next() % input.size()] ^= uint8_t(1 << (next() % 8)); break;
            case 1: if (!input.empty()) input[next() % input.size()] = uint8_t(next()); break;
            case 2: if (!input.empty()) input.resize(next() % input.size()); break;
            case 3: input.insert(input.begin() + (input.empty() ? 0 : next() % input.size()), uint8_t(next() % 4 == 0 ? 0 : next())); break;
            case 4: if (input.size() > 10) { size_t at = 6 + next() % 4; input[at] = uint8_t(next() & (next() % 2 ? 0xFF : 0x7F)); } break;
            case 5: if (input.size() > 14) { size_t at = 10 + next() % (input.size() - 10); input[at] = uint8_t(next() % 2 ? 0xFF : 0); } break;
            case 6: if (!input.empty()) { size_t at = next() % input.size(); size_t n = next() % 64; std::vector<uint8_t> copy(input.begin() + at, input.begin() + std::min(input.size(), at + n)); input.insert(input.end(), copy.begin(), copy.end()); } break;
            }
        }
        const uint8_t* guarded = guardedPlace(input.data(), input.size());
#ifdef ID3V2_NEGATIVE_CONTROL
        volatile uint8_t pastEnd = guarded[input.size()];
        (void)pastEnd;
#endif
        auto frames = WebCore::parseID3v2Frames(guarded, input.size());
        for (auto& f : frames) {
            if (f.key.size() != 4 || f.bytes.size() > input.size() || f.text.size() > 3 * input.size() + 4)
                abort();
        }
        totalFrames += frames.size();
        releaseGuardedCopies();
    }
    printf("iterations=%lu frames=%lu\n", iterations, totalFrames);
    auto frames = WebCore::parseID3v2Frames(seeds[0].data(), seeds[0].size());
    return 0;
}
