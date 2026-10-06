#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *load(const char *path, int mode)
{
    void *handle = dlopen(path, RTLD_NOW | mode);
    if (!handle) {
        fprintf(stderr, "%s: %s\n", path, dlerror());
        exit(1);
    }
    return handle;
}

int main(int argc, char **argv)
{
    if (argc != 6)
        return 2;
    int clientFirst = !strcmp(argv[1], "client-first");
    int mode = !strcmp(argv[2], "global") ? RTLD_GLOBAL : RTLD_LOCAL;
    void *client = NULL;
    if (clientFirst)
        client = load(argv[3], mode);
    load(argv[4], mode);
    load(argv[5], mode);
    if (!clientFirst)
        client = load(argv[3], mode);
    int (*check)(void) = dlsym(client, "check_client_libraries");
    if (!check || !check()) {
        fprintf(stderr, "client bound to another library\n");
        return 1;
    }
    printf("PASS: %s, %s\n", argv[1], argv[2]);
    return 0;
}
