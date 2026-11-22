# AGENTS.md — native_pdf_kit

Native PDF toolkit for Flutter. Direct iOS/Android interop, no platform
channels and no bundled third-party PDF engine.

## Purpose

Provide fast, reliable PDF rendering, imaging, optimization, text extraction,
OCR and page operations for Flutter apps, mostly from our own code, with a
permissive MIT license owned by Eishal Cyril.

## Repository

- GitHub (personal): `https://github.com/eishalcyril/native_pdf_kit`
- Remote: `git@github.com:eishalcyril/native_pdf_kit.git`
- Identity: `Eishal Cyril <eishalcyril2@gmail.com>`
- SSH: repository-local `core.sshCommand` uses `~/.ssh/id_ed25519_personal`.
- Never commit or push this project to the office Bitbucket repository.
- Layout: the core package is the repository root; the OCR companion lives in
  `packages/native_pdf_kit_ocr`.

## Resume here — session handoff (2026-11-20, second pass)

### Where we stopped

- Core version: **0.3.2**. OCR companion: **0.1.2**.
- **Published on pub.dev on 2026-11-20**:
  - <https://pub.dev/packages/native_pdf_kit> (0.3.2, 0 warnings, ~1 MB
    with README screenshots),
  - <https://pub.dev/packages/native_pdf_kit_ocr> (0.1.2, 0 warnings, 35 KB).
  - Earlier same-day releases: core 0.3.0/0.3.1, OCR 0.1.0/0.1.1.
  - `dart pub login` is configured as `eishalcyril2@gmail.com` (Eishal Cyril).
  - A clean temp project resolves both hosted versions; the OCR package
    resolves `native_pdf_kit ^0.3.0` transitively.
  - `pana` reports **160/160** for both packages (pub.dev max).
- Tests:
  - core: **16/16** (`flutter test`, after `./tool/build_native_test_lib.sh`),
  - OCR macOS: **7/7** (PDFKit text layer, Vision OCR, OCR-only, text-only, blank
    pages, capabilities, cancellation),
  - Android device: **3/3** on the Pixel 8 Pro API 36 emulator (ML Kit document,
    ML Kit image, LiteRT PP-OCRv5 image).
- Verified builds:
  - iOS simulator debug (example launched on iPhone 17 Pro simulator),
  - iOS device release (`flutter build ios --release --no-codesign`),
  - Android debug and release APK,
  - macOS debug (Swift Package Manager integration, not just CocoaPods),
  - example builds and launches.
- Supported targets: **iOS 13+**, macOS 10.15+, **Android API 21+**
  (LiteRT requires API 24 and is app opt-in).
- Office app state (`/Users/cufa/workspace/hims-f-b-mobileapp`):
  - `packages/native_pdf_kit/` has been **removed** from the app.
  - App `pubspec.yaml` now uses **`native_pdf_kit: ^0.3.0` from pub.dev**
    (switched from the git dependency on 2026-11-20).
  - `flutter pub get` resolves the hosted 0.3.0 and the iOS simulator debug
    build passes.
  - App changes are **uncommitted**; do not push them to Bitbucket as part of
    this package work.
  - Files touched: `pubspec.yaml`, `pubspec.lock`,
    `lib/hims_inventory/grn_ai/screens/elements/document_upload.dart`.
  - PDF compression path: `_optimizePdfInBackground` →
    `NativePdfOptimizer.optimize` via `compute`; `_compressPdf({lossless})`.

### Immediate next actions, in order

1. ~~Switch the office app to the hosted core~~ — done; it uses
   `native_pdf_kit: ^0.3.0` and builds. Add `native_pdf_kit_ocr: ^0.1.0` only
   if OCR is wanted.
2. **Office app OCR integration**, if product wants it: add
   `native_pdf_kit_ocr: ^0.1.0` and use `NativePdfOcr.recognizeDocument` for
   scanned GRNs. Decide whether the bundled ML Kit model is acceptable;
   otherwise add the unbundled artifact or move to LiteRT.
3. **Optimizer coverage still missing**: JPX/CCITT/JBIG2, CMYK, soft masks,
   palettes and encrypted PDFs are left unchanged. Implement only with real
   samples and a visual comparison; do not break the "never corrupt" rule.
4. **Signing/encryption:** do not hand-roll. Requires AES-256 per ISO 32000,
   PKCS#7/CMS, X.509, timestamping and a security audit.
5. **Editing:** annotations, form fields, richer content edits, thumbnail cache.
6. **Quality:** physical Android device matrix, very large files (500+ pages),
   parser/writer fuzzing beyond the 60-mutation smoke test, memory ceilings for
   high-resolution OCR, and a LiteRT benchmark on a physical phone.

### Known limitations to keep visible

- Optimizer: xref streams, hybrid files, `/ObjStm`, `/Prev` incremental updates
  and PNG/TIFF predictors are supported. Encrypted, JPX/CCITT/JBIG2, CMYK,
  indexed/palette, masked and soft-masked images are returned unchanged.
