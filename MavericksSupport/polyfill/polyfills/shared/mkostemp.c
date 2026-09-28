/*
 * mkostemp / mkostemps (10.12+).
 *
 * The flags-taking mkstemp variants were added after 10.9; 10.9 has only
 * mkstemp/mkstemps. Generate the candidate here so O_CLOEXEC and the other requested
 * flags are present on the atomic O_CREAT|O_EXCL open itself.
 *
 * Plain C, no wk_polyfill.h: the vendored non-WebKit binaries (the GStreamer/FFmpeg
 * media stack, the build's own python3) compile this same source, and they carry no
 * polyfill registry. One definition, used by all of them.
 */

#include <stdlib.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <unistd.h>

static int createTemporary(char *tmpl, int suffixLength, int flags)
{
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    if (!tmpl || suffixLength < 0 || (flags & ~(O_APPEND | O_SHLOCK | O_EXLOCK | O_CLOEXEC))) {
        errno = EINVAL;
        return -1;
    }
    size_t length = strlen(tmpl);
    if (length >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return -1;
    }
    if ((size_t)suffixLength >= length || strchr(tmpl + length - suffixLength, '/')) {
        errno = EINVAL;
        return -1;
    }

    char *suffix = tmpl + length - suffixLength;
    char *replace = suffix;
    while (replace > tmpl && replace[-1] == 'X')
        --replace;
    for (char *character = replace; character < suffix; ++character)
        *character = alphabet[arc4random_uniform(sizeof(alphabet) - 1)];

    char initial[PATH_MAX];
    size_t randomLength = suffix - replace;
    memcpy(initial, replace, randomLength);
    for (;;) {
        int fd = open(tmpl, O_RDWR | O_CREAT | O_EXCL | flags, S_IRUSR | S_IWUSR);
        if (fd >= 0)
            return fd;
        if (errno != EEXIST)
            return -1;

        char *character = replace;
        char *initialCharacter = initial;
        for (;;) {
            if (character == suffix) {
                errno = EEXIST;
                return -1;
            }
            const char *position = strchr(alphabet, *character);
            if (!position) {
                errno = EIO;
                return -1;
            }
            *character = position[1] ? position[1] : alphabet[0];
            if (*character != *initialCharacter)
                break;
            ++character;
            ++initialCharacter;
        }
    }
}

int mkostemp(char *tmpl, int flags) { return createTemporary(tmpl, 0, flags); }
int mkostemps(char *tmpl, int suffixlen, int flags) { return createTemporary(tmpl, suffixlen, flags); }
