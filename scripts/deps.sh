#!/usr/bin/env bash
# The prebuilt dependencies: scripts/build-deps.sh's output for $DEPS_ARCH (the Mac's own architecture unless set),
# published as a release asset so CI, releases and local builds use the same binaries without building them again.
# The archive is named after the architecture and the recipe: deps-<arch>-<first 12 hex digits of the SHA-256 of build-deps.sh without
# its comment lines>. A changed recipe
# has no archive until the "Prebuilt dependencies" workflow publishes one (it runs when the recipe changes on the
# branch); until then this builds from source.
#
# Usage: scripts/deps.sh [fetch]   make .deps/<arch> hold this recipe's dependencies: kept if it already does,
#                                  else downloaded (SHA-256 checked), else built with scripts/build-deps.sh
#        scripts/deps.sh name      print the archive's name
#        scripts/deps.sh pack DIR  write <name>.tar.xz and <name>.tar.xz.sha256 into DIR from .deps/<arch>
set -euo pipefail
cd "$(dirname "$0")/.."
arch=${DEPS_ARCH:-$(uname -m)}
prefix=${LOUPE_DEPS:-$PWD/.deps/$arch}
repo=${DEPS_REPO:-ampire5/Loupe}
# Comments do not count: only the recipe's commands and versions name the archive.
name=deps-$arch-$(grep -v '^[[:space:]]*#' scripts/build-deps.sh | shasum -a 256 | cut -c1-12)
# The .pc files hold absolute paths; in the archive they read @DEPS_PREFIX@, put back on unpacking.
placeholder=@DEPS_PREFIX@

case ${1:-fetch} in
    name)
        echo "$name" ;;
    pack)
        out=${2:?usage: scripts/deps.sh pack DIR}
        [[ -f "$prefix/.name" && $(<"$prefix/.name") == "$name" ]] \
            || { echo "error: $prefix is not $name (run scripts/deps.sh first)" >&2; exit 1; }
        stage=$(mktemp -d)
        trap 'rm -rf "$stage"' EXIT
        cp -R "$prefix/include" "$prefix/lib" "$stage/"
        for pc in "$stage"/lib/pkgconfig/*.pc; do
            sed -i '' "s#$prefix#$placeholder#g" "$pc"
        done
        mkdir -p "$out"
        tar -C "$stage" -cJf "$out/$name.tar.xz" include lib
        (cd "$out" && shasum -a 256 "$name.tar.xz" >"$name.tar.xz.sha256")
        echo "Packed $out/$name.tar.xz" ;;
    fetch)
        if [[ -f "$prefix/.name" && $(<"$prefix/.name") == "$name" ]]; then
            exit 0
        fi
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        url=https://github.com/$repo/releases/download/$name/$name.tar.xz
        if curl -fsSL -o "$tmp/deps.tar.xz" "$url" && curl -fsSL -o "$tmp/deps.sha256" "$url.sha256"; then
            expected=$(cut -d' ' -f1 "$tmp/deps.sha256")
            actual=$(shasum -a 256 "$tmp/deps.tar.xz" | cut -d' ' -f1)
            [[ "$expected" == "$actual" ]] \
                || { echo "error: $name.tar.xz has SHA-256 $actual, the release says $expected" >&2; exit 1; }
            rm -rf "$prefix"
            mkdir -p "$prefix"
            tar -C "$prefix" -xJf "$tmp/deps.tar.xz"
            for pc in "$prefix"/lib/pkgconfig/*.pc; do
                sed -i '' "s#$placeholder#$prefix#g" "$pc"
            done
            echo "Downloaded $name into $prefix"
        else
            echo "No prebuilt $name at $repo: building it (scripts/build-deps.sh)" >&2
            scripts/build-deps.sh
        fi
        echo "$name" >"$prefix/.name" ;;
    *)
        echo "usage: scripts/deps.sh [fetch | name | pack DIR]" >&2
        exit 2 ;;
esac
