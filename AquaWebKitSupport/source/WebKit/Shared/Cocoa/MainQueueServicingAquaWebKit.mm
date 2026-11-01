#import "config.h"
#import "MainQueueServicingAquaWebKit.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <limits>
#import <mach/mach.h>
#import <wtf/RetainPtr.h>

extern "C" {
mach_port_t _dispatch_get_main_queue_port_4CF(void);
void _dispatch_main_queue_callback_4CF(mach_msg_header_t*);
void* _CFGetTSD(uint32_t slot);
void* _CFSetTSD(uint32_t slot, void* value, void (*destructor)(void*));
}

namespace WebKit {

// CoreFoundation's thread-specific slot that marks the main queue as being serviced, and the value
// __CFRunLoopRun stores in it around _dispatch_main_queue_callback_4CF.
static constexpr uint32_t isInGCDMainQueueSlot = 4;
static void* const isInGCDMainQueueValue = reinterpret_cast<void*>(6);

// The same receive __CFRunLoopServiceMachPort performs with a zero timeout: a received message larger than
// the buffer stays queued and the run loop services it.
static void serviceMainQueue(CFRunLoopObserverRef, CFRunLoopActivity, void*)
{
    if (_CFGetTSD(isInGCDMainQueueSlot))
        return;

    mach_port_t port = _dispatch_get_main_queue_port_4CF();
    alignas(mach_msg_header_t) uint8_t buffer[3 * 1024];
    auto* message = reinterpret_cast<mach_msg_header_t*>(buffer);
    message->msgh_bits = 0;
    message->msgh_local_port = port;
    message->msgh_remote_port = MACH_PORT_NULL;
    message->msgh_size = sizeof(buffer);
    message->msgh_id = 0;
    mach_msg_option_t options = MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TIMEOUT
        | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AV);
    if (mach_msg(message, options, 0, sizeof(buffer), port, 0, MACH_PORT_NULL) != MACH_MSG_SUCCESS)
        return;

    _CFSetTSD(isInGCDMainQueueSlot, isInGCDMainQueueValue, nullptr);
    @autoreleasepool {
        _dispatch_main_queue_callback_4CF(message);
    }
    _CFSetTSD(isInGCDMainQueueSlot, nullptr, nullptr);
}

void serviceMainQueueAtRunLoopExit()
{
    // First among the exit observers, ahead of the rendering update and the Core Animation commit. Common
    // modes only, as __CFRunLoopRun services the main queue only in a common mode.
    RetainPtr observer = adoptCF(CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopExit, true, std::numeric_limits<CFIndex>::min(), serviceMainQueue, nullptr));
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer.get(), kCFRunLoopCommonModes);
}

} // namespace WebKit
