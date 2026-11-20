/// On-device OCR and high-fidelity text extraction for `native_pdf_kit`.
///
/// Apple Vision and PDFKit on iOS/macOS; ML Kit Text Recognition v2 or
/// LiteRT + PP-OCRv5 on Android. Progress is polled natively, so jobs stay off
/// the platform thread and can be cancelled.
library;

export 'src/native_pdf_ocr.dart';
export 'src/ocr_types.dart';
