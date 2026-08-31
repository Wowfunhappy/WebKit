/*
 * sbcheck -- compile a sandbox profile the way WebKit compiles it, and report whether 10.9's
 * sandbox accepts it.
 *
 * The profiles in MavericksSupport/sandbox/ are applied by AuxiliaryProcess::initializeSandbox(),
 * which CRASH()es when a profile will not compile -- so a profile that does not compile is a
 * WebContent process that dies at launch. This asks the same question ahead of time, against the
 * same libsandbox, with the same named parameters populateSandboxInitializationParameters() sets.
 *
 * It only ever COMPILES a profile; it never applies one, so running it cannot confine anything.
 *
 *   sbcheck <profile.sb> [KEY=VALUE ...]
 *
 * Extra KEY=VALUE arguments override or add named parameters. Exits 0 if the profile compiles.
 */

#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* libsandbox's compile API is SPI; these match Source/WTF/wtf/spi/darwin/SandboxSPI.h. */
typedef void *sandbox_params_t;
typedef struct {
    const char *builtin;
    unsigned char *data;
    size_t size;
} *sandbox_profile_t;

extern sandbox_params_t sandbox_create_params(void);
extern int sandbox_set_param(sandbox_params_t, const char *key, const char *value);
extern sandbox_profile_t sandbox_compile_file(const char *path, sandbox_params_t, char **error);
extern void sandbox_free_profile(sandbox_profile_t);

static void setParameter(sandbox_params_t params, const char *key, const char *value)
{
    if (sandbox_set_param(params, key, value))
        fprintf(stderr, "warning: could not set sandbox parameter %s\n", key);
}

static void stripTrailingSlash(char *path)
{
    size_t length = strlen(path);
    if (length && path[length - 1] == '/')
        path[length - 1] = '\0';
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <profile.sb> [KEY=VALUE ...]\n", argv[0]);
        return 2;
    }

    sandbox_params_t params = sandbox_create_params();
    if (!params) {
        fprintf(stderr, "sandbox_create_params failed\n");
        return 2;
    }

    char temporaryDirectory[PATH_MAX] = "";
    char cacheDirectory[PATH_MAX] = "";
    confstr(_CS_DARWIN_USER_TEMP_DIR, temporaryDirectory, sizeof(temporaryDirectory));
    confstr(_CS_DARWIN_USER_CACHE_DIR, cacheDirectory, sizeof(cacheDirectory));
    /* addConfDirectoryParameter() drops the trailing slash confstr() returns; a subpath filter
       rejects one ("subpaths must not end with a slash"). */
    stripTrailingSlash(temporaryDirectory);
    stripTrailingSlash(cacheDirectory);

    struct passwd *entry = getpwuid(getuid());
    const char *home = entry ? entry->pw_dir : "/Users/unknown";
    char homePreferences[PATH_MAX];
    snprintf(homePreferences, sizeof(homePreferences), "%s/Library/Preferences", home);

    setParameter(params, "WEBKIT2_FRAMEWORK_DIR", "/System/Library/PrivateFrameworks");
    setParameter(params, "DARWIN_USER_TEMP_DIR", temporaryDirectory);
    setParameter(params, "DARWIN_USER_CACHE_DIR", cacheDirectory);
    setParameter(params, "HOME_DIR", home);
    setParameter(params, "HOME_LIBRARY_PREFERENCES_DIR", homePreferences);
    setParameter(params, "CPU", "x86_64");
    setParameter(params, "ENABLE_SANDBOX_MESSAGE_FILTER", "NO");

    for (int i = 2; i < argc; ++i) {
        char *equals = strchr(argv[i], '=');
        if (!equals) {
            fprintf(stderr, "ignoring malformed parameter '%s'\n", argv[i]);
            continue;
        }
        *equals = '\0';
        setParameter(params, argv[i], equals + 1);
    }

    char *error = NULL;
    sandbox_profile_t profile = sandbox_compile_file(argv[1], params, &error);
    if (!profile) {
        printf("FAIL  %s\n      %s\n", argv[1], error ? error : "(no error text)");
        return 1;
    }

    printf("ok    %s (%zu bytes)\n", argv[1], profile->size);
    sandbox_free_profile(profile);
    return 0;
}
