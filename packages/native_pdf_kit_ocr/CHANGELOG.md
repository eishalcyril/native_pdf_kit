## 0.1.1

- README screenshots for iOS (Vision) and Android (ML Kit).
- Example picks a real PDF or image and previews it before OCR.
- No API changes.

## 0.1.0

First release.

- Apple Vision OCR and PDFKit text-layer extraction on iOS 13+/macOS 10.15+,
  with per-line boxes, confidence, intra-page Vision progress and cancellation.
- Android ML Kit Text Recognition v2 (bundled Latin model) with optional
  Chinese, Devanagari, Japanese and Korean script artifacts.
- Optional LiteRT + PP-OCRv5 engine (DB detector, CTC recognizer) with model
  files supplied by the app.
- Unified `PdfOcrOptions`, `PdfOcrEvent` stream, per-page results and
  `PdfOcrDocument` aggregate.
- Realtime progress polled from a native worker; no platform channels.
- Android 15+ native text-layer path; pure-Dart text-layer fallback in a
  background isolate.
- iOS and macOS CocoaPods/SPM integration, Android Gradle module with R8 rules.
