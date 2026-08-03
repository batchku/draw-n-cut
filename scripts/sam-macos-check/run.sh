#!/usr/bin/env bash
#
# Compiles and runs the macOS SAM 2 pipeline check (see main.swift for why
# this exists alongside the simulator test suite). Exit 0 = SAM produces a
# plausible fish mask on this machine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -O \
    -o "${BUILD_DIR}/sam-macos-check" \
    "${SCRIPT_DIR}/main.swift" \
    "${ROOT_DIR}/DrawNCut/Segmentation/SAM2Segmenter.swift"

"${BUILD_DIR}/sam-macos-check" "${ROOT_DIR}/Models" "${ROOT_DIR}/Fixtures/fish-photo.jpg"
