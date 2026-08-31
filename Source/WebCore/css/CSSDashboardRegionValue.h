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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
 */

// MAVERICKS_BACKPORT: CSS value backing the legacy -apple-dashboard-region property (control
// regions used by 10.9 Dashboard widgets). The whole subsystem was removed upstream in 2d364c6;
// this is a modern reimplementation (the 2019 version stored regions inside CSSPrimitiveValue,
// which no longer supports arbitrary ref types, so a dedicated CSSValue subclass is used).

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
        RefPtr<CSSPrimitiveValue> top;
        RefPtr<CSSPrimitiveValue> right;
        RefPtr<CSSPrimitiveValue> bottom;
        RefPtr<CSSPrimitiveValue> left;
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
