// os_unfair_lock (polyfills/shared/os_unfair_lock.c): the shipped archive's definition keeps the
// 10.12 lock-word layout (the owner's mach thread port, zero when free), excludes under contention,
// and crashes on the misuse libplatform's crashes on. The probe links libpolyfill.a the way WebKit
// does and calls the symbols as WTF::UnfairLock and libpas's pas_lock do.
#include <os/lock.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

// os_unfair_lock and its operations are 10.12+ in the SDK and absent on the 10.9 runtime;
// supplying them is what this probe checks, so every use below is the layer's own.
#pragma clang diagnostic ignored "-Wunguarded-availability"

// <os/lock_private.h>, which libpas calls with OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION | ADAPTIVE_SPIN.
extern void os_unfair_lock_lock_with_options(os_unfair_lock_t lock, uint32_t options);
#define OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION 0x00010000
#define OS_UNFAIR_LOCK_ADAPTIVE_SPIN 0x00040000

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-72s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static uint32_t word(const os_unfair_lock *lock)
{
    return __atomic_load_n((const uint32_t *)lock, __ATOMIC_SEQ_CST);
}

static os_unfair_lock sharedLock = OS_UNFAIR_LOCK_INIT;
static uint64_t counter;
enum { threads = 8, iterations = 200000 };

static void *contendPlain(void *arg)
{
    (void)arg;
    for (int i = 0; i < iterations; i++) {
        os_unfair_lock_lock(&sharedLock);
        counter++;
        os_unfair_lock_unlock(&sharedLock);
    }
    return NULL;
}

static void *contendAdaptive(void *arg)
{
    (void)arg;
    for (int i = 0; i < iterations; i++) {
        os_unfair_lock_lock_with_options(&sharedLock, OS_UNFAIR_LOCK_DATA_SYNCHRONIZATION | OS_UNFAIR_LOCK_ADAPTIVE_SPIN);
        counter++;
        os_unfair_lock_unlock(&sharedLock);
    }
    return NULL;
}

static void runContended(void *(*body)(void *), const char *what)
{
    pthread_t tids[threads];
    counter = 0;
    for (int i = 0; i < threads; i++)
        pthread_create(&tids[i], NULL, body, NULL);
    for (int i = 0; i < threads; i++)
        pthread_join(tids[i], NULL);
    check(counter == (uint64_t)threads * iterations, what);
    check(word(&sharedLock) == 0, "the lock is free again afterwards");
}

static os_unfair_lock heldLock = OS_UNFAIR_LOCK_INIT;
static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gateChanged = PTHREAD_COND_INITIALIZER;
static int holderReady, holderRelease;

static void *holder(void *arg)
{
    (void)arg;
    os_unfair_lock_lock(&heldLock);
    pthread_mutex_lock(&gate);
    holderReady = 1;
    pthread_cond_broadcast(&gateChanged);
    while (!holderRelease)
        pthread_cond_wait(&gateChanged, &gate);
    pthread_mutex_unlock(&gate);
    os_unfair_lock_unlock(&heldLock);
    return NULL;
}

// Runs body in a child and reports how the child ended: 0 for a normal return, else the signal.
static int endsWith(void (*body)(void))
{
    pid_t pid = fork();
    if (pid == 0) {
        body();
        _exit(0);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}

static os_unfair_lock childLock = OS_UNFAIR_LOCK_INIT;
static void lockTwice(void) { os_unfair_lock_lock(&childLock); os_unfair_lock_lock(&childLock); }
static void unlockFree(void) { os_unfair_lock_unlock(&childLock); }
static void *unlockFromOtherThread(void *arg) { (void)arg; os_unfair_lock_unlock(&childLock); return NULL; }
static void unlockElsewhere(void)
{
    pthread_t tid;
    os_unfair_lock_lock(&childLock);
    pthread_create(&tid, NULL, unlockFromOtherThread, NULL);
    pthread_join(tid, NULL);
}
static void assertOwnerOfFree(void) { os_unfair_lock_assert_owner(&childLock); }
static void assertNotOwnerWhileOwning(void) { os_unfair_lock_lock(&childLock); os_unfair_lock_assert_not_owner(&childLock); }
static void ownedAssertsPass(void)
{
    os_unfair_lock_assert_not_owner(&childLock);
    os_unfair_lock_lock(&childLock);
    os_unfair_lock_assert_owner(&childLock);
    os_unfair_lock_unlock(&childLock);
    os_unfair_lock_assert_not_owner(&childLock);
}

int main(void)
{
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    uint32_t self = pthread_mach_thread_np(pthread_self());
    check(word(&lock) == 0, "OS_UNFAIR_LOCK_INIT is the zero word");
    os_unfair_lock_lock(&lock);
    check(word(&lock) == self, "a held lock's word is the owner's mach thread port");
    check(!os_unfair_lock_trylock(&lock), "trylock fails on a held lock");
    os_unfair_lock_unlock(&lock);
    check(word(&lock) == 0, "unlock clears the word");
    check(os_unfair_lock_trylock(&lock), "trylock takes a free lock");
    check(word(&lock) == self, "trylock records the owner");
    os_unfair_lock_unlock(&lock);
    os_unfair_lock_lock_with_flags(&lock, OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN);
    check(word(&lock) == self, "lock_with_flags records the owner");
    os_unfair_lock_unlock(&lock);

    pthread_t tid;
    pthread_create(&tid, NULL, holder, NULL);
    pthread_mutex_lock(&gate);
    while (!holderReady)
        pthread_cond_wait(&gateChanged, &gate);
    pthread_mutex_unlock(&gate);
    check(word(&heldLock) != 0 && word(&heldLock) != self, "another thread's hold shows that thread as owner");
    check(!os_unfair_lock_trylock(&heldLock), "trylock fails on another thread's lock");
    pthread_mutex_lock(&gate);
    holderRelease = 1;
    pthread_cond_broadcast(&gateChanged);
    pthread_mutex_unlock(&gate);
    os_unfair_lock_lock(&heldLock);
    check(word(&heldLock) == self, "a waiter acquires once the holder unlocks");
    os_unfair_lock_unlock(&heldLock);
    pthread_join(tid, NULL);

    runContended(contendPlain, "8 threads x 200k: every increment under os_unfair_lock_lock is counted");
    runContended(contendAdaptive, "8 threads x 200k: every increment under lock_with_options(ADAPTIVE_SPIN) is counted");

    check(endsWith(ownedAssertsPass) == 0, "assert_owner on a held lock and assert_not_owner on a free one return");
    check(endsWith(lockTwice) == SIGILL, "a recursive lock traps");
    check(endsWith(unlockFree) == SIGILL, "unlocking a free lock traps");
    check(endsWith(unlockElsewhere) == SIGILL, "unlocking another thread's lock traps");
    check(endsWith(assertOwnerOfFree) == SIGILL, "assert_owner on a free lock traps");
    check(endsWith(assertNotOwnerWhileOwning) == SIGILL, "assert_not_owner on a held lock traps");

    if (failures)
        printf("os_unfair_lock probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
