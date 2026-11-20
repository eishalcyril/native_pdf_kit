// native_pdf_ocr.m
//
// High-fidelity text extraction and OCR for native_pdf_kit_ocr.
//
//   - PDFKit extracts a born-digital page's text layer with per-line boxes.
//   - CoreGraphics rasterizes pages that have no usable text layer.
//   - Vision recognizes text in the rasterized page or in a supplied image.
//
// All work runs on a background queue. Dart polls progress; cancellation is
// cooperative and works inside Vision. Only OS frameworks are used.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <PDFKit/PDFKit.h>
#import <Vision/Vision.h>
#import <dispatch/dispatch.h>

#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "native_pdf_kit_ocr.h"

typedef struct NpdfOcrSession {
  pthread_mutex_t lock;
  int status;
  int stage;
  double progress;
  int cancelled;
  int released;
  int refcount;
  char *result;
  char *error;
  CFTypeRef request;  // CFBridgingRetain'd while Vision is running
} NpdfOcrSession;

// ─────────────────────────────────────────────────────────────────────────────
// Small helpers
// ─────────────────────────────────────────────────────────────────────────────

static NSDictionary *npdfocr_parse_options(const char *json) {
  if (json == NULL || json[0] == '\0') return @{};
  NSData *data = [NSData dataWithBytes:json length:strlen(json)];
  NSError *error = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  return [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
}

static NSString *npdfocr_string_option(NSDictionary *options, NSString *key,
                                       NSString *fallback) {
  id value = options[key];
  return [value isKindOfClass:[NSString class]] ? value : fallback;
}

static BOOL npdfocr_bool_option(NSDictionary *options, NSString *key,
                                BOOL fallback) {
  id value = options[key];
  return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static double npdfocr_double_option(NSDictionary *options, NSString *key,
                                    double fallback) {
  id value = options[key];
  return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

static int npdfocr_int_option(NSDictionary *options, NSString *key,
                              int fallback) {
  id value = options[key];
  return [value isKindOfClass:[NSNumber class]] ? [value intValue] : fallback;
}

static char *npdfocr_strdup(const char *text) {
  if (text == NULL) return NULL;
  size_t length = strlen(text);
  char *copy = (char *)malloc(length + 1);
  if (copy != NULL) memcpy(copy, text, length + 1);
  return copy;
}

static char *npdfocr_json_copy(id object) {
  if (object == nil || ![NSJSONSerialization isValidJSONObject:object]) {
    return NULL;
  }
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                 options:0
                                                   error:&error];
  if (data == nil) return NULL;
  char *buffer = (char *)malloc((size_t)data.length + 1);
  if (buffer == NULL) return NULL;
  memcpy(buffer, data.bytes, (size_t)data.length);
  buffer[data.length] = '\0';
  return buffer;
}

static NSUInteger npdfocr_character_count(NSString *text) {
  if (text == nil) return 0;
  NSUInteger count = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c != ' ' && c != '\t' && c != '\n' && c != '\r') count++;
  }
  return count;
}

static NSArray *npdfocr_normalized_box(CGRect box, CGRect page) {
  if (page.size.width <= 0 || page.size.height <= 0) {
    return @[ @0, @0, @0, @0 ];
  }
  double x = (box.origin.x - page.origin.x) / page.size.width;
  double y =
      1.0 - ((box.origin.y - page.origin.y) + box.size.height) / page.size.height;
  double width = box.size.width / page.size.width;
  double height = box.size.height / page.size.height;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x > 1) x = 1;
  if (y > 1) y = 1;
  if (width < 0) width = 0;
  if (height < 0) height = 0;
  if (x + width > 1) width = 1 - x;
  if (y + height > 1) height = 1 - y;
  return @[ @(x), @(y), @(width), @(height) ];
}

