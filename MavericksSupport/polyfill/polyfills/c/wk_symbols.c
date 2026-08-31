// See wk_symbols.h. Approval is per use; nothing here is a general tool.
#include "wk_symbols.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syslog.h>
#include <unistd.h>

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

// A vtable's extent is not recorded anywhere, so it ends where the next symbol of the image begins.
// The scan starts past the offset-to-top and typeinfo words the vtable symbol addresses, which is
// where the function pointers start.
static bool wk_vtable_extent(const wk_image *image, const char *vtableSymbol, void ***first, void ***last)
{
    struct wk_symtab table;
    if (!wk_symtab_of(image, &table))
        return false;

    uint64_t vtable = 0;
    bool found = false;
    for (uint32_t i = 0; i < table.count && !found; ++i) {
        if (!table.symbols[i].n_un.n_strx || (table.symbols[i].n_type & N_TYPE) != N_SECT)
            continue;
        if (!strcmp(table.strings + table.symbols[i].n_un.n_strx, vtableSymbol)) {
            vtable = table.symbols[i].n_value;
            found = true;
        }
    }
    if (!found)
        return false;

    uint64_t next = 0;
    for (uint32_t i = 0; i < table.count; ++i) {
        if (!table.symbols[i].n_un.n_strx || (table.symbols[i].n_type & N_TYPE) != N_SECT)
            continue;
        uint64_t value = table.symbols[i].n_value;
        if (value > vtable && (!next || value < next))
            next = value;
    }
    if (!next || next - vtable < 3 * sizeof(void *))
        return false;

    *first = (void **)(uintptr_t)(vtable + 2 * sizeof(void *) + image->slide);
    *last = (void **)(uintptr_t)(next + image->slide);
    return true;
}

// Whether |address| lies in a WebKit image this layer is linked into. wk_image_marker.c puts the
// __DATA,__wk_marker section in each of them, and a CFNetwork vtable slot pointing at one is a
// sibling copy of the patch below having already run.
static bool wk_address_is_in_polyfilled_image(const void *address)
{
    Dl_info info;
    if (!address || !dladdr(address, &info) || !info.dli_fbase)
        return false;
    unsigned long size = 0;
    return getsectiondata((const struct mach_header_64 *)info.dli_fbase, "__DATA", "__wk_marker", &size) && size;
}

// The write: one pointer-sized store into a location the caller has already established holds what it
// expects, over however many pages that store spans, leaving the protection the region came with.
static void wk_store_pointer(const char *what, void **slot, const void *value)
{
    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0)
        wk_patch_fail(what, "sysconf(_SC_PAGESIZE) gave no page size to align the write to");

    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(pageSize - 1);
    size_t span = ((uintptr_t)slot + sizeof(*slot) > page + (uintptr_t)pageSize)
        ? (size_t)pageSize * 2 : (size_t)pageSize;

    vm_address_t region = (vm_address_t)page;
    vm_size_t regionSize = 0;
    struct vm_region_basic_info_64 info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &region, &regionSize, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &infoCount, &objectName) != KERN_SUCCESS
        || region > page)
        wk_patch_fail(what, "the protection of the page holding the location could not be read");
    if (objectName != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), objectName);

    if (mprotect((void *)page, span, PROT_READ | PROT_WRITE))
        wk_patch_fail(what, "the page holding the location could not be made writable");
    *slot = (void *)value;
    if (mprotect((void *)page, span, (int)info.protection))
        wk_patch_fail(what, "the page holding the location could not be given its protection back");
}

void wk_patch_pointer(const wk_pointer_patch *patch)
{
    if (patch->isInScope && !patch->isInScope())
        return;

    wk_image image;
    if (!wk_find_image(patch->imagePathSuffix, &image))
        wk_patch_fail(patch->what, "the image this patches is not loaded in this process");

    void **slot = (void **)wk_symbol_in_image(&image, patch->symbol);
    if (!slot)
        wk_patch_fail(patch->what, "the image's symbol table does not name the location this patches");

    // The value this patch writes is already there: a sibling framework's copy of this initializer.
    if (*slot == patch->replacement)
        return;

    if (patch->describes && !patch->describes(*slot))
        wk_patch_fail(patch->what, "the location does not hold what this patch is written against");

    wk_store_pointer(patch->what, slot, patch->replacement);
}

void *wk_patch_vtable_slot(const wk_vtable_patch *patch, bool *installed)
{
    *installed = false;
    if (patch->isInScope && !patch->isInScope())
        return NULL;

    wk_image image;
    if (!wk_find_image(patch->imagePathSuffix, &image))
        wk_patch_fail(patch->what, "the image this patches is not loaded in this process");

    void *original = wk_symbol_in_image(&image, patch->originalSymbol);
    if (!original)
        wk_patch_fail(patch->what, "the image's symbol table does not name the function this stands in for");

    void **first, **last;
    if (!wk_vtable_extent(&image, patch->vtableSymbol, &first, &last))
        wk_patch_fail(patch->what, "the image's symbol table does not name the vtable this patches");

    void **slot = NULL;
    for (void **entry = first; entry < last; ++entry) {
        if (*entry == original) {
            if (slot)
                wk_patch_fail(patch->what, "the vtable holds that function in more than one slot, so no one slot is the one this patches");
            slot = entry;
        }
    }

    if (!slot) {
        // The function this stands in for is no longer in the vtable. Another slot pointing into a
        // WebKit image is a sibling framework's copy of this patch having run first; anything else is
        // a CFNetwork this patch does not describe. The dladdr walk runs only on this no-slot path:
        // per slot of the common first-load pass it would be the dominant cost of the patch.
        bool siblingIsInThisVtable = false;
        for (void **entry = first; entry < last && !siblingIsInThisVtable; ++entry)
            siblingIsInThisVtable = *entry == patch->replacement || wk_address_is_in_polyfilled_image(*entry);
        if (!siblingIsInThisVtable)
            wk_patch_fail(patch->what, "the vtable does not hold the function this stands in for");
        return original;
    }

    wk_store_pointer(patch->what, slot, patch->replacement);
    *installed = true;
    return original;
}
