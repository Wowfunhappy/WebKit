/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES ARE DISCLAIMED.
 */

// MAVERICKS_BACKPORT: computed-style storage for the legacy -apple-dashboard-region property
// (control regions used by 10.9 Dashboard widgets). Removed upstream in 2d364c6.

#pragma once

#if ENABLE(DASHBOARD_SUPPORT)

#include <WebCore/StyleDashboardRegion.h>
#include <WebCore/StyleValueTypes.h>
#include <wtf/Vector.h>

namespace WebCore {
namespace Style {

struct DashboardRegions {
    DashboardRegions() = default;
    DashboardRegions(CSS::Keyword::None) { }

    bool isNone() const { return list.isEmpty(); }

    Vector<WebCore::StyleDashboardRegion> list;

    bool operator==(const DashboardRegions&) const = default;
};

} // namespace Style
} // namespace WebCore

#endif // ENABLE(DASHBOARD_SUPPORT)
