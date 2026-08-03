#!/usr/bin/env bash
#
# download-models.sh — fetch SAM 2.1 Small Core ML models from Apple's
# official Hugging Face repo (apple/coreml-sam2.1-small) into Models/.
#
# Why Small (not Tiny): the mask boundary becomes the laser CUT outline, so
# boundary quality matters more than in a preview use case. Small is ~94 MB
# vs Tiny's ~79 MB — a marginal size delta for a noticeably better hiera
# backbone (facebook/sam2.1-hiera-small vs -tiny).
#
# Files are fetched directly over HTTPS via the /resolve/ endpoint, so there
# is no git-lfs involvement and no risk of ending up with LFS pointer files.
# Every file is size-checked; LFS-tracked files are also sha256-verified.
#
# Usage: scripts/download-models.sh
# Idempotent: already-verified files are skipped.

set -euo pipefail

REPO="apple/coreml-sam2.1-small"
REVISION="main"
BASE_URL="https://huggingface.co/${REPO}/resolve/${REVISION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="${ROOT_DIR}/Models"

mkdir -p "$MODELS_DIR"

# path|expected_size_bytes|sha256 ("-" = not LFS, size check only)
FILES=(
  "SAM2_1SmallImageEncoderFLOAT16.mlpackage/Manifest.json|617|-"
  "SAM2_1SmallImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel|203631|736602a3130875072f843df123ce3ceff41ec2f917a867da56f7c2264d81a567"
  "SAM2_1SmallImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin|81268288|6128a58f10cbcb7797bd12a7ec1e05ab4e9f8c80bd14ed05bbc43a9c9935a9c3"
  "SAM2_1SmallPromptEncoderFLOAT16.mlpackage/Manifest.json|617|-"
  "SAM2_1SmallPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel|20618|3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3"
  "SAM2_1SmallPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin|2101056|e29c6c65ef7754f8f6ed26155ca39ea703de3a7f576be5a7d3b8e29545059f31"
  "SAM2_1SmallMaskDecoderFLOAT16.mlpackage/Manifest.json|617|-"
  "SAM2_1SmallMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel|75167|3536b71674dc706381f42833b55627fd3d1f2c1b68a365b49255284b4f7b55c7"
  "SAM2_1SmallMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin|10222400|dbc4910c434fee657ed9f001da7abcb467d2a37ac235099c6aa47628b122ec4e"
)

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

verify() {
  local path="$1" expected_size="$2" expected_sha="$3"
  [[ -f "$path" ]] || return 1
  local actual_size
  actual_size="$(file_size "$path")"
  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "  size mismatch for $path: got $actual_size, want $expected_size" >&2
    return 1
  fi
  # An LFS pointer file is ~131 bytes of text; the size check above already
  # rules that out for weights, but verify the hash too when we have one.
  if [[ "$expected_sha" != "-" ]]; then
    local actual_sha
    actual_sha="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      echo "  sha256 mismatch for $path" >&2
      return 1
    fi
  fi
  return 0
}

failures=0
for entry in "${FILES[@]}"; do
  IFS='|' read -r rel size sha <<<"$entry"
  dest="${MODELS_DIR}/${rel}"
  if verify "$dest" "$size" "$sha"; then
    echo "ok (cached)  $rel"
    continue
  fi
  echo "downloading  $rel"
  mkdir -p "$(dirname "$dest")"
  curl -fSL --retry 3 --retry-delay 2 -o "${dest}.tmp" "${BASE_URL}/${rel}"
  mv "${dest}.tmp" "$dest"
  if verify "$dest" "$size" "$sha"; then
    echo "verified     $rel ($size bytes)"
  else
    echo "FAILED to verify $rel" >&2
    failures=$((failures + 1))
  fi
done

if [[ $failures -gt 0 ]]; then
  echo "ERROR: $failures file(s) failed verification." >&2
  exit 1
fi

echo
echo "All SAM 2.1 Small Core ML models downloaded and verified in ${MODELS_DIR}/"
du -sh "${MODELS_DIR}"/*.mlpackage