- Flate image conversion handles 8-bit DeviceRGB/DeviceGray only, no masks.
- Text extraction (pure Dart): `Tj`/`TJ` best effort; CMaps and custom
  encodings are ignored. Apple's companion uses PDFKit instead.
- Merge appends pages and renumbers objects; source outlines are dropped.
- Page edits flatten the page tree; target outlines are dropped.
- OCR: ML Kit cannot abort an in-flight page (Vision can). LiteRT confidence is
  reported as 0.0 because CTC logits are not calibrated. LiteRT models are not
  bundled and require minSdk 24.
- Android OCR/ML Kit needs the bundled model in the APK (~98 MB universal
  release example; use ABI splits in production).
- `tool/jnigen.dart` needs `flutter pub get` inside the core package and
  `ANDROID_HOME`/`ANDROID_SDK_ROOT`.
- The OCR package is nested inside the core repository. Pub applies the root
  `.pubignore` (which excludes `packages/` from the core archive) to nested
  publishes too, so **do not publish it in place**; use
  `tool/publish.sh`, which stages a clean copy in a temp directory.
- SPM manifests require `FlutterFramework`; CocoaPods and SPM builds are both
  tested (macOS build used SPM).
- The example disables release lint (`checkReleaseBuilds = false`) because AGP
  9's lint crashes on `file_selector_android` JavaDoc parsing. The published
  packages do not set this.
- README screenshots are generated with `flutter drive`; raw driver output is
  gitignored, resized copies live in `doc/screenshots/`.

### Handoff hygiene

- Personal identity/key only; never use the office Bitbucket credentials here.
- Generated files (`lib/src/android.g.dart`, example `GeneratedPlugin*`) are
  not hand-edited.
- Licensed MIT © Eishal Cyril; no third-party source in either package.
  `package:ffi`, `package:jni`, ML Kit and LiteRT are dependencies, not bundled
  source. PP-OCRv5 weights are Apache-2.0 and must not be committed.
- Test dylibs and `.litert_models` are build artifacts; do not commit them.

## Architecture

```
lib/
  native_pdf_kit.dart          public barrel
  src/bindings.dart            FFI bindings + loader (Apple)
  src/document.dart            pages, sizes, rendering, capabilities
  src/image.dart               native image resize/encode
  src/android_backend.dart     JNIgen PdfRenderer/Bitmap backend
  src/android.g.dart           generated JNIgen bindings (do not edit)
  src/optimizer/pdf_optimizer.dart
                               parser/writer, optimizer, text extraction,
                               page edits, merge, metadata
darwin/native_pdf_kit/         C shim over CoreGraphics + ImageIO
android/build.gradle           Android module declaration (Dart/JNI only)
tool/jnigen.dart               Android binding generator
tool/build_native_test_lib.sh  macOS test dylib builder
test/                          core tests (16)
example/                       iOS/Android/macOS example, demo UI,
                               integration_test/ocr_test.dart
packages/native_pdf_kit_ocr/
  lib/src/native_pdf_ocr.dart  page orchestration, progress, cancellation
  lib/src/apple_ocr.dart       Vision/PDFKit FFI + pollable session
  lib/src/android_ocr.dart     JNI bridge (low-level package:jni)
  darwin/.../native_pdf_ocr.m  PDFKit text layer, CoreGraphics render, Vision
  android/src/main/java/...    OcrBridge, MlKitEngine, LiteRtEngine
  test/                        macOS OCR tests (7)
```

- **Apple core**: direct FFI (`DynamicLibrary.process`) to a narrow C surface
  over CoreGraphics and ImageIO. Linked with CocoaPods and SPM.
- **Apple OCR**: Objective-C surface over PDFKit, CoreGraphics and Vision.
  Work runs on a global queue; Dart polls status, progress and stage. Vision's
  `progressHandler` gives intra-page progress; cancellation uses
  `VNRequest.cancel`.
- **Android core**: JNIgen to `android.graphics.pdf.PdfRenderer`, `Bitmap` and
  `BitmapFactory`, through `package:jni`.
- **Android OCR**: a Java bridge with its own worker thread. ML Kit runs
  synchronously on that thread with a latch; LiteRT runs the PP-OCRv5 detector
  and CTC recognizer. Dart polls a JSON status. Android 15+ text extraction
  uses `PdfRenderer.Page.getTextContents`; older versions fall back to the
  pure-Dart extractor in a background isolate.
- **Optimizer**: pure Dart parser/writer, Flate via `dart:io` zlib, embedded
  JPEG conversion through the platform codecs.
- **No platform channels anywhere.**

## Completed — 0.3.0 / OCR 0.1.0

- Core 0.2.0 features (rendering, imaging, optimizer, text, page edits, merge,
  metadata).
- Optimizer: xref streams, hybrid files, `/ObjStm` object streams,
  incremental-update `/Prev` chains, PNG/TIFF predictors, Flate RGB/gray image
  to JPEG conversion, `DCTDecode` downsampling.
