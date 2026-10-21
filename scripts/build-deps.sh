#!/usr/bin/env bash
# The recipe of Loupe's decoders: static, for the architecture in scripts/deps.arch (arm64 on main, x86_64 on
# lts/macos26), built from source into .deps/<arch> (or $LOUPE_DEPS). The app links them in and bundles no dylibs (and
# Homebrew builds no Intel bottles any more):
#   libjpeg-turbo; brotli and highway; Loupe's libjxl (github.com/ampire5/libjxl, branch `loupe`: v0.12.0 plus the DC
#   image functions, pinned to a commit below); libde265 and libheif (LoupeBench only, HEIC without AVIF).
# Builds on either Mac, natively or as a cross build. Builds every time: scripts/deps.sh, which the build scripts call,
# downloads the prebuilt result of this exact recipe instead, and runs this only when there is none. A change here is
# a new recipe (a new prebuilt archive).
# The `# renovate:` lines let Renovate (renovate.json on main) propose version updates.
# Needs: brew install cmake ninja pkgconf (and nasm for x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."
# renovate: datasource=github-tags depName=libjpeg-turbo/libjpeg-turbo
jpeg_turbo_version=3.2.0
# renovate: datasource=github-tags depName=google/brotli extractVersion=^v(?<version>.+)$
brotli_version=1.2.0
# renovate: datasource=github-tags depName=google/highway
highway_version=1.4.0
# renovate: datasource=github-tags depName=strukturag/libde265 extractVersion=^v(?<version>.+)$
libde265_version=1.1.3
# renovate: datasource=github-tags depName=strukturag/libheif extractVersion=^v(?<version>.+)$
libheif_version=1.23.6
libjxl_commit=8b643990a3f30a55c220386329a3c59ccf189473   # branch loupe
min=26.0
arch=$(<scripts/deps.arch)
[[ $arch == arm64 || $arch == x86_64 ]] || { echo "error: scripts/deps.arch names $arch, not arm64 or x86_64" >&2; exit 1; }
prefix=${LOUPE_DEPS:-$PWD/.deps/$arch}
rm -rf "$prefix"
src=$prefix/src
mkdir -p "$src"
# Only this prefix: Homebrew's libraries must not leak into the static link.
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
unset PKG_CONFIG_PATH
export MACOSX_DEPLOYMENT_TARGET=$min

clone() {   # repository tag-or-branch directory
    git -c advice.detachedHead=false clone -q --depth 1 -b "$2" "https://github.com/$1" "$src/$3"
}
clone libjpeg-turbo/libjpeg-turbo "$jpeg_turbo_version" libjpeg-turbo
clone google/brotli "v$brotli_version" brotli
clone google/highway "$highway_version" highway
git init -q "$src/libjxl"
git -C "$src/libjxl" fetch -q --depth 1 https://github.com/ampire5/libjxl "$libjxl_commit"
git -C "$src/libjxl" -c advice.detachedHead=false checkout -q FETCH_HEAD
git -C "$src/libjxl" submodule update -q --init --depth 1 third_party/skcms third_party/lcms
clone strukturag/libde265 "v$libde265_version" libde265
clone strukturag/libheif "v$libheif_version" libheif

# A cross build even for the Mac's own architecture: CMake (Homebrew's may be arm64 under Rosetta) would take its own
# CPU for the target's.
cmake_target=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=$arch -DCMAKE_OSX_ARCHITECTURES=$arch
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min" -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)"
    -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF)
# Build trees sit next to the sources: highway (and others) have a Bazel BUILD file, which a `build` directory inside
# would collide with on macOS's case-insensitive file system.
build() {   # directory, then its CMake options
    local dir=$src/$1 out=$src/$1.out
    shift
    cmake -S "$dir" -B "$out" "${cmake_target[@]}" "$@" >/dev/null
    cmake --build "$out" >/dev/null
    cmake --install "$out" >/dev/null
}
build libjpeg-turbo -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=ON -DCMAKE_ASM_NASM_COMPILER=nasm
build brotli -DBROTLI_DISABLE_TESTS=ON
build highway -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF
build libjxl -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON
build libde265 -DENABLE_SDL=OFF -DENABLE_DECODER=OFF -DENABLE_ENCODER=OFF
build libheif -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF -DENABLE_PLUGIN_LOADING=OFF -DWITH_EXAMPLES=OFF \
    -DWITH_GDK_PIXBUF=OFF -DWITH_X265=OFF -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF -DWITH_DAV1D=OFF \
    -DWITH_RAV1E=OFF -DWITH_SvtEnc=OFF -DWITH_KVAZAAR=OFF -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF \
    -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF -DWITH_FFMPEG_DECODER=OFF -DWITH_OPENJPH_ENCODER=OFF \
    -DWITH_LIBSHARPYUV=OFF

# (Output is captured first: with pipefail, `nm | grep -q` can fail spuriously when grep quits early.)
symbols=$(nm -g "$prefix/lib/libjxl.a" 2>/dev/null)
grep -q _JxlDecoderGetDCImage <<<"$symbols" \
    || { echo "error: libjxl.a has no JxlDecoderGetDCImage (wrong branch?)" >&2; exit 1; }

# SwiftPM reads only `Libs`: each .pc gets its whole static link line there (pkg-config --static), keeping the flags
# SwiftPM allows (-L, -l, -framework), plus libc++ for the C++ libraries.
pcdir=$prefix/lib/pkgconfig
for pc in "$pcdir"/*.pc; do
    name=$(basename "$pc" .pc)
    libs=$( (pkg-config --static --libs "$name"; echo -lc++) | tr ' ' '\n' | awk '
        framework { print "-framework " $0; framework = 0; next }
        $0 == "-framework" { framework = 1; next }
        /^-[lL]/ { print }' | awk '!seen[$0]++' | tr '\n' ' ')
    awk -v libs="$libs" '/^Libs:/ { print "Libs: " libs; next } /^(Libs|Requires)\.private:/ { next } { print }' \
        "$pc" >"$pc.flat"
done
for pc in "$pcdir"/*.pc; do mv "$pc.flat" "$pc"; done

for lib in turbojpeg jxl jxl_threads heif; do
    [[ $(lipo -archs "$prefix/lib/lib$lib.a") == "$arch" ]] \
        || { echo "error: lib$lib.a is not $arch only: $(lipo -archs "$prefix/lib/lib$lib.a")" >&2; exit 1; }
done
rm -rf "$src"
echo "Decoders (libjpeg-turbo $jpeg_turbo_version, libjxl ${libjxl_commit:0:10}, libheif $libheif_version; macOS $min) installed in $prefix"
