#!/usr/bin/env bash
# Builds Loupe's decoders for the lts/macos26 line (LTS_POLICY.md): x86_64, static, into .deps/x86_64 (or
# $LOUPE_DEPS). Homebrew builds no Intel bottles any more, so the Intel app links them in and bundles no dylibs:
#   libjpeg-turbo; brotli and highway; Loupe's libjxl (github.com/ampire5/libjxl, branch `loupe`: v0.12.0 plus the DC
#   image functions); libde265 and libheif (LoupeBench only, HEIC without AVIF).
# Runs on an Intel Mac and on Apple Silicon (a cross build). A finished build is kept: delete the directory, or
# change a version below, to build again.
# Needs: brew install cmake ninja nasm pkgconf
set -euo pipefail
cd "$(dirname "$0")/.."
jpeg_turbo_version=3.2.0
brotli_version=1.2.0
highway_version=1.4.0
libde265_version=1.1.3
libheif_version=1.23.6
libjxl_branch=loupe
min=26.0
prefix=${LOUPE_DEPS:-$PWD/.deps/x86_64}
libjxl_sha=$(git ls-remote https://github.com/ampire5/libjxl "refs/heads/$libjxl_branch" | cut -f1)
[[ -n "$libjxl_sha" ]] || { echo "error: no branch $libjxl_branch in ampire5/libjxl" >&2; exit 1; }
stamp="libjpeg-turbo $jpeg_turbo_version, brotli $brotli_version, highway $highway_version, libjxl ${libjxl_sha:0:10}, libde265 $libde265_version, libheif $libheif_version, macOS $min"
if [[ -f "$prefix/.stamp" && $(<"$prefix/.stamp") == "$stamp" ]]; then
    echo "Decoders ($stamp) already in $prefix"
    exit 0
fi
rm -rf "$prefix"
src=$prefix/src
mkdir -p "$src"
# Only this prefix: Homebrew's arm64 libraries must not leak into the x86_64 link.
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
unset PKG_CONFIG_PATH
export MACOSX_DEPLOYMENT_TARGET=$min

clone() {   # repository tag-or-branch directory
    git -c advice.detachedHead=false clone -q --depth 1 -b "$2" "https://github.com/$1" "$src/$3"
}
clone libjpeg-turbo/libjpeg-turbo "$jpeg_turbo_version" libjpeg-turbo
clone google/brotli "v$brotli_version" brotli
clone google/highway "$highway_version" highway
clone ampire5/libjxl "$libjxl_branch" libjxl
git -C "$src/libjxl" submodule update -q --init --depth 1 third_party/skcms third_party/lcms
clone strukturag/libde265 "v$libde265_version" libde265
clone strukturag/libheif "v$libheif_version" libheif

# A cross build even on an Intel Mac: Homebrew's CMake is arm64 and would take the host's CPU for the target's.
cmake_x86_64=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_OSX_ARCHITECTURES=x86_64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min" -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)"
    -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF)
# Build trees sit next to the sources: highway (and others) have a Bazel BUILD file, which a `build` directory inside
# would collide with on macOS's case-insensitive file system.
build() {   # directory, then its CMake options
    local dir=$src/$1 out=$src/$1.out
    shift
    cmake -S "$dir" -B "$out" "${cmake_x86_64[@]}" "$@" >/dev/null
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
    [[ $(lipo -archs "$prefix/lib/lib$lib.a") == x86_64 ]] \
        || { echo "error: lib$lib.a is not x86_64 only: $(lipo -archs "$prefix/lib/lib$lib.a")" >&2; exit 1; }
done
rm -rf "$src"
echo "$stamp" >"$prefix/.stamp"
echo "Decoders ($stamp) installed in $prefix"
