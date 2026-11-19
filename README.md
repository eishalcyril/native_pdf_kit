# native_pdf_kit

Fast, dependency-free **native PDF rendering and image encoding** for Flutter,
built on direct interop — no platform channels, no bundled third-party engine.

- **iOS / macOS**: CoreGraphics for PDF pages, ImageIO for JPEG/PNG encoding.
- **Android**: JNIgen over the platform's `PdfRenderer`, `Bitmap` and
  `BitmapFactory`.

Everything here is our own code calling OS APIs. There is no third-party
source in this package, so the only copyright notice is ours.

## Why

Platform channels serialize every call and force async plumbing. Rendering a
PDF page or re-encoding an image is a bulk-data job: direct FFI passes bytes
without a serialization round trip, and the system codecs are the fastest and
highest-quality option on the platform.

## Device support

- **iOS 13+** (iPhone 6s and later) and **macOS 10.15+**.
- **Android 5.0+ (API 21)**, including arm64-v8a, armeabi-v7a and x86_64.
- No hardware-specific APIs: rendering uses the platform PDF stack, imaging
  uses the platform codecs.

## Install

```yaml
dependencies:
  native_pdf_kit:
    path: packages/native_pdf_kit   # or ^0.1.0 once published
```

## Usage

```dart
import 'package:native_pdf_kit/native_pdf_kit.dart';

final document = NativePdfDocument.open('/path/file.pdf');
print(document.pageCount);
print(document.pageSize(0)); // 595.0 × 842.0 pt

final jpeg = document.renderPage(0, width: 1240);
final png = document.renderPage(
  0,
  width: 1240,
  format: NativeImageFormat.png,
);
```

Compress an image with the native codecs:

```dart
final result = NativeImageCompressor.compress(
  bytes,
  maxDimension: 2048,
  quality: 82,
  format: NativeImageFormat.jpeg,
);
```

### Optimization, text and page edits

```dart
final report = NativePdfOptimizer.optimize(
  bytes,
  reduceImages: true,        // false for strict lossless
  maxImageDimension: 2480,   // ~300 DPI for A4
  jpegQuality: 85,
);
if (report.changed) save(report.bytes);

final text = PdfTextExtractor.extract(bytes);          // best effort
final rotated = PdfPageEditor.rotate(bytes, degrees: 90);
final reordered = reorderPdfPages(bytes, [2, 0]);       // also split/remove
final merged = mergePdfs([first, second]);              // append documents

final meta = PdfMetadataEditor.read(bytes);
final withMeta = PdfMetadataEditor.write(
  bytes,
  PdfMetadata(title: 'GRN scan', author: 'Eishal Cyril'),
);
```

The optimizer understands classic xref tables, drops unreachable objects,
recompresses Flate streams at level 9 and downsamples `DCTDecode` images. It
re-parses its own output, compares page counts, and returns the input unchanged
for anything it cannot handle safely (xref streams, hybrid files, encryption).

Text extraction reads `Tj`/`TJ` from Flate or uncompressed content streams; it
ignores CMaps, so simple standard-font documents work best. Scanned pages have
no text layer.

## Capabilities

```dart
NativePdfCapabilities.isSupported;      // iOS, macOS, Android
NativePdfCapabilities.rendering;        // page count, size, raster
NativePdfCapabilities.imageCompression; // resize + JPEG/PNG
NativePdfCapabilities.optimization;     // in-house optimizer
NativePdfCapabilities.textExtraction;   // best-effort text layer
NativePdfCapabilities.pageEditing;      // rotate/reorder/remove/split
```

Unsupported features fail with an explicit exception rather than silently
doing nothing.

## Performance notes

- Rendering and encoding happen in the system stacks, in C, with no Dart-side
  image decode.
- The API is synchronous; call it from a background isolate for large pages so
  the UI thread stays free.
- Page images are returned as freshly allocated bytes; no native handles are
  retained, so there is nothing to leak.
- Rendering honours the PDF page rotation and fills transparency with white,
  which is what OCR and document previews expect.

## Running the tests

`flutter test` runs on the Dart VM, which does not link CocoaPods sources into
the test process. Build the test dylib first:

```sh
./tool/build_native_test_lib.sh
flutter test
```

The example app runs the same code on a device or simulator:

```sh
cd example
flutter run
```

## Android notes

Android has no public text-extraction or PDF-writing API, so this package is
honest about capabilities: rendering, page size and image encoding work;
`textExtraction` and `editing` report `false`. Bindings are generated with
JNIgen from `android.jar` and call the platform classes directly.

Regenerate the Android bindings after changing the class list:

```sh
dart run tool/jnigen.dart
```

That needs a JDK 17–21 and the Android SDK (`ANDROID_HOME`).

## Not in 0.2.0

- **Signing** and **encryption**: security-critical; they need vetted crypto and
  an audit rather than a home-grown implementation.
- **OCR**: needs a platform/ML engine (Apple Vision, Android ML Kit). ML Kit is
  a Google SDK, so it is a licensing decision separate from this package.
- Annotations, forms and metadata editing.

## License

MIT, Copyright (c) 2026 Eishal Cyril.
