#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define mkostemp testedMkostemp
#define mkostemps testedMkostemps
#include "../../polyfills/shared/mkostemp.c"
#undef mkostemps
#undef mkostemp

int main(void)
{
    char path[] = "/tmp/wk-mkostemp.XXXXXX";
    int fd = testedMkostemp(path, O_CLOEXEC | O_APPEND);
    assert(fd >= 0);
    assert((fcntl(fd, F_GETFD) & FD_CLOEXEC) == FD_CLOEXEC);
    assert((fcntl(fd, F_GETFL) & O_APPEND) == O_APPEND);
    struct stat status;
    assert(!fstat(fd, &status));
    assert((status.st_mode & 0777) == 0600);
    assert(write(fd, "x", 1) == 1);
    close(fd);
    assert(!unlink(path));

    char suffixed[] = "/tmp/wk-mkostemps.XXXXXX.data";
    fd = testedMkostemps(suffixed, 5, O_SHLOCK);
    assert(fd >= 0 && !strcmp(suffixed + strlen(suffixed) - 5, ".data"));
    close(fd);
    assert(!unlink(suffixed));

    char invalid[] = "/tmp/wk-mkostemp.XXXXXX";
    assert(testedMkostemp(invalid, O_NONBLOCK) == -1 && errno == EINVAL);

    char empty[] = "";
    assert(testedMkostemp(empty, 0) == -1 && errno == EINVAL);

    char suffixConsumesTemplate[] = "suffix";
    assert(testedMkostemps(suffixConsumesTemplate, strlen(suffixConsumesTemplate), 0) == -1 && errno == EINVAL);

    char tooLong[PATH_MAX + 1];
    memset(tooLong, 'X', PATH_MAX);
    tooLong[PATH_MAX] = '\0';
    assert(testedMkostemp(tooLong, 0) == -1 && errno == ENAMETOOLONG);
    puts("PASS: temporary creation applies flags atomically and preserves suffixes");
    return 0;
}
