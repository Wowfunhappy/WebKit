/*
 * MAVERICKS_BACKPORT debugging tool (#43 keystone): in-process hardware watchpoint.
 *
 * Sets an x86-64 debug-register (DR0..DR3) write watchpoint on up to four addresses
 * across ALL current and future threads of this process, and logs the faulting thread's
 * backtrace whenever any of them is written. Built to catch the exact writer of the stray
 * 0xfffffffe store into an IPC::Connection's ThreadSafeWeakPtrControlBlock::m_word.
 *
 * Why this and not lldb: lldb-320 on this VM is flaky and Guard Malloc / DYLD injection
 * cannot reach the sandboxed XPC NetworkProcess. This is compiled directly into WTF, so it
 * runs inside the target process with no injection. Debug-register watchpoints are TRAPS
 * (reported after the store completes), delivered as SIGTRAP when no debugger is attached,
 * so a plain signal handler can log and continue with no single-step dance.
 *
 * Debug-only; gate calls behind an env var so production paths never arm it.
 */

#pragma once

#if PLATFORM(MAC) && CPU(X86_64)

#include <wtf/ExportMacros.h>

namespace WTF {

// Arm a write watchpoint on [address, address+8). Safe to call up to 4 times (DR0..DR3);
// further calls are ignored. No-op unless the env var WK_WATCHPOINT is set to 1.
WTF_EXPORT_PRIVATE void armHardwareWatchpoint(const void* address, const char* label);

// True if WK_WATCHPOINT=1 (so callers can skip computing the address otherwise).
WTF_EXPORT_PRIVATE bool hardwareWatchpointEnabled();

} // namespace WTF

#endif // PLATFORM(MAC) && CPU(X86_64)
