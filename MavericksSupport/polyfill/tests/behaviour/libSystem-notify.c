#include <dispatch/dispatch.h>
#include <notify.h>
#include <stdbool.h>
#include <stdio.h>
#include <unistd.h>

extern bool notify_is_valid_token(int);
extern uint32_t notify_register_plain(const char *, int *);
static int failures;
static void check(bool condition, const char *message)
{
    printf("  %s: %s\n", message, condition ? "ok" : "FAIL");
    failures += !condition;
}

int main(void)
{
    check(!notify_is_valid_token(-1), "negative token is invalid");
    check(!notify_is_valid_token(2147483647), "unregistered token is invalid");
    char name[128];
    snprintf(name, sizeof(name), "org.webkit.polyfill.notify.%d", getpid());
    int plain = -1, shared = -1, first = -1, second = -1;
    check(notify_register_plain(name, &plain) == NOTIFY_STATUS_OK, "plain registration");
    check(notify_register_check(name, &shared) == NOTIFY_STATUS_OK, "check registration");
    check(notify_is_valid_token(plain), "plain token is valid");
    check(notify_is_valid_token(shared) && notify_is_valid_token(shared), "check token is valid on repeated queries");
    int changed = 0;
    check(notify_check(shared, &changed) == NOTIFY_STATUS_OK && changed, "validity queries preserve the pending check");
    check(notify_check(shared, &changed) == NOTIFY_STATUS_OK && !changed, "native check consumes its pending state");

    dispatch_queue_t queue = dispatch_queue_create("org.webkit.polyfill.notify", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t delivered = dispatch_semaphore_create(0);
    check(notify_register_dispatch(name, &first, queue, ^(int token) {
        (void)token;
        dispatch_semaphore_signal(delivered);
    }) == NOTIFY_STATUS_OK, "first dispatch registration");
    check(notify_register_dispatch(name, &second, queue, ^(int token) {
        (void)token;
        dispatch_semaphore_signal(delivered);
    }) == NOTIFY_STATUS_OK, "second dispatch registration");
    check(notify_is_valid_token(first) && notify_is_valid_token(second), "same-name dispatch tokens are independently valid");
    check(notify_post(name) == NOTIFY_STATUS_OK, "post notification");
    check(!dispatch_semaphore_wait(delivered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), "first dispatch handler receives notification");
    check(!dispatch_semaphore_wait(delivered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), "second dispatch handler receives notification");
    notify_cancel(first);
    check(!notify_is_valid_token(first) && notify_is_valid_token(second), "cancelling one dispatch token preserves its sibling");
    notify_cancel(second);
    notify_cancel(shared);
    notify_cancel(plain);
    check(!notify_is_valid_token(second) && !notify_is_valid_token(shared) && !notify_is_valid_token(plain), "cancelled dispatch, check and plain tokens are invalid");
    dispatch_sync(queue, ^{});
    dispatch_release(delivered);
    dispatch_release(queue);
    return failures ? 1 : 0;
}
