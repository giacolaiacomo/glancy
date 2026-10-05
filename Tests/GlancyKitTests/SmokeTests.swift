import Testing
@testable import GlancyKit

@MainActor @Test func hubPicksHighestPriority() {
    let hub = ActivityHub()
    hub.post(LiveActivity(id: "a", module: .media, priority: 30, left: .init(EmptyViewBox()), right: .init(EmptyViewBox())))
    hub.post(LiveActivity(id: "b", module: .agents, priority: 90, left: .init(EmptyViewBox()), right: .init(EmptyViewBox())))
    #expect(hub.top?.id == "b")
    hub.clear("b")
    #expect(hub.top?.id == "a")
}

import SwiftUI
struct EmptyViewBox: View { var body: some View { EmptyView() } }

@Suite("Legacy migration")
struct LegacyMigrationTests {
    @Test func movesOldDataIntoAnExistingNewFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("glancy-mig-\(UUID().uuidString)")
        let old = root.appendingPathComponent("Lunetta"), new = root.appendingPathComponent("Glancy")
        try fm.createDirectory(at: old.appendingPathComponent("clipboard"), withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: old.appendingPathComponent("shelf.json"))
        try Data("old".utf8).write(to: old.appendingPathComponent("tiling.json"))
        try Data("new".utf8).write(to: new.appendingPathComponent("tiling.json"))
        try Data().write(to: old.appendingPathComponent("lunetta.lock"))
        LegacyMigration.moveContents(of: old, into: new)
        #expect(fm.fileExists(atPath: new.appendingPathComponent("clipboard").path))
        #expect(fm.fileExists(atPath: new.appendingPathComponent("shelf.json").path))
        #expect(try String(contentsOf: new.appendingPathComponent("tiling.json"), encoding: .utf8) == "new")
        #expect(fm.fileExists(atPath: old.path))          // tiling.json could not move: old kept
        try? fm.removeItem(at: root)
    }
}
