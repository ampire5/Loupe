#!/usr/bin/env bash
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
# On screen: build errors, the failing expectations as they happen and a summary of each pass's failed tests; the
# whole output is in .build/test.log (scripts/test-report.sh). TEST_VERBOSE=1 shows everything, as CI does.
set -e
cd "$(dirname "$0")/.."
. scripts/libjxl-env.sh
. scripts/test-report.sh
# The tests are built for $DEPS_ARCH ($DEPS_TRIPLE, scripts/libjxl-env.sh). For the Mac's own architecture `swift test` runs them as
# usual. For x86_64 on Apple Silicon (`DEPS_ARCH=x86_64`, CI's x86_64 job) they are cross-built natively and only the test bundle runs
# under Rosetta, through SwiftPM's own swift-testing helper: the compiler under Rosetta took most of CI's time, and
# `swift test` itself under Rosetta spent minutes compiling the manifests again. Arguments go to the testing library
# (`--filter`, `--skip`, `--no-parallel`).
mode=core
case "${1:-}" in
    core|render|full) mode=$1; shift ;;
esac
nice=()
report_build "Loupe (build)" swift build --build-tests --triple "$DEPS_TRIPLE"
if [[ $(uname -m) == "$DEPS_ARCH" ]]; then
    tests() { "${nice[@]}" swift test --skip-build --triple "$DEPS_TRIPLE" "$@"; }
else
    helper=$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper
    bundle=$(swift build --triple "$DEPS_TRIPLE" --show-bin-path)/LoupePackageTests.xctest/Contents/MacOS/LoupePackageTests
    if [[ -x "$helper" && -f "$bundle" ]]; then
        # The bundle finds swift-testing where swift test would point it; DYLD_* goes through arch's -e, as
        # /usr/bin/arch drops it from its own environment.
        platform=$(xcrun --show-sdk-platform-path)/Developer
        tests() {
            "${nice[@]}" arch "-$DEPS_ARCH" -e DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" \
                -e DYLD_LIBRARY_PATH="$platform/usr/lib" "$helper" --test-bundle-path "$bundle" \
                --testing-library swift-testing "$@"
        }
    else
        tests() { "${nice[@]}" arch "-$DEPS_ARCH" swift test --skip-build --triple "$DEPS_TRIPLE" "$@"; }
    fi
fi
# Every pass runs, a failed one too; the script fails if any did.
status=0
report_tests "Loupe core" tests --skip LoupeRenderTests "$@" || status=1
render_filter=(--filter LoupeRenderTests)
for arg in "$@"; do
    case "$arg" in --filter|--filter=*) render_filter=() ;; esac
done
nice=(nice -n 15)
case "$mode" in
    render) report_tests "Loupe render" tests --no-parallel "${render_filter[@]}" "$@" || status=1 ;;
    full) export LOUPE_FULL_TESTS=1; report_tests "Loupe render (full)" tests --no-parallel "${render_filter[@]}" "$@" || status=1 ;;
esac
exit $status
