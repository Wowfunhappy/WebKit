// MAVERICKS_BACKPORT: TCC framework not available. Stubbed.
#pragma once

#include <wtf/Compiler.h>
#include <wtf/Platform.h>

DECLARE_SYSTEM_HEADER

// MAVERICKS_BACKPORT: these constants MUST equal real TCC's TCCAccessPreflightResult enum (and the
// libtcc_polyfill shim that supplies TCCAccessPreflight on 10.9): Granted=0, Denied=1, Unknown=2.
// The shim (MavericksSupport/polyfill/src/tcc_polyfill.c) returns 0 to mean Granted for
// camera/microphone; MediaPermissionUtilities.mm compares the result against kTCCAccessPreflightGranted,
// so the value here must be 0 or the grant short-circuit never fires.
typedef int TCCAccessPreflightResult;
#define kTCCAccessPreflightGranted 0
#define kTCCAccessPreflightDenied 1
#define kTCCAccessPreflightUnknown 2

// tcc_identity_t / tcc_identity_type_t are part of TCC's newer identity API (absent on 10.9).
// These appear only in soft-linked signatures (TCCSoftLink.h); the function is never resolved on
// 10.9, so the declared types only need to exist for compilation.
typedef struct __TCCIdentity *tcc_identity_t;
typedef uint32_t tcc_identity_type_t;
#define TCC_IDENTITY_CODE_BUNDLE_ID ((tcc_identity_type_t)0)
