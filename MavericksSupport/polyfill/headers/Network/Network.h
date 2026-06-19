#ifndef _NETWORK_NETWORK_H_POLYFILL_
#define _NETWORK_NETWORK_H_POLYFILL_
/* Network.framework polyfill for macOS 10.9 (real framework requires 10.14+).
 * Provides opaque type declarations for nw_* types.
 * Define __NW_CONNECTION_H__ so NetworkSPI.h skips its own declarations. */
#define __NW_CONNECTION_H__ 1

#include <dispatch/dispatch.h>
#include <os/object.h>

#ifndef OS_OBJECT_RETURNS_RETAINED
#define OS_OBJECT_RETURNS_RETAINED
#endif

/* Only declare types NOT provided by CFNetworkSPI.h.
 * CFNetworkSPI.h provides: nw_array, nw_object, nw_context, nw_endpoint,
 * nw_resolver, nw_parameters, nw_path_evaluator, nw_proxy_config,
 * nw_protocol_options, nw_establishment_report, nw_context_privacy_level_t.
 * We provide the rest. */
#define NW_POLYFILL_TYPES_DECLARED 1

#if OS_OBJECT_USE_OBJC
/* ObjC mode: ALL types via OS_OBJECT_DECL */
OS_OBJECT_DECL(nw_connection);
OS_OBJECT_DECL(nw_listener);
OS_OBJECT_DECL(nw_path);
OS_OBJECT_DECL(nw_endpoint);
OS_OBJECT_DECL(nw_parameters);
OS_OBJECT_DECL(nw_protocol_definition);
OS_OBJECT_DECL(nw_protocol_options);
OS_OBJECT_DECL(nw_protocol_metadata);
OS_OBJECT_DECL(nw_connection_group);
OS_OBJECT_DECL(nw_resolver_config);
OS_OBJECT_DECL(nw_privacy_context);
OS_OBJECT_DECL(nw_interface);
OS_OBJECT_DECL(nw_resolver);
OS_OBJECT_DECL(nw_array);
OS_OBJECT_DECL(nw_context);
OS_OBJECT_DECL(nw_path_evaluator);
OS_OBJECT_DECL(nw_establishment_report);
OS_OBJECT_DECL(nw_object);
OS_OBJECT_DECL(nw_proxy_config);
typedef enum {
    nw_context_privacy_level_public = 1,
    nw_context_privacy_level_private = 2,
    nw_context_privacy_level_sensitive = 3,
    nw_context_privacy_level_silent = 4,
} nw_context_privacy_level_t;
#else
/* C/C++ mode: define ALL types since CFNetworkSPI.h ObjC declarations don't apply */
typedef void *nw_connection_t;
typedef void *nw_listener_t;
typedef void *nw_path_t;
typedef void *nw_endpoint_t;
typedef void *nw_parameters_t;
typedef void *nw_protocol_definition_t;
typedef void *nw_protocol_options_t;
typedef void *nw_protocol_metadata_t;
typedef void *nw_connection_group_t;
typedef void *nw_resolver_config_t;
typedef void *nw_privacy_context_t;
typedef void *nw_interface_t;
typedef void *nw_resolver_t;
typedef void *nw_array_t;
typedef void *nw_context_t;
typedef void *nw_path_evaluator_t;
typedef void *nw_establishment_report_t;
typedef void *nw_object_t;
typedef void *nw_proxy_config_t;
typedef unsigned int nw_context_privacy_level_t;
#endif

typedef void (^nw_parameters_configure_protocol_block_t)(void *);

/* Types needed by NetworkSoftLink.h (normally from NetworkSPI.h, which is skipped
   because we define __NW_CONNECTION_H__). */
typedef struct nw_http_fields *nw_http_fields_t;
typedef nw_http_fields_t nw_http_response_t;
typedef void (^nw_http_optional_string_accessor_t)(const char * _Nullable string);

#endif /* _NETWORK_NETWORK_H_POLYFILL_ */
