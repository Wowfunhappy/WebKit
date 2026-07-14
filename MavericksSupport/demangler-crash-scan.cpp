// MAVERICKS_BACKPORT: worker for neutralize-demangler-crashers.py.
//
// Reads mangled names (one per line, passed verbatim to __cxa_demangle) and
// demangles every one with the HOST 10.9 libc++abi demangler, which heap-
// corrupts on certain modern-C++ manglings. Each batch runs in a fork()ed
// child so a demangler crash only kills a throwaway process; a dead batch is
// bisected down to the individual offending names, printed as
// "CRASHER <index> <name>" on stdout. A range that fails but whose halves
// both pass (the bug is layout-dependent and can fail to reproduce on
// re-run) is reported as "UNATTRIBUTED <lo> <hi>" instead of being silently
// dropped -- the orchestrator retries or aborts on those. Exits 0 with no
// CRASHER/UNATTRIBUTED lines iff a full pass over the input is clean.
//
// The orchestrator runs this under DYLD_INSERT_LIBRARIES with the freecheck
// interposer (traps wild free of unallocated pointers) plus Guard Malloc
// (traps heap overruns), both inherited across fork. Detection still cannot
// be fully deterministic -- the demangler bug reads uninitialized stack, so
// results depend on environment/stack layout; the orchestrator runs several
// varied-environment trials and generalizes hits to their template family.
//
// usage: demangler-crash-scan <symfile> <batchsize>
//        demangler-crash-scan --selftest-wildfree
//            frees a known-garbage pointer; must _exit(42) via the freecheck
//            interposer. Any other exit means detection is NOT live (e.g.
//            DYLD_INSERT_LIBRARIES silently failed) and the orchestrator
//            aborts rather than run a scan that cannot see crashers.
//        demangler-crash-scan --selftest-overrun
//            writes one byte past a malloc'd block; must fault on Guard
//            Malloc's guard page (exit 43 via the quiet-death handler),
//            else overrun detection is NOT live.
//
// freecheck and Guard Malloc are mutually exclusive per trial: with both
// inserted the worker floods "pointer being freed was not allocated" for
// ordinary startup frees and aborts before scanning (gmalloc's non-standard
// zone confuses the pointer-to-zone lookup the interposer and libmalloc
// rely on). The orchestrator inserts exactly one per trial.

#include <cxxabi.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static char **lines;
static size_t nlines;

// Exit status a child uses for "the demangler (or a detector) blew up here".
// Any nonzero child status counts as a crash signal to the parent.
#define CRASHED_EXIT 43

static void die_quietly(int)
{
    _exit(CRASHED_EXIT);
}

// Children die by design (that is the detection signal); ReportCrash hooks
// abnormal exits at the host level, so the only way to keep it from writing
// a .crash into DiagnosticReports for every bisection child is to catch the
// fatal signal and exit normally -- no signal death, no EXC_CRASH, no report.
static void suppress_crash_reporter(void)
{
    const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP,
                         SIGSYS };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++)
        signal(sigs[i], die_quietly);
}

static void load(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror("open"); exit(2); }
    size_t cap = 1 << 20;
    lines = (char **)malloc(cap * sizeof(char *));
    char *buf = NULL;
    size_t bufcap = 0;
    ssize_t len;
    while ((len = getline(&buf, &bufcap, f)) != -1) {
        while (len && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
            buf[--len] = 0;
        if (!len)
            continue;
        if (nlines == cap) {
            cap *= 2;
            lines = (char **)realloc(lines, cap * sizeof(char *));
        }
        lines[nlines++] = strdup(buf);
    }
    if (ferror(f)) { perror("getline"); exit(2); }
    free(buf);
    fclose(f);
}

// Demangle [lo,hi) in a fork()ed child; true iff the child exits cleanly.
static bool range_survives(size_t lo, size_t hi)
{
    pid_t pid = fork();
    if (pid == 0) {
        suppress_crash_reporter();
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0)
            dup2(devnull, 2); // silence malloc/gmalloc abort spam
        for (size_t i = lo; i < hi; i++) {
            int status = 0;
            char *r = abi::__cxa_demangle(lines[i], NULL, NULL, &status);
            free(r);
        }
        _exit(0);
    }
    int status;
    waitpid(pid, &status, 0);
    return status == 0;
}

// Returns the number of signals (CRASHER or UNATTRIBUTED lines) emitted for
// this range, so a failing parent range only reports UNATTRIBUTED when its
// entire subtree produced nothing.
static size_t report_crashers_in(size_t lo, size_t hi)
{
    if (lo >= hi || range_survives(lo, hi))
        return 0;
    if (hi - lo == 1) {
        printf("CRASHER %zu %s\n", lo, lines[lo]);
        fflush(stdout);
        return 1;
    }
    size_t mid = lo + (hi - lo) / 2;
    size_t n = report_crashers_in(lo, mid) + report_crashers_in(mid, hi);
    if (n == 0) {
        printf("UNATTRIBUTED %zu %zu\n", lo, hi);
        fflush(stdout);
        return 1;
    }
    return n;
}

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--selftest-wildfree")) {
        suppress_crash_reporter();
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0)
            dup2(devnull, 2);
        free((void *)0x6f43626557283c74); // interposer must _exit(42) here
        _exit(1); // free returned: wild-free detection is NOT live
    }
    if (argc == 2 && !strcmp(argv[1], "--selftest-overrun")) {
        suppress_crash_reporter();
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0)
            dup2(devnull, 2);
        // Guard Malloc puts each block at the end of its own page(s); the
        // first byte past a 16-aligned block is the guard page, so this
        // write must fault (exiting CRASHED_EXIT via die_quietly) when
        // gmalloc is live. Without gmalloc it lands in ordinary heap slack
        // and the write survives.
        volatile char *p = (volatile char *)malloc(16);
        p[16] = 1;
        _exit(1); // survived: overrun detection is NOT live
    }
    if (argc < 3) {
        fprintf(stderr, "usage: demangler-crash-scan <symfile> <batchsize>\n"
                        "       demangler-crash-scan --selftest-wildfree\n");
        return 2;
    }
    load(argv[1]);
    size_t batch = (size_t)atol(argv[2]);
    if (!batch)
        batch = nlines ? nlines : 1;
    for (size_t lo = 0; lo < nlines; lo += batch) {
        size_t hi = lo + batch;
        if (hi > nlines)
            hi = nlines;
        report_crashers_in(lo, hi);
    }
    return 0;
}
