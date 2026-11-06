// host-exports <image>: prints each Mach-O symbol name read from stdin that this host already has: a
// name <image>'s polyfill registry (__DATA,__wk_pfmap) declares a replacement of, or one its provider
// exports here. The provider is the one the registry entry names, and libSystem for a name the
// registry does not hold, as for the libc gap-fills in shared/.
#include "wk_polyfill.h"

#include <dlfcn.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t *image;
static size_t imageSize;
static const struct mach_header_64 *header;

static const char *stringAt(uint64_t address)
{
    const uint8_t *command = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)load;
            if (address >= segment->vmaddr && address - segment->vmaddr < segment->filesize) {
                uint64_t offset = segment->fileoff + (address - segment->vmaddr);
                return offset < imageSize ? (const char *)image + offset : NULL;
            }
        }
        command += load->cmdsize;
    }
    return NULL;
}

static const struct wk_polyfill_entry *registry(size_t *count)
{
    const uint8_t *command = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)load;
            const struct section_64 *section = (const struct section_64 *)(segment + 1);
            for (uint32_t s = 0; s < segment->nsects; s++, section++) {
                if (!strncmp(section->segname, "__DATA", 16) && !strncmp(section->sectname, "__wk_pfmap", 16)) {
                    *count = section->size / sizeof(struct wk_polyfill_entry);
                    return (const struct wk_polyfill_entry *)(image + section->offset);
                }
            }
        }
        command += load->cmdsize;
    }
    *count = 0;
    return NULL;
}

static void *providerHandle(const char *provider)
{
    char path[1024];
    if (!provider)
        snprintf(path, sizeof(path), "/usr/lib/libSystem.B.dylib");
    else if (provider[0] == '/')
        snprintf(path, sizeof(path), "%s", provider);
    else
        snprintf(path, sizeof(path), "/System/Library/Frameworks/%s.framework/%s", provider, provider);
    return dlopen(path, RTLD_LAZY | RTLD_LOCAL);
}

int main(int argc, char **argv)
{
    FILE *file = argc == 2 ? fopen(argv[1], "rb") : NULL;
    if (!file) {
        fprintf(stderr, "usage: host-exports <image> < names\n");
        return 1;
    }
    fseek(file, 0, SEEK_END);
    imageSize = (size_t)ftell(file);
    rewind(file);
    uint8_t *bytes = malloc(imageSize);
    if (fread(bytes, 1, imageSize, file) != imageSize)
        return 1;
    fclose(file);
    image = bytes;
    header = (const struct mach_header_64 *)image;
    if (header->magic != MH_MAGIC_64) {
        fprintf(stderr, "host-exports: %s is not a 64-bit Mach-O image\n", argv[1]);
        return 1;
    }

    size_t entryCount;
    const struct wk_polyfill_entry *entries = registry(&entryCount);
    char line[4096];
    while (fgets(line, sizeof(line), stdin)) {
        line[strcspn(line, "\n")] = '\0';
        if (line[0] != '_')
            continue;
        const char *name = line + 1;
        const char *provider = NULL;
        int replaces = 0;
        for (size_t i = 0; i < entryCount; i++) {
            const char *entryName = stringAt((uint64_t)(uintptr_t)entries[i].name);
            if (entryName && !strcmp(entryName, name)) {
                provider = entries[i].provider ? stringAt((uint64_t)(uintptr_t)entries[i].provider) : NULL;
                replaces = entries[i].intent == WK_POLYFILL_REPLACES;
                break;
            }
        }
        void *handle = replaces ? NULL : providerHandle(provider);
        if (replaces || (handle && dlsym(handle, name)))
            puts(line);
    }
    return 0;
}
