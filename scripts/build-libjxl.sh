#!/usr/bin/env bash
# On lts/macos26 Loupe's libjxl (github.com/ampire5/libjxl, branch `loupe`) is built with the other decoders, x86_64
# and static: scripts/build-deps.sh.
exec "$(dirname "$0")/build-deps.sh" "$@"
