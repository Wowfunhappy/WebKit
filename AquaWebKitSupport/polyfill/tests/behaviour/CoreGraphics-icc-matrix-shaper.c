// The ICC repair's matrix/TRC route (c/ICCProfile.c). An RGB profile whose lut tags are all one
// matrix/TRC transform -- A2B0, A2B1/A2B2 identical to it, B2A0 its inverse -- reaches ColorSync as the
// matrix/TRC profile it is, its parametric curves intact, and draws exactly as that profile written by
// hand. A profile whose other lut tags say anything else keeps its lut tags, sampled.
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

extern CFDataRef wk_iccProfileForColorSync(CFDataRef profile);

static void write32(unsigned char *b, unsigned v) { b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v; }
static unsigned read32(const unsigned char *b) { return (unsigned)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]; }
static void writeFixed(unsigned char *b, double v) { write32(b, (unsigned)(int)lround(v * 65536)); }

static const double toXYZ[9] = { .4360747, .3850649, .1430804, .2225045, .7168786, .0606169, .0139322, .0971045, .7141733 };

static void inverse3(const double m[9], double out[9])
{
    double d = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
    for (unsigned row = 0; row < 3; ++row) {
        for (unsigned column = 0; column < 3; ++column) {
            unsigned r0 = (column + 1) % 3, r1 = (column + 2) % 3, c0 = (row + 1) % 3, c1 = (row + 2) % 3;
            out[3 * row + column] = (m[3 * r0 + c0] * m[3 * r1 + c1] - m[3 * r0 + c1] * m[3 * r1 + c0]) / d;
        }
    }
}

static unsigned writePara(unsigned char *b, double gamma)
{
    memcpy(b, "para", 4);
    memset(b + 4, 0, 8);
    writeFixed(b + 12, gamma);
    return 16;
}

// A matrix-shaper lut: identity B curves, the sRGB matrix in the lut's PCSXYZ encoding (its inverse for
// mBA), and para gamma M curves.
static unsigned writeShaper(unsigned char *tag, bool reverse, double gamma)
{
    memset(tag, 0, 32);
    memcpy(tag, reverse ? "mBA " : "mAB ", 4);
    tag[8] = tag[9] = 3;
    unsigned b = 32, matrix = b + 36, m = matrix + 48;
    write32(tag + 12, b);
    write32(tag + 16, matrix);
    write32(tag + 20, m);
    for (unsigned c = 0; c < 3; ++c) {
        memcpy(tag + b + 12 * c, "curv", 4);
        memset(tag + b + 12 * c + 4, 0, 8);
    }
    double values[9];
    if (reverse) {
        inverse3(toXYZ, values);
        for (unsigned i = 0; i < 9; ++i)
            values[i] *= 65535.0 / 32768;
    } else {
        for (unsigned i = 0; i < 9; ++i)
            values[i] = toXYZ[i] * 32768 / 65535;
    }
    for (unsigned i = 0; i < 9; ++i)
        writeFixed(tag + matrix + 4 * i, values[i]);
    memset(tag + matrix + 36, 0, 12);
    for (unsigned c = 0; c < 3; ++c)
        writePara(tag + m + 16 * c, gamma);
    return m + 48;
}

struct tag { const char *signature; int kind; double gamma; };   // kind: 0 XYZ wtpt, 1 mAB, 2 mBA, 3 XYZ colorant, 4 para TRC

static CFDataRef build(const struct tag *tags, unsigned count)
{
    static unsigned char bytes[4096];
    memset(bytes, 0, sizeof(bytes));
    memcpy(bytes + 4, "appl", 4);
    write32(bytes + 8, 0x04300000);
    memcpy(bytes + 12, "mntrRGB XYZ ", 12);
    memcpy(bytes + 36, "acsp", 4);
    writeFixed(bytes + 68, .9642);
    writeFixed(bytes + 72, 1);
    writeFixed(bytes + 76, .8249);
    write32(bytes + 128, count);
    unsigned cursor = 132 + 12 * count;
    for (unsigned i = 0; i < count; ++i) {
        unsigned char *tag = bytes + cursor;
        unsigned size;
        if (tags[i].kind == 0 || tags[i].kind == 3) {
            memcpy(tag, "XYZ ", 4);
            memset(tag + 4, 0, 4);
            unsigned column = tags[i].signature[0] == 'r' ? 0 : tags[i].signature[0] == 'g' ? 1 : 2;
            // A colorant is the lut matrix's own s15Fixed16 entry, out of the lut's PCSXYZ encoding.
            for (unsigned row = 0; row < 3; ++row)
                writeFixed(tag + 8 + 4 * row, tags[i].kind ? lround(toXYZ[3 * row + column] * 32768 / 65535 * 65536) / 65536.0 * 65535 / 32768
                    : (double[]){ .9642, 1, .8249 }[row]);
            size = 20;
        } else if (tags[i].kind == 4)
            size = writePara(tag, tags[i].gamma);
        else
            size = writeShaper(tag, tags[i].kind == 2, tags[i].gamma);
        memcpy(bytes + 132 + 12 * i, tags[i].signature, 4);
        write32(bytes + 132 + 12 * i + 4, cursor);
        write32(bytes + 132 + 12 * i + 8, size);
        cursor += (size + 3) & ~3u;
    }
    write32(bytes, cursor);
    return CFDataCreate(NULL, bytes, cursor);
}

