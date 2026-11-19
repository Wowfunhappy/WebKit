/*
 * (C) 1999-2003 Lars Knoll (knoll@kde.org)
 * Copyright (C) 2004, 2005, 2006, 2007, 2008, 2012, 2013 Apple Inc. All rights reserved.
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
 */

// AQUAWEBKIT: see CSSDashboardRegionValue.h.

#include "config.h"
#include "CSSDashboardRegionValue.h"

#if ENABLE(DASHBOARD_SUPPORT)

#include <wtf/text/StringBuilder.h>

namespace WebCore {

String CSSDashboardRegionValue::customCSSText(const CSS::SerializationContext& context) const
{
    StringBuilder result;
    for (auto& region : m_regions) {
        if (!result.isEmpty())
            result.append(' ');

        if (region.geometryType == 0 /* None */) {
            result.append("none"_s);
            continue;
        }

        result.append("dashboard-region("_s);
        result.append(region.label);
        result.append(' ');
        result.append(region.geometryType == 1 /* Circle */ ? "circle"_s : "rectangle"_s);
        if (region.top)
            result.append(' ', region.top->cssText(context));
        if (region.right)
            result.append(' ', region.right->cssText(context));
        if (region.bottom)
            result.append(' ', region.bottom->cssText(context));
        if (region.left)
            result.append(' ', region.left->cssText(context));
        result.append(')');
    }
    return result.toString();
}

bool CSSDashboardRegionValue::equals(const CSSDashboardRegionValue& other) const
{
    if (m_regions.size() != other.m_regions.size())
        return false;
    for (size_t i = 0; i < m_regions.size(); ++i) {
        auto& a = m_regions[i];
        auto& b = other.m_regions[i];
        if (a.label != b.label || a.geometryType != b.geometryType)
            return false;
        if (!compareCSSValuePtr(a.top, b.top) || !compareCSSValuePtr(a.right, b.right)
            || !compareCSSValuePtr(a.bottom, b.bottom) || !compareCSSValuePtr(a.left, b.left))
            return false;
    }
    return true;
}

} // namespace WebCore

#endif // ENABLE(DASHBOARD_SUPPORT)
