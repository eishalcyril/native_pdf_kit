#!/usr/bin/env bash
# Downloads the Apache-2.0 PP-OCRv5 LiteRT models used by the optional engine.
#
# Usage:
#   tool/fetch_litert_ocr_models.sh [destination]
#
# The models are not redistributed with the package. Point PdfLiteRtModels at
# the files in the destination directory.
set -euo pipefail

DEST="${1:-${PWD}/.litert_models}"
BASE="https://huggingface.co/litert-community/PP-OCRv5-LiteRT/resolve/main"

mkdir -p "$DEST"

for file in ppocr_det_fp16.tflite ppocr_rec_fp16.tflite ppocrv5_dict.txt; do
  if [ -f "$DEST/$file" ]; then
    echo "already present: $DEST/$file"
    continue
  fi
  echo "downloading $file"
  curl -fL --retry 3 -o "$DEST/$file" "$BASE/$file"
done

echo
echo "Models are in $DEST"
echo "  detector:   $DEST/ppocr_det_fp16.tflite"
echo "  recognizer: $DEST/ppocr_rec_fp16.tflite"
echo "  dictionary: $DEST/ppocrv5_dict.txt"
echo
echo "The models are Apache-2.0 (PaddleOCR). Do not commit them to the repo."
