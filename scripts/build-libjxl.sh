#!/usr/bin/env bash
# On lts/macos26 Loupe's libjxl (github.com/ampire5/libjxl, branch `loupe`) is built with the other decoders, x86_64
# and static: scripts/build-deps.sh, through scripts/deps.sh (prebuilt when published).
exec "$(dirname "$0")/deps.sh" fetch
