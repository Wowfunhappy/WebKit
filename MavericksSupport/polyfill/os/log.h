#ifndef _OS_LOG_H_
#define _OS_LOG_H_

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct os_log_s *os_log_t;
#define OS_LOG_DEFAULT ((os_log_t)0)
#define OS_LOG_DISABLED ((os_log_t)0)

typedef enum {
    OS_LOG_TYPE_DEFAULT = 0x00,
    OS_LOG_TYPE_INFO    = 0x01,
    OS_LOG_TYPE_DEBUG   = 0x02,
    OS_LOG_TYPE_ERROR   = 0x10,
    OS_LOG_TYPE_FAULT   = 0x11,
} os_log_type_t;

/* Stub implementations - os_log is a no-op on 10.9 */
#define os_log(log, format, ...) ((void)0)
#define os_log_info(log, format, ...) ((void)0)
#define os_log_debug(log, format, ...) ((void)0)
#define os_log_error(log, format, ...) ((void)0)
#define os_log_fault(log, format, ...) ((void)0)
#define os_log_with_type(log, type, format, ...) ((void)0)

static inline os_log_t os_log_create(const char *subsystem, const char *category) {
    (void)subsystem; (void)category;
    return OS_LOG_DEFAULT;
}

static inline int os_log_type_enabled(os_log_t log, os_log_type_t type) {
    (void)log; (void)type;
    return 0;
}

#ifdef __cplusplus
}
#endif

#endif /* _OS_LOG_H_ */