static NSDictionary *npdfocr_page_payload(NSString *source, NSString *engine,
                                          NSString *text, NSArray *lines,
                                          double width, double height) {
  return @{
    @"source" : source,
    @"engine" : engine,
    @"text" : text ?: @"",
    @"lines" : lines ?: @[],
    @"width" : @(width),
    @"height" : @(height),
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Session state
// ─────────────────────────────────────────────────────────────────────────────

static void npdfocr_set_stage(NpdfOcrSession *session, int stage,
                              double progress) {
  pthread_mutex_lock(&session->lock);
  session->stage = stage;
  if (progress > session->progress) session->progress = progress;
  pthread_mutex_unlock(&session->lock);
}

static int npdfocr_is_cancelled(NpdfOcrSession *session) {
  pthread_mutex_lock(&session->lock);
  int value = session->cancelled;
  pthread_mutex_unlock(&session->lock);
  return value;
}

static void npdfocr_finish(NpdfOcrSession *session, int status, char *result,
                           const char *error) {
  pthread_mutex_lock(&session->lock);
  free(session->result);
  free(session->error);
  session->result = result;
  session->error = npdfocr_strdup(error);
  session->status = status;
  session->stage = NPDFOCR_STAGE_PREPARING;
  session->progress = 1.0;
  pthread_mutex_unlock(&session->lock);
}

static void npdfocr_unref(NpdfOcrSession *session) {
  int free_now = 0;
  pthread_mutex_lock(&session->lock);
  session->refcount--;
  if (session->refcount == 0) free_now = 1;
  pthread_mutex_unlock(&session->lock);
  if (!free_now) return;
  pthread_mutex_destroy(&session->lock);
  free(session->result);
  free(session->error);
  free(session);
}

static NpdfOcrSession *npdfocr_session_create(void) {
  NpdfOcrSession *session = (NpdfOcrSession *)calloc(1, sizeof(NpdfOcrSession));
  if (session == NULL) return NULL;
  pthread_mutex_init(&session->lock, NULL);
  session->status = NPDFOCR_STATUS_RUNNING;
  session->stage = NPDFOCR_STAGE_PREPARING;
  session->refcount = 2;  // one for the caller, one for the worker
  return session;
}

// ─────────────────────────────────────────────────────────────────────────────
// PDF text layer
// ─────────────────────────────────────────────────────────────────────────────

static NSDictionary *npdfocr_text_layer(const char *path, int page_index) {
  NSString *file_path = [NSString stringWithUTF8String:path];
  if (file_path == nil) return nil;

  NSURL *url = [NSURL fileURLWithPath:file_path];
  PDFDocument *document = [[PDFDocument alloc] initWithURL:url];
  if (document == nil) return nil;
  if (page_index < 0 || page_index >= (int)[document pageCount]) {
    return nil;
  }

  PDFPage *page = [document pageAtIndex:(NSUInteger)page_index];
  if (page == nil) {
    return nil;
  }

  CGRect media = [page boundsForBox:kPDFDisplayBoxMediaBox];
  NSMutableArray *lines = [NSMutableArray array];
  NSMutableArray *texts = [NSMutableArray array];

  PDFSelection *selection = [page selectionForRect:media];
  NSArray<PDFSelection *> *by_line = [selection selectionsByLine];
  for (PDFSelection *line in by_line) {
    NSString *line_text = [line string];
    if (line_text == nil || npdfocr_character_count(line_text) == 0) continue;
    CGRect bounds = [line boundsForPage:page];
    [texts addObject:line_text];
    [lines addObject:@{
      @"text" : line_text,
      @"confidence" : @1.0,
      @"box" : npdfocr_normalized_box(bounds, media),
    }];
  }

  if (texts.count == 0) {
    NSString *whole = [page string];
    if (whole != nil && npdfocr_character_count(whole) > 0) {
      [texts addObject:whole];
      [lines addObject:@{
        @"text" : whole,
        @"confidence" : @1.0,
        @"box" : @[ @0, @0, @1, @1 ],
      }];
    }
  }

  NSDictionary *payload = npdfocr_page_payload(
      @"text-layer", @"pdfkit", [texts componentsJoinedByString:@"\n"], lines,
      media.size.width, media.size.height);

  return payload;
}

// ─────────────────────────────────────────────────────────────────────────────
// Rasterization
// ─────────────────────────────────────────────────────────────────────────────

static CGPDFDocumentRef npdfocr_open_document(const char *path) {
  if (path == NULL || path[0] == '\0') return NULL;
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false);
  if (url == NULL) return NULL;
  CGPDFDocumentRef document = CGPDFDocumentCreateWithURL(url);
  CFRelease(url);
  return document;
}

static CGImageRef npdfocr_render_page(CGPDFDocumentRef document, int index,
                                      double target_width) {
  if (document == NULL || index < 0 ||
      (size_t)index >= CGPDFDocumentGetNumberOfPages(document)) {
    return NULL;
  }
  CGPDFPageRef page = CGPDFDocumentGetPage(document, (size_t)index + 1);
  if (page == NULL) return NULL;

  CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
  if (box.size.width <= 0 || box.size.height <= 0) return NULL;

  int rotation = ((int)CGPDFPageGetRotationAngle(page) % 360 + 360) % 360;
  double page_width = box.size.width;
  double page_height = box.size.height;
  if (rotation == 90 || rotation == 270) {
    double swap = page_width;
    page_width = page_height;
    page_height = swap;
  }

  double width = target_width > 0 ? target_width : page_width * 2.0;
  double scale = width / page_width;
  size_t pixel_width = (size_t)lround(page_width * scale);
  size_t pixel_height = (size_t)lround(page_height * scale);
  if (pixel_width < 1 || pixel_height < 1 || pixel_width > 20000 ||
      pixel_height > 20000) {
    return NULL;
  }

  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(
      NULL, pixel_width, pixel_height, 8, pixel_width * 4, space,
      kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (context == NULL) return NULL;

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
  return image;
}

static CGImageRef npdfocr_decode_image(const uint8_t *bytes, int length,
                                       double max_dimension) {
  if (bytes == NULL || length <= 0) return NULL;
  CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)length);
  if (data == NULL) return NULL;
  CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
  CFRelease(data);
  if (source == NULL) return NULL;

  CGImageRef image = NULL;
  double limit = max_dimension > 0 ? max_dimension : 3000.0;
  CFNumberRef max_size =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &limit);
  if (max_size != NULL) {
    const void *keys[] = {
      kCGImageSourceCreateThumbnailFromImageAlways,
      kCGImageSourceCreateThumbnailWithTransform,
      kCGImageSourceThumbnailMaxPixelSize,
    };
    const void *values[] = { kCFBooleanTrue, kCFBooleanTrue, max_size };
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 3, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (options != NULL) {
      image = CGImageSourceCreateThumbnailAtIndex(source, 0, options);
      CFRelease(options);
    }
    CFRelease(max_size);
  }
  if (image == NULL) {
    image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  }
  CFRelease(source);
  return image;
}