- `PdfTextExtractor.extractPages` (per-page, one parse), predictor-aware.
- OCR companion:
  - Apple Vision revision 3, accurate/fast, language hints, auto-detect,
    line boxes, confidence, PDFKit text layer with per-line boxes,
    intra-page progress and cancellation.
  - Android ML Kit Text Recognition v2 bundled Latin; optional Chinese,
    Devanagari, Japanese, Korean artifacts via reflection.
  - Android LiteRT + PP-OCRv5 (DB detector, CTC decoder, dictionary) with
    app-supplied models.
  - `PdfOcrEvent` stream: progress, page, done; `extractDocument` /
    `extractImage` conveniences; cooperative cancellation.
  - Example demo UI with engine/mode pickers, live progress, page cards.
- Verified on macOS tests, iOS simulator/device builds, Android emulator
  runtime (ML Kit + LiteRT), macOS SPM build.

### Benchmarks (macOS, Dart JIT, `tool/benchmark.dart`)

- 100-page text PDF, 0.31 MB: `extract` 19 ms, `extractPages` 16 ms,
  lossless optimize 15 ms (322 KB → 54.5 KB).

## Planned / not done

1. **Optimizer coverage**
   - JPX/CCITT/JBIG2, CMYK, palettes, soft masks.
   - encrypted PDFs (needs decryption first).
   - fuzzing beyond the smoke test; large-file benchmarks.
2. **OCR**
   - physical Android device verification and memory limits on large scans.
   - ML Kit script artifacts bundled by the app; unbundled Play Services option.
   - LiteRT GPU/NPU delegates and model download UX.
   - optional PDF page-range UI helpers.
3. **Signing and encryption** — do not hand-roll.
4. **Editing** — annotations, form fields, thumbnail cache.
5. **Post-publish** — watch the pub.dev analysis/score, and bump the app
   dependency (core 0.3.0 / OCR 0.1.0).

## Commands

```sh
# Core
flutter pub get
flutter analyze
./tool/build_native_test_lib.sh   # macOS test dylib
flutter test

# Android bindings (core)
ANDROID_HOME="$HOME/Library/Android/sdk" dart run tool/jnigen.dart

# OCR companion
cd packages/native_pdf_kit_ocr
flutter pub get
./tool/build_native_test_lib.sh
flutter test
tool/fetch_litert_ocr_models.sh /tmp/ppocr   # optional models

# Example builds
cd example
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
flutter build apk --debug
flutter build apk --release
flutter build macos --debug

# Device OCR tests (models optional; skip if absent)
flutter test integration_test/ocr_test.dart -d emulator-5554

# Capture README screenshots (writes example/screenshots/, then copy to doc/)
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/screenshot_test.dart -d <device-id>

# Publish
dart pub publish --dry-run
dart pub publish
packages/native_pdf_kit_ocr/tool/publish.sh --dry-run
packages/native_pdf_kit_ocr/tool/publish.sh
```

## Testing notes

- `flutter test` runs on the Dart VM; plugin sources are not linked into the
  test process. Build the test dylib first with `tool/build_native_test_lib.sh`.
- Core tests cover text/image PDFs, merge, metadata, rotate, reorder/split,
  unsupported input, xref streams, hybrid files, object streams, predictors,
  incremental updates, Flate-to-JPEG, a real CUPS PDF and a 60-iteration
  corruption smoke test.
- OCR tests need the companion's dylib (`build/libnative_pdf_kit_ocr.dylib`)
  and copy the core dylib alongside it.
- Android device tests run through the example app. To exercise LiteRT, push
  the three model files to `/data/local/tmp/ppocr` (world-readable); the test
  also checks the app cache and skips when models are absent.
- The emulator used for verification is `Pixel_8_Pro_API_36`; its data
  partition was raised to 10 GB so the universal debug APK can install.

## License policy

- MIT, Copyright (c) 2026 Eishal Cyril, for both packages.
- No third-party source is copied into these packages.
- `package:ffi`, `package:jni`, ML Kit and LiteRT are dependencies, not bundled
  source. Do not copy their license text into these repositories' README/LICENSE.
- ML Kit is a closed-source Google SDK with its own terms; it is bundled by
  default in the OCR companion and must be an explicit product decision.
- PP-OCRv5 models are Apache-2.0 (PaddleOCR) and are downloaded, not
  redistributed. Do not commit model weights.
- Do not relicense upstream engines or embed AGPL/commercial PDF engines
  without an explicit decision.

## App integration

- The office Flutter app must not vendor the core package under its `packages/`
  directory.
- Preferred: publish to pub.dev and depend on `native_pdf_kit: ^0.3.0` and,
  if OCR is needed, `native_pdf_kit_ocr: ^0.1.0`.
- Temporary option: a git dependency on this repository, `ref: main`; for OCR
  use the same git dependency with `path: packages/native_pdf_kit_ocr`.
- After publishing, switch the app to the hosted versions and re-run
  `flutter pub get`.
