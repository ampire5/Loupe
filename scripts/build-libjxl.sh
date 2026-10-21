#!/usr/bin/env bash
# Loupe's libjxl (github.com/ampire5/libjxl, branch `loupe`) is built with the other decoders, static, for
# scripts/deps.arch: scripts/build-deps.sh, through scripts/deps.sh (prebuilt when published).
exec "$(dirname "$0")/deps.sh" fetch
