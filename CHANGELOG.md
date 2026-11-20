## 0.3.0

- Optimizer: PDF 1.5 xref streams, hybrid files, `/ObjStm` object streams,
  incremental-update `/Prev` chains and PNG/TIFF predictors.
- Optimizer: converts 8-bit DeviceRGB/DeviceGray Flate images to JPEG, in
  addition to `DCTDecode` downsampling.
- `PdfTextExtractor.extractPages` returns per-page text in one parse; Flate
  predictors are supported.
- New companion package `native_pdf_kit_ocr` 0.1.0:
  Apple Vision + PDFKit, Android ML Kit Text Recognition v2, optional LiteRT +
  PP-OCRv5, realtime progress, cancellation, line boxes.
- Example app: live OCR demo and Android/iOS device integration tests.
- Android release build verified with ML Kit and LiteRT 2.3.0; iOS simulator
  and device builds verified with Vision/PDFKit.
- Tests: 16 core tests plus 6 macOS OCR tests and 3 Android device tests.

## 0.2.0

- In-house PDF optimizer: classic xref parsing, object garbage collection,
  maximum-effort Flate recompression, and JPEG image downsampling through the
  native codecs. Unsupported files are returned unchanged.
- Best-effort text-layer extraction (`PdfTextExtractor`).
- Page operations: rotate, reorder, remove and split/extract
  (`PdfPageEditor.rotate`, `reorderPdfPages`).
- Cross-document merge with object renumbering (`mergePdfs`).
- Document metadata read/write (`PdfMetadataEditor`).
- iOS deployment target lowered to 13.0; Android API 21+; SPM manifest fixed.
- Verified release builds: iOS device (`--no-codesign`) and Android release APK.
- Deterministic Android binding generation without a hard-coded SDK path.

## 0.1.0

First release.

- iOS/macOS: direct FFI to CoreGraphics for PDF page count, page size and
  rasterization.
- iOS/macOS: ImageIO-based image resizing and JPEG/PNG encoding.
- Android: JNIgen bindings to `PdfRenderer`, `Bitmap` and `BitmapFactory` for
  the same page and image operations.
- JPEG rendering honours page rotation and flattens transparency to white.
- Native image compression applies EXIF orientation before resizing.
- Capability flags report unsupported features explicitly.
- macOS test dylib builder and an iOS/macOS example app.
