/*
 * Mavericks has no vnode cloning operation. Validate the available native
 * path/fd/type/mount contract, then report the documented ENOTSUP capability
 * failure without creating a destination or copying any data. Authorization
 * cannot make this unsupported operation possible; do not approximate its ACL
 * checks with a process-wide credential change or a broader access() request.
 */
#include <sys/clonefile.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

static int fail(int error)
{
    errno = error;
    return -1;
}

static int validate_flags(uint32_t flags)
{
    if (flags & ~(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY | CLONE_ACL | CLONE_NOFOLLOW_ANY | CLONE_RESOLVE_BENEATH))
        return fail(EINVAL);
    /* These valid flags need kernel namei constraints absent on 10.9. Report
     * the cloning capability before traversing a path they might forbid. */
    if (flags & (CLONE_NOFOLLOW_ANY | CLONE_RESOLVE_BENEATH))
        return fail(ENOTSUP);
    return 0;
}

/* Native syscalls copy path strings from potentially invalid caller memory.
 * Copy through Mach's checked VM interface before inspecting any byte here or
 * passing the path to shared atcalls (which examines relative pathnames). */
static int copy_path(const char *path, char copy[PATH_MAX])
{
    if (!path)
        return fail(EFAULT);
    size_t copied = 0;
    while (copied < PATH_MAX) {
        uintptr_t address = (uintptr_t)path + copied;
        if (address < (uintptr_t)path)
            return fail(EFAULT);
        size_t amount = vm_page_size - (address % vm_page_size);
        if (amount > PATH_MAX - copied)
            amount = PATH_MAX - copied;
        mach_vm_size_t actual = 0;
        if (mach_vm_read_overwrite(mach_task_self(), address, amount, (mach_vm_address_t)(copy + copied), &actual) != KERN_SUCCESS || actual != amount)
            return fail(EFAULT);
        if (memchr(copy + copied, '\0', amount))
            return 0;
        copied += amount;
    }
    return fail(ENAMETOOLONG);
}

static int validate_destination(int dirfd, const char *untrustedPath, uint32_t flags, dev_t sourceDevice, unsigned links)
{
    char path[PATH_MAX];
    if (copy_path(untrustedPath, path))
        return -1;
    size_t length = strlen(path);
    if (!length)
        return fail(ENOENT);

    struct stat destination;
    if (!fstatat(dirfd, path, &destination, flags & CLONE_NOFOLLOW ? AT_SYMLINK_NOFOLLOW : 0))
        return fail(EEXIST);
    if (errno != ENOENT)
        return -1;
    /* An absent trailing-slash component cannot name a new clone. */
    if (path[length - 1] == '/')
        return fail(ENOENT);

    char parent[PATH_MAX];
    memcpy(parent, path, length + 1);
    char *leaf = strrchr(parent, '/');
    const char *name = leaf ? path + (leaf - parent) + 1 : path;
    if (leaf)
        leaf[leaf == parent ? 1 : 0] = '\0';
    else
        strcpy(parent, ".");
    int parentFD = openat(dirfd, parent, O_EVTONLY | O_DIRECTORY | O_CLOEXEC);
    if (parentFD < 0)
        return -1;

    int result;
    /* Following a dangling final symlink resolves its target relative to the
     * link's directory, as native CREATE name lookup does. */
    if (!(flags & CLONE_NOFOLLOW) && !fstatat(parentFD, name, &destination, AT_SYMLINK_NOFOLLOW) && S_ISLNK(destination.st_mode)) {
        char target[PATH_MAX];
        ssize_t size = readlinkat(parentFD, name, target, sizeof(target) - 1);
        if (size < 0)
            result = -1;
        else if (links >= MAXSYMLINKS)
            result = fail(ELOOP);
        else {
            target[size] = '\0';
            result = validate_destination(parentFD, target, flags, sourceDevice, links + 1);
        }
    } else if (fstat(parentFD, &destination))
        result = -1;
    else
        result = fail(destination.st_dev == sourceDevice ? ENOTSUP : EXDEV);
    int error = errno;
    close(parentFD);
    errno = error;
    return result;
}

static int clone_from_fd(int sourceFD, int destinationFD, const char *destination, uint32_t flags)
{
    struct stat source;
    if (fstat(sourceFD, &source))
        return -1;
    if (S_ISDIR(source.st_mode)) {
        struct statfs filesystem;
        struct stat root;
        if (fstatfs(sourceFD, &filesystem) || stat(filesystem.f_mntonname, &root))
            return -1;
        if (root.st_dev == source.st_dev && root.st_ino == source.st_ino)
            return fail(EINVAL);
    } else if (!S_ISREG(source.st_mode) && !S_ISLNK(source.st_mode))
        return fail(EINVAL);
    return validate_destination(destinationFD, destination, flags, source.st_dev, 0);
}

int fclonefileat(int sourceFD, int destinationFD, const char *destination, uint32_t flags)
{
    if (validate_flags(flags))
        return -1;
    int mode = fcntl(sourceFD, F_GETFL);
    if (mode < 0)
        return -1;
    if ((mode & O_ACCMODE) == O_WRONLY || (mode & O_EVTONLY))
        return fail(EBADF);
    return clone_from_fd(sourceFD, destinationFD, destination, flags);
}

int clonefileat(int sourceFD, const char *untrustedSource, int destinationFD, const char *destination, uint32_t flags)
{
    if (validate_flags(flags))
        return -1;
    char source[PATH_MAX];
    if (copy_path(untrustedSource, source))
        return -1;
    int fd = openat(sourceFD, source, O_EVTONLY | O_NONBLOCK | O_CLOEXEC | (flags & CLONE_NOFOLLOW ? O_SYMLINK : 0));
    if (fd < 0)
        return -1;
    int result = clone_from_fd(fd, destinationFD, destination, flags);
    int error = errno;
    close(fd);
    errno = error;
    return result;
}

int clonefile(const char *source, const char *destination, uint32_t flags)
{
    return clonefileat(AT_FDCWD, source, AT_FDCWD, destination, flags);
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(clonefile, NULL, &clonefile, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(clonefileat, NULL, &clonefileat, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(fclonefileat, NULL, &fclonefileat, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
