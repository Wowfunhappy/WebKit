/*
 * The Network.framework resolver-configuration entry point TestController::platformDestroy calls on
 * macOS 10.9, which has no Network.framework. This build compiles out initializeDNS
 * (ENABLE_DNS_SERVER_FOR_TESTING is 0), so no resolver configuration is ever published and there is
 * nothing to unpublish.
 */

#import "config.h"

#import <pal/spi/cocoa/NetworkSPI.h>

void nw_resolver_config_unpublish(nw_resolver_config_t)
{
}
