#!/bin/sh
# Test passes (docs/testing.md):
#   scripts/test.sh          everyday: every target except the Metal render tests (~5 s, parallel)
#   scripts/test.sh render   the everyday pass, then the render tests without the CPU-reference matrices
#                            (TestLevel.fullOnly), one at a time at low priority (~70 s on one core)
#   scripts/test.sh full     the everyday pass, then every render test, CPU-reference matrices included
#                            (LOUPE_FULL_TESTS=1), one at a time at low priority: before a merge and when the
#                            renderer, its shaders or ViewTransform change
# The render tests run serially: in parallel they keep every core at 100 % and cost ~5x the CPU time
# (424 s of CPU against 90 s for the same tests, docs/testing.md).
# Extra arguments go to every `swift test` call (e.g. --filter PanRubberTests). Repeated --filter options are OR-ed, so
# when the caller passes --filter, the render pass uses it instead of the default LoupeRenderTests filter: it narrows.
set -e
# lts/macos26: the tests run as x86_64, under Rosetta on Apple Silicon.
[ "$(uname -m)" = x86_64 ] || exec arch -x86_64 /bin/sh "$0" "$@"
cd "$(dirname "$0")/.."
. scripts/libjxl-env.sh
mode=core
case "$1" in
    core|render|full) mode=$1; shift ;;
esac
swift test --skip LoupeRenderTests "$@"
render_filter="--filter LoupeRenderTests"
for arg in "$@"; do
    case "$arg" in --filter|--filter=*) render_filter="" ;; esac
done
case "$mode" in
    render) nice -n 15 swift test --skip-build --no-parallel $render_filter "$@" ;;
    full) LOUPE_FULL_TESTS=1 nice -n 15 swift test --skip-build --no-parallel $render_filter "$@" ;;
esac
