// Network: entry points and constants modern WebKit references from Network.framework, which 10.9
// does not ship at all.
#include "wk_polyfill.h"

#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// WebTransport's only implementation is the Cocoa network path
// (NetworkProcess/webtransport/cocoa/NetworkTransport{Session,Stream}Cocoa.mm), built on
// Network.framework. The three constants it reads are an nw_content_context_t and two
// nw_parameters_configure_protocol_block_t, and NULL is the truthful 10.9 value for all three: there
// is no Network.framework, so there is no default message context and no configure block.
//
// These are declared for the same reason as the Security block above -- so that reading one cannot
// fault. WebTransportEnabled keeps upstream's default, so the JS constructor is exposed; what keeps
// the nw_* functions from being called is NetworkTransportSession::create, which first asks
// canLoad_Network_nw_parameters_create_webtransport_http() and its three siblings. Those resolve
// through the absent-provider dlopen token, which answers NULL for every Network.framework name, so
// create() returns nullptr and a page's `new WebTransport(url)` fails to connect before any nw_*
// call is reached.
// Every definition in this file answers "10.9 ships no Network.framework". They are declared WEAK so
// an image that implements these entry points for itself binds its own -- TestWebKitAPI's HTTPServer
// does, over sockets and SecureTransport -- while every other image, which has no such implementation,
// still gets the answer here.
typedef void *PolyVoidPtrConst;
WK_POLYFILL_CONST_WEAK("Network", PolyVoidPtrConst, _nw_content_context_default_message, NULL);
WK_POLYFILL_CONST_WEAK("Network", PolyVoidPtrConst, _nw_parameters_configure_protocol_default_configuration, NULL);
WK_POLYFILL_CONST_WEAK("Network", PolyVoidPtrConst, _nw_parameters_configure_protocol_disable, NULL);

// ---------------------------------------------------------------------------------------------------
// Network.framework known-tracker lookup — Network.framework is empty on 10.9, so these two entry
// points are absent. ResourceError::blockedTrackerHostName() reads them only when an NSError carries
// an _NSURLErrorNWPathKey, a key the 10.9 loaders never attach; the caller tolerates a null result
// (an empty tracker host name). The nw_path_t / nw_endpoint_t handles are opaque pointers.
// ---------------------------------------------------------------------------------------------------

// Copies the effective remote endpoint from a network path. No such path object is ever produced on
// 10.9, so this returns null.
WK_POLYFILL_ABSENT("Network", const void *, nw_path_copy_effective_remote_endpoint, (const void *path))
{
    (void)path;
    return NULL;
}

// Returns the known-tracker host name an endpoint resolved to, or null when it is not a known tracker.
// On 10.9 there is no tracker-classification engine, so this returns null.
WK_POLYFILL_ABSENT("Network", const char *, nw_endpoint_get_known_tracker_name, (const void *endpoint))
{
    (void)endpoint;
    return NULL;
}

// Copies the proxy endpoint a connection was established through. NetworkSessionCocoa reads this to
// report a proxy's host name to Web Inspector; it comes off an NSURLSessionTaskTransactionMetrics
// _establishmentReport, and 10.9 has no such metrics object at all, so there is never a report to
// describe and null is the accurate answer. The caller already treats null as "no proxy name".
WK_POLYFILL_ABSENT("Network", const void *, nw_establishment_report_copy_proxy_endpoint, (const void *report))
{
    (void)report;
    return NULL;
}

// Returns an endpoint's host name. Reachable only with an endpoint from the call above, which 10.9
// never produces.
WK_POLYFILL_ABSENT("Network", const char *, nw_endpoint_get_hostname, (const void *endpoint))
{
    (void)endpoint;
    return NULL;
}

// ---------------------------------------------------------------------------------------------
// Network.framework (10.14+) — a framework 10.9 does not have AT ALL. (Metal.c covers Metal, the
// same way.)
//
// WebKit2 weak-links it, so every reference below binds to address 0 and a call branches there.
// The call sites do guard today: WebTransport's are behind canLoad_Network_* probes
// (NetworkTransportSessionCocoa.mm:258-262 returns nullptr before reaching any nw_* call).
// These entries are not written because those guards are believed broken; they are written
// because "the call site guards it" is a property of TODAY's call sites, invisible to the linker, and
// re-verified only by someone remembering to. A defined failure is the difference between a future
// unguarded call returning nil and jumping to 0.
//
// Gap-filling these is regression-free precisely BECAUSE the framework is absent, and that is what
// makes the set decidable rather than a judgement call. A gap-fill can only flip a soft-link probe
// for a name the layer actually supplies, and these names and the soft-linked ones are disjoint sets:
// NetworkSoftLink.mm soft-links nw_parameters_create_webtransport_http, the nw_webtransport_* family
// and nw_connection_abort_reads/writes, none of which appear below. dlsym therefore answers NULL for
// every canLoad_Network_* probe, create() returns nullptr at NetworkTransportSessionCocoa.mm:263, and
// the call sites keep taking their own absent-API paths. (Contrast the
// SecCertificateCopyNotValidAfterDate family: absent on 10.9, but Security.framework IS present, so a
// gap-fill there COULD flip a probe and make a caller believe a feature exists. Those stay inventory,
// and check-absent-references.sh splits the two cases on exactly this rule.)
//
// The signatures use opaque pointers rather than nw_*/MTL types: those headers describe frameworks
// that are not here, and this file deliberately does not include them. Every parameter is
// pointer-sized or an integer, so the ABI matches whatever a caller was compiled against.
//
// Every body below aborts. There is no Network.framework to carry the operation out, and a WebTransport
// endpoint that reports a created connection or an accepted send it never made stalls the caller
// forever; the definitions exist to satisfy the weak-linked reference, and reaching one means the
// canLoad_ gate above stopped holding.
static void __attribute__((noreturn)) wkNoNetworkFramework(const char *symbol)
{
    fprintf(stderr, "[wk_polyfill] FATAL: %s was called, but 10.9 has no Network.framework. "
                    "The canLoad_Network_* gate in NetworkTransportSession::create is supposed to "
                    "make every entry point in this block unreachable.\n", symbol);
    fflush(stderr);
    abort();
}

WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void *, nw_endpoint_create_url, (const char *url))
{ (void)url; wkNoNetworkFramework("nw_endpoint_create_url"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void *, nw_group_descriptor_create_multiplex, (void *endpoint))
{ (void)endpoint; wkNoNetworkFramework("nw_group_descriptor_create_multiplex"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void *, nw_connection_group_create, (void *descriptor, void *parameters))
{ (void)descriptor; (void)parameters; wkNoNetworkFramework("nw_connection_group_create"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_group_set_queue, (void *group, void *queue))
{ (void)group; (void)queue; wkNoNetworkFramework("nw_connection_group_set_queue"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_group_set_state_changed_handler, (void *group, void *handler))
{ (void)group; (void)handler; wkNoNetworkFramework("nw_connection_group_set_state_changed_handler"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_group_set_new_connection_handler, (void *group, void *handler))
{ (void)group; (void)handler; wkNoNetworkFramework("nw_connection_group_set_new_connection_handler"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_group_start, (void *group))
{ (void)group; wkNoNetworkFramework("nw_connection_group_start"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_group_cancel, (void *group))
{ (void)group; wkNoNetworkFramework("nw_connection_group_cancel"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void *, nw_connection_group_extract_connection, (void *group, void *endpoint, void *protocol))
{ (void)group; (void)endpoint; (void)protocol; wkNoNetworkFramework("nw_connection_group_extract_connection"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void *, nw_connection_group_copy_protocol_metadata, (void *group, void *definition))
{ (void)group; (void)definition; wkNoNetworkFramework("nw_connection_group_copy_protocol_metadata"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_start, (void *connection))
{ (void)connection; wkNoNetworkFramework("nw_connection_start"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_cancel, (void *connection))
{ (void)connection; wkNoNetworkFramework("nw_connection_cancel"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_set_queue, (void *connection, void *queue))
{ (void)connection; (void)queue; wkNoNetworkFramework("nw_connection_set_queue"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_set_state_changed_handler, (void *connection, void *handler))
{ (void)connection; (void)handler; wkNoNetworkFramework("nw_connection_set_state_changed_handler"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_send, (void *connection, void *content, void *context, bool is_complete, void *completion))
{ (void)connection; (void)content; (void)context; (void)is_complete; (void)completion; wkNoNetworkFramework("nw_connection_send"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_connection_receive, (void *connection, uint32_t minimum, uint32_t maximum, void *completion))
{ (void)connection; (void)minimum; (void)maximum; (void)completion; wkNoNetworkFramework("nw_connection_receive"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void *, nw_connection_copy_protocol_metadata, (void *connection, void *definition))
{ (void)connection; (void)definition; wkNoNetworkFramework("nw_connection_copy_protocol_metadata"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", int, nw_error_get_error_domain, (void *error))
{ (void)error; wkNoNetworkFramework("nw_error_get_error_domain"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", int, nw_error_get_error_code, (void *error))
{ (void)error; wkNoNetworkFramework("nw_error_get_error_code"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, nw_quic_set_max_datagram_frame_size, (void *options, uint16_t size))
{ (void)options; (void)size; wkNoNetworkFramework("nw_quic_set_max_datagram_frame_size"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void *, nw_tls_copy_sec_protocol_options, (void *options))
{ (void)options; wkNoNetworkFramework("nw_tls_copy_sec_protocol_options"); }
// The three sec_* entries are DECLARED by Security.framework's headers (SecProtocolTypes.h,
// SecProtocolOptions.h) even though Network.framework is what implements them, so unlike the nw_*
// entries above these must use the real SDK types -- this file includes <Security/Security.h>.
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, sec_protocol_options_set_peer_authentication_required, (sec_protocol_options_t options, bool peer_authentication_required))
{ (void)options; (void)peer_authentication_required; wkNoNetworkFramework("sec_protocol_options_set_peer_authentication_required"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", void, sec_protocol_options_set_verify_block, (sec_protocol_options_t options, sec_protocol_verify_t verify_block, dispatch_queue_t verify_block_queue))
{ (void)options; (void)verify_block; (void)verify_block_queue; wkNoNetworkFramework("sec_protocol_options_set_verify_block"); }
WK_POLYFILL_ABSENT_FATAL_WEAK("Network", SecTrustRef, sec_trust_copy_ref, (sec_trust_t trust))
{ (void)trust; wkNoNetworkFramework("sec_trust_copy_ref"); }
