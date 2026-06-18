/*
 * kIOMainPortDefault (added macOS 12, replaces kIOMasterPortDefault) --
 * custom polyfill (not from macports-legacy-support).
 *
 * Both are MACH_PORT_NULL (0).
 */

#include <mach/mach_port.h>

const mach_port_t kIOMainPortDefault = 0;
