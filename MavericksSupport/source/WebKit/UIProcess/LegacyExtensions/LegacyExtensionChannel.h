// The channel between Safari's UI process, where Safari 7 extensions run, and the UI processes of other
// apps whose web views act as Safari tabs to them. Safari's process is the hub; each other process is a
// satellite. Messages are JSON objects, sent on a queue of their own and received on the main run loop
// in the order they were sent; a send waits for room in its peer's queue for as long as the peer lives.
// A peer that exits goes away.

#pragma once

#include <wtf/Function.h>
#include <wtf/JSONValues.h>

namespace WebKit::LegacyExtensions {

// The hub. A satellite is known by a number of its own from its hello to the end of its process. The hub
// answers a hello on a queue of its own with the welcome messages it was last given.
void startHub(Function<void(uint64_t satellite, Ref<JSON::Object>&&)>&& receive, Function<void(uint64_t satellite)>&& satelliteDidGoAway);
void setWelcomeMessages(Vector<Ref<JSON::Object>>&&);
void sendToSatellite(uint64_t satellite, const JSON::Object&);
Vector<uint64_t> satellites();

// A satellite connects to the hub when the hub runs, and again whenever it starts. While the hub runs,
// startSatellite returns once the hub's welcome messages are received.
void startSatellite(Function<void(uint64_t satelliteNumber)>&& didConnect, Function<void(Ref<JSON::Object>&&)>&& receive, Function<void()>&& hubDidGoAway);
void sendToHub(const JSON::Object&);

} // namespace WebKit::LegacyExtensions
