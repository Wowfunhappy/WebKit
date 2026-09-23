#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

enum { threadCount = 32 };
enum Mode { native, concurrent, openFailure, interruptedPartialRead, endOfFile, readFailure };
static enum Mode mode;
static unsigned opens;
static unsigned closes;
static unsigned reads;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static unsigned ready;

static int testOpen(const char *path, int flags, ...)
{
    __atomic_add_fetch(&opens, 1, __ATOMIC_RELAXED);
    if (mode == openFailure) {
        errno = EMFILE;
        return -1;
    }
    int fd = open(path, flags);
    assert(fd >= 0);
    if (mode == concurrent) {
        pthread_mutex_lock(&mutex);
        ++ready;
        pthread_cond_broadcast(&condition);
        while (ready != threadCount)
            pthread_cond_wait(&condition, &mutex);
        pthread_mutex_unlock(&mutex);
    }
    return fd;
}

static int testClose(int fd)
{
    __atomic_add_fetch(&closes, 1, __ATOMIC_RELAXED);
    return close(fd);
}

static ssize_t testRead(int fd, void *buffer, size_t count)
{
    unsigned call = __atomic_add_fetch(&reads, 1, __ATOMIC_RELAXED);
    if (mode == interruptedPartialRead) {
        if (call == 1) {
            errno = EINTR;
            return -1;
        }
        size_t length = count < 7 ? count : 7;
        memset(buffer, 0xA5, length);
        return length;
    }
    if (mode == endOfFile)
        return 0;
    if (mode == readFailure) {
        errno = EFAULT;
        return -1;
    }
    return read(fd, buffer, count);
}

#define open testOpen
#define close testClose
#define read testRead
#define getentropy testedGetentropy
#include "../../polyfills/shared/getentropy.c"
#undef getentropy
#undef read
#undef close
#undef open

static unsigned descriptorCount(void)
{
    unsigned result = 0;
    for (int fd = 0; fd < getdtablesize(); ++fd) {
        if (fcntl(fd, F_GETFD) != -1)
            ++result;
    }
    return result;
}

static void *fill(void *buffer)
{
    assert(testedGetentropy(buffer, 256) == 0);
    return NULL;
}

static void concurrentInitialization(void)
{
    mode = concurrent;
    unsigned before = descriptorCount();
    pthread_t threads[threadCount];
    uint8_t buffers[threadCount][256];
    for (unsigned i = 0; i < threadCount; ++i)
        assert(!pthread_create(&threads[i], NULL, fill, buffers[i]));
    for (unsigned i = 0; i < threadCount; ++i)
        assert(!pthread_join(threads[i], NULL));
    assert(opens == threadCount);
    assert(closes == threadCount - 1);
    assert(descriptorCount() == before + 1);
    mode = native;
    fill(buffers[0]);
    assert(opens == threadCount);
    assert(memcmp(buffers[0], buffers[1], sizeof(buffers[0])));
}

static void sizesAndOpenFailure(void)
{
    uint8_t buffer[257];
    mode = openFailure;
    assert(testedGetentropy(NULL, 0) == 0);
    assert(!opens);
    assert(testedGetentropy(buffer, sizeof(buffer)) == -1 && errno == EIO);
    assert(!opens);
    assert(testedGetentropy(buffer, 1) == -1 && errno == EMFILE);
    assert(opens == 1);
    mode = native;
    assert(testedGetentropy(buffer, 256) == 0);
    assert(opens == 2);
}

static void readConditions(void)
{
    uint8_t buffer[256] = { 0 };
    mode = interruptedPartialRead;
    assert(testedGetentropy(buffer, sizeof(buffer)) == 0);
    assert(reads == 38);
    for (unsigned i = 0; i < sizeof(buffer); ++i)
        assert(buffer[i] == 0xA5);
    mode = endOfFile;
    assert(testedGetentropy(buffer, 1) == -1 && errno == EIO);
    mode = readFailure;
    assert(testedGetentropy(buffer, 1) == -1 && errno == EFAULT);
    mode = native;
    assert(testedGetentropy(buffer, sizeof(buffer)) == 0);
    assert(opens == 1);
}

static void run(void (*test)(void), const char *name)
{
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        alarm(20);
        test();
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && !WEXITSTATUS(status));
    printf("PASS %s\n", name);
}

int main(void)
{
    run(concurrentInitialization, "concurrent first calls publish one entropy descriptor");
    run(sizesAndOpenFailure, "zero length, size limit, and retry after open failure");
    run(readConditions, "complete fill, EINTR, EOF, and read errors");
    return 0;
}
