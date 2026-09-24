// On SIGINFO, loads librewrite.dylib from the process's own DARWIN_USER_TEMP_DIR, which the sandbox lets it read.
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

__attribute__((constructor)) static void installLateLoader(void)
{
    signal(SIGINFO, SIG_IGN);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINFO, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_event_handler(source, ^{
        char directory[PATH_MAX], path[PATH_MAX];
        if (!confstr(_CS_DARWIN_USER_TEMP_DIR, directory, sizeof(directory)))
            return;
        snprintf(path, sizeof(path), "%slibrewrite.dylib", directory);
        dlopen(path, RTLD_NOW);
    });
    dispatch_resume(source);
}
