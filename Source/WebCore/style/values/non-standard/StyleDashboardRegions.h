/*
 * Copyright (C) 2026 Wowfunhappy. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

// AQUAWEBKIT: computed-style storage for the legacy -apple-dashboard-region property
// (control regions used by 10.9 Dashboard widgets).

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
