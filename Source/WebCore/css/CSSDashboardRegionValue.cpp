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

// MAVERICKS_BACKPORT: see CSSDashboardRegionValue.h.

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
            result.append(", "_s);

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
