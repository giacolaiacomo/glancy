import Foundation
import Testing
@testable import GlancyKit

// In-app updates (Sparkle 2): when Glancy checks (launch, panel open at most once a day, the
// switch), the found-update state, the command bar entries, the strings, the build numbers and
// the appcast script. Sparkle itself never starts here: the test runner is not a Glancy.app.

private func defaults() -> (UserDefaults, () -> Void) {
    let suite = "ai.glancy.tests.updates.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    return (d, { d.removePersistentDomain(forName: suite) })
}

@MainActor
private final class FakeDriver: UpdateDriver {
    var background = 0
    var user = 0
    func checkInBackground() { background += 1 }
    func checkNow() { user += 1 }
}

/// A clock the test moves by hand.
private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(hours: Double) { now = now.addingTimeInterval(hours * 3600) }
}

@MainActor
private func makeUpdates(_ d: UserDefaults, clock: Clock, supported: Bool = true) -> (AppUpdates, () -> FakeDriver?) {
    var made: FakeDriver?
    let updates = AppUpdates(defaults: d, now: { clock.now }, supported: supported) { _ in
        let f = FakeDriver()
        made = f
        return f
    }
    return (updates, { made })
}

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func run(_ script: String, _ args: [String], env: [String: String] = [:]) throws -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [root.appendingPathComponent(script).path] + args
    p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

@Suite("Update schedule")
@MainActor
struct UpdateScheduleTests {
    @Test func launchChecksOnceWhenOn() {
        let (d, done) = defaults(); defer { done() }
        let clock = Clock()
        let (updates, driver) = makeUpdates(d, clock: clock)
        #expect(updates.automatic)                       // on by default
        #expect(driver() == nil)                         // Sparkle is not built before the first check
        updates.appLaunched()
        #expect(driver()?.background == 1)
        #expect(updates.checks == ["launch"])
        #expect(updates.lastCheck == clock.now)
    }

    @Test func panelOpenWaitsADay() {
        let (d, done) = defaults(); defer { done() }
        let clock = Clock()
        let (updates, driver) = makeUpdates(d, clock: clock)
        updates.appLaunched()
        clock.advance(hours: 1)
        updates.panelOpened()
        clock.advance(hours: 22.9)
        updates.panelOpened()
        #expect(driver()?.background == 1)               // < 24 h since the launch check
        clock.advance(hours: 0.2)
        updates.panelOpened()
        #expect(driver()?.background == 2)
        updates.panelOpened()
        #expect(driver()?.background == 2)               // and the clock restarts from there
        #expect(updates.checks == ["launch", "panel"])
    }

    @Test func firstPanelOpenChecksWhenNeverChecked() {
        let (d, done) = defaults(); defer { done() }
        let (updates, driver) = makeUpdates(d, clock: Clock())
        updates.panelOpened()
        #expect(driver()?.background == 1)
    }

    @Test func lastCheckSurvivesARelaunch() {
        let (d, done) = defaults(); defer { done() }
        let clock = Clock()
        let (first, _) = makeUpdates(d, clock: clock)
        first.appLaunched()
        clock.advance(hours: 2)
        let (second, driver) = makeUpdates(d, clock: clock)
        second.panelOpened()
        #expect(driver() == nil)                         // persisted: no check, no Sparkle
        #expect(second.lastCheck != nil)
    }

    @Test func clockMovedBackChecks() {
        let (d, done) = defaults(); defer { done() }
        let clock = Clock()
        let (updates, driver) = makeUpdates(d, clock: clock)
        updates.appLaunched()
        clock.advance(hours: -5)
        updates.panelOpened()
        #expect(driver()?.background == 2)
    }

    @Test func switchOffMeansNoChecks() {
        let (d, done) = defaults(); defer { done() }
        let clock = Clock()
        let (updates, driver) = makeUpdates(d, clock: clock)
        updates.automatic = false
        updates.appLaunched()
        clock.advance(hours: 48)
        updates.panelOpened()
        #expect(driver() == nil)                         // never built
        #expect(updates.checks.isEmpty)
        // Persisted for the next launch.
        let (again, _) = makeUpdates(d, clock: clock)
        #expect(!again.automatic)
        // "Check now" still works, with Sparkle's window.
        updates.checkNow()
        #expect(driver()?.user == 1)
        #expect(driver()?.background == 0)
    }

    @Test func unsupportedCopyNeverBuildsSparkle() {
        let (d, done) = defaults(); defer { done() }
        let (updates, driver) = makeUpdates(d, clock: Clock(), supported: false)
        updates.appLaunched()
        updates.panelOpened()
        updates.checkNow()
        #expect(driver() == nil)
        #expect(updates.checks.isEmpty)
        #expect(updates.lastCheck == nil)
    }

    @Test func foundUpdateUntilTheSessionEnds() {
        let (d, done) = defaults(); defer { done() }
        let (updates, driver) = makeUpdates(d, clock: Clock())
        updates.appLaunched()
        #expect(updates.available == nil)
        updates.found("0.3.0")
        #expect(updates.available == "0.3.0")
        updates.install()                                // the dot / "Update to": Sparkle's window
        #expect(driver()?.user == 1)
        updates.sessionFinished()
        #expect(updates.available == nil)
    }

    /// The test runner is not a Glancy.app: Sparkle never starts in tests, the renderer or a dev
    /// build. The unattended test driver is refused for the real bundle id.
    @Test func sparkleOnlyInsideTheApp() {
        #expect(!SparkleDriver.usable(bundle: .main))
        #expect(SparkleDriver.releaseBundleID == "ai.glancy.app")
    }
}

