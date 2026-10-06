// WebCore's SharedMemoryHandle::createVMShare/createVMCopy share a span by making a Mach memory entry
// with MAP_MEM_USE_DATA_ADDR, and SharedMemory::map recovers the span's own address by passing
// VM_FLAGS_RETURN_DATA_ADDR to mach_vm_map. This kernel takes the first flag and refuses the second,
// so a span that does not begin on a page boundary cannot be addressed through an entry at all and
// SharedMemoryCocoa.mm copies it into a page-aligned region instead. Both halves of that are premises
// of the code, so both are asserted here: a page-aligned span must round-trip byte-exact, and an
// unaligned one must be refused rather than answer with the wrong bytes.
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

// Returns: 0 mapped and byte-exact, 1 mapped but wrong bytes, 2 mach_vm_map refused, 3 entry refused.
static int roundTrip(unsigned char *base, size_t skew, size_t length, unsigned long long shareFlag)
{
    unsigned char *data = base + skew;
    memory_object_size_t entrySize = length;
    mach_port_t port = MACH_PORT_NULL;
    if (mach_make_memory_entry_64(mach_task_self(), &entrySize, (memory_object_offset_t)(uintptr_t)data,
            VM_PROT_READ | VM_PROT_IS_MASK | shareFlag | MAP_MEM_USE_DATA_ADDR, &port, MACH_PORT_NULL) != KERN_SUCCESS)
        return 3;

    mach_vm_address_t mapped = 0;
    kern_return_t kr = mach_vm_map(mach_task_self(), &mapped, entrySize, 0,
        VM_FLAGS_ANYWHERE | VM_FLAGS_RETURN_DATA_ADDR, port, 0, FALSE,
        VM_PROT_READ, VM_PROT_READ, VM_INHERIT_NONE);
    mach_port_deallocate(mach_task_self(), port);
    if (kr != KERN_SUCCESS)
        return 2;

    int exact = memcmp((const void *)(uintptr_t)mapped, data, length) == 0;
    mach_vm_deallocate(mach_task_self(), mapped, entrySize);
    return exact ? 0 : 1;
}

int main(void)
{
    const size_t region = 256 * 1024;
    mach_vm_address_t address = 0;
    if (mach_vm_allocate(mach_task_self(), &address, region, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) {
        printf("  could not allocate the probe region                              FAIL\n");
        return 1;
    }
    unsigned char *base = (unsigned char *)(uintptr_t)address;
    for (size_t i = 0; i < region; i++)
        base[i] = (unsigned char)(i * 31 + 7);

    const size_t lengths[] = { 100, 4096, 8192, 100000 };
    const size_t skews[] = { 1, 8, 64, 3000, 4095 };
    const unsigned long long shareFlags[] = { MAP_MEM_VM_SHARE, MAP_MEM_VM_COPY };
    const char *shareNames[] = { "MAP_MEM_VM_SHARE", "MAP_MEM_VM_COPY" };

    for (unsigned s = 0; s < 2; s++) {
        char what[128];
        int allExact = 1, allRefused = 1;
        for (unsigned l = 0; l < sizeof(lengths) / sizeof(lengths[0]); l++) {
            if (roundTrip(base, 0, lengths[l], shareFlags[s]) != 0)
                allExact = 0;
            for (unsigned k = 0; k < sizeof(skews) / sizeof(skews[0]); k++) {
                if (roundTrip(base, skews[k], lengths[l], shareFlags[s]) != 2)
                    allRefused = 0;
            }
        }
        snprintf(what, sizeof(what), "%s: a page-aligned span round-trips byte-exact", shareNames[s]);
        check(allExact, what);
        snprintf(what, sizeof(what), "%s: an unaligned span is refused, never mapped wrong", shareNames[s]);
        check(allRefused, what);
    }

    mach_vm_deallocate(mach_task_self(), address, region);
    if (failures)
        printf("Mach memory-entry data-address probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
