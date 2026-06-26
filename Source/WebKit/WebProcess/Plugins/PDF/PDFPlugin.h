#pragma once
// Stubbed for MAVERICKS_BACKPORT

#if ENABLE(PDF_PLUGIN)

namespace WebKit {

// MAVERICKS_BACKPORT: inline PDFs DOWNLOAD (open in Preview) on 10.9; the full PDFKit-backed plugin is stubbed out.
class PDFPlugin {
public:
    // MAVERICKS_BACKPORT: stub always reports the PDFKit layer controller as unavailable so no inline plugin is created.
    static bool pdfKitLayerControllerIsAvailable() { return false; }
};

} // namespace WebKit

// MAVERICKS_BACKPORT: end of the stubbed PDF_PLUGIN body.
#endif
