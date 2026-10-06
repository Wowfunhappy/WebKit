// Standalone robustness harness for the libheif + FFmpeg HEVC decode path HEIFImageDecoder uses.
// heif_probe_decode() below is the call sequence the WebCore decoder makes, limits included.
//
//   probe <files...>                  decode each file, print what came out
//   fuzz <iterations> <seed> <files>  mutate the files in-process and decode each mutant
//
// A fatal signal (a UBSan trap is SIGILL; a libgmalloc guard page is SIGBUS/SIGSEGV) or a 20 s
// alarm writes the input that caused it beside the harness and exits.

#include "heif_probe.h"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/time.h>
#include <unistd.h>
#include <vector>

static std::vector<uint8_t> g_current;
static unsigned long g_iteration;

static void writeCurrent(const char* prefix)
{
    char name[128];
    snprintf(name, sizeof(name), "%s-%d-%lu.heic", prefix, getpid(), g_iteration);
    int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        size_t off = 0;
        while (off < g_current.size()) {
            ssize_t n = write(fd, g_current.data() + off, g_current.size() - off);
            if (n <= 0)
                break;
            off += n;
        }
        close(fd);
    }
    write(2, name, strlen(name));
    write(2, "\n", 1);
}

static void onFatal(int sig)
{
    writeCurrent(sig == SIGALRM ? "hang" : "crash");
    _exit(128 + sig);
}

static std::vector<uint8_t> readFile(const char* path)
{
    std::vector<uint8_t> bytes;
    FILE* f = fopen(path, "rb");
    if (!f)
        return bytes;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
        bytes.insert(bytes.end(), buf, buf + n);
    fclose(f);
    return bytes;
}

// xorshift64*
static uint64_t g_rng;
static uint64_t rnd()
{
    g_rng ^= g_rng >> 12;
    g_rng ^= g_rng << 25;
    g_rng ^= g_rng >> 27;
    return g_rng * 2685821657736338717ULL;
}
static size_t rndBelow(size_t n) { return n ? rnd() % n : 0; }

static const char* kBoxes[] = {
    "ftyp", "meta", "hdlr", "pitm", "iloc", "iinf", "infe", "iref", "iprp", "ipco", "ipma", "ispe", "hvcC",
    "colr", "pixi", "irot", "imir", "clap", "auxC", "grid", "dimg", "thmb", "auxl", "cdsc", "idat", "mdat",
    "moov", "trak", "stsd", "hvc1", "iovl", "iden", "lsel", "oinf", "tols", "rloc", "a1op", "a1lx", "grpl",
    "altr", "Exif", "mime", "uri ", "av01", "j2k1", "vvc1", "avc1", "jpeg", "unci", "mski", "tili", "lhv1",
};

