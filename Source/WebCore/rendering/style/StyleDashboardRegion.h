/*
 * Copyright (C) 2000 Lars Knoll (knoll@kde.org)
 *           (C) 2000 Antti Koivisto (koivisto@kde.org)
 *           (C) 2000 Dirk Mueller (mueller@kde.org)
 * Copyright (C) 2003, 2005, 2006, 2007, 2008 Apple Inc. All rights reserved.
 * Copyright (C) 2006 Graham Dennis (graham.dennis@gmail.com)
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

// MAVERICKS_BACKPORT: restored with legacy Dashboard control-region support (removed upstream in 2d364c6).
// Every Dashboard widget declares its regions as `dashboard-region(<label> <geometry> 0 0 0 0)` — i.e. zero
// offsets, so the control region is simply the element's own border box. The 2019 implementation also carried a
// LengthBox of per-edge offsets, but that box type no longer exists in modern WebKit and no shipping widget uses
// non-zero offsets, so the offsets are parsed (for compatibility) and the region rect is taken from the renderer's
// border box at collection time.

#pragma once

#if ENABLE(DASHBOARD_SUPPORT)

#include <wtf/text/WTFString.h>

namespace WebCore {

// Dashboard region attributes. Not inherited.

struct StyleDashboardRegion {
    String label;
    int type;

    enum {
        None,
        Circle,
        Rectangle
    };

    bool operator==(const StyleDashboardRegion& o) const
    {
        return type == o.type && label == o.label;
    }

    bool operator!=(const StyleDashboardRegion& o) const
    {
        return !(*this == o);
    }
};

} // namespace WebCore

#endif // ENABLE(DASHBOARD_SUPPORT)
