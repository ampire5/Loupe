#!/usr/bin/env bash
# Builds Loupe's libjxl: ../libjxl next to this checkout, or $LOUPE_LIBJXL (a clone of github.com/libjxl/libjxl,
# branch `loupe` off v0.12.0 with the DC image functions) into its dist/ — libjxl, libjxl_cms and libjxl_threads only, Release, brotli and
# highway from Homebrew. Dylibs get absolute install names in dist/lib, so `swift test` runs against them;
# bundle-dylibs.sh relocates them into the app. Run again after changing the branch: the build is incremental.
# Needs: brew install cmake ninja brotli highway
set -euo pipefail
src=${LOUPE_LIBJXL:-$(cd "$(dirname "$0")/../.." && pwd)/libjxl}
dist=$src/dist
[[ -d "$src/.git" ]] || { echo "no libjxl clone at $src" >&2; exit 1; }
branch=$(git -C "$src" rev-parse --abbrev-ref HEAD)
[[ "$branch" == loupe ]] || echo "warning: $src is on branch $branch, not loupe" >&2
cmake -S "$src" -B "$src/build-dist" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$dist" -DCMAKE_INSTALL_NAME_DIR="$dist/lib" -DCMAKE_MACOSX_RPATH=OFF \
    -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON >/dev/null
cmake --build "$src/build-dist"
cmake --install "$src/build-dist" >/dev/null
nm -gU "$dist/lib/libjxl.dylib" | grep -q _JxlDecoderGetDCImage \
    || { echo "error: $dist/lib/libjxl.dylib has no JxlDecoderGetDCImage (wrong branch?)" >&2; exit 1; }
echo "libjxl ($(git -C "$src" rev-parse --short HEAD)) installed in $dist"
