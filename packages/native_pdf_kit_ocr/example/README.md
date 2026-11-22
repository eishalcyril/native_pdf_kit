# native_pdf_kit_ocr example

A small Flutter app that generates a PDF, runs OCR-only extraction with live
progress, and shows the text and line boxes.

```sh
flutter pub get
flutter run
```

Run it on an iOS/macOS device or simulator for Apple Vision, or on an Android
device/emulator for ML Kit. The sample forces `PdfOcrMode.ocrOnly` so the
screenshot shows the OCR engine rather than the PDF text-layer fast path.

The full demo with real PDF/image picking lives in the core repository's
`example/` app.
