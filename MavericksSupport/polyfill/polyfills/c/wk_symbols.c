// Resolve native archive writers from the loaded system image.
#include "wk_symbols.h"

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syslog.h>

void wk_patch_fail(const char *what, const char *reason)
{
    syslog(LOG_ERR, "[wk_polyfill] FATAL: %s: %s.", what, reason);
    fprintf(stderr, "[wk_polyfill] FATAL: %s: %s.\n", what, reason);
    fflush(stderr);
    abort();
}

bool wk_find_image(const char *pathSuffix, wk_image *image)
{
    size_t suffixLength = strlen(pathSuffix);
    for (uint32_t i = 0, count = _dyld_image_count(); i < count; ++i) {
        const char *path = _dyld_get_image_name(i);
        if (!path)
            continue;
        size_t length = strlen(path);
        if (length < suffixLength || strcmp(path + length - suffixLength, pathSuffix))
            continue;
        image->index = i;
        image->path = path;
        image->slide = _dyld_get_image_vmaddr_slide(i);
        return true;
    }
    return false;
}

// __LINKEDIT is mapped at its vmaddr plus the slide, and the symbol and string tables are recorded as
// offsets into the file, so the table addresses are that mapping less __LINKEDIT's own file offset.
struct wk_symtab {
    const struct nlist_64 *symbols;
    uint32_t count;
    const char *strings;
};

static bool wk_symtab_of(const wk_image *image, struct wk_symtab *table)
{
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(image->index);
    if (!header || header->magic != MH_MAGIC_64)
        return false;

    const struct load_command *command = (const struct load_command *)(header + 1);
    const struct symtab_command *symtab = NULL;
    uint64_t linkeditVMAddress = 0, linkeditFileOffset = 0;
    bool foundLinkedit = false;

    for (uint32_t i = 0; i < header->ncmds; ++i) {
        if (command->cmd == LC_SYMTAB)
            symtab = (const struct symtab_command *)command;
        else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (!strcmp(segment->segname, SEG_LINKEDIT)) {
                linkeditVMAddress = segment->vmaddr;
                linkeditFileOffset = segment->fileoff;
                foundLinkedit = true;
            }
        }
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }
    if (!symtab || !foundLinkedit)
        return false;

    const uint8_t *linkedit = (const uint8_t *)(uintptr_t)(linkeditVMAddress + image->slide - linkeditFileOffset);
    table->symbols = (const struct nlist_64 *)(linkedit + symtab->symoff);
    table->count = symtab->nsyms;
    table->strings = (const char *)(linkedit + symtab->stroff);
    return true;
}

void *wk_symbol_in_image(const wk_image *image, const char *name)
{
    struct wk_symtab table;
    if (!wk_symtab_of(image, &table))
        return NULL;
    for (uint32_t i = 0; i < table.count; ++i) {
        if (!table.symbols[i].n_un.n_strx || (table.symbols[i].n_type & N_TYPE) != N_SECT)
            continue;
        if (strcmp(table.strings + table.symbols[i].n_un.n_strx, name))
            continue;
        return (void *)(uintptr_t)(table.symbols[i].n_value + image->slide);
    }
    return NULL;
}

