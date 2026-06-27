/*
 * Copyright (C) 2004-2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.
 */

// MAVERICKS_BACKPORT: see WebDashboardRegion.h.

#import "WebDashboardRegion.h"

@implementation WebDashboardRegion

- (id)initWithRect:(NSRect)r clip:(NSRect)c type:(WebDashboardRegionType)t
{
    self = [super init];
    if (!self)
        return nil;
    rect = r;
    clip = c;
    type = t;
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[WebDashboardRegion allocWithZone:zone] initWithRect:rect clip:clip type:type];
}

- (NSRect)dashboardRegionClip
{
    return clip;
}

- (NSRect)dashboardRegionRect
{
    return rect;
}

- (WebDashboardRegionType)dashboardRegionType
{
    return type;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"WebDashboardRegion rect:%@ clip:%@ type:%d", NSStringFromRect(rect), NSStringFromRect(clip), (int)type];
}

@end
