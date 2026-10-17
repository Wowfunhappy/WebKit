/*
 * dyld's version queries (10.10+): whether the main executable, or a given image, was built with at
 * least a given SDK or deployment target. 10.9's dyld answers the older form of the same question,
 * dyld_get_program_sdk_version / dyld_get_program_min_os_version, from the main executable's
 * LC_VERSION_MIN_MACOSX, and these answer from the same load command.
 *
 * Plain C: Apple's libxml2 and libxslt in the deps build ask these questions too.
 */

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

/* dyld_priv.h's version types. The layout is the ABI: two uint32_t packed into one 64-bit integer
 * register. */
typedef uint32_t dyld_platform_t;
typedef struct {
    dyld_platform_t platform;
    uint32_t version;
} dyld_build_version_t;

#define WK_PLATFORM_MACOS 1         /* PLATFORM_MACOS; the only platform this OS runs */
#define WK_VERSION_SET 0xffffffffu  /* dyld_build_version_t.platform marking a "version set" (below) */
#define WK_VERSION_NONE 0xffffffffu /* a version nothing can be at least as new as */

/* LC_BUILD_VERSION is how linkers newer than 10.9's record platform/minos/sdk; 10.9's <mach-o/loader.h>
 * knows only LC_VERSION_MIN_MACOSX, which is what a binary deploying to 10.9 carries. Both are read, so
 * an image's versions do not depend on which linker produced it. */
#ifndef LC_BUILD_VERSION
#define LC_BUILD_VERSION 0x32
struct build_version_command {
    uint32_t cmd, cmdsize, platform, minos, sdk, ntools;
};
#endif

/* dyld's "version set" form of dyld_build_version_t: platform == 0xffffffff means the version field is
 * a DATE (0xYYYYMMDD) naming the OS releases that shipped together on that date, and the comparison is
 * against whichever of those releases belongs to the running platform. 10.9 carries no such table, so
 * the macOS column of dyld's own is restated here. The season -> macOS pairing is the one WebKit
 * encodes: Source/WTF/wtf/spi/darwin/dyldSPI.h lists each dyld_<season>_os_versions macro alongside
 * the DYLD_MACOSX_VERSION_* constant that season's fallback check uses. */
static const struct { uint32_t set; uint32_t macos; } wk_version_sets[] = {
    { 0x07DE0901, 0x000A0A00 }, /* fall 2014      -> macOS 10.10 */
    { 0x07DF0901, 0x000A0B00 }, /* fall 2015      -> macOS 10.11 */
    { 0x07E00901, 0x000A0C00 }, /* fall 2016      -> macOS 10.12 */
    { 0x07E10901, 0x000A0D00 }, /* fall 2017      -> macOS 10.13 */
    { 0x07E20301, 0x000A0D04 }, /* spring 2018    -> macOS 10.13.4 */
    { 0x07E20901, 0x000A0E00 }, /* fall 2018      -> macOS 10.14 */
    { 0x07E30301, 0x000A0E04 }, /* spring 2019    -> macOS 10.14.4 */
    { 0x07E30901, 0x000A0F00 }, /* fall 2019      -> macOS 10.15 */
    { 0x07E30C01, 0x000A0F01 }, /* late fall 2019 -> macOS 10.15.1 */
    { 0x07E40301, 0x000A0F04 }, /* spring 2020    -> macOS 10.15.4 */
    { 0x07E40901, 0x000A1000 }, /* fall 2020      -> macOS 10.16 */
    { 0x07E50301, 0x000B0300 }, /* spring 2021    -> macOS 11.3 */
    { 0x07E50901, 0x000C0000 }, /* fall 2021      -> macOS 12.0 */
    { 0x07E60301, 0x000C0300 }, /* spring 2022    -> macOS 12.3 */
    { 0x07E60901, 0x000D0000 }, /* fall 2022      -> macOS 13.0 */
    { 0x07E70301, 0x000D0300 }, /* 2022 SU E      -> macOS 13.3 */
    { 0x07E70901, 0x000E0000 }, /* fall 2023      -> macOS 14.0 */
    { 0x07E70C01, 0x000E0200 }, /* 2023 SU C      -> macOS 14.2 */
    { 0x07E80301, 0x000E0400 }, /* 2023 SU E      -> macOS 14.4 */
    { 0x07E80901, 0x000F0000 }, /* fall 2024      -> macOS 15.0 */
    { 0x07E80C01, 0x000F0200 }, /* 2024 SU C      -> macOS 15.2 */
    { 0x07E90301, 0x000F0400 }, /* 2024 SU E      -> macOS 15.4 */
    { 0x07E90501, 0x000F0500 }, /* 2024 SU F      -> macOS 15.5 */
    { 0x07E90B01, 0x001A0100 }, /* 2025 SU B      -> macOS 26.1 */
};

