#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/resource.h>

static pthread_t main_thread;
static size_t main_size;

static void *worker(void *context)
{
    assert(pthread_get_stacksize_np(main_thread) == main_size);
    assert(pthread_get_stacksize_np(pthread_self()) == (size_t)context);
    return NULL;
}

int main(void)
{
    struct rlimit limit;
    assert(!getrlimit(RLIMIT_STACK, &limit));
    main_size = limit.rlim_cur < 0x40000000 ? (size_t)limit.rlim_cur : 0x40000000;
    main_thread = pthread_self();
    assert(pthread_get_stacksize_np(main_thread) == main_size);
    pthread_attr_t attr;
    assert(!pthread_attr_init(&attr));
    const size_t custom = 2 * 1024 * 1024;
    assert(!pthread_attr_setstacksize(&attr, custom));
    pthread_t thread;
    assert(!pthread_create(&thread, &attr, worker, (void *)custom));
    assert(!pthread_join(thread, NULL));
    assert(!pthread_attr_destroy(&attr));
    puts("PASS: process main stack size from main/worker, custom pthread stack unchanged");
    return 0;
}
