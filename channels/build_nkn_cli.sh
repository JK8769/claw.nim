#!/usr/bin/env bash
# Build nkn-cli for the current or target platform.
# Requires Go 1.21+.
#
# Usage:
#   ./channels/build_nkn_cli.sh              # build for current OS/arch
#   ./channels/build_nkn_cli.sh linux amd64  # cross-compile
#
# Output goes to channels/bin/nkn-cli

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/nkn-cli"
OUT_DIR="$SCRIPT_DIR/bin"

TARGET_OS="${1:-$(go env GOOS)}"
TARGET_ARCH="${2:-$(go env GOARCH)}"

echo "Building nkn-cli for ${TARGET_OS}/${TARGET_ARCH}..."

mkdir -p "$OUT_DIR"
cd "$SRC_DIR"

OUTPUT="nkn-cli"
if [ "$TARGET_OS" = "windows" ]; then
  OUTPUT="nkn-cli.exe"
fi

CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
  go build -o "$OUT_DIR/$OUTPUT" main.go

echo "Built: $OUT_DIR/$OUTPUT"
