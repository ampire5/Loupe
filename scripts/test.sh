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
cd "$(dirname "$0")/.."
. scripts/libjxl-env.sh
# lts/macos26: the tests are x86_64 ($LTS_TRIPLE). On Apple Silicon they are cross-built natively and only run under
# Rosetta (the compiler under Rosetta took most of CI's time); on an Intel Mac `swift test` builds them as usual.
if [ "$(uname -m)" = x86_64 ]; then
    run="" build=""
else
    swift build --build-tests --triple "$LTS_TRIPLE"
    run="arch -x86_64" build="--skip-build"
fi
mode=core
case "$1" in
    core|render|full) mode=$1; shift ;;
esac
$run swift test $build --triple "$LTS_TRIPLE" --skip LoupeRenderTests "$@"
render_filter="--filter LoupeRenderTests"
for arg in "$@"; do
    case "$arg" in --filter|--filter=*) render_filter="" ;; esac
done
case "$mode" in
    render) nice -n 15 $run swift test --skip-build --triple "$LTS_TRIPLE" --no-parallel $render_filter "$@" ;;
    full) LOUPE_FULL_TESTS=1 nice -n 15 $run swift test --skip-build --triple "$LTS_TRIPLE" --no-parallel $render_filter "$@" ;;
esac
