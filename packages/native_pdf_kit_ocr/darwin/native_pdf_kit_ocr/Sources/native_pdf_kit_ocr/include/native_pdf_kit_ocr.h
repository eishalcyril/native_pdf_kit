// Native OCR surface for native_pdf_kit_ocr.
//
// A page job runs on a private queue: it first tries the PDF text layer
// (PDFKit), and if that is insufficient it rasterizes the page with
// CoreGraphics and runs Apple Vision. Progress is polled from Dart, which
// keeps the whole pipeline off the platform thread without callbacks or
// platform channels.

#ifndef NATIVE_PDF_KIT_OCR_H
#define NATIVE_PDF_KIT_OCR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NPDFOCR_STATUS_RUNNING 1
#define NPDFOCR_STATUS_DONE 2
#define NPDFOCR_STATUS_CANCELLED 3
#define NPDFOCR_STATUS_FAILED 4

#define NPDFOCR_STAGE_PREPARING 0
#define NPDFOCR_STAGE_TEXT_LAYER 1
#define NPDFOCR_STAGE_RENDERING 2
#define NPDFOCR_STAGE_RECOGNIZING 3

/// Starts a PDF page job. `options_json` is a JSON object; see the Dart
/// `PdfOcrOptions.toJson` for the keys. Returns an opaque handle or NULL.
void *npdfocr_page_start(const char *path, int page_index,
                         const char *options_json);

/// Starts an encoded-image (PNG/JPEG) job. The bytes are copied.
void *npdfocr_image_start(const uint8_t *bytes, int length,
                          const char *options_json);

/// Returns NPDFOCR_STATUS_* and writes the current progress (0..1) and stage.
int npdfocr_poll(void *handle, double *progress, int *stage);

/// Returns the terminal NPDFOCR_STATUS_* without touching progress.
int npdfocr_status(void *handle);

/// UTF-8 JSON result, valid until npdfocr_release. NULL until DONE.
const char *npdfocr_result(void *handle);

/// UTF-8 error message, or NULL.
const char *npdfocr_error(void *handle);

/// Requests cancellation; the job settles to NPDFOCR_STATUS_CANCELLED.
void npdfocr_cancel(void *handle);

/// Releases the handle after its queue drains. Safe to call once.
void npdfocr_release(void *handle);

/// JSON array of BCP-47 language identifiers supported by the OS.
/// The returned pointer must be freed with npdfocr_string_free.
char *npdfocr_supported_languages(const char *options_json);

void npdfocr_string_free(char *value);

/// 1 when the native OCR backend is available.
int npdfocr_available(void);

#ifdef __cplusplus
}
#endif

#endif
