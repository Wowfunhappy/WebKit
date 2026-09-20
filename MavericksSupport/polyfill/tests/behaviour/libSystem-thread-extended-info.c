// thread_info(THREAD_EXTENDED_INFO), which this kernel answers with KERN_INVALID_ARGUMENT and the
// layer fills from proc_pidinfo(PROC_PIDTHREADINFO). The probe names a thread through
// pthread_setname_np and requires the replacement to report that name, a run state and priorities;
// it also requires 10.9's own thread_info to keep refusing the flavor, so the gate fails if the
// premise ever stops holding, and it requires another flavor and an undersized request to pass
// through untouched. The probe links the shipped archive the way WebKit does, so it exercises the
// definitions WebKit will bind.
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <mach/thread_info.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    fflush(stdout);
    if (!ok)
        failures++;
}

static const char *probeThreadName = "WKExtendedInfoProbe";
static volatile int probeThreadReady;
static volatile int probeThreadStop;
static mach_port_t probeThreadPort;

static void *probeThread(void *unused)
{
    (void)unused;
    pthread_setname_np(probeThreadName);
    probeThreadPort = mach_thread_self();
    probeThreadReady = 1;
    while (!probeThreadStop)
        usleep(1000);
    return NULL;
}

int main(void)
{
    pthread_t thread;
    if (pthread_create(&thread, NULL, probeThread, NULL)) {
        printf("thread_info probe: could not create the probe thread\n");
        return 1;
    }
    while (!probeThreadReady)
        usleep(1000);

    // 1. 10.9's own thread_info still refuses the flavor: without that, the replacement has nothing
    //    to supply and this probe would pass on the kernel's answer rather than on the layer's.
    void *libsystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
    kern_return_t (*systemThreadInfo)(thread_inspect_t, thread_flavor_t, thread_info_t, mach_msg_type_number_t *) =
        libsystem ? dlsym(libsystem, "thread_info") : NULL;
    check(systemThreadInfo != NULL, "10.9's thread_info is reachable for comparison");
    check(systemThreadInfo != (void *)thread_info, "the linked thread_info is the archive's");
    if (systemThreadInfo) {
        thread_extended_info_data_t bare;
        mach_msg_type_number_t bareCount = THREAD_EXTENDED_INFO_COUNT;
        kern_return_t bareResult = systemThreadInfo(probeThreadPort, THREAD_EXTENDED_INFO, (thread_info_t)&bare, &bareCount);
        check(bareResult != KERN_SUCCESS, "10.9's own thread_info refuses THREAD_EXTENDED_INFO");
    }

    // 2. The replacement answers the flavor with the thread's own name and state.
    thread_extended_info_data_t extended;
    memset(&extended, 0xAA, sizeof(extended));
    mach_msg_type_number_t extendedCount = THREAD_EXTENDED_INFO_COUNT;
    kern_return_t kr = thread_info(probeThreadPort, THREAD_EXTENDED_INFO, (thread_info_t)&extended, &extendedCount);
    check(kr == KERN_SUCCESS, "thread_info(THREAD_EXTENDED_INFO) succeeds");
    check(extendedCount == THREAD_EXTENDED_INFO_COUNT, "the reply length is the flavor's");
    check(!strcmp(extended.pth_name, probeThreadName), "the reply carries the thread's pthread name");
    check(extended.pth_run_state > 0, "the reply carries a run state");
    check(extended.pth_maxpriority > 0, "the reply carries the thread's priorities");

    // 3. A request too small for the flavor is left as the kernel answered it.
    thread_extended_info_data_t narrow;
    mach_msg_type_number_t narrowCount = THREAD_EXTENDED_INFO_COUNT - 1;
    kr = thread_info(probeThreadPort, THREAD_EXTENDED_INFO, (thread_info_t)&narrow, &narrowCount);
    check(kr != KERN_SUCCESS, "an undersized request keeps the kernel's refusal");

    // 4. Another flavor passes through.
    thread_basic_info_data_t basic;
    mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
    kr = thread_info(probeThreadPort, THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount);
    check(kr == KERN_SUCCESS, "THREAD_BASIC_INFO passes through");

    probeThreadStop = 1;
    pthread_join(thread, NULL);

    if (failures)
        printf("thread_info probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}
