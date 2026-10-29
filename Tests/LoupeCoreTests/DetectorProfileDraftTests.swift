import Foundation
import Testing
@testable import LoupeCore

private let profileText = "# private configuration\n[classes]\nCAT=cat\nDOG=dog\nBALL=ball\n\n[play]\nchain=cat,face\nsize=70% # keep\n\n[other]\nchain=dog\n"
@Test func createProfileKeepsOtherSectionsAndOrderedGroups() throws {
    var draft = DetectorProfileDraft(name: "My profile", chain: [SubjectKind(rawValue: "dog+ball")!, .face])
    draft.composition.weights[SubjectKind(rawValue: "dog")!] = 1.5
    let text = try draft.writing(in: profileText, creating: true)
    #expect(text.hasPrefix(profileText))
    let setup = DetectorSetup.parse(text).0
    let mode = try #require(setup.modes.first { $0.name == "my profile" })
    #expect(mode.chain.map(\.rawValue) == ["dog+ball", "face"])
    #expect(mode.composition.weights[SubjectKind(rawValue: "dog")!] == 1.5)
}
@Test func profileEditingPreservesCommentsAndRejectsUnsafeChanges() throws {
    let draft = DetectorProfileDraft(name: "play", chain: [.face])
    let edited = try draft.writing(in: profileText, creating: false)
    #expect(edited.contains("# keep") && edited.contains("[other]\nchain=dog"))
    #expect(throws: Error.self) { try draft.writing(in: profileText, creating: true) }
    #expect(throws: Error.self) { try DetectorProfileDraft(name: "bad\n[classes]", chain: [.face]).writing(in: profileText, creating: true) }
    #expect(throws: Error.self) { try DetectorProfileDraft(name: "empty", chain: []).writing(in: profileText, creating: true) }
    #expect(throws: Error.self) { try DetectorProfileDraft(name: "unknown", chain: [SubjectKind(rawValue: "unknown")!]).writing(in: profileText, creating: true) }
}
@Test func profileEditorRejectsDuplicateGroupsAndInvalidWeights() {
    let a = SubjectKind(rawValue: "dog+ball")!, b = SubjectKind(rawValue: "ball+dog")!
    #expect(throws: Error.self) { try DetectorProfileDraft(name: "duplicate", chain: [a,b]).writing(in: profileText, creating: true) }
    var draft = DetectorProfileDraft(name: "weight", chain: [.face]); draft.composition.weights[.face] = .nan
    #expect(throws: Error.self) { try draft.writing(in: profileText, creating: true) }
}

@Test func concurrentProfileWritesKeepBothProfiles() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("detector.conf")
    try profileText.write(to: file, atomically: true, encoding: .utf8)
    let a = DetectorProfileDraft(name: "one", chain: [.face])
    let b = DetectorProfileDraft(name: "two", chain: [.person])
    async let first = DetectorProfileFiles.edit(file) { try a.writing(in: $0, creating: true) }
    async let second = DetectorProfileFiles.edit(file) { try b.writing(in: $0, creating: true) }
    _ = try await (first, second)
    let setup = DetectorSetup.load(from: file).0
    #expect(Set(setup.modes.map(\.name)).isSuperset(of: ["one", "two", "play", "other"]))
}

@Test func editingCommentedAndSpacedHeadersDoesNotDuplicateProfiles() throws {
    for header in ["[play] # keep this caption", "[ play ]"] {
        let original = profileText.replacingOccurrences(of: "[play]", with: header)
        let edited = try DetectorProfileDraft(name: "play", chain: [.person]).writing(in: original, creating: false)
        let profiles = DetectorSetup.parse(edited).0.modes.filter { $0.name == "play" }
        #expect(profiles.count == 1 && profiles.first?.chain == [.person])
        #expect(edited.contains(header))
    }
}
