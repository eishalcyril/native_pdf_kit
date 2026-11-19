# AGENTS.md — native_pdf_kit

Native PDF toolkit for Flutter. Direct iOS/Android interop, no platform
channels and no bundled third-party engine.

## Purpose

Provide fast, reliable PDF rendering, imaging, optimization, text extraction
and page operations for Flutter apps, entirely from our own code, with a
permissive MIT license owned by Eishal Cyril.

## Repository

- GitHub (personal): `https://github.com/eishalcyril/native_pdf_kit`
- Remote: `git@github.com:eishalcyril/native_pdf_kit.git`
- Identity: `Eishal Cyril <eishalcyril2@gmail.com>`
- SSH: repository-local `core.sshCommand` uses `~/.ssh/id_ed25519_personal`.
- Never commit or push this project to the office Bitbucket repository.

## Resume here — session handoff (2026-11-20)

### Where we stopped

- Package version: **0.2.0**. Committed and pushed to `main`; this note is
  part of that history.
- **Not published to pub.dev** — no credentials on the development machine.
  `dart pub publish --dry-run` reports **0 warnings** (~245 KB archive).
- Tests: **12/12 pass**. Run `./tool/build_native_test_lib.sh` before
  `flutter test` (the Dart VM test process does not link the plugin).
- Verified builds:
  - iOS simulator (app + example),
  - iOS device release (`flutter build ios --release --no-codesign`),
  - Android debug and release APK,
  - fresh clone of this repo: pub get, tests, analyze, example iOS build.
- Supported targets: **iOS 13+**, macOS 10.15+, **Android API 21+**.
- Office app state (`/Users/cufa/workspace/hims-f-b-mobileapp`):
  - `packages/native_pdf_kit/` has been **removed** from the app.
  - App `pubspec.yaml` uses a git dependency on this repo (`ref: main`).
  - App builds and launches on the iPhone 18 Pro simulator.
  - App changes are **uncommitted**; do not push them to Bitbucket as part of
    this package work.
  - Files touched in the app: `pubspec.yaml`, `pubspec.lock`,
    `lib/hims_inventory/grn_ai/screens/elements/document_upload.dart`.
  - The app's PDF compression path: `_optimizePdfInBackground` →
    `NativePdfOptimizer.optimize` via `compute`; `_compressPdf({lossless})`.

### Immediate next actions, in order

1. **Publish 0.2.0** (`dart pub login`, dry run, `dart pub publish`), then
   switch the office app from the git dependency to `native_pdf_kit: ^0.2.0`
   so CI does not depend on a personal git repository.
2. **Optimizer coverage (highest value):**
   xref streams, hybrid files and object streams (`/ObjStm`); then Flate
   images with predictors, JPX/CCITT/JBIG2, CMYK and soft masks.
   Until then, modern PDFs are returned unchanged by the optimizer.
3. **OCR decision:** Apple Vision is the Apple path. Android needs Google
   ML Kit (third-party SDK/licence) or a self-hosted model; the app does not
   use OCR, so this is a product/licensing decision, not a blocker.
4. **Signing/encryption:** do not hand-roll. Requires AES-256 per ISO 32000,
   PKCS#7/CMS, X.509, timestamping and a security audit.
5. **Editing:** annotations, form fields, richer content edits, thumbnail
   cache.
6. **Quality:** older-device matrix, large-file benchmarks, parser/writer
   fuzzing, Android optimizer runtime on a physical device (the current
   Android verification is emulator + build).

### Known limitations to keep visible

- Optimizer: classic xref tables only; encrypted/hybrid/object-stream PDFs
  are returned unchanged (safe, not optimized).
- Image downsampling: `DCTDecode`, RGB/gray, no masks; everything else is kept.
- Text extraction: `Tj`/`TJ` best effort; font CMaps and custom encodings are
  ignored.
- Merge: appends pages and renumbers objects; source outlines are not carried.
- Page edits: flatten the page tree; target outlines are dropped.
- `tool/jnigen.dart` needs `flutter pub get` **inside this package** and
  `ANDROID_HOME`/`ANDROID_SDK_ROOT`. The app's analyzer no longer includes it.
- SPM manifest requires `FlutterFramework`; CocoaPods and SPM builds are both
  tested.

### Handoff hygiene

