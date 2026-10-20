#!/usr/bin/env bash
# Builds build/Loupe.app (release). Only the Loupe product is built. Its decoders (libjpeg-turbo from Homebrew, Loupe's
# own libjxl from ../libjxl/dist — scripts/build-libjxl.sh — and their dependencies) are copied into
# Contents/Frameworks by bundle-dylibs.sh; libheif is not linked by the app.
# Usage: scripts/make-app.sh [--install]   (--install copies the app to ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/libjxl-env.sh
swift build -c release --product Loupe
app=build/Loupe.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Loupe" "$app/Contents/MacOS/Loupe"
scripts/bundle-dylibs.sh "$app"
# The bundle must run on a Mac without Homebrew: every link of the binary and of each bundled dylib must be a
# system library or a dylib inside Contents/Frameworks, and no rpath may point outside the bundle/system.
# (Command output is captured first: with pipefail, `otool | grep -q` can fail spuriously when grep quits early.)
check_links() {
    local bad=0 file links rpaths line name
    for file in "$app/Contents/MacOS/Loupe" "$app"/Contents/Frameworks/*.dylib; do
        [[ -f "$file" ]] || continue
        links=$(otool -L "$file" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility.*$//')
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            case "$line" in
                /usr/lib/* | /System/*) ;;
                @rpath/*)
                    name=${line#@rpath/}
                    if [[ ! -f "$app/Contents/Frameworks/$name" ]]; then
                        echo "error: $file links $line, which is not in Contents/Frameworks" >&2; bad=1
                    fi ;;
                *) echo "error: $file links $line" >&2; bad=1 ;;
            esac
        done <<<"$links"
        rpaths=$(otool -l "$file" | awk '/cmd LC_RPATH/ {r=1} r && $1 == "path" {print $2; r=0}')
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            case "$line" in
                /usr/lib/* | /System/* | @loader_path | @loader_path/* | @executable_path/*) ;;
                *) echo "error: $file has LC_RPATH $line" >&2; bad=1 ;;
            esac
        done <<<"$rpaths"
    done
    return $bad
}
if ! check_links; then
    echo "error: Loupe.app links something outside the allow-list (see above)" >&2
    exit 1
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
# Document icons, one per format (CFBundleTypeIconFile in Info.plist), from the image lab's doc_icons.sh.
cp Resources/DocumentIcons/*.icns "$app/Contents/Resources/"
# App icon: the Icon Composer package (art.png rendered outside this repository) is compiled by
# actool into Assets.car (Liquid Glass icon, CFBundleIconName) plus AppIcon.icns (CFBundleIconFile, for older
# readers). actool ships with Xcode, not with the Command Line Tools; without it the app builds with the generic
# icon. Absolute paths: actool runs in a long-lived helper that resolves relative paths against its own directory.
if xcrun --find actool >/dev/null 2>&1; then
    icon_tmp=$(mktemp -d)
    xcrun actool "$PWD/Resources/Icons/AppIcon.icon" --compile "$PWD/$app/Contents/Resources" --platform macosx \
        --minimum-deployment-target 26.0 --app-icon AppIcon \
        --output-partial-info-plist "$icon_tmp/partial.plist" >"$icon_tmp/actool.log" 2>&1 \
        || { cat "$icon_tmp/actool.log" >&2; echo "error: actool failed to compile the app icon" >&2; exit 1; }
    for f in Assets.car AppIcon.icns; do
        [[ -f "$app/Contents/Resources/$f" ]] || { echo "error: actool did not produce $f" >&2; exit 1; }
    done
    # The `app-icon` alternates (one full-bleed picture each; actool cuts the rounded square and adds the glass
    # edge): only their .icns is kept, as Contents/Resources/AppIcons/<name>.icns, which the app sets as its
    # Dock icon at run time. Their Assets.car goes, so the bundle's own icon stays AppIcon.
    mkdir -p "$app/Contents/Resources/AppIcons"
    for package in Resources/Icons/Alternates/*.icon; do
        name=$(basename "$package" .icon)
        mkdir -p "$icon_tmp/$name"
        xcrun actool "$PWD/$package" --compile "$icon_tmp/$name" --platform macosx \
            --minimum-deployment-target 26.0 --app-icon "$name" \
            --output-partial-info-plist "$icon_tmp/$name.plist" >"$icon_tmp/actool.log" 2>&1 \
            || { cat "$icon_tmp/actool.log" >&2; echo "error: actool failed to compile $package" >&2; exit 1; }
        [[ -f "$icon_tmp/$name/$name.icns" ]] || { echo "error: actool did not produce $name.icns" >&2; exit 1; }
        cp "$icon_tmp/$name/$name.icns" "$app/Contents/Resources/AppIcons/"
    done
    rm -rf "$icon_tmp"
else
    echo "warning: actool not found (needs Xcode); Loupe.app gets the generic icon" >&2
fi
# Sign nested code first (install_name_tool invalidated the signatures), then the app.
for dylib in "$app"/Contents/Frameworks/*.dylib; do
    codesign --force --sign - "$dylib"
done
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Loupe.app"
    cp -R "$app" "$HOME/Applications/"
    echo "Installed to ~/Applications/Loupe.app"
fi
