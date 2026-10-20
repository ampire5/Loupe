# Sourced by the build scripts (test.sh, make-app.sh) from the package root: Loupe links its own libjxl, a clone on
# branch `loupe` next to this checkout (../libjxl, or $LOUPE_LIBJXL) built into its dist/ by scripts/build-libjxl.sh. Its pkg-config files come ahead of Homebrew's, so the
# CJXL module (Package.swift, unchanged) finds it; Homebrew's libjxl lacks JxlDecoderGetDCImage and fails the build.
export LOUPE_LIBJXL="${LOUPE_LIBJXL:-$(cd "$PWD/.." && pwd)/libjxl}"
export PKG_CONFIG_PATH="$LOUPE_LIBJXL/dist/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
