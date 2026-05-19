#pragma once
// Stubbed for macOS 10.9 backport

#if ENABLE(PDF_PLUGIN)

namespace WebKit {

class PDFPlugin {
public:
    static bool pdfKitLayerControllerIsAvailable() { return false; }
};

} // namespace WebKit

#endif
