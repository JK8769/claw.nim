#!/usr/bin/env bash
# Build lark-cli from the channels/lark-cli submodule.
# Requires Go 1.23+ and Python 3 (for metadata fetching).
#
# Usage:
#   ./channels/build_lark_cli.sh              # build for current platform
#   ./channels/build_lark_cli.sh linux amd64  # cross-compile
#
# Output goes to channels/bin/lark-cli

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/lark-cli"
OUT_DIR="$SCRIPT_DIR/bin"

if [ ! -f "$SRC_DIR/main.go" ]; then
  echo "Submodule not initialized. Run: git submodule update --init channels/lark-cli" >&2
  exit 1
fi

TARGET_OS="${1:-$(go env GOOS)}"
TARGET_ARCH="${2:-$(go env GOARCH)}"

echo "Building lark-cli for ${TARGET_OS}/${TARGET_ARCH}..."

mkdir -p "$OUT_DIR"
cd "$SRC_DIR"

OUTPUT="lark-cli"
if [ "$TARGET_OS" = "windows" ]; then
  OUTPUT="lark-cli.exe"
fi

# Fetch API metadata (required by build)
python3 scripts/fetch_meta.py

GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" \
  go build -trimpath -ldflags "-s -w" -o "$OUT_DIR/$OUTPUT" .

echo "Built: $OUT_DIR/$OUTPUT"
