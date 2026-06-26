// MAVERICKS_BACKPORT: Empty stub header provided for the 10.9 build. Base 83b24ce ships
// WKTextExtractionUtilities.mm and several #import "WKTextExtractionUtilities.h" sites
// (WKWebView.mm, WebPageProxy.cpp) but no matching header; the text-extraction utilities
// rely on newer-OS APIs we don't ship, so this header resolves those imports as a no-op.
#pragma once
