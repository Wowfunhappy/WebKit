#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern bool _set_user_dir_suffix(const char *);
static int failures;
static void check(bool condition, const char *message)
{
    printf("  %s: %s\n", message, condition ? "ok" : "FAIL");
    failures += !condition;
}

int main(void)
{
    const char *original = getenv("DIRHELPER_USER_DIR_SUFFIX");
    char *saved = original ? strdup(original) : NULL;
    check(_set_user_dir_suffix(NULL), "clear user directory suffix");
    char baseline[1024], suffixed[1024], restored[1024], suffix[64];
    snprintf(suffix, sizeof(suffix), "wk-dirhelper-%d..suffix", getpid());
    const int names[] = { _CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR };
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        check(confstr(names[i], baseline, sizeof(baseline)) > 0, "resolve native base directory");
        check(_set_user_dir_suffix(suffix), "set suffix containing two consecutive dots");
        check(confstr(names[i], suffixed, sizeof(suffixed)) > 0, "native dirhelper resolves the suffix");
        char expected[2048];
        snprintf(expected, sizeof(expected), "%s%s/", baseline, suffix);
        check(!strcmp(suffixed, expected), "native directory contains the requested suffix");
        check(_set_user_dir_suffix(NULL), "clear suffix after resolving");
        check(confstr(names[i], restored, sizeof(restored)) > 0 && !strcmp(restored, baseline), "native directory returns to its base");
        rmdir(suffixed);
    }
    _set_user_dir_suffix(saved);
    free(saved);
    return failures ? 1 : 0;
}
