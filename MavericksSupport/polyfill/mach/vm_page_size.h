#ifndef _MACH_VM_PAGE_SIZE_H_
#define _MACH_VM_PAGE_SIZE_H_

#include <mach/mach_init.h>
#include <mach/vm_types.h>

/* vm_page_size and vm_page_shift are declared in mach_init.h on older macOS */

#ifndef vm_kernel_page_size
#define vm_kernel_page_size vm_page_size
#endif

#ifndef vm_kernel_page_shift
#define vm_kernel_page_shift vm_page_shift
#endif

#ifndef vm_kernel_page_mask
#define vm_kernel_page_mask (vm_kernel_page_size - 1)
#endif

#endif /* _MACH_VM_PAGE_SIZE_H_ */
