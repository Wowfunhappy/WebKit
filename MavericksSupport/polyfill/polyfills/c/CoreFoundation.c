// CoreFoundation: entry points modern WebKit calls that 10.9's CoreFoundation does not export.
#include "wk_polyfill.h"

#include <CoreFoundation/CoreFoundation.h>
#include <xpc/xpc.h>

// ---------------------------------------------------------------------------------------------------
// CoreFoundation prefs daemon tuning — optimizations for sandboxed XPC services; no-ops on 10.9.
// ---------------------------------------------------------------------------------------------------

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetDirectModeEnabled, (int enabled))
{
    (void)enabled;
}

WK_POLYFILL_ABSENT("CoreFoundation", void, _CFPrefsSetReadOnly, (Boolean flag))
{
    (void)flag;
}

// The XPC bootstrap-dictionary channel is absent on 10.9 (see xpc_copy_bootstrap and
// xpc_connection_set_bootstrap in libSystem.m). This fills a bootstrap dictionary with the caller
// bundle's identity; with no bootstrap channel there is nothing to fill in, so the dictionary the
// caller passes is simply left as it was.
WK_POLYFILL_ABSENT("CoreFoundation", void, _CFBundleSetupXPCBootstrap, (xpc_object_t bootstrap))
{
    (void)bootstrap;
}
