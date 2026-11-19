#ifndef NATIVE_PDF_KIT_H
#define NATIVE_PDF_KIT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Human-readable message for the most recent failure on this thread.
const char *npdf_last_error(void);

/// Releases a buffer returned by this library.
void npdf_free(void *pointer);

/// Number of pages in the PDF at `path`, or -1 on failure.
int npdf_page_count(const char *path);

/// Media box of page `index` (0-based), in PDF points. Returns 0 on success.
int npdf_page_size(const char *path, int index, double *out_width,
                   double *out_height);

/// Rasterizes page `index` to `target_width` pixels wide, encoded as JPEG
/// (`format` 0) or PNG (`format` 1). Returns a malloc'd buffer that the caller
/// releases with `npdf_free`, or NULL on failure.
uint8_t *npdf_render_page(const char *path, int index, double target_width,
                          int quality, int format, int *out_length);

/// Decodes an image, resizes it so its longest edge is at most
/// `max_dimension`, and re-encodes it as JPEG (`format` 0) or PNG
/// (`format` 1). Returns a malloc'd buffer, or NULL on failure.
uint8_t *npdf_compress_image(const uint8_t *bytes, int length,
                             double max_dimension, int quality, int format,
                             int *out_width, int *out_height, int *out_length);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_PDF_KIT_H */
