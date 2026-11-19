#!/usr/bin/env bash
# Builds the native test library for macOS.
#
# `flutter test` runs on the Dart VM, which does not link CocoaPods/SPM plugin
# sources into the test process. This script compiles the same C file into a
# dylib that the Dart loader picks up from `build/`.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build

clang -dynamiclib -fPIC -O2 \
  -isysroot "$SDK" \
  -mmacosx-version-min=10.15 \
  -I darwin/native_pdf_kit/Sources/native_pdf_kit/include \
  darwin/native_pdf_kit/Sources/native_pdf_kit/native_pdf.c \
  -o build/libnative_pdf_kit.dylib \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework CoreFoundation

echo "Built build/libnative_pdf_kit.dylib"
