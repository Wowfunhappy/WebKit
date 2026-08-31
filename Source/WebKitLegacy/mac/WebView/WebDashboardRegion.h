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

// MAVERICKS_BACKPORT: restored value object for the legacy Dashboard control-region SPI removed upstream
// in e4325475 ("Remove Legacy Dashboard Support"). macOS 10.9's DashboardClient reads dashboardRegionType /
// dashboardRegionRect / dashboardRegionClip from the objects in -[WebView _dashboardRegions].

#import <Foundation/Foundation.h>

typedef enum {
    WebDashboardRegionTypeNone,
    WebDashboardRegionTypeCircle,
    WebDashboardRegionTypeRectangle,
    WebDashboardRegionTypeScrollerRectangle
} WebDashboardRegionType;

@interface WebDashboardRegion : NSObject <NSCopying> {
    NSRect rect;
    NSRect clip;
    WebDashboardRegionType type;
}
- (id)initWithRect:(NSRect)rect clip:(NSRect)clip type:(WebDashboardRegionType)type;
- (NSRect)dashboardRegionClip;
- (NSRect)dashboardRegionRect;
- (WebDashboardRegionType)dashboardRegionType;
@end