// ─────────────────────────────────────────────────────────────────────────────
// Vision
// ─────────────────────────────────────────────────────────────────────────────

static VNRequestTextRecognitionLevel npdfocr_level(NSDictionary *options) {
  NSString *level = npdfocr_string_option(options, @"textLevel", @"accurate");
  return [level isEqualToString:@"fast"] ? VNRequestTextRecognitionLevelFast
                                         : VNRequestTextRecognitionLevelAccurate;
}

static NSDictionary *npdfocr_recognize(CGImageRef image,
                                       NSDictionary *options,
                                       NpdfOcrSession *session) {
  VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
  request.recognitionLevel = npdfocr_level(options);
  request.usesLanguageCorrection =
      npdfocr_bool_option(options, @"languageCorrection", YES);
  request.preferBackgroundProcessing = YES;

  NSArray *languages = options[@"languages"];
  if ([languages isKindOfClass:[NSArray class]] && languages.count > 0) {
    request.recognitionLanguages = languages;
  }

  id detect_language = options[@"detectLanguage"];
  if ([detect_language isKindOfClass:[NSNumber class]] &&
      [detect_language boolValue]) {
    if (@available(iOS 16.0, macOS 13.0, *)) {
      request.automaticallyDetectsLanguage = YES;
    }
  }

  if (@available(iOS 16.0, macOS 13.0, *)) {
    request.revision = VNRecognizeTextRequestRevision3;
  }

  npdfocr_set_stage(session, NPDFOCR_STAGE_RECOGNIZING, 0.15);
  request.progressHandler = ^(VNRequest *request, double progress,
                              NSError *error) {
    npdfocr_set_stage(session, NPDFOCR_STAGE_RECOGNIZING,
                      0.15 + 0.85 * progress);
  };

  CFTypeRef previous = NULL;
  pthread_mutex_lock(&session->lock);
  previous = session->request;
  session->request = CFBridgingRetain(request);
  int cancelled = session->cancelled;
  pthread_mutex_unlock(&session->lock);
  if (previous != NULL) CFRelease(previous);

  NSError *error = nil;
  if (!cancelled) {
    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:image
                                           orientation:kCGImagePropertyOrientationUp
                                               options:@{}];
    [handler performRequests:@[ request ] error:&error];
  }

  CFTypeRef running = NULL;
  pthread_mutex_lock(&session->lock);
  running = session->request;
  session->request = NULL;
  pthread_mutex_unlock(&session->lock);
  if (running != NULL) CFRelease(running);

  if (cancelled || npdfocr_is_cancelled(session)) {
    return nil;
  }

  if (error != nil) {
    // `performRequests` reports failures through NSError.
    return @{ @"error" : error.localizedDescription ?: @"Vision failed" };
  }

  NSMutableArray *lines = [NSMutableArray array];
  NSMutableArray *texts = [NSMutableArray array];
  NSArray *observations = request.results;
  if ([observations isKindOfClass:[NSArray class]]) {
    for (VNRecognizedTextObservation *observation in observations) {
      VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
      if (candidate == nil) continue;
      NSString *text = candidate.string;
      if (text == nil || text.length == 0) continue;
      [texts addObject:text];
      [lines addObject:@{
        @"text" : text,
        @"confidence" : @(candidate.confidence),
        @"box" : npdfocr_normalized_box(observation.boundingBox,
                                        CGRectMake(0, 0, 1, 1)),
      }];
    }
  }

  NSDictionary *payload = npdfocr_page_payload(
      @"ocr", @"apple-vision", [texts componentsJoinedByString:@"\n"], lines,
      (double)CGImageGetWidth(image), (double)CGImageGetHeight(image));
  return payload;
}

