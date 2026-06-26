/*
 * MAVERICKS_BACKPORT debugging tool (#43 keystone): in-process x86-64 hardware watchpoint.
 * See HardwareWatchpoint.h for rationale. Debug-only; armed only when WK_WATCHPOINT=1.
 */

#include "config.h"
#include "HardwareWatchpoint.h"

#if PLATFORM(MAC) && CPU(X86_64)

#include <atomic>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

namespace WTF {

static constexpr int kMaxWatch = 4;

static std::atomic<bool> g_enabled { false };
static std::atomic<bool> g_enabledResolved { false };
static const void* g_addrs[kMaxWatch] = { nullptr, nullptr, nullptr, nullptr };
static const char* g_labels[kMaxWatch] = { nullptr, nullptr, nullptr, nullptr };
static std::atomic<int> g_count { 0 };
static std::atomic<bool> g_handlerInstalled { false };
static std::atomic<bool> g_monitorStarted { false };

bool hardwareWatchpointEnabled()
{
    if (!g_enabledResolved.load(std::memory_order_acquire)) {
        const char* v = ::getenv("WK_WATCHPOINT");
        g_enabled.store(v && v[0] == '1', std::memory_order_relaxed);
        g_enabledResolved.store(true, std::memory_order_release);
    }
    return g_enabled.load(std::memory_order_relaxed);
}

// ---- async-signal-safe logging helpers ----
static void safeAppendHex(char* buf, int& len, int cap, unsigned long long v)
{
    char tmp[18];
    int t = 0;
    if (!v)
        tmp[t++] = '0';
    while (v && t < 16) {
        int d = v & 0xf;
        tmp[t++] = d < 10 ? char('0' + d) : char('a' + d - 10);
        v >>= 4;
    }
    if (len + t + 2 >= cap)
        return;
    buf[len++] = '0';
    buf[len++] = 'x';
    while (t > 0)
        buf[len++] = tmp[--t];
}

static void safeAppendStr(char* buf, int& len, int cap, const char* s)
{
    while (s && *s && len < cap - 1)
        buf[len++] = *s++;
}

// Compute the DR7 enable word for g_count watchpoints (8-byte write watchpoints).
static unsigned long long computeDR7(int count)
{
    unsigned long long dr7 = 0;
    for (int i = 0; i < count; ++i) {
        dr7 |= (1ull << (2 * i));        // Li: local enable
        dr7 |= (1ull << (2 * i + 1));    // Gi: global enable
        dr7 |= (1ull << (16 + 4 * i));   // R/Wi = 01 (write)
        dr7 |= (1ull << (19 + 4 * i));   // LENi = 10 (8 bytes)
    }
    return dr7;
}

static void armThread(thread_act_t thread, int count, unsigned long long dr7)
{
    x86_debug_state64_t ds;
    mach_msg_type_number_t cnt = x86_DEBUG_STATE64_COUNT;
    if (thread_get_state(thread, x86_DEBUG_STATE64, (thread_state_t)&ds, &cnt) != KERN_SUCCESS)
        return;
    ds.__dr0 = count > 0 ? (uint64_t)(uintptr_t)g_addrs[0] : 0;
    ds.__dr1 = count > 1 ? (uint64_t)(uintptr_t)g_addrs[1] : 0;
    ds.__dr2 = count > 2 ? (uint64_t)(uintptr_t)g_addrs[2] : 0;
    ds.__dr3 = count > 3 ? (uint64_t)(uintptr_t)g_addrs[3] : 0;
    ds.__dr6 = 0; // clear status bits
    ds.__dr7 = dr7;
    thread_set_state(thread, x86_DEBUG_STATE64, (thread_state_t)&ds, x86_DEBUG_STATE64_COUNT);
}

static void armAllThreads()
{
    int count = g_count.load(std::memory_order_acquire);
    if (!count)
        return;
    unsigned long long dr7 = computeDR7(count);
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS)
        return;
    for (mach_msg_type_number_t i = 0; i < n; ++i) {
        armThread(threads[i], count, dr7);
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_act_t));
}

static void* monitorMain(void*)
{
    // Re-arm debug registers on all threads, including ones spawned after arming
    // (GCD worker threads on the IPC receive queue / Storage.persistent queue).
    for (;;) {
        armAllThreads();
        usleep(10 * 1000); // 10ms
    }
    return nullptr;
}

