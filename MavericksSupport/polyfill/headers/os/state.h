// Polyfill for os/state.h (10.12+)
#ifndef _OS_STATE_H_
#define _OS_STATE_H_
typedef int os_state_reason;
#define OS_STATE_REASON_GENERAL 0
#define OS_STATE_REASON_NETWORKING 1
#define OS_STATE_REASON_CELLULAR 2
#define OS_STATE_REASON_AUTHENTICATION 3
typedef struct { int unused; } os_state_data_s;
typedef os_state_data_s* os_state_data_t;
#define OS_STATE_DATA_SIZE_NEEDED(x) 0
typedef void (^os_state_block_t)(os_state_data_t);
static inline void os_state_add_handler(dispatch_queue_t q, os_state_block_t b) { (void)q; (void)b; }
#endif