static void mutate(std::vector<uint8_t>& d)
{
    int rounds = 1 + (int)rndBelow(4);
    for (int r = 0; r < rounds && !d.empty(); ++r) {
        switch (rndBelow(10)) {
        case 0: { // bit flips
            int flips = 1 + (int)rndBelow(8);
            for (int i = 0; i < flips; ++i)
                d[rndBelow(d.size())] ^= (uint8_t)(1u << rndBelow(8));
            break;
        }
        case 1: { // interesting byte values
            static const uint8_t v[] = { 0x00, 0x01, 0x7f, 0x80, 0xff, 0xfe, 0x10, 0x40 };
            d[rndBelow(d.size())] = v[rndBelow(sizeof(v))];
            break;
        }
        case 2: { // interesting 32-bit big-endian value somewhere in the first 64 KB (the meta box)
            static const uint32_t v[] = { 0, 1, 7, 8, 0xffffffff, 0x7fffffff, 0x80000000, 0xffff, 0x10000, 65536 * 4, 16384, 512 };
            size_t lim = std::min<size_t>(d.size(), 65536);
            if (lim < 4)
                break;
            size_t p = rndBelow(lim - 3);
            uint32_t x = v[rndBelow(sizeof(v) / sizeof(v[0]))];
            d[p] = x >> 24; d[p + 1] = x >> 16; d[p + 2] = x >> 8; d[p + 3] = x;
            break;
        }
        case 3: { // corrupt a box header or the fields right after a known 4CC
            const char* name = kBoxes[rndBelow(sizeof(kBoxes) / sizeof(kBoxes[0]))];
            std::vector<size_t> hits;
            size_t lim = std::min<size_t>(d.size(), 1 << 20);
            for (size_t i = 0; i + 4 <= lim; ++i)
                if (!memcmp(&d[i], name, 4))
                    hits.push_back(i);
            if (hits.empty())
                break;
            size_t h = hits[rndBelow(hits.size())];
            long off = (long)rndBelow(24) - 4; // the size field, the name, and the first fields
            long p = (long)h + off;
            if (p < 0 || (size_t)p >= d.size())
                break;
            if (rndBelow(2))
                d[p] ^= (uint8_t)(1u << rndBelow(8));
            else
                d[p] = (uint8_t)rnd();
            break;
        }
        case 4: { // truncate
            d.resize(rndBelow(d.size()) + 1);
            break;
        }
        case 5: { // delete a chunk
            size_t p = rndBelow(d.size());
            size_t n = std::min(d.size() - p, 1 + rndBelow(64));
            d.erase(d.begin() + p, d.begin() + p + n);
            break;
        }
        case 6: { // insert random bytes
            size_t p = rndBelow(d.size());
            size_t n = 1 + rndBelow(32);
            std::vector<uint8_t> ins(n);
            for (auto& b : ins)
                b = (uint8_t)rnd();
            d.insert(d.begin() + p, ins.begin(), ins.end());
            break;
        }
        case 7: { // duplicate a chunk of the file elsewhere (repeats boxes)
            size_t p = rndBelow(d.size());
            size_t n = std::min(d.size() - p, 1 + rndBelow(256));
            std::vector<uint8_t> chunk(d.begin() + p, d.begin() + p + n);
            d.insert(d.begin() + rndBelow(d.size()), chunk.begin(), chunk.end());
            break;
        }
        case 8: { // random overwrite of a short run anywhere (HEVC payload)
            size_t p = rndBelow(d.size());
            size_t n = std::min(d.size() - p, 1 + rndBelow(16));
            for (size_t i = 0; i < n; ++i)
                d[p + i] = (uint8_t)rnd();
            break;
        }
        case 9: { // swap two 4CCs of the table in place
            const char* from = kBoxes[rndBelow(sizeof(kBoxes) / sizeof(kBoxes[0]))];
            const char* to = kBoxes[rndBelow(sizeof(kBoxes) / sizeof(kBoxes[0]))];
            size_t lim = std::min<size_t>(d.size(), 1 << 20);
            for (size_t i = 0; i + 4 <= lim; ++i) {
                if (!memcmp(&d[i], from, 4)) {
                    memcpy(&d[i], to, 4);
                    if (rndBelow(3) == 0)
                        break;
                }
            }
            break;
        }
        }
    }
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s probe <files...> | fuzz <iterations> <seed> <files...>\n", argv[0]);
        return 2;
    }
    if (!getenv("HEIF_NO_HANDLER")) {
        for (int s : { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGALRM })
            signal(s, onFatal);
    }

    if (!strcmp(argv[1], "probe")) {
        int failures = 0;
        for (int i = 2; i < argc; ++i) {
            g_current = readFile(argv[i]);
            struct timeval t0, t1;
            gettimeofday(&t0, nullptr);
            alarm(60);
            HEIFProbeResult r = heif_probe_decode(g_current.data(), g_current.size());
            alarm(0);
            gettimeofday(&t1, nullptr);
            double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_usec - t0.tv_usec) / 1e3;
            printf("%-28s %s %dx%d alpha=%d prem=%d bits=%d profile=%s grid=%d rot=%d items=%s sum=%08x %.0fms %s\n",
                strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i], r.ok ? "OK  " : "FAIL",
                r.width, r.height, r.hasAlpha, r.premultiplied, r.lumaBits, r.profile.c_str(), r.isGrid,
                r.transformed, r.itemTypes.c_str(), r.checksum, ms, r.error.c_str());
            failures += !r.ok;
        }
        return failures ? 1 : 0;
    }

    if (!strcmp(argv[1], "fuzz") && argc >= 5) {
        unsigned long iterations = strtoul(argv[2], nullptr, 10);
        g_rng = strtoull(argv[3], nullptr, 10) * 0x9E3779B97F4A7C15ULL + 1;
        std::vector<std::vector<uint8_t>> seeds;
        for (int i = 4; i < argc; ++i) {
            auto b = readFile(argv[i]);
            if (!b.empty())
                seeds.push_back(std::move(b));
        }
        unsigned long ok = 0;
        for (g_iteration = 0; g_iteration < iterations; ++g_iteration) {
            g_current = seeds[rndBelow(seeds.size())];
            mutate(g_current);
            alarm(20);
            HEIFProbeResult r = heif_probe_decode(g_current.data(), g_current.size());
            alarm(0);
            ok += r.ok;
        }
        printf("fuzz done: %lu iterations, %lu decoded\n", iterations, ok);
        return 0;
    }
    return 2;
}
