// The C interface of wk_pdf (src/lib.rs): hayro parses a PDF and replays its first page as CoreGraphics
// drawing.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WKPDFDocument WKPDFDocument;

// The first page's crop box (intersected with its media box), or its media box where that is empty, in
// PDF user space, and its /Rotate in degrees (0, 90, 180 or 270).
typedef struct {
    double x;
    double y;
    double width;
    double height;
    int32_t rotation;
} WKPDFPageBounds;

// NULL when the bytes are not a PDF hayro can open.
WKPDFDocument *wk_pdf_document_create(const uint8_t *data, size_t length);
void wk_pdf_document_destroy(WKPDFDocument *);
size_t wk_pdf_document_page_count(const WKPDFDocument *);
bool wk_pdf_document_first_page_bounds(const WKPDFDocument *, WKPDFPageBounds *);
// Draws the first page into `context`, a CGContextRef whose user space is the page as displayed: its
// rotated crop box at the origin, y up, one unit per point.
bool wk_pdf_document_draw_first_page(const WKPDFDocument *, void *context);

#ifdef __cplusplus
}
#endif
