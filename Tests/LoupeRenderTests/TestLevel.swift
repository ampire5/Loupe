import Foundation
import Testing

/// Render tests whose CPU reference (Core Graphics or a CPU resampler over every pixel of every case) costs tens of
/// seconds of CPU on all cores run only in the full pass, `scripts/test.sh full` (`LOUPE_FULL_TESTS=1`): before a
/// merge and when the renderer, its shaders or `ViewTransform` change. The everyday pass keeps every other render
/// test, so each path is still drawn and checked against cheaper expectations.
enum TestLevel {
    static let full = ProcessInfo.processInfo.environment["LOUPE_FULL_TESTS"] == "1"
    static let fullOnly = ConditionTrait.enabled(if: full, "CPU-reference matrix: LOUPE_FULL_TESTS=1 (scripts/test.sh full)")
}
