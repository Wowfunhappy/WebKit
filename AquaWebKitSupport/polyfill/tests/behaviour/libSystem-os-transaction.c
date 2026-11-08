// os_transaction_create (polyfills/c/libSystem.m) counts one launchd transaction for the handle's
// lifetime and leaves dirty tracking to launchd: in a process launchd did not start with
// EnableTransactions, taking and releasing a transaction leaves the process untracked.
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

extern void *os_transaction_create(const char *description);
extern size_t _vproc_transaction_count(void);
extern int proc_get_dirty(pid_t, uint32_t *);

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-66s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static uint32_t dirtyFlags(void)
{
    uint32_t flags = 0;
    proc_get_dirty(getpid(), &flags);
    return flags;
}

int main(void)
{
    size_t before = _vproc_transaction_count();
    void *transaction = os_transaction_create("org.aquawebkit.os-transaction-probe");
    check(transaction != NULL, "os_transaction_create returns a handle");
    check(_vproc_transaction_count() == before + 1, "the handle holds one launchd transaction");
    check(dirtyFlags() == 0, "a process outside launchd stays untracked while it holds one");
    dispatch_release((dispatch_queue_t)transaction);
    // libdispatch runs a queue's finalizer after its last release, off the releasing thread.
    for (int i = 0; i < 100 && _vproc_transaction_count() != before; i++)
        usleep(10000);
    check(_vproc_transaction_count() == before, "releasing the handle ends its transaction");
    check(dirtyFlags() == 0, "and the process is still untracked");
    if (failures)
        printf("os_transaction probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