// ─────────────────────────────────────────────────────────────────────────────
// Jobs
// ─────────────────────────────────────────────────────────────────────────────

static void npdfocr_run_page(NpdfOcrSession *session, const char *path,
                             int page_index, NSDictionary *options) {
  NSString *mode = npdfocr_string_option(options, @"mode", @"auto");
  int min_chars = npdfocr_int_option(options, @"minTextChars", 12);

  if (![mode isEqualToString:@"ocr"]) {
    npdfocr_set_stage(session, NPDFOCR_STAGE_TEXT_LAYER, 0.02);
    NSDictionary *text_layer = npdfocr_text_layer(path, page_index);
    if (text_layer != nil) {
      NSString *text = text_layer[@"text"];
      if ([mode isEqualToString:@"text"] ||
          npdfocr_character_count(text) >= (NSUInteger)min_chars) {
        char *json = npdfocr_json_copy(text_layer);
        if (json != NULL) {
          npdfocr_finish(session, NPDFOCR_STATUS_DONE, json, NULL);
          return;
        }
      }
    }
    if ([mode isEqualToString:@"text"]) {
      NSDictionary *empty = npdfocr_page_payload(@"text-layer", @"pdfkit", @"",
                                                 @[], 0, 0);
      npdfocr_finish(session, NPDFOCR_STATUS_DONE, npdfocr_json_copy(empty),
                     NULL);
      return;
    }
    if (npdfocr_is_cancelled(session)) {
      npdfocr_finish(session, NPDFOCR_STATUS_CANCELLED, NULL, NULL);
      return;
    }
  }

  double render_width = npdfocr_double_option(options, @"renderWidth", 2000.0);
  if (render_width < 200) render_width = 200;
  if (render_width > 6000) render_width = 6000;

  npdfocr_set_stage(session, NPDFOCR_STAGE_RENDERING, 0.08);
  CGPDFDocumentRef document = npdfocr_open_document(path);
  if (document == NULL) {
    npdfocr_finish(session, NPDFOCR_STATUS_FAILED, NULL,
                   "could not open the PDF");
    return;
  }
  CGImageRef image = npdfocr_render_page(document, page_index, render_width);
  CGPDFDocumentRelease(document);
  if (image == NULL) {
    npdfocr_finish(session, NPDFOCR_STATUS_FAILED, NULL,
                   "could not rasterize the page");
    return;
  }

  if (npdfocr_is_cancelled(session)) {
    CGImageRelease(image);
    npdfocr_finish(session, NPDFOCR_STATUS_CANCELLED, NULL, NULL);
    return;
  }

  NSDictionary *result = npdfocr_recognize(image, options, session);
  CGImageRelease(image);

  if (npdfocr_is_cancelled(session)) {
    npdfocr_finish(session, NPDFOCR_STATUS_CANCELLED, NULL, NULL);
    return;
  }
  if (result == nil) {
    npdfocr_finish(session, NPDFOCR_STATUS_FAILED, NULL, "Vision returned no result");
    return;
  }
  if (result[@"error"] != nil) {
    npdfocr_finish(session, NPDFOCR_STATUS_FAILED, NULL,
                   [result[@"error"] UTF8String]);
    return;
  }
  npdfocr_finish(session, NPDFOCR_STATUS_DONE, npdfocr_json_copy(result), NULL);
}

