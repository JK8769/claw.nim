#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GGML_DIR="$SCRIPT_DIR/ggml"
BUILD_DIR="$GGML_DIR/build"
OUT_DIR="$SCRIPT_DIR/lib"

mkdir -p "$OUT_DIR"

# Detect platform
OS="$(uname -s)"
ARCH="$(uname -m)"

CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_BUILD_TESTS=OFF -DGGML_BUILD_EXAMPLES=OFF"

case "$OS" in
  Darwin)
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_METAL=ON"
    echo "Building ggml for macOS ($ARCH) with Metal..."
    ;;
  Linux)
    CMAKE_ARGS="$CMAKE_ARGS -DGGML_METAL=OFF"
    # Enable CUDA if nvcc is available
    if command -v nvcc >/dev/null 2>&1; then
      CMAKE_ARGS="$CMAKE_ARGS -DGGML_CUDA=ON"
      echo "Building ggml for Linux ($ARCH) with CUDA..."
    else
      echo "Building ggml for Linux ($ARCH) CPU-only..."
    fi
    ;;
  *)
    echo "Unsupported OS: $OS"
    exit 1
    ;;
esac

cmake -B "$BUILD_DIR" -S "$GGML_DIR" $CMAKE_ARGS
cmake --build "$BUILD_DIR" --config Release -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu)"

# Collect static libs (they're in subdirectories)
find "$BUILD_DIR/src" -name "libggml*.a" -exec cp {} "$OUT_DIR/" \;

# Metal shader on macOS
if [ "$OS" = "Darwin" ] && [ -f "$BUILD_DIR/bin/ggml-metal.metallib" ]; then
  cp "$BUILD_DIR/bin/ggml-metal.metallib" "$OUT_DIR/"
fi

echo ""
echo "=== ggml build complete ==="
ls -lh "$OUT_DIR"/*.a 2>/dev/null
echo "Output: $OUT_DIR/"
