import Foundation
import LoupeCore
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

    /// Logs what the rest of this turn of the main run loop costs, its layout and Core Animation commit included
    /// (`turn <label>: N ms CPU, M ms wall`): a one-shot observer after the commit's, as the run loop goes to wait.
    static func measureTurn(_ label: String) {
        guard isEnabled else { return }
        let cpu = ThreadCPU.milliseconds(), wall = CACurrentMediaTime()
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            log(String(format: "turn %@: %.1f ms CPU, %.1f ms wall", label, ThreadCPU.milliseconds() - cpu,
                       (CACurrentMediaTime() - wall) * 1000))
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
