// PDFDocumentImage's document backend on this port: hayro (platform/graphics/hayro, wk_pdf.h) parses the
// PDF and replays its first page as CoreGraphics drawing in the context PDFDocumentImage draws into.
// libwk_pdf is loaded on first use from the Frameworks directory beside WebCore, where it ships.

#include "config.h"
#include "PDFDocumentImage.h"

#if USE(HAYRO_FOR_PDFDOCUMENTIMAGE)

#include "GraphicsContext.h"
#include "SharedBuffer.h"
#include <dlfcn.h>
#include <mutex>
#include <wk_pdf.h>
#include <wtf/FileSystem.h>
#include <wtf/text/CString.h>

namespace WebCore {

namespace {

struct WKPDFLibrary {
    decltype(&wk_pdf_document_create) create { nullptr };
    decltype(&wk_pdf_document_destroy) destroy { nullptr };
    decltype(&wk_pdf_document_page_count) pageCount { nullptr };
    decltype(&wk_pdf_document_first_page_bounds) firstPageBounds { nullptr };
    decltype(&wk_pdf_document_draw_first_page) drawFirstPage { nullptr };
};

const WKPDFLibrary& wkPDFLibrary()
{
    static std::once_flag once;
    static WKPDFLibrary library;
    std::call_once(once, [] {
        Dl_info info;
        dladdr(reinterpret_cast<const void*>(&wkPDFLibrary), &info);
        auto directory = FileSystem::parentPath(String::fromUTF8(info.dli_fname));
        auto path = FileSystem::pathByAppendingComponent(FileSystem::pathByAppendingComponent(directory, "Frameworks"_s), "libwk_pdf.dylib"_s);
        void* handle = dlopen(path.utf8().data(), RTLD_LAZY | RTLD_LOCAL);
        library.create = reinterpret_cast<decltype(library.create)>(dlsym(handle, "wk_pdf_document_create"));
        library.destroy = reinterpret_cast<decltype(library.destroy)>(dlsym(handle, "wk_pdf_document_destroy"));
        library.pageCount = reinterpret_cast<decltype(library.pageCount)>(dlsym(handle, "wk_pdf_document_page_count"));
        library.firstPageBounds = reinterpret_cast<decltype(library.firstPageBounds)>(dlsym(handle, "wk_pdf_document_first_page_bounds"));
        library.drawFirstPage = reinterpret_cast<decltype(library.drawFirstPage)>(dlsym(handle, "wk_pdf_document_draw_first_page"));
    });
    return library;
}

} // namespace

void PDFDocumentImage::HayroDocumentDeleter::operator()(WKPDFDocument* document) const
{
    wkPDFLibrary().destroy(document);
}

void PDFDocumentImage::createPDFDocument()
{
    auto buffer = protect(data())->makeContiguous();
    auto bytes = buffer->span();
    m_document = std::unique_ptr<WKPDFDocument, HayroDocumentDeleter>(wkPDFLibrary().create(bytes.data(), bytes.size()));
}

void PDFDocumentImage::computeBoundsForCurrentPage()
{
    WKPDFPageBounds bounds { };
    if (!wkPDFLibrary().firstPageBounds(m_document.get(), &bounds))
        return;
    m_cropBox = FloatRect(bounds.x, bounds.y, bounds.width, bounds.height);
    m_rotationDegrees = bounds.rotation;
}

unsigned PDFDocumentImage::pageCount() const
{
    return wkPDFLibrary().pageCount(m_document.get());
}

void PDFDocumentImage::drawPDFPage(GraphicsContext& context)
{
    wkPDFLibrary().drawFirstPage(m_document.get(), context.platformContext());
}

} // namespace WebCore

#endif // USE(HAYRO_FOR_PDFDOCUMENTIMAGE)