- Personal identity/key only; never use the office Bitbucket credentials here.
- Generated files (`lib/src/android.g.dart`, example `GeneratedPlugin*`) are
  not hand-edited.
- Licensed MIT © Eishal Cyril; no third-party source in this package.
  `package:ffi` and `package:jni` are dependencies, not bundled code.

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
test/                          unit tests
example/                       iOS/Android/macOS example app
```

- **Apple**: direct FFI (`DynamicLibrary.process`) to a narrow C surface that
  uses CoreGraphics and ImageIO. Linked with CocoaPods and SPM.
- **Android**: JNIgen bindings to `android.graphics.pdf.PdfRenderer`,
  `Bitmap` and `BitmapFactory`, through `package:jni`.
- **No native runtime of our own on Android**; the platform classes do the
  work.
- **Optimizer**: pure Dart parser/writer, Flate via `dart:io` zlib, embedded
  JPEG downsampling through the platform codecs.

## Completed — 0.2.0

- Page count, media box, render to JPEG/PNG at a target width.
- Native image resize/encode with EXIF orientation (Apple ImageIO, Android
  Bitmap).
- In-house optimizer:
  - classic xref parsing, reachability and garbage collection,
  - maximum-effort Flate recompression,
  - JPEG (`DCTDecode`, RGB/gray, no masks) downsampling,
  - output re-parsed and page-count verified; unsupported input returned
    unchanged.
- Best-effort text-layer extraction (`Tj`, `TJ`, `'`, `"`; Flate/uncompressed).
- Page rotate, reorder, remove, split/extract (`reorderPdfPages`).
- Cross-document merge (`mergePdfs`) with object renumbering.
- Document metadata read/write (`PdfMetadataEditor`).
- Capability flags (`NativePdfCapabilities`).
- iOS 13+, macOS 10.15+, Android API 21+.
- Verified: iOS device release build (`--no-codesign`), Android release APK,
  iOS simulator run, 12/12 tests.

## Planned / not done

1. **Optimizer coverage**
   - xref streams, hybrid files, object streams (`/ObjStm`)
   - Flate images with predictors, JPX/CCITT/JBIG2, CMYK, soft masks
   - encrypted PDFs (needs decryption first)
2. **OCR**
   - Apple Vision (OS framework) is the preferred Apple path.
   - Android needs Google ML Kit or a self-hosted model; ML Kit is a
     third-party SDK and needs an explicit licensing decision.
3. **Signing and encryption**
   - Do not hand-roll. Requires AES-256 per ISO 32000, PKCS#7/CMS, X.509,
     timestamping and a security audit.
4. **Editing**
   - annotations, form fields, richer content editing, thumbnails cache.
5. **Quality**
   - device matrix (older iPhones/Android), large-file benchmarks, fuzzing of
     the parser/writer.

## Commands

```sh
flutter pub get
flutter analyze
./tool/build_native_test_lib.sh   # macOS test dylib
flutter test

# Android bindings
ANDROID_HOME="$HOME/Library/Android/sdk" dart run tool/jnigen.dart

# Example builds
cd example
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
flutter build apk --debug
flutter build apk --release

# Publish
dart pub publish --dry-run
dart pub publish
```

## Testing notes

- `flutter test` runs on the Dart VM; plugin sources are not linked into the
  test process. Build `build/libnative_pdf_kit.dylib` first with
  `tool/build_native_test_lib.sh`.
- The optimizer accepts classic xref PDFs only. Tests cover text PDFs, image
  PDFs, merge, metadata, rotate, reorder/split, unsupported input and a real
  CUPS-generated PDF.
- Generated files `lib/src/android.g.dart` and `example/**/GeneratedPlugin*`
  must not be hand-edited.

## License policy

- MIT, Copyright (c) 2026 Eishal Cyril.
- No third-party source is copied into this package.
- `package:ffi` and `package:jni` are dependencies (BSD, Dart team), not
  bundled source. Do not copy their license text into this repository's
  README/LICENSE.
- Do not relicense upstream engines or embed AGPL/commercial PDF engines
  without an explicit decision.

## App integration

- The office Flutter app must not vendor this package under its `packages/`
  directory.
- Preferred: publish to pub.dev and depend on `native_pdf_kit: ^0.2.0`.
- Temporary option: a git dependency on this repository, `ref: main`.
- After publishing, switch the app to the pub version and re-run
  `flutter pub get`.
