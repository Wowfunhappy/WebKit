// Firefox's dns.resolve for Safari 7 extensions: a host name resolved by the system resolver, as Firefox's
// native resolver resolves it.

#pragma once

#include <wtf/CompletionHandler.h>
#include <wtf/Expected.h>
#include <wtf/JSONValues.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit::LegacyExtensions {

// Resolves `hostname` off the main thread with Firefox's ResolveFlags names in `flags`, and answers on the
// main thread with a DNSRecord `{ addresses, canonicalName, isTRR }` or an nsresult name. `prefetchDisabled`
// is whether DNS prefetching is off, which refuses a `speculate` lookup as Firefox does.
void resolveHostname(const String& hostname, const Vector<String>& flags, bool prefetchDisabled, CompletionHandler<void(Expected<Ref<JSON::Object>, String>&&)>&&);

} // namespace WebKit::LegacyExtensions
