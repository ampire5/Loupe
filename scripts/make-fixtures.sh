#!/bin/bash
# Generates the single-image bench fixtures (HEIC, AVIF, JXL x2, WebP, PNG) from one big JPEG so
# the decoders can be compared on the same pixels. Output is git-ignored; the source is copied to
# a local temp dir first so nothing is ever written next to it (the bench folders are SMB mounts).
#
# usage: scripts/make-fixtures.sh <source.jpg> [outdir=Tests/Fixtures/bench]
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: $0 <source.jpg> [outdir=Tests/Fixtures/bench]" >&2
    exit 2
fi
src=$1
out=${2:-Tests/Fixtures/bench}

for tool in sips cjxl avifenc cwebp; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool (brew install jpeg-xl libavif webp)" >&2; exit 1; }
done
[ -f "$src" ] || { echo "no such file: $src" >&2; exit 1; }

mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/loupe-fixtures.XXXXXX")
trap 'rm -rf "$work"' EXIT

step() { echo "==> $*" >&2; }

step "copying source to $work"
cp "$src" "$work/src.jpg"
width=$(sips -g pixelWidth "$work/src.jpg" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$work/src.jpg" | awk '/pixelHeight/ {print $2}')
echo "source: ${width}x${height}" >&2

step "big.heic (sips; HEIC tiles large images itself)"
sips -s format heic "$work/src.jpg" --out "$out/big.heic" >/dev/null

step "big.avif (avifenc -s 6 -j all)"
# A single-image grid gives heif-tiles independent tiles to decode. Grid tiles must be even-sized
# for 4:2:0 and at least 64 px, so pick the largest column/row counts that divide the image evenly.
grid_args=()
pick_split() { # $1 = size; prints the largest n <= 8 with size/n even and >= 64
    local size=$1 n
    for n in 8 7 6 5 4 3 2; do
        if [ $((size % n)) -eq 0 ] && [ $((size / n % 2)) -eq 0 ] && [ $((size / n)) -ge 64 ]; then
            echo "$n"; return
        fi
    done
    echo 1
}
cols=$(pick_split "$width")
rows=$(pick_split "$height")
if [ "$cols" -gt 1 ] || [ "$rows" -gt 1 ]; then
    grid_args=(--grid "${cols}x${rows}")
    echo "avif grid: ${cols}x${rows}" >&2
else
    echo "avif grid: none (no even split of ${width}x${height})" >&2
fi
avifenc -s 6 -j all ${grid_args[@]+"${grid_args[@]}"} "$work/src.jpg" "$out/big.avif" >/dev/null

step "big.jxl (cjxl -d 1 -e 7, VarDCT re-encode)"
cjxl --lossless_jpeg=0 -d 1 -e 7 "$work/src.jpg" "$out/big.jxl" >/dev/null 2>&1

step "big-lossless-jpeg.jxl (cjxl --lossless_jpeg=1)"
cjxl --lossless_jpeg=1 "$work/src.jpg" "$out/big-lossless-jpeg.jxl" >/dev/null 2>&1

step "big.webp (cwebp -q 90; WebP is limited to 16383 px per side)"
webp_src="$work/src.jpg"
if [ "$width" -gt 16383 ] || [ "$height" -gt 16383 ]; then
    sips -Z 16383 "$work/src.jpg" --out "$work/webp-src.jpg" >/dev/null
    webp_src="$work/webp-src.jpg"
fi
cwebp -q 90 "$webp_src" -o "$out/big.webp" >/dev/null 2>&1

step "big.png (sips)"
sips -s format png "$work/src.jpg" --out "$out/big.png" >/dev/null

echo >&2
ls -l "$out" >&2
