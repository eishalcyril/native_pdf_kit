# native_pdf_kit_ocr

On-device OCR and high-fidelity text extraction for
[`native_pdf_kit`](https://github.com/eishalcyril/native_pdf_kit).

- **Apple (iOS 13+, macOS 10.15+)**: Vision OCR with PDFKit as the text-layer
  fast path. No model download, no network.
- **Android (API 21+)**: ML Kit Text Recognition v2, bundled by default.
  Optional **LiteRT + PP-OCRv5** engine for a fully open, self-hosted stack.
- **Realtime progress**: the native worker is polled from Dart, so per-page and
  intra-page progress arrives while OCR runs. No platform channels.
- **Cancellation**, structured line boxes, confidence, text-layer/OCR fallback
  and image OCR.

The package is a companion to `native_pdf_kit`: the core stays
dependency-free and MIT-clean, and apps that do not need OCR pay nothing.

## Install

```yaml
dependencies:
  native_pdf_kit: ^0.3.0
  native_pdf_kit_ocr: ^0.1.0
```

### Android

ML Kit is a closed-source Google SDK, free to use under Google's ML Kit terms.
The bundled artifact is the default:

```gradle
implementation 'com.google.mlkit:text-recognition:16.0.1'
```

That dependency is already declared by this package. It works offline and
without Google Play Services, at the cost of a few megabytes in the APK.

Optional ML Kit scripts (Chinese, Devanagari, Japanese, Korean) are **not**
bundled. Add the artifact the app needs; the engine detects it and falls back
to Latin when it is absent:

```gradle
implementation 'com.google.mlkit:text-recognition-chinese:16.0.1'
```

#### LiteRT + PP-OCRv5 (optional, fully open models)

LiteRT is `compileOnly` in this package so the default APK stays small and
API 21 compatible. To use it:

1. Raise `minSdk` to 24 and add the runtime to the app:

```gradle
dependencies {
    implementation 'com.google.ai.edge.litert:litert:2.3.0'
}
```

2. Fetch the Apache-2.0 models (about 27 MB) with
   `tool/fetch_litert_ocr_models.sh`, ship them however the app prefers, and
   pass their paths:

```dart
PdfOcrOptions(
  engine: PdfOcrEngine.liteRt,
  liteRtModels: PdfLiteRtModels(
    detectorPath: '$dir/ppocr_det_fp16.tflite',
    recognizerPath: '$dir/ppocr_rec_fp16.tflite',
    dictionaryPath: '$dir/ppocrv5_dict.txt',
  ),
)
```

Models are not bundled with this package. The example app demonstrates the
engine on an emulator with models pushed to `/data/local/tmp/ppocr`.

### Apple

Vision and PDFKit are OS frameworks, linked by the CocoaPods/SPM manifest.
There is nothing to install and nothing to download.

## Usage

```dart
import 'package:native_pdf_kit/native_pdf_kit.dart';
import 'package:native_pdf_kit_ocr/native_pdf_kit_ocr.dart';

final document = NativePdfDocument.open('/path/scan.pdf');

await for (final event in NativePdfOcr.recognizeDocument(document)) {
  switch (event) {
    case PdfOcrProgress():
      print('${(event.overallProgress * 100).round()}% '
          'page ${event.pageIndex + 1}: ${event.stage}');
    case PdfOcrPageEvent():
      print('page ${event.page.index + 1}: ${event.page.text}');
    case PdfOcrDoneEvent():
      print(event.document.text);
  }
}
```

One call when progress is not needed:

```dart
final result = await NativePdfOcr.extractDocument(document);
```

Image OCR (camera scans, screenshots):

```dart
final result = await NativePdfOcr.extractImage(
  pngBytes,
  options: const PdfOcrOptions(mode: PdfOcrMode.ocrOnly),
);
```

Cancel by cancelling the subscription:

```dart
final subscription = NativePdfOcr.recognizeDocument(document).listen(...);
await subscription.cancel(); // stops the native job cooperatively
```

## How pages are processed

`PdfOcrMode.auto` is the default and tries the cheap path first:

- **Apple**: PDFKit reads the page's text layer with per-line boxes. If the
  page has fewer than `minTextLayerCharacters` non-whitespace characters, the
  page is rasterized and sent to Vision.
- **Android**: the pure-Dart parser reads the text layer once, in a background
  isolate. Pages without a usable layer are rendered and sent to ML Kit or
  LiteRT. Android 15+ also has a native text-layer path inside the bridge.

Use `PdfOcrMode.ocrOnly` to force OCR (for example to compare engines) or
`PdfOcrMode.textLayerOnly` to never rasterize.

## Options that matter

| Option | Effect |
| --- | --- |
| `engine` | `auto`, `appleVision`, `mlKit`, `liteRt` |
| `mode` | text-layer/OCR fallback, OCR only, text only |
| `recognitionLevel` | Vision fast vs accurate |
| `languages` | Apple BCP-47 hints, in priority order |
| `detectLanguage` | Apple automatic language detection (iOS 16+) |
| `languageCorrection` | good for prose, can hurt serial numbers |
| `renderWidth` | raster width in pixels (default 2000) |
| `minTextLayerCharacters` | born-digital threshold (default 12) |
| `script` | ML Kit script model |
| `progressInterval` | poll cadence (default 80 ms) |

`renderWidth` is the main quality/performance knob. 1600–2200 px is a good
range for A4/Letter; receipts and dense forms benefit from 2400+.

## Structured results

```dart
for (final line in page.lines) {
  print('${line.confidence.toStringAsFixed(2)} '
      '${line.box} ${line.text}');
}
```

Boxes are normalized to the page (`0..1`, origin top-left), so they map onto a
`CustomPaint` or a zoomable preview without knowing the raster size.

## Licensing

- Apple Vision and PDFKit are OS frameworks.
- ML Kit is a Google SDK with its own terms. It is bundled only because the app
  depends on this package; remove the dependency if that is unacceptable.
- PP-OCRv5 models are Apache-2.0; weights are downloaded by the app, not
  redistributed here.
- The Dart and Java/Objective-C bridge code in this package is MIT,
  Copyright (c) 2026 Eishal Cyril.

## Limitations

- ML Kit cannot abort an in-flight page; cancellation takes effect between
  pages (Vision can cancel inside a page).
- LiteRT confidence is reported as `0.0` because PP-OCRv5 CTC logits are not
  calibrated probabilities.
- Text layers with custom CMaps and broken fonts rely on the OS engine; the
  pure-Dart fallback is best effort.
- Encrypted PDFs must be decrypted before OCR; `native_pdf_kit` does not
  decrypt them yet.