static void npdfocr_run_image(NpdfOcrSession *session, const uint8_t *bytes,
                              int length, NSDictionary *options) {
  double max_dimension =
      npdfocr_double_option(options, @"renderWidth", 3000.0);
  npdfocr_set_stage(session, NPDFOCR_STAGE_RENDERING, 0.05);
  CGImageRef image = npdfocr_decode_image(bytes, length, max_dimension);
  if (image == NULL) {
    npdfocr_finish(session, NPDFOCR_STATUS_FAILED, NULL,
                   "could not decode the image");
    return;
  }
  if (npdfocr_is_cancelled(session)) {
    CGImageRelease(image);
    npdfocr_finish(session, NPDFOCR_STATUS_CANCELLED, NULL, NULL);
    return;
  }

  NSDictionary *result = npdfocr_recognize(image, options, session);
  CGImageRelease(image);

  if (npdfocr_is_cancelled(session)) {
    npdfocr_finish(session, NPDFOCR_STATUS_CANCELLED, NULL, NULL);
    return;
  }
  if (result == nil || result[@"error"] != nil) {
    const char *message = result == nil ? "Vision returned no result"
                                        : [result[@"error"] UTF8String];
    npdfocr_finish(session, NPDFOCR_STATUS_FAILED, NULL, message);
    return;
  }
  npdfocr_finish(session, NPDFOCR_STATUS_DONE, npdfocr_json_copy(result), NULL);
}

static void *npdfocr_start(const char *path, int page_index,
                           const uint8_t *bytes, int length,
                           const char *options_json) {
  NpdfOcrSession *session = npdfocr_session_create();
  if (session == NULL) return NULL;

  char *path_copy = npdfocr_strdup(path);
  char *options_copy = npdfocr_strdup(options_json);
  uint8_t *bytes_copy = NULL;
  if (bytes != NULL && length > 0) {
    bytes_copy = (uint8_t *)malloc((size_t)length);
    if (bytes_copy != NULL) memcpy(bytes_copy, bytes, (size_t)length);
  }

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
      NSDictionary *options = npdfocr_parse_options(options_copy);
      if (bytes_copy != NULL) {
        npdfocr_run_image(session, bytes_copy, length, options);
      } else if (path_copy != NULL) {
        npdfocr_run_page(session, path_copy, page_index, options);
      } else {
        npdfocr_finish(session, NPDFOCR_STATUS_FAILED, NULL,
                       "no page path or image data");
      }
    }
    free(path_copy);
    free(options_copy);
    free(bytes_copy);
    npdfocr_unref(session);
  });

  return session;
}

