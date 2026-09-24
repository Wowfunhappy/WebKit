/*
 * Copyright (C) 2026. All rights reserved.
 * SPDX-License-Identifier: BSD-2-Clause
 */

#pragma once

#include <wtf/Ref.h>

namespace WebKit {

class NetworkDataTask;
class NetworkDataTaskClient;
class NetworkSession;
struct NetworkLoadParameters;

// The task for a load: its request retargeted by the process's WKExternalURLRewrite, if any, then
// curl for HTTP(S) and NSURLSession for local and registered custom protocols.
Ref<NetworkDataTask> createNetworkDataTaskCocoa(NetworkSession&, NetworkDataTaskClient&, const NetworkLoadParameters&);

} // namespace WebKit
