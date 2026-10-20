import Foundation
import QuartzCore

/// Load and frame events on stderr, only when the environment has `LOUPE_DEBUG` set
/// (`LOUPE_DEBUG=1 build/Loupe.app/Contents/MacOS/Loupe photo.jpg`). Silent by default so a
/// normal launch costs nothing; it exists to check the idle behaviour (no frames while nothing
/// changes) without a screen. Each line starts with `CACurrentMediaTime()`, the clock of the display
/// link's timestamps, so frame intervals and event timing can be read off the log.
enum DebugLog {
    static let isEnabled = ProcessInfo.processInfo.environment["LOUPE_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = String(format: "[loupe %.4f] ", CACurrentMediaTime()) + message() + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
