// Metal: entry points modern WebKit references from Metal.framework, which 10.9 does not ship at all.
// WebKit2 weak-links it, so a reference binds to address 0 and a call would branch there; these
// definitions give each a defined "no device" answer instead. Network.c explains why gap-filling an
// entirely absent framework is regression-free.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>

// Metal. "No devices" is what a machine without Metal has, but the two entry points spell that
// differently and the difference matters to a CF-side caller: MTLCreateSystemDefaultDevice() returns
// an id, whose documented "no Metal device" answer is nil, while MTLCopyAllDevices() returns
// NSArray<id<MTLDevice>> * NS_RETURNS_RETAINED, whose answer is an EMPTY array. Handing back NULL
// there would fault any caller that goes straight to CFArrayGetCount/CFArrayGetValueAtIndex instead
// of sending an ObjC message.
WK_POLYFILL_ABSENT("Metal", void *, MTLCreateSystemDefaultDevice, (void))
{ return NULL; }
WK_POLYFILL_ABSENT("Metal", CFArrayRef, MTLCopyAllDevices, (void))
{ return CFArrayCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeArrayCallBacks); }
