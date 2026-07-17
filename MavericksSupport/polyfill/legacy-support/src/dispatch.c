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
 * dispatch_queue_create_with_target (10.12) is provided once by
 * polyfill_stubs.m (which preserves the target via dispatch_set_target_queue);
 * it is intentionally NOT redefined here.
 */

/*
 * dispatch_assert_queue (public 10.12; the real ABI symbol is versioned
 * '$V2').  10.9's libdispatch already exports the unversioned real function
 * _dispatch_assert_queue, so forward the '$V2' import straight to it (declared
 * with an asm label so the compiler doesn't re-map our call back to '$V2' and
 * recurse).  Preserves the assertion semantics exactly rather than stubbing it.
 */
extern void mpls_dispatch_assert_queue_stock(dispatch_queue_t queue) __asm__("_dispatch_assert_queue");
extern void dispatch_assert_queue_dollarV2(dispatch_queue_t queue) __asm__("_dispatch_assert_queue$V2");
void dispatch_assert_queue_dollarV2(dispatch_queue_t queue) {
	mpls_dispatch_assert_queue_stock(queue);
}

/* dispatch_workloop_* (10.14) — workloops don't exist; emulate with a serial queue. */
typedef struct dispatch_object_s *dispatch_workloop_t;
dispatch_workloop_t dispatch_workloop_create(const char *label) {
	return (dispatch_workloop_t)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}
dispatch_workloop_t dispatch_workloop_create_inactive(const char *label) {
	return (dispatch_workloop_t)dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
}
