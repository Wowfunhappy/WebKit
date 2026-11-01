// The GCD main queue, serviced at the exit of each run of the main run loop in WebKit's XPC services.
//
// CoreFoundation services the main queue from a run's wait set and, from the run's second iteration, by a
// direct receive on the main-queue port. CoreFoundation adds that port to the wait set before each wait;
// XNU 2422's ipc_mqueue_add does not prepost a port set when a port with queued messages joins it, so the
// main queue's pending wake-up stays invisible to the set receive. A run that returns after its first
// handled source (-[NSRunLoop runMode:beforeDate:]) never reaches the direct receive, and while a version-0
// source is signalled at every run entry the main queue is not serviced at all. Where the kernel preposts,
// the set receive of the run's first iteration delivers the wake-up after that iteration's version-0
// sources and before the run's exit observers; the drain takes that place.

#pragma once

namespace WebKit {

// Called on the main thread before the service's run loop starts.
void serviceMainQueueAtRunLoopExit();

} // namespace WebKit
