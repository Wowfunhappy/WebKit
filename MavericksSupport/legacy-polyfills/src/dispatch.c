/*
 * Grand Central Dispatch shims for APIs newer than 10.9 --
 * custom polyfill (not from macports-legacy-support).
 */

#include <dispatch/dispatch.h>

/* dispatch_async_and_wait family (10.14) — emulate via dispatch_sync. */
void dispatch_async_and_wait(dispatch_queue_t queue, dispatch_block_t block) {
	dispatch_sync(queue, block);
}
void dispatch_async_and_wait_f(dispatch_queue_t queue, void *ctx, void (*work)(void*)) {
	dispatch_sync_f(queue, ctx, work);
}
void dispatch_barrier_async_and_wait(dispatch_queue_t queue, dispatch_block_t block) {
	dispatch_barrier_sync(queue, block);
}
void dispatch_barrier_async_and_wait_f(dispatch_queue_t queue, void *ctx, void (*work)(void*)) {
	dispatch_barrier_sync_f(queue, ctx, work);
}

/* dispatch_set_qos_class_floor (10.14) — no-op. */
void dispatch_set_qos_class_floor(dispatch_object_t object, int qos_class, int relpri) {
	(void)object; (void)qos_class; (void)relpri;
}

/*
 * dispatch_queue_create_with_target (10.12) — drop the target, create a
 * regular queue.  The real ABI symbol carries a '$V2' suffix; we expose it
 * via an asm label on a real function (assembler-independent, unlike a
 * '.set' absolute alias, which the 10.9 assembler leaves undefined).  We also
 * keep the plain '_V2' symbol for completeness.
 */
static dispatch_queue_t mpls_dqcwt(const char *label, dispatch_queue_attr_t attr,
                                   dispatch_queue_t target) {
	(void)target;
	return dispatch_queue_create(label, attr);
}
dispatch_queue_t dispatch_queue_create_with_target_V2(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target) {
	return mpls_dqcwt(label, attr, target);
}
extern dispatch_queue_t dispatch_queue_create_with_target_dollarV2(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target) __asm__("_dispatch_queue_create_with_target$V2");
dispatch_queue_t dispatch_queue_create_with_target_dollarV2(const char *label, dispatch_queue_attr_t attr, dispatch_queue_t target) {
	return mpls_dqcwt(label, attr, target);
}

/* dispatch_workloop_* (10.14) — workloops don't exist; emulate with a serial queue. */
typedef struct dispatch_object_s *dispatch_workloop_t;
dispatch_workloop_t dispatch_workloop_create(const char *label) {
	return (dispatch_workloop_t)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}
dispatch_workloop_t dispatch_workloop_create_inactive(const char *label) {
	return (dispatch_workloop_t)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}
