// The atexit replacement (polyfills/c/libSystem.m): a function registered with it runs in strict LIFO order
// with __cxa_atexit entries at exit(), and a function whose code lives in a dlopen'd image runs when that
// image is unloaded and not again at exit, as 10.9's own atexit does. Built twice: as the probe (linked
// against libpolyfill.a the way WebKit is) and, with -DWK_ATEXIT_BUNDLE, as the unloadable image.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef WK_ATEXIT_BUNDLE

static void bundleHandler(void)
{
    fputs("D", stdout);
}

void wk_register_from_bundle(int (*registerFunction)(void (*)(void)))
{
    registerFunction(bundleHandler);
}

#else

extern int __cxa_atexit(void (*)(void *), void *, void *);
extern void *__dso_handle;

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

static void handlerA(void) { fputs("A", stdout); }
static void handlerB(void *argument) { fputs(argument == &failures ? "B" : "b?", stdout); }
static void handlerC(void) { fputs("C", stdout); }

// Runs in a child whose stdout is a pipe the parent reads: the order handlers ran in is the output.
static void exerciseInChild(const char *bundlePath)
{
    void *bundle = dlopen(bundlePath, RTLD_NOW | RTLD_LOCAL);
    void (*registerFromBundle)(int (*)(void (*)(void))) = bundle ? dlsym(bundle, "wk_register_from_bundle") : NULL;
    if (!registerFromBundle) {
        fputs("no-bundle", stdout);
        exit(0);
    }
    atexit(handlerA);
    __cxa_atexit(handlerB, &failures, &__dso_handle);
    registerFromBundle(atexit);
    atexit(handlerC);
    fputs("[", stdout);
    dlclose(bundle);
    fputs("]", stdout);
    exit(0);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        printf("usage: %s <bundle>\n", argv[0]);
        return 2;
    }

    void *libc = dlopen("/usr/lib/system/libsystem_c.dylib", RTLD_LAZY | RTLD_NOLOAD);
    void *systemAtexit = libc ? dlsym(libc, "atexit") : NULL;
    check(systemAtexit != NULL, "10.9's atexit is reachable for comparison");
    check(systemAtexit != (void *)atexit, "the linked atexit is the archive's, not 10.9's");

    int output[2];
    if (pipe(output)) {
        perror("pipe");
        return 1;
    }
    fflush(stdout);
    pid_t child = fork();
    if (!child) {
        close(output[0]);
        dup2(output[1], STDOUT_FILENO);
        close(output[1]);
        exerciseInChild(argv[1]);
    }
    close(output[1]);
    char order[64] = { 0 };
    size_t length = 0;
    ssize_t n;
    while (length < sizeof(order) - 1 && (n = read(output[0], order + length, sizeof(order) - 1 - length)) > 0)
        length += (size_t)n;
    close(output[0]);
    int status = 0;
    waitpid(child, &status, 0);
    check(WIFEXITED(status) && !WEXITSTATUS(status), "the child exits normally");

    printf("  handler order: %s\n", order);
    check(strncmp(order, "[D]", 3) == 0, "the dlopen'd image's handler runs at its dlclose");
    check(strcmp(order + 3, "CBA") == 0, "exit runs the rest in LIFO order with __cxa_atexit, not the image's again");

    if (failures)
        printf("atexit probe: %d FAILURE(S)\n", failures);
    return failures ? 1 : 0;
}

#endif
