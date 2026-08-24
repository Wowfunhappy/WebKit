// PowerLog: the one entry point modern WebKit references from PowerLog.framework, which 10.9 does not
// ship at all. GPUProcessProxyCocoa.mm weak-imports it and null-checks the pointer before calling, so
// the reference binds to address 0 and the call is already guarded -- but a weak reference nothing on
// the host provides is exactly what the absent-reference gate refuses, and a definition here is the
// honest answer rather than a load command for an image that does not exist.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>

// PLQueryRegistered answers a query addressed to a registered PowerLog client. Its documented "no
// answer" return is NULL, which is what a machine with no PowerLog daemon produces for every query;
// GPUProcessProxy::isPowerLoggingInTaskMode() reads that as "not in task mode" and the GPU process
// leaves power logging off, exactly as it does on a Mac where the query returns nothing.
WK_POLYFILL_ABSENT("PowerLog", CFDictionaryRef, PLQueryRegistered, (short clientID, CFStringRef queryName, CFDictionaryRef parameters))
{
    (void)clientID;
    (void)queryName;
    (void)parameters;
    return NULL;
}
