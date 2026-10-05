import Foundation

/// Glancy was called Lunetta until 2026-10-05. On the first launch under the new name, carry the
/// old preferences and data over, once: the defaults domain and the Application Support folder.
/// The welcome checklist is shown again, because macOS treats the renamed app as a new one and its
/// permissions (Accessibility, Calendar, Bluetooth…) have to be granted again.
enum LegacyMigration {
    static let oldDomain = "ai.lunetta.app"
    static let oldFolder = "Lunetta"
    private static let doneKey = "migratedFromLunetta"

    static func run(defaults: UserDefaults = .standard, fileManager fm: FileManager = .default) {
        if !defaults.bool(forKey: doneKey) {
            if let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty {
                for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
                defaults.removeObject(forKey: "onboardingShown")
            }
            defaults.set(true, forKey: doneKey)
        }
        // Files: item by item (the new folder may already exist), then the old folder goes.
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        moveContents(of: support.appendingPathComponent(oldFolder, isDirectory: true),
                     into: support.appendingPathComponent("Glancy", isDirectory: true), fileManager: fm)
    }

    static func moveContents(of from: URL, into to: URL, fileManager fm: FileManager = .default) {
        guard let items = try? fm.contentsOfDirectory(atPath: from.path) else { return }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in items where !name.hasSuffix(".lock") && !name.hasSuffix(".pid") {
            let dest = to.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: from.appendingPathComponent(name), to: dest) }
        }
        let left = (try? fm.contentsOfDirectory(atPath: from.path)) ?? []
        if left.allSatisfy({ $0.hasSuffix(".lock") || $0.hasSuffix(".pid") || $0 == ".DS_Store" }) {
            try? fm.removeItem(at: from)
        }
    }
}
