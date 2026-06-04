// macOS 10.9 backport: TCC framework not available. Stubbed.
#pragma once
typedef int TCCAccessPreflightResult;
#define kTCCAccessPreflightDenied 0
#define kTCCAccessPreflightUnknown 1
#define kTCCAccessPreflightGranted 2

// tcc_identity_t / tcc_identity_type_t are part of TCC's newer identity API (absent on 10.9).
// These appear only in soft-linked signatures (TCCSoftLink.h); the function is never resolved on
// 10.9, so the declared types only need to exist for compilation.
typedef struct __TCCIdentity *tcc_identity_t;
typedef uint32_t tcc_identity_type_t;
#define TCC_IDENTITY_CODE_BUNDLE_ID ((tcc_identity_type_t)0)
