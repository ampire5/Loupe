import Testing
import Foundation
@testable import LoupeCore

@Suite struct SingleInstanceTests {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func inst(_ pid: Int32, _ date: Date?) -> RunningInstance {
        RunningInstance(pid: pid, key: "app", launchDate: date)
    }
    private func inst(_ pid: Int32, _ key: String, _ date: Date?) -> RunningInstance {
        RunningInstance(pid: pid, key: key, launchDate: date)
    }

    @Test func noOtherInstanceMeansMeStays() {
        let me = inst(10, t0)
        #expect(SingleInstance.primary(over: me, among: []) == nil)
    }

    @Test func earlierLaunchIsPrimary() {
        let me = inst(10, t0)
        let other = inst(5, t0.addingTimeInterval(-10))
        #expect(SingleInstance.primary(over: me, among: [other]) == other)
    }

    @Test func laterLaunchLeavesMePrimary() {
        let me = inst(10, t0)
        #expect(SingleInstance.primary(over: me, among: [inst(5, t0.addingTimeInterval(10))]) == nil)
    }

    @Test func equalDatesFallToSmallerPid() {
        let me = inst(10, t0)
        let lower = inst(5, t0)
        #expect(SingleInstance.primary(over: me, among: [lower]) == lower)
        #expect(SingleInstance.primary(over: me, among: [inst(20, t0)]) == nil)
    }

    @Test func nilDateLosesAgainstDatedOne() {
        let dated = inst(50, t0)
        #expect(SingleInstance.primary(over: inst(10, nil), among: [dated]) == dated)
        #expect(SingleInstance.primary(over: dated, among: [inst(10, nil)]) == nil)
    }

    @Test func twoNilDatesFallToPid() {
        let lower = inst(5, nil)
        #expect(SingleInstance.primary(over: inst(10, nil), among: [lower]) == lower)
        #expect(SingleInstance.primary(over: inst(10, nil), among: [inst(20, nil)]) == nil)
    }

    @Test func differentKeysAreIgnored() {
        let me = inst(10, t0)
        #expect(SingleInstance.primary(over: me, among: [inst(5, "other", t0.addingTimeInterval(-10))]) == nil)
    }

    @Test func meInTheListIsIgnored() {
        let me = inst(10, t0)
        #expect(SingleInstance.primary(over: me, among: [me]) == nil)
        let earlier = inst(5, t0.addingTimeInterval(-1))
        #expect(SingleInstance.primary(over: me, among: [me, earlier]) == earlier)
    }

    @Test func pickingTheEarliestOfSeveral() {
        let me = inst(10, t0)
        let a = inst(3, t0.addingTimeInterval(-5)), b = inst(4, t0.addingTimeInterval(-9))
        #expect(SingleInstance.primary(over: me, among: [a, b]) == b)
    }
}
