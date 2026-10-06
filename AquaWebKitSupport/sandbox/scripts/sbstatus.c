/*
 * sbstatus -- ask the kernel whether a running process is confined, and what its sandbox denies.
 *
 * A profile that fails to apply is not always loud: the point of this tool is that "Safari still
 * works" is not evidence the child processes are sandboxed. sandbox_check() asks the kernel about
 * a live pid, so it cannot be fooled by a profile that was compiled but never applied.
 *
 *   sbstatus <pid> [<pid> ...]
 *
 * Prints, per pid: whether it is in a sandbox at all, then a few probes that a correctly applied
 * WebKit profile must DENY. Exits nonzero if any pid is unconfined or fails a probe.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum sandbox_filter_type {
    SANDBOX_FILTER_NONE,
    SANDBOX_FILTER_PATH,
    SANDBOX_FILTER_GLOBAL_NAME,
    SANDBOX_FILTER_LOCAL_NAME,
    SANDBOX_FILTER_APPLEEVENT_DESTINATION,
    SANDBOX_FILTER_RIGHT_NAME,
};

extern const enum sandbox_filter_type SANDBOX_CHECK_NO_REPORT;
extern int sandbox_check(pid_t, const char *operation, enum sandbox_filter_type, ...);

/* Probes a correctly applied WebContent/Networking/GPU profile denies. Each is outside every path
   those profiles grant, so a "permitted" answer means the process is not really confined. */
static const struct {
    const char *operation;
    const char *path;
} deniedProbes[] = {
    { "file-write-data", "/Users" },
    { "file-read-data", "/private/etc/sudoers" },
    { "file-write-create", "/private/tmp/webkit-sandbox-probe" },
};

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <pid> [<pid> ...]\n", argv[0]);
        return 2;
    }

    int failures = 0;
    for (int i = 1; i < argc; ++i) {
        pid_t pid = (pid_t)atoi(argv[i]);
        if (pid <= 0) {
            fprintf(stderr, "not a pid: %s\n", argv[i]);
            failures++;
            continue;
        }

        int confined = sandbox_check(pid, NULL, SANDBOX_FILTER_NONE | SANDBOX_CHECK_NO_REPORT);
        if (confined < 0) {
            printf("pid %d: could not be queried (gone, or not permitted)\n", pid);
            failures++;
            continue;
        }
        printf("pid %d: %s\n", pid, confined ? "SANDBOXED" : "NOT SANDBOXED");
        if (!confined) {
            failures++;
            continue;
        }

        for (size_t p = 0; p < sizeof(deniedProbes) / sizeof(deniedProbes[0]); ++p) {
            int denied = sandbox_check(pid, deniedProbes[p].operation,
                SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT, deniedProbes[p].path);
            printf("    %-18s %-32s %s\n", deniedProbes[p].operation, deniedProbes[p].path,
                denied ? "denied (expected)" : "PERMITTED -- profile is not confining this");
            if (!denied)
                failures++;
        }
    }

    return failures ? 1 : 0;
}
