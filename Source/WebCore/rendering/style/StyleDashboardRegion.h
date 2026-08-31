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
// `dashboard-region(<label> <geometry> <top> <right> <bottom> <left>)` insets the region from the element's
// border box by the four offsets, which shipping widgets do use (Calculator splits one element into two 43px-
// apart circles that way). They resolve to fixed pixels at style-build time.

#pragma once

#if ENABLE(DASHBOARD_SUPPORT)

#include <wtf/text/WTFString.h>

namespace WebCore {

// Dashboard region attributes. Not inherited.

struct StyleDashboardRegion {
    String label;
    int type;
    float top { 0 };
    float right { 0 };
    float bottom { 0 };
    float left { 0 };

    enum {
        None,
        Circle,
        Rectangle
    };

    bool operator==(const StyleDashboardRegion& o) const
    {
        return type == o.type && label == o.label
            && top == o.top && right == o.right && bottom == o.bottom && left == o.left;
    }

    bool operator!=(const StyleDashboardRegion& o) const
    {
        return !(*this == o);
    }
};

} // namespace WebCore

#endif // ENABLE(DASHBOARD_SUPPORT)