static bool hasTag(CFDataRef profile, const char *signature)
{
    const unsigned char *b = CFDataGetBytePtr(profile);
    for (unsigned i = 0; i < read32(b + 128); ++i) {
        if (!memcmp(b + 132 + 12 * i, signature, 4))
            return true;
    }
    return false;
}

static int failures;
static void check(bool ok, const char *name)
{
    printf("  %s: %s\n", name, ok ? "ok" : "FAIL");
    failures += !ok;
}

static void draw(CGColorSpaceRef space, unsigned char value, unsigned char out[4])
{
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(out, 1, 1, 8, 4, srgb, kCGImageAlphaNoneSkipLast);
    CGFloat components[] = { value / 255.0, value / 255.0, value / 255.0, 1 };
    CGColorRef color = CGColorCreate(space, components);
    CGContextSetFillColorWithColor(context, color);
    CGContextFillRect(context, CGRectMake(0, 0, 1, 1));
    CGColorRelease(color);
    CGContextRelease(context);
    CGColorSpaceRelease(srgb);
}

int main(void)
{
    const double gamma = 2.2;
    struct tag forwardOnly[] = { { "wtpt", 0, 0 }, { "A2B0", 1, gamma } };
    struct tag consistent[] = { { "wtpt", 0, 0 }, { "A2B0", 1, gamma }, { "A2B1", 1, gamma }, { "B2A0", 2, 1 / gamma } };
    struct tag otherIntent[] = { { "wtpt", 0, 0 }, { "A2B0", 1, gamma }, { "A2B1", 1, 2.4 }, { "B2A0", 2, 1 / gamma } };
    struct tag notInverse[] = { { "wtpt", 0, 0 }, { "A2B0", 1, gamma }, { "B2A0", 2, 1 / 1.8 } };
    struct tag byHand[] = { { "wtpt", 0, 0 }, { "rXYZ", 3, 0 }, { "gXYZ", 3, 0 }, { "bXYZ", 3, 0 }, { "rTRC", 4, gamma }, { "gTRC", 4, gamma }, { "bTRC", 4, gamma } };
    struct { struct tag *tags; unsigned count; bool converts; const char *name; } cases[] = {
        { forwardOnly, 2, true, "a lone matrix-shaper A2B0 becomes matrix/TRC" },
        { consistent, 4, true, "an identical A2B1 and inverse B2A0 become matrix/TRC" },
        { otherIntent, 4, false, "a different A2B1 keeps the lut tags" },
        { notInverse, 3, false, "a B2A0 that is not the inverse keeps the lut tags" },
    };
    CFDataRef reference = build(byHand, 7);
    CGColorSpaceRef referenceSpace = CGColorSpaceCreateWithICCProfile(reference);
    assert(referenceSpace);
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        CFDataRef profile = build(cases[i].tags, cases[i].count);
        CFDataRef repaired = wk_iccProfileForColorSync(profile);
        bool converted = hasTag(repaired, "rTRC") && !hasTag(repaired, "A2B0");
        check(converted == cases[i].converts && (converted || hasTag(repaired, "A2B0")), cases[i].name);
        CGColorSpaceRef space = CGColorSpaceCreateWithICCProfile(profile);
        check(space != NULL, "the space builds");
        if (space && cases[i].converts) {
            bool same = true;
            for (unsigned value = 0; value < 256; ++value) {
                unsigned char a[4], b[4];
                draw(space, value, a);
                draw(referenceSpace, value, b);
                same &= !memcmp(a, b, 3);
            }
            check(same, "it draws every gray level exactly as the matrix/TRC profile written by hand");
        }
        if (space)
            CGColorSpaceRelease(space);
        CFRelease(repaired);
        CFRelease(profile);
    }
    CGColorSpaceRelease(referenceSpace);
    CFRelease(reference);
    printf("CoreGraphics-icc-matrix-shaper: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}
