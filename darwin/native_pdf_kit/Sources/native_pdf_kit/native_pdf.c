// native_pdf.c
//
// Narrow C surface over the system PDF and image stacks:
//   - CoreGraphics: open a PDF, count/measure pages, draw a page.
//   - ImageIO: encode JPEG/PNG and resize images with the native codecs.
//
// Only OS APIs are used. There is no third-party source in this file.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define NPDF_EXPORT __attribute__((visibility("default")))

#define NPDF_FORMAT_JPEG 0
#define NPDF_FORMAT_PNG 1

static char npdf_error[512];

static void npdf_set_error(const char *message) {
  const char *text = message == NULL ? "" : message;
  strncpy(npdf_error, text, sizeof(npdf_error) - 1);
  npdf_error[sizeof(npdf_error) - 1] = '\0';
}

NPDF_EXPORT const char *npdf_last_error(void) { return npdf_error; }

NPDF_EXPORT void npdf_free(void *pointer) { free(pointer); }

static CGPDFDocumentRef npdf_open_document(const char *path) {
  if (path == NULL || path[0] == '\0') {
    npdf_set_error("empty PDF path");
    return NULL;
  }

  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
  if (url == NULL) {
    npdf_set_error("invalid PDF path");
    return NULL;
  }

  CGPDFDocumentRef document = CGPDFDocumentCreateWithURL(url);
  CFRelease(url);
  if (document == NULL) {
    npdf_set_error("could not open the PDF");
  }
  return document;
}

static CGPDFPageRef npdf_get_page(CGPDFDocumentRef document, int index) {
  size_t count = CGPDFDocumentGetNumberOfPages(document);
  if (index < 0 || (size_t)index >= count) {
    npdf_set_error("page index out of range");
    return NULL;
  }
  CGPDFPageRef page = CGPDFDocumentGetPage(document, (size_t)index + 1);
  if (page == NULL) {
    npdf_set_error("page not found");
  }
  return page;
}

NPDF_EXPORT int npdf_page_count(const char *path) {
  CGPDFDocumentRef document = npdf_open_document(path);
  if (document == NULL) {
    return -1;
  }
  int count = (int)CGPDFDocumentGetNumberOfPages(document);
  CGPDFDocumentRelease(document);
  return count;
}

NPDF_EXPORT int npdf_page_size(
    const char *path, int index, double *out_width, double *out_height) {
  CGPDFDocumentRef document = npdf_open_document(path);
  if (document == NULL) {
    return -1;
  }

  CGPDFPageRef page = npdf_get_page(document, index);
  if (page == NULL) {
    CGPDFDocumentRelease(document);
    return -1;
  }

  CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
  if (out_width != NULL) {
    *out_width = box.size.width;
  }
  if (out_height != NULL) {
    *out_height = box.size.height;
  }

  CGPDFDocumentRelease(document);
  return 0;
}

static int npdf_has_alpha(CGImageRef image) {
  CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
  return alpha != kCGImageAlphaNone && alpha != kCGImageAlphaNoneSkipFirst &&
         alpha != kCGImageAlphaNoneSkipLast;
}

// JPEG has no alpha; draw transparent images over white instead of letting
// ImageIO produce black or refuse the encode.
static CGImageRef npdf_opaque_copy(CGImageRef image) {
  if (!npdf_has_alpha(image)) {
    return CGImageRetain(image);
  }

  size_t width = CGImageGetWidth(image);
  size_t height = CGImageGetHeight(image);
  if (width == 0 || height == 0) {
    npdf_set_error("image has no pixels");
    return NULL;
  }

  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      NULL, width, height, 8, width * 4, space,
      kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (context == NULL) {
    npdf_set_error("could not create an image context");
    return NULL;
  }

  CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
  CGContextFillRect(context, CGRectMake(0, 0, width, height));
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  CGImageRef opaque = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  return opaque;
}

static uint8_t *npdf_encode_image(
    CGImageRef source, int quality, int format, int *out_length) {
  if (out_length != NULL) {
    *out_length = 0;
  }

  CGImageRef image = source;
  int release_image = 0;
  if (format == NPDF_FORMAT_JPEG && npdf_has_alpha(source)) {
    image = npdf_opaque_copy(source);
    if (image == NULL) {
      return NULL;
    }
    release_image = 1;
  }

  CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
  if (data == NULL) {
    npdf_set_error("could not allocate output data");
    if (release_image) {
      CGImageRelease(image);
    }
    return NULL;
  }

  CFStringRef type =
      format == NPDF_FORMAT_PNG ? CFSTR("public.png") : CFSTR("public.jpeg");
  CGImageDestinationRef destination =
      CGImageDestinationCreateWithData(data, type, 1, NULL);
  if (destination == NULL) {
    npdf_set_error("could not create an image encoder");
    CFRelease(data);
    if (release_image) {
      CGImageRelease(image);
    }
    return NULL;
  }

  CFDictionaryRef properties = NULL;
  CFMutableDictionaryRef mutable_properties = NULL;
  CFNumberRef quality_number = NULL;
  if (format == NPDF_FORMAT_JPEG) {
    int clamped = quality < 1 ? 85 : (quality > 100 ? 100 : quality);
    double value = (double)clamped / 100.0;
    quality_number =
        CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &value);
    mutable_properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (mutable_properties != NULL && quality_number != NULL) {
      CFDictionarySetValue(mutable_properties,
                           kCGImageDestinationLossyCompressionQuality,
                           quality_number);
    }
    properties = mutable_properties;
  }

  CGImageDestinationAddImage(destination, image, properties);
  int finalized = CGImageDestinationFinalize(destination) ? 1 : 0;

  if (quality_number != NULL) {
    CFRelease(quality_number);
  }
  if (mutable_properties != NULL) {
    CFRelease(mutable_properties);
  }
  CFRelease(destination);

  uint8_t *result = NULL;
  if (finalized) {
    CFIndex length = CFDataGetLength(data);
    if (length > 0) {
      result = (uint8_t *)malloc((size_t)length);
      if (result != NULL) {
        memcpy(result, CFDataGetBytePtr(data), (size_t)length);
        if (out_length != NULL) {
          *out_length = (int)length;
        }
      } else {
        npdf_set_error("could not allocate the encoded image");
      }
    } else {
      npdf_set_error("the encoder produced no data");
    }
  } else {
    npdf_set_error("could not encode the image");
  }

  CFRelease(data);
  if (release_image) {
    CGImageRelease(image);
  }
  return result;
}

