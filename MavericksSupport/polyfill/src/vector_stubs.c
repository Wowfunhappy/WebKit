/* Replacement stubs for SandboxExtension Vector-returning methods.
 * The originals in final_stubs.o are 3-byte "xorl %eax, %eax; retq" stubs
 * that don't initialize the struct-return output buffer, leaving garbage
 * that crashes the Vector destructor.
 *
 * These replacements properly zero the 16-byte Vector buffer (ptr=0, size=0,
 * capacity=0) so the destructor's NULL-check catches it.
 */
#include <string.h>

/* Vector layout: 8-byte buffer ptr + 4-byte size + 4-byte capacity = 16 bytes */
#define ZERO_VECTOR(out) memset((out), 0, 16)

/* SandboxExtension::createHandlesForMachLookup (span overload) */
void _ZN6WebKit16SandboxExtension26createHandlesForMachLookupENSt3__14spanIKN3WTF12ASCIILiteralELm18446744073709551615EEENS1_8optionalI13audit_token_tEENS0_20MachBootstrapOptionsENS3_9OptionSetINS_21SandboxExtensionFlagsELNS3_14ConcurrencyTagE0EEE(void* out)
{
    ZERO_VECTOR(out);
}

/* SandboxExtension::createHandlesForMachLookup (initializer_list overload) */
void _ZN6WebKit16SandboxExtension26createHandlesForMachLookupESt16initializer_listIKN3WTF12ASCIILiteralEENSt3__18optionalI13audit_token_tEENS0_20MachBootstrapOptionsENS2_9OptionSetINS_21SandboxExtensionFlagsELNS2_14ConcurrencyTagE0EEE(void* out)
{
    ZERO_VECTOR(out);
}

/* SandboxExtension::createHandlesForIOKitClassExtensions */
void _ZN6WebKit16SandboxExtension36createHandlesForIOKitClassExtensionsENSt3__14spanIKN3WTF12ASCIILiteralELm18446744073709551615EEENS1_8optionalI13audit_token_tEENS3_9OptionSetINS_21SandboxExtensionFlagsELNS3_14ConcurrencyTagE0EEE(void* out)
{
    ZERO_VECTOR(out);
}

/* AuxiliaryProcessProxy::platformOverrideLanguages() const
 * Returns empty Vector<String> - we don't have language overrides anyway. */
void _ZNK6WebKit21AuxiliaryProcessProxy25platformOverrideLanguagesEv(void* out)
{
    ZERO_VECTOR(out);
}

/* AuxiliaryProcessProxy::fetchAudioComponentServerRegistrations()
 * Returns RefPtr<SharedBuffer>(nullptr) - 8 bytes of zero. */
void _ZN6WebKit21AuxiliaryProcessProxy38fetchAudioComponentServerRegistrationsEv(void* out)
{
    *(void**)out = 0;
}
