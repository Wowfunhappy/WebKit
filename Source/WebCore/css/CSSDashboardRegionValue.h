/*
 * (C) 1999-2003 Lars Knoll (knoll@kde.org)
 * Copyright (C) 2004, 2005, 2006, 2008 Apple Inc. All rights reserved.
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

// AQUAWEBKIT: legacy Dashboard control regions hold numeric or auto offsets.

#pragma once

#if ENABLE(DASHBOARD_SUPPORT)

#include "CSSPrimitiveValue.h"
#include "CSSValue.h"
#include <wtf/Function.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class CSSDashboardRegionValue final : public CSSValue {
public:
    // Mirrors StyleDashboardRegion's geometry enum: 0 = None, 1 = Circle, 2 = Rectangle.
    struct Region {
        String label;
        int geometryType { 0 };
        RefPtr<CSSValue> top;
        RefPtr<CSSValue> right;
        RefPtr<CSSValue> bottom;
        RefPtr<CSSValue> left;
    };

    static Ref<CSSDashboardRegionValue> create(Vector<Region>&& regions)
    {
        return adoptRef(*new CSSDashboardRegionValue(WTF::move(regions)));
    }

    const Vector<Region>& regions() const { return m_regions; }

    String customCSSText(const CSS::SerializationContext&) const;
    bool equals(const CSSDashboardRegionValue&) const;

    IterationStatus customVisitChildren(NOESCAPE const Function<IterationStatus(CSSValue&)>& func) const
    {
        for (auto& region : m_regions) {
            if (region.top && func(*region.top) == IterationStatus::Done)
                return IterationStatus::Done;
            if (region.right && func(*region.right) == IterationStatus::Done)
                return IterationStatus::Done;
            if (region.bottom && func(*region.bottom) == IterationStatus::Done)
                return IterationStatus::Done;
            if (region.left && func(*region.left) == IterationStatus::Done)
                return IterationStatus::Done;
        }
        return IterationStatus::Continue;
    }

private:
    explicit CSSDashboardRegionValue(Vector<Region>&& regions)
        : CSSValue(ClassType::DashboardRegion)
        , m_regions(WTF::move(regions))
    {
    }

    Vector<Region> m_regions;
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_CSS_VALUE(CSSDashboardRegionValue, isDashboardRegionValue())

#endif // ENABLE(DASHBOARD_SUPPORT)
