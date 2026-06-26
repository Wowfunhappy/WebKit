// MAVERICKS_BACKPORT: Stub replacing base 83b24ce's BrowserEngineKit/UIKit alias table.
// Those WKBE* -> BE*/UIWK* defines target iOS 16+ BrowserEngineKit and UIKit types absent on
// 10.9; this Mac build never instantiates them, so the whole mapping is reduced to a no-op.
#pragma once
