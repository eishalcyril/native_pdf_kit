#!/usr/bin/env bash
# Builds the macOS test dylib for native_pdf_kit_ocr.
#
# `flutter test` runs on the Dart VM, which does not link CocoaPods/SPM plugin
# sources into the test process. This script compiles the same Objective-C
# source into a dylib that the Dart loader picks up from `build/`.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build

# The tests also use the core package's renderer; build its dylib too.
CORE_ROOT="$(cd ../.. && pwd)"
if [ -x "$CORE_ROOT/tool/build_native_test_lib.sh" ]; then
  "$CORE_ROOT/tool/build_native_test_lib.sh"
  cp "$CORE_ROOT/build/libnative_pdf_kit.dylib" build/libnative_pdf_kit.dylib
fi

clang -dynamiclib -fPIC -O2 -fobjc-arc \
  -isysroot "$SDK" \
  -mmacosx-version-min=10.15 \
  -I darwin/native_pdf_kit_ocr/Sources/native_pdf_kit_ocr/include \
  darwin/native_pdf_kit_ocr/Sources/native_pdf_kit_ocr/native_pdf_ocr.m \
  -o build/libnative_pdf_kit_ocr.dylib \
  -framework Foundation \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework Vision \
  -framework PDFKit

echo "Built build/libnative_pdf_kit_ocr.dylib"
