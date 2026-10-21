# Sourced by the build scripts (test.sh, make-app.sh) from the package root. On lts/macos26 (LTS_POLICY.md) Loupe is
# x86_64 and links its decoders statically, Loupe's own libjxl among them: scripts/build-deps.sh builds them into
# .deps/x86_64 (or $LOUPE_DEPS) the first time. Their pkg-config files come ahead of Homebrew's, so the CJXL,
# CTurboJPEG and CHeif modules (Package.swift, unchanged) find them; Homebrew's libjxl lacks JxlDecoderGetDCImage.
export LOUPE_DEPS="${LOUPE_DEPS:-$PWD/.deps/x86_64}"
export PKG_CONFIG_PATH="$LOUPE_DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
[ -f "$LOUPE_DEPS/.stamp" ] || scripts/build-deps.sh