NPDF_EXPORT uint8_t *npdf_render_page(
    const char *path, int index, double target_width, int quality, int format,
    int *out_length) {
  if (out_length != NULL) {
    *out_length = 0;
  }

  CGPDFDocumentRef document = npdf_open_document(path);
  if (document == NULL) {
    return NULL;
  }

  CGPDFPageRef page = npdf_get_page(document, index);
  if (page == NULL) {
    CGPDFDocumentRelease(document);
    return NULL;
  }

  CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
  if (box.size.width <= 0.0 || box.size.height <= 0.0) {
    npdf_set_error("the page has no size");
    CGPDFDocumentRelease(document);
    return NULL;
  }

  int rotation = ((int)CGPDFPageGetRotationAngle(page) % 360 + 360) % 360;
  double page_width = box.size.width;
  double page_height = box.size.height;
  if (rotation == 90 || rotation == 270) {
    double swap = page_width;
    page_width = page_height;
    page_height = swap;
  }

  double width = target_width > 0.0 ? target_width : page_width * 2.0;
  double scale = width / page_width;
  size_t pixel_width = (size_t)lround(page_width * scale);
  size_t pixel_height = (size_t)lround(page_height * scale);
  if (pixel_width < 1 || pixel_height < 1 || pixel_width > 20000 ||
      pixel_height > 20000) {
    npdf_set_error("unreasonable render size");
    CGPDFDocumentRelease(document);
    return NULL;
  }

  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      NULL, pixel_width, pixel_height, 8, pixel_width * 4, space,
      kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (context == NULL) {
    npdf_set_error("could not create a render context");
    CGPDFDocumentRelease(document);
    return NULL;
  }

  CGContextSetRGBFillColor(context, 1.0, 1.0, 1.0, 1.0);
  CGContextFillRect(
      context, CGRectMake(0, 0, (CGFloat)pixel_width, (CGFloat)pixel_height));

  CGAffineTransform transform = CGPDFPageGetDrawingTransform(
      page, kCGPDFMediaBox,
      CGRectMake(0, 0, (CGFloat)pixel_width, (CGFloat)pixel_height), 0, true);
  CGContextConcatCTM(context, transform);
  CGContextDrawPDFPage(context, page);

  CGImageRef image = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  CGPDFDocumentRelease(document);

  if (image == NULL) {
    npdf_set_error("could not rasterize the page");
    return NULL;
  }

  uint8_t *result = npdf_encode_image(image, quality, format, out_length);
  CGImageRelease(image);
  return result;
}

NPDF_EXPORT uint8_t *npdf_compress_image(
    const uint8_t *bytes, int length, double max_dimension, int quality,
    int format, int *out_width, int *out_height, int *out_length) {
  if (out_width != NULL) {
    *out_width = 0;
  }
  if (out_height != NULL) {
    *out_height = 0;
  }
  if (out_length != NULL) {
    *out_length = 0;
  }
  if (bytes == NULL || length <= 0) {
    npdf_set_error("empty image data");
    return NULL;
  }

  CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)length);
  if (data == NULL) {
    npdf_set_error("could not read the image data");
    return NULL;
  }

  CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
  CFRelease(data);
  if (source == NULL) {
    npdf_set_error("unsupported image format");
    return NULL;
  }

  CGImageRef image = NULL;
  double limit = max_dimension > 0.0 ? max_dimension : 2048.0;
  CFNumberRef max_pixel_size = CFNumberCreate(
      kCFAllocatorDefault, kCFNumberDoubleType, &limit);
  if (max_pixel_size != NULL) {
    const void *keys[] = {kCGImageSourceCreateThumbnailFromImageAlways,
                          kCGImageSourceCreateThumbnailWithTransform,
                          kCGImageSourceThumbnailMaxPixelSize};
    const void *values[] = {kCFBooleanTrue, kCFBooleanTrue, max_pixel_size};
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (options != NULL) {
      image = CGImageSourceCreateThumbnailAtIndex(source, 0, options);
      CFRelease(options);
    }
  }
  if (image == NULL) {
    image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  }
  CFRelease(max_pixel_size);
  CFRelease(source);

  if (image == NULL) {
    npdf_set_error("could not decode the image");
    return NULL;
  }

  if (out_width != NULL) {
    *out_width = (int)CGImageGetWidth(image);
  }
  if (out_height != NULL) {
    *out_height = (int)CGImageGetHeight(image);
  }

  uint8_t *result = npdf_encode_image(image, quality, format, out_length);
  CGImageRelease(image);
  return result;
}