/* The macOS release a version set names. The table is ordered by date, so the first entry at or after
 * the requested date is the release being asked about; a date past the end names a release newer than
 * anything this table knows, which no SDK can be shown to be at least as new as. */
static uint32_t wk_macos_version_for_version_set(uint32_t versionSet)
{
    for (size_t i = 0; i < sizeof(wk_version_sets) / sizeof(wk_version_sets[0]); i++) {
        if (wk_version_sets[i].set >= versionSet)
            return wk_version_sets[i].macos;
    }
    return WK_VERSION_NONE;
}

/* platform / minimum-OS / SDK of a Mach-O image, read from whichever load command records them. */
static bool wk_image_build_versions(const struct mach_header *header, uint32_t *platform, uint32_t *minos, uint32_t *sdk)
{
    if (!header)
        return false;

    const uint8_t *cursor;
    uint32_t commandCount;
    if (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64) {
        cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        commandCount = ((const struct mach_header_64 *)header)->ncmds;
    } else if (header->magic == MH_MAGIC || header->magic == MH_CIGAM) {
        cursor = (const uint8_t *)header + sizeof(struct mach_header);
        commandCount = header->ncmds;
    } else
        return false;

    for (uint32_t i = 0; i < commandCount; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command))
            return false;
        if (command->cmd == LC_VERSION_MIN_MACOSX) {
            const struct version_min_command *version = (const struct version_min_command *)command;
            *platform = WK_PLATFORM_MACOS;
            *minos = version->version;
            *sdk = version->sdk;
            return true;
        }
        if (command->cmd == LC_BUILD_VERSION) {
            const struct build_version_command *build = (const struct build_version_command *)command;
            *platform = build->platform;
            *minos = build->minos;
            *sdk = build->sdk;
            return true;
        }
        cursor += command->cmdsize;
    }
    return false;
}

/* Is `have` (a version of `platform`) at least `want`? A query about a platform the image was not
 * built for cannot be satisfied, which is also what dyld answers. */
static bool wk_version_at_least(uint32_t platform, uint32_t have, dyld_build_version_t want)
{
    if (want.platform == WK_VERSION_SET) {
        if (platform != WK_PLATFORM_MACOS)
            return false;
        uint32_t mapped = wk_macos_version_for_version_set(want.version);
        return mapped != WK_VERSION_NONE && have >= mapped;
    }
    if (want.platform != platform)
        return false;
    return have >= want.version;
}

/* 10.9's libdyld accessors for the main executable's SDK and deployment target. */
extern uint32_t dyld_get_program_sdk_version(void);
extern uint32_t dyld_get_program_min_os_version(void);

bool dyld_program_sdk_at_least(dyld_build_version_t version)
{
    return wk_version_at_least(WK_PLATFORM_MACOS, dyld_get_program_sdk_version(), version);
}

bool dyld_program_minos_at_least(dyld_build_version_t version)
{
    return wk_version_at_least(WK_PLATFORM_MACOS, dyld_get_program_min_os_version(), version);
}

bool dyld_sdk_at_least(const struct mach_header *header, dyld_build_version_t version)
{
    uint32_t platform = 0, minos = 0, sdk = 0;
    if (!wk_image_build_versions(header, &platform, &minos, &sdk))
        return false;
    (void)minos;
    return wk_version_at_least(platform, sdk, version);
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(dyld_program_sdk_at_least, NULL, &dyld_program_sdk_at_least, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(dyld_program_minos_at_least, NULL, &dyld_program_minos_at_least, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(dyld_sdk_at_least, NULL, &dyld_sdk_at_least, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
