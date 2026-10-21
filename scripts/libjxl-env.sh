# Sourced by the build scripts (test.sh, make-app.sh) from the package root. Loupe builds for scripts/deps.arch
# ($DEPS_TRIPLE): arm64 on main, x86_64 on lts/macos26, natively or as a cross build (test.sh then runs the tests under
# Rosetta). It links its decoders statically, Loupe's own libjxl among them: scripts/deps.sh downloads the prebuilt
# ones into .deps/<arch> (or $LOUPE_DEPS) the first time, or builds them (scripts/build-deps.sh). Their pkg-config
# files come ahead of Homebrew's, so the CJXL, CTurboJPEG and CHeif modules (Package.swift, unchanged) find them;
# Homebrew's libjxl lacks JxlDecoderGetDCImage.
DEPS_ARCH=$(cat scripts/deps.arch)
DEPS_TRIPLE=$DEPS_ARCH-apple-macosx26.0
export DEPS_ARCH DEPS_TRIPLE
export LOUPE_DEPS="${LOUPE_DEPS:-$PWD/.deps/$DEPS_ARCH}"
export PKG_CONFIG_PATH="$LOUPE_DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
scripts/deps.sh fetch
