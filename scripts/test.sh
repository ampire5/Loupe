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
# lts/macos26: the tests are x86_64 ($LTS_TRIPLE). On an Intel Mac `swift test` builds and runs them as usual. On
# Apple Silicon they are cross-built natively and only the test bundle runs under Rosetta, through SwiftPM's own
# swift-testing helper: the compiler under Rosetta took most of CI's time, and `swift test` itself under Rosetta spent
# minutes compiling the manifests again. Arguments go to the testing library (`--filter`, `--skip`, `--no-parallel`).
mode=core
case "$1" in
    core|render|full) mode=$1; shift ;;
esac
NICE=""
if [ "$(uname -m)" = x86_64 ]; then
    swift build --build-tests --triple "$LTS_TRIPLE"
    tests() { $NICE swift test --skip-build --triple "$LTS_TRIPLE" "$@"; }
else
    swift build --build-tests --triple "$LTS_TRIPLE"
    helper=$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper
    bundle=$(swift build --triple "$LTS_TRIPLE" --show-bin-path)/LoupePackageTests.xctest
    if [ -x "$helper" ] && [ -d "$bundle" ]; then
        tests() { $NICE arch -x86_64 "$helper" --test-bundle-path "$bundle" --testing-library swift-testing "$@"; }
    else
        tests() { $NICE arch -x86_64 swift test --skip-build --triple "$LTS_TRIPLE" "$@"; }
    fi
fi
tests --skip LoupeRenderTests "$@"
render_filter="--filter LoupeRenderTests"
for arg in "$@"; do
    case "$arg" in --filter|--filter=*) render_filter="" ;; esac
done
NICE="nice -n 15"
case "$mode" in
    render) tests --no-parallel $render_filter "$@" ;;
    full) LOUPE_FULL_TESTS=1; export LOUPE_FULL_TESTS; tests --no-parallel $render_filter "$@" ;;
esac