static void watchpointSignalHandler(int, siginfo_t*, void* uapVoid)
{
    auto* uap = static_cast<ucontext_t*>(uapVoid);
    unsigned long long rip = 0, rbp = 0;
    if (uap && uap->uc_mcontext) {
        rip = uap->uc_mcontext->__ss.__rip;
        rbp = uap->uc_mcontext->__ss.__rbp;
    }

    char buf[1400];
    int len = 0;
    safeAppendStr(buf, len, sizeof(buf), "WATCHPOINT-HIT pid=");
    safeAppendHex(buf, len, sizeof(buf), (unsigned long long)::getpid());
    safeAppendStr(buf, len, sizeof(buf), " rip=");
    safeAppendHex(buf, len, sizeof(buf), rip);
    // Log the current values at each watched address so we can see which one took 0xfffffffe.
    for (int i = 0, c = g_count.load(std::memory_order_relaxed); i < c; ++i) {
        safeAppendStr(buf, len, sizeof(buf), " [");
        safeAppendStr(buf, len, sizeof(buf), g_labels[i] ? g_labels[i] : "?");
        safeAppendStr(buf, len, sizeof(buf), "@");
        safeAppendHex(buf, len, sizeof(buf), (unsigned long long)(uintptr_t)g_addrs[i]);
        safeAppendStr(buf, len, sizeof(buf), "=");
        safeAppendHex(buf, len, sizeof(buf), g_addrs[i] ? *(const volatile unsigned long long*)g_addrs[i] : 0);
        safeAppendStr(buf, len, sizeof(buf), "]");
    }
    safeAppendStr(buf, len, sizeof(buf), " frames=");
    safeAppendHex(buf, len, sizeof(buf), rip);
    safeAppendStr(buf, len, sizeof(buf), " ");
    // Walk the frame-pointer chain. Guard each dereference against obviously-bad pointers.
    unsigned long long fp = rbp;
    for (int i = 0; i < 28 && fp; ++i) {
        if (fp & 0x7)
            break;
        unsigned long long ret = *(const volatile unsigned long long*)(fp + 8);
        unsigned long long next = *(const volatile unsigned long long*)(fp);
        if (!ret)
            break;
        safeAppendHex(buf, len, sizeof(buf), ret);
        safeAppendStr(buf, len, sizeof(buf), " ");
        if (next <= fp) // frame pointers grow downward (toward higher addresses on the stack)
            break;
        fp = next;
    }
    buf[len++] = '\n';

    int fd = ::open("/tmp/wk_watchpoint.log", O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        (void)::write(fd, buf, (size_t)len);
        ::close(fd);
    }
    // Data watchpoints are post-instruction traps; returning resumes at the next instruction.
    // DR6 status bits are cleared by the monitor thread on its next pass.
}

void armHardwareWatchpoint(const void* address, const char* label)
{
    if (!hardwareWatchpointEnabled() || !address)
        return;

    // Install the SIGTRAP handler once. Hardware-watchpoint #DB is delivered as SIGTRAP
    // when no Mach debugger is attached.
    if (!g_handlerInstalled.exchange(true)) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = watchpointSignalHandler;
        sa.sa_flags = SA_SIGINFO | SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGTRAP, &sa, nullptr);
    }

    // Register the address (up to kMaxWatch).
    int slot = g_count.load(std::memory_order_acquire);
    if (slot >= kMaxWatch)
        return;
    // Avoid duplicates.
    for (int i = 0; i < slot; ++i) {
        if (g_addrs[i] == address)
            return;
    }
    g_addrs[slot] = address;
    g_labels[slot] = label;
    g_count.store(slot + 1, std::memory_order_release);

    armAllThreads();

    if (!g_monitorStarted.exchange(true)) {
        pthread_t t;
        pthread_create(&t, nullptr, monitorMain, nullptr);
        pthread_detach(t);
    }

    {
        char msg[160];
        int len = 0;
        safeAppendStr(msg, len, sizeof(msg), "WATCHPOINT-ARMED ");
        safeAppendStr(msg, len, sizeof(msg), label ? label : "?");
        safeAppendStr(msg, len, sizeof(msg), " @");
        safeAppendHex(msg, len, sizeof(msg), (unsigned long long)(uintptr_t)address);
        msg[len++] = '\n';
        int fd = ::open("/tmp/wk_watchpoint.log", O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            (void)::write(fd, msg, (size_t)len);
            ::close(fd);
        }
    }
}

} // namespace WTF

#endif // PLATFORM(MAC) && CPU(X86_64)