@Suite("Update commands and strings")
@MainActor
struct UpdateCommandTests {
    @Test func commandBarOffersCheckAndInstall() {
        let (d, done) = defaults(); defer { done() }
        let (updates, driver) = makeUpdates(d, clock: Clock())
        var items = BuiltinCommands.updateItems(tag: "Glancy", updates: updates)
        #expect(items.map(\.id) == ["glancy.updates.check"])
        items[0].run?()
        #expect(driver()?.user == 1)
        updates.found("0.3.0")
        items = BuiltinCommands.updateItems(tag: "Glancy", updates: updates)
        #expect(items.map(\.id) == ["glancy.updates.check", "glancy.updates.install"])
        #expect(items[1].rank >= 50)                     // suggested on an empty bar
        #expect(items[1].title.contains("0.3.0"))
        #expect(BuiltinCommands.updateItems(tag: "Glancy", updates: nil).isEmpty)
        let (other, _) = makeUpdates(d, clock: Clock(), supported: false)
        #expect(BuiltinCommands.updateItems(tag: "Glancy", updates: other).isEmpty)
    }

    /// Every string the update code shows has an Italian line with the same placeholders.
    @Test func everyStringIsTranslated() throws {
        let folder = root.appendingPathComponent("Sources/GlancyKit/Updates")
        var used = Set<String>()
        let literal = /L10n\.tr\("((?:[^"\\]|\\.)*)"/
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for m in text.matches(of: literal) { used.insert(String(m.1)) }
        }
        // Strings shown from other folders (the command bar; the version on Settings → About).
        for s in ["Check for Updates", "Install Update %@", "Version %@"] { used.insert(s) }
        #expect(used.count >= 10)
        for s in used {
            let it = try #require(UpdatesText.italian[s], "no Italian for \(s)")
            #expect(it.components(separatedBy: "%@").count == s.components(separatedBy: "%@").count, "\(s)")
        }
        #expect(Set(UpdatesText.italian.keys) == used, "unused Italian strings")
    }
}

@Suite("Release numbering and appcast")
struct ReleaseScriptTests {
    @Test func buildNumberGrowsWithTheVersion() throws {
        let versions = ["0.2.2", "0.2.9", "0.2.10", "0.2.90", "0.2.91", "0.3.0", "0.10.0", "1.0.0", "1.0.1", "2.0"]
        let numbers = try versions.map { v -> Int in
            let r = try run("scripts/build-number.sh", [v])
            #expect(r.status == 0)
            return try #require(Int(r.out))
        }
        #expect(numbers == numbers.sorted() && Set(numbers).count == numbers.count)
        #expect(numbers[0] == 2002 && numbers[5] == 3000)
        #expect(numbers[0] > 51)                         // above every commit-count build before 0.3
        #expect(try run("scripts/build-number.sh", ["0.3"]).out == "3000")
        #expect(try run("scripts/build-number.sh", ["v0.3.0"]).status == 2)
        #expect(try run("scripts/build-number.sh", ["0.1000.0"]).status == 2)
    }

    @Test func buildScriptWiresSparkle() throws {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        // Glancy schedules its own checks; Sparkle's scheduler stays off.
        #expect(script.contains("<key>SUEnableAutomaticChecks</key><false/>"))
        #expect(script.contains("<key>SUFeedURL</key><string>$FEED_URL</string>"))
        #expect(script.contains("releases/latest/download/appcast.xml"))
        #expect(script.contains("<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>"))
        #expect(script.contains("CFBundleVersion</key><string>$BUILD_NUMBER"))
        #expect(script.contains("scripts/build-number.sh"))
        // make-dmg.sh reads the default version from this line.
        #expect(script.contains("VERSION=\"${GLANCY_VERSION:-"))
    }

    @Test func appcastPointsAtTheRelease() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-appcast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = dir.appendingPathComponent("Glancy-0.3.0.dmg")
        try Data("dmg".utf8).write(to: dmg)
        let out = dir.appendingPathComponent("appcast.xml")
        let sig = "sparkle:edSignature=\"c2lnbmF0dXJl\" length=\"3\""
        let r = try run("scripts/make-appcast.sh", [dmg.path, "0.3.0", out.path], env: ["GLANCY_APPCAST_SIGNATURE": sig])
        #expect(r.status == 0, "\(r.out)")
        let doc = try XMLDocument(contentsOf: out)
        func value(_ path: String) throws -> String? { try doc.nodes(forXPath: path).first?.stringValue }
        #expect(try value("/rss/channel/item/sparkle:version") == "3000")
        #expect(try value("/rss/channel/item/sparkle:shortVersionString") == "0.3.0")
        #expect(try value("/rss/channel/item/sparkle:minimumSystemVersion") == "14.0")
        #expect(try value("/rss/channel/item/sparkle:releaseNotesLink") == "https://github.com/giacolaiacomo/glancy/releases/tag/v0.3.0")
        #expect(try value("/rss/channel/item/enclosure/@url")
                == "https://github.com/giacolaiacomo/glancy/releases/download/v0.3.0/Glancy-0.3.0.dmg")
        #expect(try value("/rss/channel/item/enclosure/@sparkle:edSignature") == "c2lnbmF0dXJl")
        #expect(try value("/rss/channel/item/enclosure/@length") == "3")
        // Something that isn't sign_update's output stops the release.
        let bad = try run("scripts/make-appcast.sh", [dmg.path, "0.3.0", out.path], env: ["GLANCY_APPCAST_SIGNATURE": "oops"])
        #expect(bad.status != 0)
    }
}
