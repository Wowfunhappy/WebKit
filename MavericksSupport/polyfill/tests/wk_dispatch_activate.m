// The dispatch_activate polyfill (polyfills/system-spi.m, over the rule in
// polyfills/dispatch-activate-once.h): 10.9 has no dispatch_activate, so it is implemented over
// dispatch_resume — but activate is idempotent and resume is not, so the polyfill must resume each
// object exactly once. This probe is the guarantee that "exactly once" is keyed to the OBJECT and
// not to its ADDRESS.
//
// The distinction is not academic. dispatch_source_create() returns a SUSPENDED source, and the
// allocator hands a released source's address straight back, so an address-keyed mark makes a
// recycled source look already-activated and never resumes it — the timer simply never fires, with
// nothing at the call site to say why. An earlier version of this polyfill did exactly that.
//
// To have any teeth the probe must ACTIVATE, then RELEASE, then activate again at a recycled
// address: an address that was never passed to the polyfill is not in an address-keyed table and
// would fire regardless. So sources here are created, activated, awaited and released one wave at a
// time, and the probe asserts both that addresses really did come back AND that every source fired.
// Verified against the old address-keyed implementation, which fails it.
#import <Foundation/Foundation.h>
#import <stdio.h>

// The SHIPPED polyfill entry point out of libpolyfill.a, not the header inline: this probe links
// the archive so what it exercises is the dispatch_activate WebKit itself will call.
extern void dispatch_activate(dispatch_object_t);

#define WAVES 250

static int failures;
static void check(int ok, const char *what)
{
    printf("  %-64s %s\n", what, ok ? "ok" : "FAIL");
    if (!ok)
        failures++;
}

int main(void)
{
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("wk.dispatch_activate.probe", DISPATCH_QUEUE_SERIAL);

        NSMutableSet *activatedAddresses = [NSMutableSet set];
        unsigned recycledAfterActivation = 0;
        unsigned fired = 0;
        unsigned firstFailedWave = 0;

        for (unsigned wave = 0; wave < WAVES; ++wave) {
            dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);

            // Did this address already carry the polyfill's mark from an earlier, now-released
            // source? That is the case an address-keyed table gets wrong.
            NSNumber *address = @((uintptr_t)source);
            if ([activatedAddresses containsObject:address])
                recycledAfterActivation++;
            else
                [activatedAddresses addObject:address];

            dispatch_semaphore_t didFire = dispatch_semaphore_create(0);
            dispatch_source_set_timer(source, dispatch_time(DISPATCH_TIME_NOW, 0), DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(source, ^{ dispatch_semaphore_signal(didFire); });

            dispatch_activate(source);

            if (!dispatch_semaphore_wait(didFire, dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC)))
                fired++;
            else if (!firstFailedWave)
                firstFailedWave = wave + 1;

            // Cancel and drain before releasing: the source was resumed by the polyfill, so it is
            // safe to release, and letting the queue settle is what frees the address for reuse.
            dispatch_source_cancel(source);
            dispatch_sync(queue, ^{ });
            dispatch_release(source);
            dispatch_release(didFire);
        }

        printf("  %u of %d waves reused an address the polyfill had already marked\n", recycledAfterActivation, WAVES);
        check(recycledAfterActivation > 0, "activated addresses are recycled (probe is meaningful)");

        printf("  %u of %d activated sources fired%s\n", fired, WAVES,
            firstFailedWave ? [[NSString stringWithFormat:@" (first miss: wave %u)", firstFailedWave] UTF8String] : "");
        check(fired == WAVES, "every activated source fires, including at recycled addresses");

        // Activating an already-active object is defined to do nothing; a second dispatch_resume
        // would be an over-resume, which on a source delivers events nobody asked for.
        dispatch_source_t repeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_semaphore_t repeatFiredOnce = dispatch_semaphore_create(0);
        __block unsigned repeatFired = 0;
        dispatch_source_set_timer(repeat, dispatch_time(DISPATCH_TIME_NOW, 0), DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(repeat, ^{
            if (++repeatFired == 1)
                dispatch_semaphore_signal(repeatFiredOnce);
        });
        dispatch_activate(repeat);
        // Wait for the first delivery rather than assuming it has already been enqueued: the timer
        // fires asynchronously, so a bare dispatch_sync here can outrun it.
        check(!dispatch_semaphore_wait(repeatFiredOnce, dispatch_time(DISPATCH_TIME_NOW, 2ull * NSEC_PER_SEC)),
            "an activated one-shot source delivers once");
        dispatch_activate(repeat);
        dispatch_sync(queue, ^{ });
        check(repeatFired == 1, "re-activating an active source does not over-resume");
        dispatch_release(repeatFiredOnce);
        dispatch_source_cancel(repeat);
        dispatch_sync(queue, ^{ });
        dispatch_release(repeat);

        // Objects that are BORN ACTIVE on 10.9. dispatch_activate on an already-active object is
        // defined to do nothing; dispatch_resume on one is an over-resume, which here is not a
        // subtle mis-accounting but an immediate SIGILL. If the polyfill ever resumes these, this
        // process dies right now and the check below never prints -- which is the point: reaching
        // the end at all is the assertion.
        dispatch_queue_t createdQueue = dispatch_queue_create("wk.dispatch_activate.active", DISPATCH_QUEUE_SERIAL);
        dispatch_activate(createdQueue);
        dispatch_activate(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        dispatch_group_t group = dispatch_group_create();
        dispatch_activate(group);
        check(true, "activating already-active queues and groups survives");

        // ...and they must still work afterwards, not merely have failed to crash.
        __block bool queueStillDispatches = false;
        dispatch_sync(createdQueue, ^{ queueStillDispatches = true; });
        check(queueStillDispatches, "an activated already-active queue still dispatches");
        dispatch_release(group);
        dispatch_release(createdQueue);

        dispatch_release(queue);

        if (failures) {
            printf("wk_dispatch_activate: %d check(s) FAILED\n", failures);
            return 1;
        }
        printf("wk_dispatch_activate: all checks passed\n");
    }
    return 0;
}
