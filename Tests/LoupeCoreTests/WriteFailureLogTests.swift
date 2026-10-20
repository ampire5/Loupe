import Testing
import Foundation
@testable import LoupeCore

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
    var value: [String] { lock.withLock { all } }
}

@Test func writeFailureIsLoggedOnceUntilALaterWriteSucceeds() {
    let lines = Lines()
    let log = WriteFailureLog { lines.add($0) }
    struct Boom: Error {}
    log.failed(Boom()); log.failed(Boom())
    #expect(lines.value.count == 1 && lines.value[0].hasPrefix("loupe: could not save folder state to Loupe.db: "))
    log.succeeded()
    log.failed(Boom())
    #expect(lines.value.count == 2)
}
