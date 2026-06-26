// MAVERICKS_BACKPORT: this translation unit is reduced to an empty stub on 10.9. The upstream
// CoreLocation-backed geolocation provider relies on CLLocationManager authorization/delegate APIs
// (e.g. requestWhenInUseAuthorization, locationManagerDidChangeAuthorization:) that are not available
// on macOS 10.9, so no Core Location provider is compiled in; the source remains listed in the build.
// Stubbed for 10.9
#include "config.h"
