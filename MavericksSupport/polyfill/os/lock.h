// macOS 10.9 backport: os_unfair_lock polyfill (uses pthread_mutex internally).
#pragma once

#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    pthread_mutex_t mutex;
} os_unfair_lock;

typedef os_unfair_lock *os_unfair_lock_t;

#define OS_UNFAIR_LOCK_INIT { PTHREAD_MUTEX_INITIALIZER }

static inline void os_unfair_lock_lock(os_unfair_lock *lock) {
    pthread_mutex_lock(&lock->mutex);
}

static inline void os_unfair_lock_unlock(os_unfair_lock *lock) {
    pthread_mutex_unlock(&lock->mutex);
}

static inline int os_unfair_lock_trylock(os_unfair_lock *lock) {
    return pthread_mutex_trylock(&lock->mutex) == 0;
}

static inline void os_unfair_lock_assert_owner(const os_unfair_lock *lock) {
    (void)lock;
}

static inline void os_unfair_lock_assert_not_owner(const os_unfair_lock *lock) {
    (void)lock;
}

#ifdef __cplusplus
}
#endif
