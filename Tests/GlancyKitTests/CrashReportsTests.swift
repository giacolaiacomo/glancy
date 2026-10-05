import Foundation
import Testing
@testable import GlancyKit

// Crash capture (App/CrashReports.swift) on synthetic `.ips` reports shaped like macOS 26's.

private func tempDir(_ tag: String) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("glancy-crash-\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A report like the ones of 2026-10-05: the IOBluetooth coordinator queue trapping in a Glancy
/// @objc method; `line` adds a source line to the Glancy frame, `asi` a Swift fatal error text.
private func report(build: String = "24", queue: String = "com.apple.bluetooth.iobluetooth.coordinatorQueue",
                    symbol: String = "@objc BluetoothWatcher.didConnect(_:device:)", line: Int? = nil, asi: String? = nil) -> Data {
    let header: [String: Any] = ["app_name": "Glancy", "app_version": "0.1.0", "build_version": build, "bug_type": "309",
                                 "timestamp": "2026-10-05 16:47:35.00 +0200", "os_version": "macOS 26.6.2 (25G83)", "name": "Glancy"]
    var glancyFrame: [String: Any] = ["imageIndex": 2, "imageOffset": 4096, "symbol": symbol, "sourceFile": "BluetoothSources.swift"]
    if let line { glancyFrame["sourceLine"] = line }
    var body: [String: Any] = [
        "procName": "Glancy",
        "exception": ["type": "EXC_BREAKPOINT", "signal": "SIGTRAP", "codes": "0x1"],
        "termination": ["indicator": "Trace/BPT trap: 5", "namespace": "SIGNAL"],
        "faultingThread": 1,
        "usedImages": [["name": "libdispatch.dylib"], ["name": "libswift_Concurrency.dylib"], ["name": "Glancy"], ["name": "IOBluetooth"]],
        "threads": [
            ["id": 1, "frames": [["imageIndex": 0, "imageOffset": 1, "symbol": "mach_msg2_trap"]]],
            ["id": 2, "triggered": true, "queue": queue, "frames": [
                ["imageIndex": 0, "imageOffset": 10, "symbol": "_dispatch_assert_queue_fail"],
                ["imageIndex": 1, "imageOffset": 20, "symbol": "_swift_task_checkIsolatedSwift"],
                glancyFrame,
                ["imageIndex": 2, "imageOffset": 8192, "symbol": "thunk for @escaping", "sourceFile": "/<compiler-generated>"],
                ["imageIndex": 3, "imageOffset": 30, "symbol": "-[IOBluetoothConcreteUserNotification objcNotificationRoutine:]"],
            ]],
        ],
    ]
    if let asi { body["asi"] = ["libswiftCore.dylib": [asi]] }
    let h = try! JSONSerialization.data(withJSONObject: header)
    let b = try! JSONSerialization.data(withJSONObject: body)
    return h + Data("\n".utf8) + b
}

private func write(_ data: Data, _ name: String, in dir: URL, at date: Date) {
    let url = dir.appendingPathComponent(name)
    try? data.write(to: url)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

@Suite("Crash reports")
struct CrashReportsTests {
    @Test func parsesTheFaultingThreadAndGlancysFrames() throws {
        let s = try #require(CrashReports.parse(report(line: 118), report: "Glancy-2026-10-05-164735.ips"))
        #expect(s.version == "0.1.0 (24)")
        #expect(s.exception == "EXC_BREAKPOINT (SIGTRAP)")
        #expect(s.termination == "Trace/BPT trap: 5")
        #expect(s.thread == "thread 1 · com.apple.bluetooth.iobluetooth.coordinatorQueue")
        #expect(s.appFrames == ["@objc BluetoothWatcher.didConnect(_:device:) (BluetoothSources.swift:118)", "thunk for @escaping"])
        #expect(s.topFrames.first == "libdispatch.dylib  _dispatch_assert_queue_fail")
        #expect(s.cause?.contains("another thread") == true)
        #expect(s.message == nil)
        #expect(s.text.contains("report: ~/Library/Logs/DiagnosticReports/Glancy-2026-10-05-164735.ips"))
    }

    @Test func keepsASwiftFatalErrorMessage() throws {
        let s = try #require(CrashReports.parse(report(queue: "com.apple.main-thread", symbol: "PowerModule.add(_:)",
                                                       asi: "Fatal error: Duplicate values for key: 'a'"), report: "x.ips"))
        #expect(s.message == "Fatal error: Duplicate values for key: 'a'")
        #expect(s.text.contains("message: Fatal error: Duplicate values for key: 'a'"))
    }

    @Test func notAReportIsNil() {
        #expect(CrashReports.parse(Data("hello".utf8), report: "x.ips") == nil)
        #expect(CrashReports.parse(Data("{}\nnot json".utf8), report: "x.ips") == nil)
        #expect(CrashReports.summaryName(for: "Glancy-2026-10-06-001206.ips") == "2026-10-06-001206.txt")
        #expect(!CrashReports.isReport("Glancy_2026-10-06-001206.hang") && !CrashReports.isReport("Other-1.ips"))
    }

    /// First launch: old reports are summarised but not announced. Then each new crash is
    /// announced once, at the next launch only.
    @Test func announcesEachCrashOnce() throws {
        let reports = tempDir("reports"), out = tempDir("out")
        let defaults = try #require(UserDefaults(suiteName: "glancy.test.crashes.\(UUID().uuidString)"))
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        write(report(build: "2"), "Glancy-2026-10-05-173945.ips", in: reports, at: t0)
        write(Data("garbage".utf8), "Glancy-2026-10-05-180000.ips", in: reports, at: t0)
        write(report(), "Other-2026-10-05-173945.ips", in: reports, at: t0)

        #expect(CrashReports.check(defaults: defaults, reports: reports, out: out).isEmpty)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("2026-10-05-173945.txt").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("2026-10-05-180000.txt").path))
        #expect(CrashReports.check(defaults: defaults, reports: reports, out: out).isEmpty)

        write(report(build: "3"), "Glancy-2026-10-05-193842.ips", in: reports, at: t0.addingTimeInterval(60))
        let fresh = CrashReports.check(defaults: defaults, reports: reports, out: out)
        #expect(fresh.map(\.lastPathComponent) == ["2026-10-05-193842.txt"])
        let text = try String(contentsOf: fresh[0], encoding: .utf8)
        #expect(text.hasPrefix("Glancy 0.1.0 (3) crashed"))
        #expect(CrashReports.check(defaults: defaults, reports: reports, out: out).isEmpty)
    }

    @Test func noReportsFolderIsQuiet() throws {
        let defaults = try #require(UserDefaults(suiteName: "glancy.test.crashes.\(UUID().uuidString)"))
        let missing = tempDir("none").appendingPathComponent("absent")
        #expect(CrashReports.check(defaults: defaults, reports: missing, out: tempDir("out")).isEmpty)
        #expect(defaults.object(forKey: CrashReports.lastSeenKey) is Date)
        #expect(CrashReports.printAll(reports: missing, out: tempDir("out2")).hasPrefix("No crash reports for Glancy"))
    }

    @Test func printAllListsNewestFirst() {
        let reports = tempDir("reports"), out = tempDir("out")
        write(report(build: "2"), "Glancy-2026-10-05-173945.ips", in: reports, at: .now)
        write(report(build: "24"), "Glancy-2026-10-06-001206.ips", in: reports, at: .now)
        let text = CrashReports.printAll(reports: reports, out: out)
        #expect(text.hasPrefix("2 crashes"))
        let newer = text.range(of: "── 2026-10-06-001206.txt"), older = text.range(of: "── 2026-10-05-173945.txt")
        #expect(newer != nil && older != nil && newer!.lowerBound < older!.lowerBound)
    }

    @Test func peekIsLocalised() {
        let it = CrashReports.italian
        #expect(it["Glancy quit unexpectedly"] == "Glancy si è chiuso inaspettatamente")
        #expect(it["Glancy quit unexpectedly (%d times)"].map { String(format: $0, 3) } == "Glancy si è chiuso inaspettatamente (3 volte)")
        #expect(it["Details"] == "Dettagli")
        #expect(it["Show the crash summary in Finder"] != nil)
    }
}
