#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int renameat(int, const char *, int, const char *);
int linkat(int, const char *, int, const char *, int);

// A relative destination whose joined path is one character longer than PATH_MAX - 1, so the
// PATH_MAX-truncated join is exactly <directory>/./././<victim>.
static char *overlongPathTo(const char *directory, const char *victim)
{
    size_t prefix = strlen(directory) + 1;
    size_t name = strlen(victim);
    if ((PATH_MAX - 1 - prefix - name) % 2)
        return NULL;
    size_t dots = (PATH_MAX - 1 - prefix - name) / 2;
    char *relative = malloc(dots * 2 + name + 2);
    char *cursor = relative;
    for (size_t i = 0; i < dots; ++i) {
        *cursor++ = '.';
        *cursor++ = '/';
    }
    memcpy(cursor, victim, name);
    cursor[name] = 'x';
    cursor[name + 1] = '\0';
    return relative;
}

int main(void)
{
    char source[] = "/tmp/wk-atcalls-source.XXXXXX";
    char destination[] = "/tmp/wk-atcalls-destination.XXXXXX";
    assert(mkdtemp(source) && mkdtemp(destination));
    char resolved[PATH_MAX];
    assert(realpath(destination, resolved));

    const char *victim = "victim";
    char *relative = overlongPathTo(resolved, victim);
    if (!relative) {
        victim = "victim_";
        relative = overlongPathTo(resolved, victim);
    }
    assert(relative);

    int sourceFD = open(source, O_RDONLY);
    int destinationFD = open(destination, O_RDONLY);
    assert(sourceFD >= 0 && destinationFD >= 0);
    int file = openat(sourceFD, "file", O_CREAT | O_WRONLY, 0600);
    assert(file >= 0);
    close(file);
    int victimFile = openat(destinationFD, victim, O_CREAT | O_WRONLY, 0600);
    assert(victimFile >= 0 && write(victimFile, "keep", 4) == 4);
    close(victimFile);

    errno = 0;
    assert(renameat(sourceFD, "file", destinationFD, relative) == -1 && errno == ENAMETOOLONG);
    errno = 0;
    assert(linkat(sourceFD, "file", destinationFD, relative, 0) == -1 && errno == ENAMETOOLONG);

    char path[PATH_MAX];
    struct stat status;
    snprintf(path, sizeof(path), "%s/file", source);
    assert(!stat(path, &status) && status.st_nlink == 1);
    snprintf(path, sizeof(path), "%s/%s", destination, victim);
    assert(!stat(path, &status) && status.st_size == 4);

    assert(!unlinkat(sourceFD, "file", 0) && !unlinkat(destinationFD, victim, 0));
    assert(!rmdir(source) && !rmdir(destination));
    free(relative);
    puts("PASS: an overlong joined path fails instead of naming a truncated one");
    return 0;
}
