import Foundation
import os

/// How JPEG XL is decoded (`jxl-*` keys): libjxl threads by role and whether the 1:8 DC image serves first looks,
/// coarse previews and thumbnails.
public struct JXLOptions: Equatable, Sendable {
    public var threadsCurrent: Int
    public var threadsOther: Int
    public var dcPreview: Bool

    public init(threadsCurrent: Int = Machine.jxlThreadsCurrent, threadsOther: Int = HardwareAdvice.defaultJXLThreadsOther(.current), dcPreview: Bool = true) {
        self.threadsCurrent = threadsCurrent
        self.threadsOther = threadsOther
        self.dcPreview = dcPreview
    }

    public init(config: Config) {
        self.init(threadsCurrent: config.jxlThreadsCurrent, threadsOther: config.jxlThreadsOther,
                  dcPreview: config.jxlDCPreview)
    }
}

/// The process's `JXLOptions`, set at launch and on every config reload; `DecoderRegistry` reads it for each decoder
/// it makes, so a reload reaches the next decode.
public final class JXLSetting: Sendable {
    public static let shared = JXLSetting()

    private let lock = OSAllocatedUnfairLock(initialState: JXLOptions())

    public var options: JXLOptions {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
