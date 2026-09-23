#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
ARCHIVE="$ROOT/Vendor/Source/tiff-4.7.1.tar.gz"
EXPECTED="f698d94f3103da8ca7438d84e0344e453fe0ba3b7486e04c5bf7a9a3fabe9b69"
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL" != "$EXPECTED" ]; then
    printf 'LibTIFF source checksum mismatch\n' >&2
    exit 1
fi
BUILD=$(mktemp -d "$ROOT/build-libtiff.XXXXXX")
tar -xzf "$ARCHIVE" -C "$BUILD"
cd "$BUILD/tiff-4.7.1"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=13.0"
export LDFLAGS="-arch arm64 -mmacosx-version-min=13.0"
./configure --prefix="$ROOT/Vendor" --disable-shared --enable-static \
    --disable-tools --disable-tests --disable-contrib --disable-docs --disable-cxx \
    --disable-jpeg --disable-jbig --disable-lzma --disable-zstd --disable-webp \
    --disable-lerc --disable-libdeflate
make -j4
make install
printf 'LibTIFF rebuilt. Intermediate files: %s\n' "$BUILD"
