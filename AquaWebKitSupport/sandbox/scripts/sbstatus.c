/*
 * sbstatus -- ask the kernel whether a running process is confined, and what its sandbox denies.
 *
 * A profile that fails to apply is not always loud: the point of this tool is that "Safari still
 * works" is not evidence the child processes are sandboxed. sandbox_check() asks the kernel about
 * a live pid, so it cannot be fooled by a profile that was compiled but never applied.
 *
 *   sbstatus <webcontent|networking|gpu|webpushd> <pid> [<pid> ...]
 *
 * Prints, per pid: whether it is in a sandbox at all, then probes that the named process's profile
 * must DENY. Exits nonzero if any pid is unconfined, cannot be queried, or fails a probe.
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

enum { ALL = 0xf, WEBCONTENT = 1, NETWORKING = 2, GPU = 4, WEBPUSHD = 8 };

/* Each probe names an operation the listed profiles deny. A path beginning with "~" is relative to
   $HOME. */
static const struct {
    unsigned kinds;
    const char *operation;
    enum sandbox_filter_type filter;
    const char *argument;
} deniedProbes[] = {
    { ALL, "file-write-data", SANDBOX_FILTER_PATH, "/Users" },
    { ALL, "file-read-data", SANDBOX_FILTER_PATH, "/private/etc/sudoers" },
    { ALL, "file-write-create", SANDBOX_FILTER_PATH, "/private/tmp/webkit-sandbox-probe" },
    { ALL, "process-info-listpids", SANDBOX_FILTER_NONE, NULL },
    { WEBCONTENT | GPU | WEBPUSHD, "file-write-data", SANDBOX_FILTER_PATH, "~/Library/Keychains/login.keychain" },
    { NETWORKING, "file-write-data", SANDBOX_FILTER_PATH, "/private/var/db/mds/system/mdsObject.db" },
    { WEBCONTENT | GPU | WEBPUSHD, "file-read-data", SANDBOX_FILTER_PATH, "~/Library/Keychains/login.keychain" },
    { WEBCONTENT, "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME, "com.apple.SystemConfiguration.SCNetworkReachability" },
    { WEBCONTENT, "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME, "com.apple.GSSCred" },
    { WEBCONTENT, "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME, "com.apple.cookied" },
    { WEBCONTENT, "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME, "com.apple.dock.server" },
    { WEBCONTENT, "file-write-data", SANDBOX_FILTER_PATH, "~/Library/Preferences/com.apple.mediaaccessibility.public.plist" },
    { WEBCONTENT | GPU, "file-read-data", SANDBOX_FILTER_PATH, "/Library/QuickTime" },
    { GPU | WEBPUSHD, "file-read-data", SANDBOX_FILTER_PATH, "/Library/Frameworks" },
    { WEBPUSHD, "mach-lookup", SANDBOX_FILTER_GLOBAL_NAME, "com.apple.cookied" },
};

static unsigned kindNamed(const char *name)
{
    if (!strcmp(name, "webcontent"))
        return WEBCONTENT;
    if (!strcmp(name, "networking"))
        return NETWORKING;
    if (!strcmp(name, "gpu"))
        return GPU;
    if (!strcmp(name, "webpushd"))
        return WEBPUSHD;
    return 0;
}

int main(int argc, char **argv)
{
    unsigned kind = argc > 2 ? kindNamed(argv[1]) : 0;
    if (!kind) {
        fprintf(stderr, "usage: %s <webcontent|networking|gpu|webpushd> <pid> [<pid> ...]\n", argv[0]);
        return 2;
    }

    const char *home = getenv("HOME");
    int failures = 0;
    for (int i = 2; i < argc; ++i) {
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
            if (!(deniedProbes[p].kinds & kind))
                continue;
            char argument[1024] = "";
            if (deniedProbes[p].argument && deniedProbes[p].argument[0] == '~')
                snprintf(argument, sizeof(argument), "%s%s", home ? home : "", deniedProbes[p].argument + 1);
            else if (deniedProbes[p].argument)
                snprintf(argument, sizeof(argument), "%s", deniedProbes[p].argument);
            int result = deniedProbes[p].argument
                ? sandbox_check(pid, deniedProbes[p].operation, deniedProbes[p].filter | SANDBOX_CHECK_NO_REPORT, argument)
                : sandbox_check(pid, deniedProbes[p].operation, SANDBOX_FILTER_NONE | SANDBOX_CHECK_NO_REPORT);
            const char *verdict = result > 0 ? "denied (expected)" : result < 0 ? "ERROR -- the check itself failed" : "PERMITTED -- the profile must deny this";
            printf("    %-22s %-60s %s\n", deniedProbes[p].operation, argument, verdict);
            if (result <= 0)
                failures++;
        }
    }

    return failures ? 1 : 0;
}