// ─────────────────────────────────────────────────────────────────────────────
// Public surface
// ─────────────────────────────────────────────────────────────────────────────

void *npdfocr_page_start(const char *path, int page_index,
                         const char *options_json) {
  return npdfocr_start(path, page_index, NULL, 0, options_json);
}

void *npdfocr_image_start(const uint8_t *bytes, int length,
                          const char *options_json) {
  return npdfocr_start(NULL, 0, bytes, length, options_json);
}

int npdfocr_poll(void *handle, double *progress, int *stage) {
  if (handle == NULL) return NPDFOCR_STATUS_FAILED;
  NpdfOcrSession *session = (NpdfOcrSession *)handle;
  pthread_mutex_lock(&session->lock);
  if (progress != NULL) *progress = session->progress;
  if (stage != NULL) *stage = session->stage;
  int status = session->status;
  pthread_mutex_unlock(&session->lock);
  return status;
}

int npdfocr_status(void *handle) {
  if (handle == NULL) return NPDFOCR_STATUS_FAILED;
  NpdfOcrSession *session = (NpdfOcrSession *)handle;
  pthread_mutex_lock(&session->lock);
  int status = session->status;
  pthread_mutex_unlock(&session->lock);
  return status;
}

const char *npdfocr_result(void *handle) {
  if (handle == NULL) return NULL;
  NpdfOcrSession *session = (NpdfOcrSession *)handle;
  pthread_mutex_lock(&session->lock);
  const char *result = session->result;
  pthread_mutex_unlock(&session->lock);
  return result;
}

const char *npdfocr_error(void *handle) {
  if (handle == NULL) return NULL;
  NpdfOcrSession *session = (NpdfOcrSession *)handle;
  pthread_mutex_lock(&session->lock);
  const char *error = session->error;
  pthread_mutex_unlock(&session->lock);
  return error;
}

void npdfocr_cancel(void *handle) {
  if (handle == NULL) return;
  NpdfOcrSession *session = (NpdfOcrSession *)handle;
  pthread_mutex_lock(&session->lock);
  session->cancelled = 1;
  CFTypeRef request = session->request;
  if (request != NULL) CFRetain(request);
  pthread_mutex_unlock(&session->lock);
  if (request != NULL) {
    [(__bridge VNRecognizeTextRequest *)request cancel];
    CFRelease(request);
  }
}

void npdfocr_release(void *handle) {
  if (handle == NULL) return;
  NpdfOcrSession *session = (NpdfOcrSession *)handle;
  pthread_mutex_lock(&session->lock);
  if (session->released) {
    pthread_mutex_unlock(&session->lock);
    return;
  }
  session->released = 1;
  session->cancelled = 1;
  CFTypeRef request = session->request;
  if (request != NULL) CFRetain(request);
  pthread_mutex_unlock(&session->lock);
  if (request != NULL) {
    [(__bridge VNRecognizeTextRequest *)request cancel];
    CFRelease(request);
  }
  npdfocr_unref(session);
}

char *npdfocr_supported_languages(const char *options_json) {
  @autoreleasepool {
    NSDictionary *options = npdfocr_parse_options(options_json);
    NSError *error = nil;
    NSArray *languages = nil;
    VNRecognizeTextRequest *probe = [[VNRecognizeTextRequest alloc] init];

    if (@available(iOS 15.0, macOS 12.0, *)) {
      languages = [probe supportedRecognitionLanguagesAndReturnError:&error];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      languages = [VNRecognizeTextRequest
          supportedRecognitionLanguagesForTextRecognitionLevel:
              npdfocr_level(options)
                                                       revision:probe.revision
                                                          error:&error];
#pragma clang diagnostic pop
    }

    if (languages == nil) return NULL;
    return npdfocr_json_copy(languages);
  }
}

void npdfocr_string_free(char *value) { free(value); }

int npdfocr_available(void) {
  if (@available(iOS 13.0, macOS 10.15, *)) return 1;
  return 0;
}
