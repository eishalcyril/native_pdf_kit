#!/usr/bin/env bash
# Publishes native_pdf_kit_ocr from a clean staging copy.
#
# The package lives inside the core repository. Pub applies the repository's
# root .pubignore (which excludes `packages/` from the core archive) even when
# publishing a nested package, so publishing in place hides every file. A clean
# copy outside the repository sidesteps that and also drops the local path
# override.
#
# Usage:
#   tool/publish.sh --dry-run
#   tool/publish.sh
#
# `native_pdf_kit` must already be published on pub.dev at the version in
# pubspec.yaml. For local validation before that, set NATIVE_PDF_KIT_PATH:
#   NATIVE_PDF_KIT_PATH=../.. tool/publish.sh --dry-run
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)/native_pdf_kit_ocr"
mkdir -p "$STAGE"

rsync -a \
  --exclude build \
  --exclude .dart_tool \
  --exclude pubspec.lock \
  --exclude pubspec_overrides.yaml \
  "$PACKAGE_DIR"/ "$STAGE"/

cd "$STAGE"

if [ -n "${NATIVE_PDF_KIT_PATH:-}" ]; then
  CORE="$(cd "$NATIVE_PDF_KIT_PATH" && pwd)"
  cat > pubspec_overrides.yaml <<EOF
dependency_overrides:
  native_pdf_kit:
    path: $CORE
EOF
fi

dart pub get
exec dart pub publish "$@"
