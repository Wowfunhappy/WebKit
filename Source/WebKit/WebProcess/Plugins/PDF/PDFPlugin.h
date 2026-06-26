#pragma once
// Stubbed for MAVERICKS_BACKPORT

#if ENABLE(PDF_PLUGIN)

namespace WebKit {

class PDFPlugin {
public:
    static bool pdfKitLayerControllerIsAvailable() { return false; }
};

} // namespace WebKit

#endif
