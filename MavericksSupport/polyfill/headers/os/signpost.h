#ifndef _OS_SIGNPOST_H_
#define _OS_SIGNPOST_H_

#include <os/log.h>
#include <stdint.h>

typedef uint64_t os_signpost_id_t;
typedef uint32_t os_signpost_type_t;

#define OS_SIGNPOST_ID_NULL ((os_signpost_id_t)0)
#define OS_SIGNPOST_ID_EXCLUSIVE ((os_signpost_id_t)0xEEEEB0B5B2B2EEEE)
#define OS_SIGNPOST_ID_INVALID ((os_signpost_id_t)~0)

enum {
    OS_SIGNPOST_EVENT           = 0x00,
    OS_SIGNPOST_INTERVAL_BEGIN  = 0x01,
    OS_SIGNPOST_INTERVAL_END   = 0x02,
};

#define os_signpost_interval_begin(log, id, name, ...) ((void)0)
#define os_signpost_interval_end(log, id, name, ...) ((void)0)
#define os_signpost_event_emit(log, id, name, ...) ((void)0)
#define os_signpost_enabled(log) (0)

static inline os_signpost_id_t os_signpost_id_generate(os_log_t log) {
    (void)log;
    return OS_SIGNPOST_ID_EXCLUSIVE;
}

static inline os_signpost_id_t os_signpost_id_make_with_pointer(os_log_t log, const void *ptr) {
    (void)log;
    return (os_signpost_id_t)(uintptr_t)ptr;
}

#endif /* _OS_SIGNPOST_H_ */
