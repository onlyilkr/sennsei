import Foundation
import HeadsetCore
import Testing

@testable import SennseiCore

@Test func defaultsHaveThreeScenesWithoutTriggers() {
    let d = Scene.defaults
    #expect(d.map(\.id) == ["focus", "meeting", "travel"])
    #expect(d.allSatisfy { $0.triggers.isEmpty })
    #expect(d[0].noiseMode == .anc); #expect(d[0].eqPreset == "Flat")
    #expect(d[1].noiseMode == .transparency); #expect(d[1].pauseInTransparency == false)
    #expect(d[2].eqPreset == "Rock")
}
@Test func roundTripsThroughJSON() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scenes-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SceneStore(url: url)
    var s = Scene.defaults; s[0].triggers = [.frontApp(bundleID: "com.apple.dt.Xcode")]
    try store.save(s)
    let r = store.load()
    #expect(r.scenes == s); #expect(r.usedDefaults == false); #expect(r.fileWasCorrupt == false)
}
@Test func missingFileGivesDefaultsWithoutCreatingTheFile() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID()).json")
    let r = SceneStore(url: url).load()
    #expect(r.scenes == Scene.defaults); #expect(r.usedDefaults); #expect(r.fileWasCorrupt == false)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}
@Test func corruptFileGivesDefaultsAndIsLeftUntouched() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{ not json".utf8).write(to: url)
    let r = SceneStore(url: url).load()
    #expect(r.scenes == Scene.defaults); #expect(r.usedDefaults); #expect(r.fileWasCorrupt)
    #expect(try Data(contentsOf: url) == Data("{ not json".utf8))
}
@Test func unknownFieldsAndNewerTriggerKindsDoNotCrash() throws {
    // a future scene file: unknown field and unknown trigger kind
    let json = #"[{"id":"x","name":"X","noiseMode":"anc","extra":1,"triggers":[{"kind":"time"}]}]"#
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("future-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(json.utf8).write(to: url)
    let r = SceneStore(url: url).load()
    #expect(r.fileWasCorrupt == false)
    #expect(r.scenes.first?.id == "x"); #expect(r.scenes.first?.triggers.isEmpty == true)   // unknown trigger is skipped
}
@Test func saveCreatesTheDirectoryAndWritesAtomically() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("scenes.json")
    try SceneStore(url: url).save(Scene.defaults)
    #expect(SceneStore(url: url).load().scenes == Scene.defaults)
}
