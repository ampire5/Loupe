#!/usr/bin/env bash
# Builds build/Loupe.app (release, for $DEPS_ARCH: the Mac's own architecture unless set, scripts/libjxl-env.sh). Only
# the Loupe product is built. Its decoders (libjpeg-turbo, Loupe's own libjxl and their dependencies) are linked in
# statically (scripts/build-deps.sh), so the app bundles no dylibs; libheif is not linked by the app.
# Usage: scripts/make-app.sh [--install] [--label NAME]   (--install copies the app to ~/Applications; --label, or
# env LOUPE_BUILD_LABEL, names the build in Loupe › About Loupe, e.g. L7)
set -euo pipefail
cd "$(dirname "$0")/.."
install=0
label=${LOUPE_BUILD_LABEL:-}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install) install=1 ;;
        --label) label=${2:?--label needs a name}; shift ;;
        --label=*) label=${1#--label=} ;;
        *) echo "error: unknown argument $1" >&2; exit 1 ;;
    esac
    shift
done
. scripts/libjxl-env.sh
swift build -c release --triple "$DEPS_TRIPLE" --product Loupe
app=build/Loupe.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
built=$(swift build -c release --triple "$DEPS_TRIPLE" --show-bin-path)/Loupe
cp "$built" "$app/Contents/MacOS/Loupe"
# The symbols go to build/Loupe.dSYM, for symbolicating crash reports, not into the app (~5 MB less).
rm -rf build/Loupe.dSYM
dsymutil "$built" -o build/Loupe.dSYM >/dev/null 2>&1 || echo "warning: no build/Loupe.dSYM (dsymutil failed)" >&2
strip "$app/Contents/MacOS/Loupe"
[[ $(lipo -archs "$app/Contents/MacOS/Loupe") == "$DEPS_ARCH" ]] \
    || { echo "error: Loupe is $(lipo -archs "$app/Contents/MacOS/Loupe"), not $DEPS_ARCH" >&2; exit 1; }
# The bundle must run on a Mac without Homebrew: every link of the binary must be a system library (or a dylib inside
# Contents/Frameworks, should one come back), and no rpath may point outside the bundle/system.
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
# The build's identity for About Loupe (LoupeCore BuildInfo): commit (+dirty with uncommitted changes, the local
# Package.resolved and release.yaml aside), branch, build time with its time zone and the label. A tag checkout
# (detached HEAD) names CI's ref (GITHUB_REF_NAME), else "detached". Git is asked only when this tree is a repository's
# root: a source tree without its own .git inside another repository would take that one's commit; without git, or
# there, commit and branch read "unknown".
commit=unknown branch=unknown
top=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n $top && $(cd "$top" && pwd -P) == "$(pwd -P)" ]]; then
    commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
    branch=$(git symbolic-ref -q --short HEAD || echo "${GITHUB_REF_NAME:-detached}")
    [[ -z $(git status --porcelain -- . ':!Package.resolved' ':!release.yaml' 2>/dev/null) ]] || commit+="+dirty"
fi
for pair in "LoupeBuildCommit=$commit" "LoupeBuildBranch=$branch" "LoupeBuildDate=$(date '+%Y-%m-%d %H:%M %z')" \
    "LoupeBuildLabel=$label"; do
    plutil -replace "${pair%%=*}" -string "${pair#*=}" "$app/Contents/Info.plist"
done
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
# Signed with the local identity "Local Code Signing" (login keychain) when present: the designated requirement is then
# the bundle ID and the certificate, the same for every build, so TCC grants (network volumes, Accessibility) survive
# rebuilds; ad hoc it is the build's own hash, and every new build must be allowed again.
if security find-identity -p codesigning | grep -q '"Local Code Signing"'; then
    codesign --force --sign "Local Code Signing" "$app"
else
    echo "warning: no \"Local Code Signing\" identity: signed ad hoc, TCC grants must be given again" >&2
    codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $app"
if [[ $install == 1 ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Loupe.app"
    cp -R "$app" "$HOME/Applications/"
    echo "Installed to ~/Applications/Loupe.app"
fi
