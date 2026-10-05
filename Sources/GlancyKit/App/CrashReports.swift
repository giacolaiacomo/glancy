import AppKit
import SwiftUI

/// Crash capture. macOS writes a report to `~/Library/Logs/DiagnosticReports/Glancy-<date>.ips`
/// when Glancy crashes; at the next launch Glancy reads the ones newer than the last it saw, keeps
/// a short summary (exception, faulting thread, Glancy's own frames with file:line) in
/// `~/Library/Application Support/Glancy/crashes/<date>.txt`, and shows one drop-down:
/// "Glancy quit unexpectedly · Details" (Details reveals the summary). Once per launch, off the
/// main thread, no polling. Reports are only read. `Glancy --crashes` prints every summary.
public enum CrashReports {
    nonisolated static let lastSeenKey = "glancy.crashes.lastSeen"
    nonisolated static let appName = "Glancy"
    /// ReportCrash writes the report a few seconds after the crash: a relaunch right away still
    /// finds it.
    nonisolated static let launchDelay: Duration = .seconds(6)

    public nonisolated static var reportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    public nonisolated static var summariesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glancy/crashes", isDirectory: true)
    }

    // MARK: Summary

    public struct Summary: Equatable, Sendable {
        public var report: String          // the .ips file name
        public var timestamp: String       // as the report states it
        public var version: String         // "0.1.0 (24)"
        public var os: String
        public var exception: String       // "EXC_BREAKPOINT (SIGTRAP)"
        public var termination: String?
        public var message: String?        // application-specific info (a Swift fatal error's text)
        public var thread: String          // "thread 12 · com.apple.bluetooth.iobluetooth.coordinatorQueue"
        public var topFrames: [String]     // the faulting thread's first frames, any image
        public var appFrames: [String]     // Glancy's own frames, "symbol (File.swift:42)"
        public var cause: String?

        public var text: String {
            var lines = ["Glancy \(version) crashed \(timestamp)", os, exception]
            if let termination { lines.append("termination: \(termination)") }
            if let cause { lines.append("likely cause: \(cause)") }
            if let message { lines.append("message: \(message)") }
            lines.append("")
            lines.append(thread)
            lines += topFrames.enumerated().map { "  \($0.offset)  \($0.element)" }
            lines.append("")
            lines.append("Glancy frames:")
            lines += appFrames.isEmpty ? ["  (none)"] : appFrames.map { "  \($0)" }
            lines.append("")
            lines.append("report: ~/Library/Logs/DiagnosticReports/\(report)")
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// An `.ips` crash report: one JSON header line, then the JSON body. nil when it isn't one.
    nonisolated static func parse(_ data: Data, report: String) -> Summary? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        else { return nil }
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let faulting = (body["faultingThread"] as? Int) ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? -1
        let thread = threads.indices.contains(faulting) ? threads[faulting] : [:]
        let frames = (thread["frames"] as? [[String: Any]]) ?? []
        let ownName = (body["procName"] as? String) ?? (header["app_name"] as? String) ?? appName

        func imageName(_ f: [String: Any]) -> String {
            guard let i = f["imageIndex"] as? Int, images.indices.contains(i) else { return "?" }
            return (images[i]["name"] as? String) ?? "?"
        }
        func describe(_ f: [String: Any]) -> String {
            var s = (f["symbol"] as? String) ?? "0x" + String((f["imageOffset"] as? Int) ?? 0, radix: 16)
            if let file = f["sourceFile"] as? String, !file.hasPrefix("/<") {
                let name = (file as NSString).lastPathComponent
                s += (f["sourceLine"] as? Int).map { " (\(name):\($0))" } ?? " (\(name))"
            }
            return s
        }

        let exception = body["exception"] as? [String: Any]
        var exceptionText = (exception?["type"] as? String) ?? "unknown exception"
        if let signal = exception?["signal"] as? String { exceptionText += " (\(signal))" }
        if let subtype = exception?["subtype"] as? String { exceptionText += " · \(subtype)" }
        let termination = (body["termination"] as? [String: Any])?["indicator"] as? String
        // `asi`: {"libswiftCore.dylib": ["Fatal error: …"]}
        let message = (body["asi"] as? [String: Any])?.values
            .flatMap { ($0 as? [String]) ?? [] }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let symbols = frames.compactMap { $0["symbol"] as? String }
        var cause: String?
        if symbols.contains(where: { $0.contains("checkIsolated") || $0.contains("dispatch_assert_queue") }) {
            cause = "main-actor code was called on another thread (a callback or @objc method that is not nonisolated/@Sendable)"
        } else if let message, message.contains("Fatal error") {
            cause = "a Swift runtime check failed (see message)"
        } else if exceptionText.hasPrefix("EXC_BAD_ACCESS") {
            cause = "bad memory access"
        }

        var threadText = "thread \(faulting)"
        if let q = thread["queue"] as? String { threadText += " · \(q)" } else if let n = thread["name"] as? String { threadText += " · \(n)" }
        let version = [header["app_version"] as? String, (header["build_version"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        return Summary(
            report: report,
            timestamp: (header["timestamp"] as? String) ?? (body["captureTime"] as? String) ?? "?",
            version: version.isEmpty ? "?" : version,
            os: (header["os_version"] as? String) ?? "?",
            exception: exceptionText,
            termination: termination,
            message: message?.isEmpty == false ? message : nil,
            thread: threadText,
            topFrames: frames.prefix(6).map { "\(imageName($0))  \(describe($0))" },
            appFrames: frames.filter { imageName($0) == ownName }.prefix(8).map(describe),
            cause: cause)
    }

    // MARK: Collecting

    /// The summary file for a report: "Glancy-2026-10-06-001206.ips" → "2026-10-06-001206.txt".
    nonisolated static func summaryName(for report: String) -> String {
        var base = (report as NSString).deletingPathExtension
        if base.hasPrefix(appName + "-") { base.removeFirst(appName.count + 1) }
        return base + ".txt"
    }

    nonisolated static func isReport(_ name: String) -> Bool { name.hasPrefix(appName + "-") && name.hasSuffix(".ips") }

    /// Summarises every report in `reports` that has no summary in `out` yet. Returns the summaries
    /// of the reports written after `since` (none when `since` is nil: a first run has nothing
    /// new to tell) and the newest report date seen. Off the main thread.
    nonisolated static func collect(reports: URL, out: URL, since: Date?) -> (fresh: [URL], newest: Date?) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: reports.path) else { return ([], nil) }
        var fresh: [(Date, URL)] = []
        var newest: Date?
        for name in names where isReport(name) {
            let url = reports.appendingPathComponent(name)
            guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            newest = max(newest ?? date, date)
            let summary = out.appendingPathComponent(summaryName(for: name))
            if !fm.fileExists(atPath: summary.path) {
                guard let data = try? Data(contentsOf: url), let s = parse(data, report: name) else { continue }
                try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                guard (try? Data(s.text.utf8).write(to: summary, options: .atomic)) != nil else { continue }
            }
            if let since, date > since { fresh.append((date, summary)) }
        }
        return (fresh.sorted { $0.0 < $1.0 }.map(\.1), newest)
    }

    /// One launch: what is new since the last one; remembers what it saw. Off the main thread.
    nonisolated static func check(defaults: UserDefaults, reports: URL = reportsDirectory, out: URL = summariesDirectory,
                                  now: Date = .now) -> [URL] {
        let since = defaults.object(forKey: lastSeenKey) as? Date
        let (fresh, newest) = collect(reports: reports, out: out, since: since)
        defaults.set(max(since ?? .distantPast, newest ?? now), forKey: lastSeenKey)
        return fresh
    }

    /// At launch (the app only): looks once, a few seconds in, and shows the drop-down if Glancy
    /// crashed since it last looked.
    @MainActor static func checkAtLaunch(hub: ActivityHub) {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: launchDelay)
            let fresh = check(defaults: .standard)
            guard let last = fresh.last else { return }
            await MainActor.run { show(hub: hub, summary: last, count: fresh.count) }
        }
    }

    /// Public for the renderer.
    @MainActor public static func show(hub: ActivityHub, summary: URL, count: Int) {
        L10n.addItalian(italian)
        hub.show(PeekEvent(module: .monitor, duration: 8, content: AnyView(CrashPeek(summary: summary, count: count))))
    }

    // MARK: --crashes

    /// `Glancy --crashes`: brings the summaries up to date (reports are only read), then prints
    /// them, newest first. Doesn't touch what the app has seen.
    public nonisolated static func printAll(reports: URL = reportsDirectory, out: URL = summariesDirectory) -> String {
        _ = collect(reports: reports, out: out, since: nil)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? [])
            .filter { $0.hasSuffix(".txt") }.sorted(by: >)
        guard !files.isEmpty else { return "No crash reports for Glancy in \(reports.path).\n" }
        var text = "\(files.count) crash\(files.count == 1 ? "" : "es") · summaries in \(out.path)\n"
        for f in files {
            text += "\n── \(f)\n"
            text += (try? String(contentsOf: out.appendingPathComponent(f), encoding: .utf8)) ?? "(unreadable)\n"
        }
        return text
    }

    nonisolated static let italian: [String: String] = [
        "Glancy quit unexpectedly": "Glancy si è chiuso inaspettatamente",
        "Glancy quit unexpectedly (%d times)": "Glancy si è chiuso inaspettatamente (%d volte)",
        "Details": "Dettagli",
        "Show the crash summary in Finder": "Mostra il riepilogo nel Finder",
    ]
}

/// "Glancy quit unexpectedly · Details". The button is an AppKit click target, so it works on the
/// collapsed surface (where any other click opens the panel).
struct CrashPeek: View {
    let summary: URL
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(verbatim: count > 1 ? L10n.tr("Glancy quit unexpectedly (%d times)", count) : L10n.tr("Glancy quit unexpectedly"))
                .font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
                .fixedSize()
            Spacer(minLength: 6)
            ShelfPeekButton(title: L10n.tr("Details"), help: L10n.tr("Show the crash summary in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([summary])
            }
        }
        .frame(minWidth: 280)
    }
}
