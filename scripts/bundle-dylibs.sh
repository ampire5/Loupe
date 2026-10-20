#!/usr/bin/env bash
# Usage: scripts/bundle-dylibs.sh <Loupe.app>
# Copies every Homebrew dylib the app binary needs (transitively), and Loupe's own libjxl from ../libjxl/dist
# (scripts/build-libjxl.sh), into Contents/Frameworks, points every
# reference at @rpath/<name>, gives each copy the id @rpath/<name>, and adds the Frameworks rpath to the binary.
# Signing is left to the caller: install_name_tool invalidates signatures.
set -euo pipefail
app=${1:?usage: bundle-dylibs.sh <Loupe.app>}
bin="$app/Contents/MacOS/Loupe"
fw="$app/Contents/Frameworks"
brew=/opt/homebrew
jxl=${LOUPE_LIBJXL:-$(cd "$(dirname "$0")/../.." && pwd)/libjxl}/dist/lib
mkdir -p "$fw"

# Absolute path of a dependency as the linker recorded it (or an @rpath name searched in libjxl's and Homebrew's
# lib dirs).
resolve() {
    local ref=$1 name cand
    case "$ref" in
        "$brew"/* | "$jxl"/*) echo "$ref"; return ;;
        @rpath/*)
            name=${ref#@rpath/}
            for cand in "$jxl/$name" "$brew"/opt/*/lib/"$name"; do
                [[ -e "$cand" ]] && { echo "$cand"; return; }
            done ;;
    esac
    return 1
}

# Bundle-bound references of a file: absolute /opt/homebrew and libjxl dist paths, plus @rpath names that are not
# already bundled (those can only come from a Homebrew library's own @rpath links).
refs_of() {
    otool -L "$1" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//' |
        while IFS= read -r ref; do
            case "$ref" in
                "$brew"/* | "$jxl"/*) echo "$ref" ;;
                @rpath/*) [[ -f "$fw/${ref#@rpath/}" ]] || echo "$ref" ;;
            esac
        done
}

queue=("$bin")
while ((${#queue[@]} > 0)); do
    file=${queue[0]}
    queue=("${queue[@]:1}")
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        name=$(basename "$ref")
        if [[ ! -f "$fw/$name" ]]; then
            src=$(resolve "$ref") || { echo "error: cannot resolve $ref (needed by $file)" >&2; exit 1; }
            cp -L "$src" "$fw/$name"
            chmod u+w "$fw/$name"
            install_name_tool -id "@rpath/$name" "$fw/$name"
            # Homebrew builds carry rpaths into the Cellar; every dependency is found via the app's rpath instead.
            while IFS= read -r rp; do
                [[ -n "$rp" ]] && install_name_tool -delete_rpath "$rp" "$fw/$name"
            done < <(otool -l "$fw/$name" | awk '/cmd LC_RPATH/ {r=1} r && $1 == "path" {print $2; r=0}' | grep "^$brew" || true)
            queue+=("$fw/$name")
        fi
        install_name_tool -change "$ref" "@rpath/$name" "$file"
    done < <(refs_of "$file")
done

# The binary finds the copies through the Frameworks rpath (added once).
if ! otool -l "$bin" | awk '/cmd LC_RPATH/ {r=1} r && $1 == "path" {print $2; r=0}' | grep -qx '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$bin"
fi
echo "Bundled $(ls "$fw" | wc -l | tr -d ' ') dylibs into $fw"
