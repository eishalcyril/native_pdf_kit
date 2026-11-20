/// Fast native PDF rendering, imaging, optimization and page operations.
///
/// iOS/macOS call CoreGraphics and ImageIO through direct FFI; Android calls
/// `PdfRenderer`/`Bitmap` through JNIgen. The parser, writer, text extraction,
/// merge and page edits are pure Dart and work on every target. There are no
/// platform channels and no bundled third-party PDF engine.
///
/// OCR lives in the companion package `native_pdf_kit_ocr`.
library;

export 'src/bindings.dart' show NativeImageFormat, NativePdfException;
export 'src/document.dart';
export 'src/image.dart';
export 'src/optimizer/pdf_optimizer.dart';
