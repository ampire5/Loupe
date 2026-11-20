#!/usr/bin/env bash
# libjxl with Loupe's DC preview patch is built with the other decoders, static, for
# $DEPS_ARCH: scripts/build-deps.sh, through scripts/deps.sh (prebuilt when published).
exec "$(dirname "$0")/deps.sh" fetch
