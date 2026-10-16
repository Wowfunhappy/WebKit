/*
 * os_log (10.12+): the log objects, the backings the os_log() macros emit, and the "would this level
 * be logged?" query they consult first. Unified logging does not exist on 10.9: every level reports
 * disabled, and what is emitted anyway is dropped.
 *
 * Every log object is an os_object as libtrace's are: an instance of 10.9 libdispatch's OS_object
 * class carrying the global reference counts that make its retain and release no-ops.
 * _os_log_default is OS_LOG_DEFAULT itself. os_log_create keeps one object per subsystem/category
 * pair, created on the first call for that pair and never deallocated; the os_log_create() macro calls
 * it as _os_log_create, which takes the caller's image as well.
 *
 * Plain C: Apple's ICU in the deps build calls os_log() too, and the Widevine CDM's gap library
 * exports these. os_log_t and os_log_type_t are not visible under the 10.9 headers; a pointer and a
 * uint8_t are their ABI.
 */

#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef WK_POLYFILL_REGISTERED
#include "wk_polyfill.h"
#endif

extern char OBJC_CLASS_$_OS_object __asm__("_OBJC_CLASS_$_OS_object");

/* libdispatch's struct _os_object_s; INT_MAX is its _OS_OBJECT_GLOBAL_REFCNT. */
struct os_log_global_object {
    void *isa;
    int volatile ref_cnt;
    int volatile xref_cnt;
};
struct os_log_global_object _os_log_default = { &OBJC_CLASS_$_OS_object, INT_MAX, INT_MAX };

struct os_log_entry {
    struct os_log_global_object log;
    struct os_log_entry *next;
    char *subsystem;
    char *category;
};
static struct os_log_entry *os_log_entries;
static pthread_mutex_t os_log_entries_lock = PTHREAD_MUTEX_INITIALIZER;

void *os_log_create(const char *subsystem, const char *category)
{
    struct os_log_entry *entry;
    pthread_mutex_lock(&os_log_entries_lock);
    for (entry = os_log_entries; entry; entry = entry->next) {
        if (!strcmp(entry->subsystem, subsystem) && !strcmp(entry->category, category))
            break;
    }
    if (!entry) {
        entry = malloc(sizeof(*entry));
        if (!entry || !(entry->subsystem = strdup(subsystem)) || !(entry->category = strdup(category)))
            abort();
        entry->log = _os_log_default;
        entry->next = os_log_entries;
        os_log_entries = entry;
    }
    pthread_mutex_unlock(&os_log_entries_lock);
    return &entry->log;
}

void *_os_log_create(void *dso, const char *subsystem, const char *category)
{
    (void)dso;
    return os_log_create(subsystem, category);
}

bool os_log_type_enabled(void *log, uint8_t type)
{
    (void)log;
    (void)type;
    return false;
}

void _os_log_internal(void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size)
{
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

void _os_log_impl(void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size)
{
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

void _os_log_error_impl(void *dso, void *log, uint8_t type, const char *format, uint8_t *buf, uint32_t size)
{
    (void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

#ifdef WK_POLYFILL_REGISTERED
WK_PF_ENTRY(_os_log_default, NULL, &_os_log_default, WK_POLYFILL_CONSTANT, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(os_log_create, NULL, &os_log_create, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(_os_log_create, NULL, &_os_log_create, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(os_log_type_enabled, NULL, &os_log_type_enabled, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(_os_log_internal, NULL, &_os_log_internal, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(_os_log_impl, NULL, &_os_log_impl, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
WK_PF_ENTRY(_os_log_error_impl, NULL, &_os_log_error_impl, WK_POLYFILL_FUNCTION, WK_POLYFILL_GAP_FILL);
#endif
