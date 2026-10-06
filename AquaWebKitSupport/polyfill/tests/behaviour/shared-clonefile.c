#include <sys/clonefile.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPECT(call, error) do { errno = 0; int result = (call); \
    if (result != -1 || errno != (error)) { \
        fprintf(stderr, "%s returned %d errno %d, expected %d\n", #call, result, errno, (error)); abort(); \
    } } while (0)

static void check_path_memory(int sourceFD, int directoryFD)
{
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        size_t page = getpagesize();
        char *memory = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        assert(memory != MAP_FAILED);
        assert(!mprotect(memory + page, page, PROT_NONE));
        EXPECT(fclonefileat(sourceFD, directoryFD, memory + page, 0), EFAULT);
        EXPECT(clonefileat(directoryFD, memory + page, directoryFD, "new", 0), EFAULT);
        EXPECT(clonefileat(directoryFD, (const char *)1, directoryFD, "new", 0), EFAULT);
        memcpy(memory + page - 4, "new", 4);
        EXPECT(fclonefileat(sourceFD, directoryFD, memory + page - 4, 0), ENOTSUP);
        memset(memory + page - PATH_MAX, 'a', PATH_MAX);
        EXPECT(fclonefileat(sourceFD, directoryFD, memory + page - PATH_MAX, 0), ENAMETOOLONG);
        EXPECT(fclonefileat(sourceFD, directoryFD, memory + page - 2, 0), EFAULT);
        EXPECT(fclonefileat(sourceFD, directoryFD, memory + page, 0x80000000), EINVAL);
        EXPECT(fclonefileat(sourceFD, directoryFD, memory + page, CLONE_NOFOLLOW_ANY), ENOTSUP);
        _exit(0);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && !WEXITSTATUS(status));
}

int main(void)
{
    char directory[] = "/tmp/wk-clonefile.XXXXXX";
    assert(mkdtemp(directory));
    int directoryFD = open(directory, O_RDONLY | O_DIRECTORY);
    assert(directoryFD >= 0);
    int sourceFD = openat(directoryFD, "source", O_CREAT | O_RDWR, 0600);
    assert(sourceFD >= 0 && write(sourceFD, "original", 8) == 8);
    struct stat before, after;
    assert(!fstat(sourceFD, &before));
    EXPECT(fclonefileat(sourceFD, directoryFD, "new", 0), ENOTSUP);
    EXPECT(clonefileat(directoryFD, "source", directoryFD, "new", CLONE_ACL | CLONE_NOOWNERCOPY), ENOTSUP);
    EXPECT(fclonefileat(sourceFD, directoryFD, "source", 0), EEXIST);
    EXPECT(fclonefileat(-1, directoryFD, "new", 0), EBADF);
    int writeFD = openat(directoryFD, "source", O_WRONLY);
    assert(writeFD >= 0);
    EXPECT(fclonefileat(writeFD, directoryFD, "new", 0), EBADF);
    close(writeFD);
    EXPECT(fclonefileat(sourceFD, sourceFD, "new", 0), ENOTDIR);
    EXPECT(clonefileat(directoryFD, "missing", directoryFD, "new", 0), ENOENT);
    EXPECT(fclonefileat(sourceFD, directoryFD, "missing/new", 0), ENOENT);
    EXPECT(fclonefileat(sourceFD, directoryFD, "", 0), ENOENT);
    int pipes[2];
    assert(!pipe(pipes));
    EXPECT(fclonefileat(pipes[0], directoryFD, "new", 0), EINVAL);
    close(pipes[0]); close(pipes[1]);
    EXPECT(clonefile("/", directory, 0), EINVAL);
    assert(!symlinkat("absent-target", directoryFD, "dangling"));
    EXPECT(fclonefileat(sourceFD, directoryFD, "dangling", CLONE_NOFOLLOW), EEXIST);
    EXPECT(fclonefileat(sourceFD, directoryFD, "dangling", 0), ENOTSUP);
    EXPECT(clonefileat(directoryFD, "dangling", directoryFD, "new", CLONE_NOFOLLOW), ENOTSUP);
    EXPECT(clonefileat(directoryFD, "dangling", directoryFD, "new", 0), ENOENT);
    EXPECT(fclonefileat(sourceFD, AT_FDCWD, "/dev/wk-clonefile-nonexistent", 0), EXDEV);
    check_path_memory(sourceFD, directoryFD);
    assert(!fstat(sourceFD, &after));
    assert(before.st_ino == after.st_ino && before.st_size == after.st_size);
    assert(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec);
    char contents[8];
    assert(pread(sourceFD, contents, sizeof(contents), 0) == 8 && !memcmp(contents, "original", 8));
    EXPECT(fstatat(directoryFD, "new", &after, 0), ENOENT);
    EXPECT(fstatat(directoryFD, "absent-target", &after, 0), ENOENT);
    assert(!unlinkat(directoryFD, "dangling", 0));
    assert(!unlinkat(directoryFD, "source", 0));
    close(sourceFD); close(directoryFD);
    assert(!rmdir(directory));
    puts("PASS: clone capability, native validation, safe path memory, no source/destination changes");
    return 0;
}
