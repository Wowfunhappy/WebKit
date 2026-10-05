// An extension's files, which only Safari's process can read: safari-extension:// loads in a satellite's
// pages go through its UI process's custom protocol to the hub, which loads them through Safari's.

#pragma once

#include <wtf/CompletionHandler.h>
#include <wtf/Forward.h>
#include <wtf/JSONValues.h>
#include <wtf/Vector.h>

namespace WebKit::LegacyExtensions {

using ResourceCompletionHandler = CompletionHandler<void(std::optional<Vector<uint8_t>>&&, String&& mimeType)>;

// The hub.
void loadExtensionResource(const URL&, ResourceCompletionHandler&&);
Ref<JSON::Object> fetchedMessage(double fetchID, std::optional<Vector<uint8_t>>&&, String&& mimeType);

// A satellite.
void serveExtensionResources(Function<void(const URL&, ResourceCompletionHandler&&)>&& fetch);

} // namespace WebKit::LegacyExtensions
