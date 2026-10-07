import AppKit
import Observation
import SwiftUI

/// Settings → About: version and build, updates (Sparkle), links, crash reports, Quit.
struct AboutSection: View {
    let context: SurfaceContext
    let crashes: CrashLog

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsBox {
                HStack(spacing: 16) {
                    Image(nsImage: AboutInfo.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Glancy")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(SettingsStyle.primary)
                        Text(verbatim: L10n.tr("Version %@", AboutInfo.version))
                            .font(SettingsStyle.font(.m))
                            .foregroundStyle(SettingsStyle.secondary)
                            .textSelection(.enabled)
                        Text(verbatim: tr("Your MacBook's notch, put to work."))
                            .font(SettingsStyle.font(.s))
                            .foregroundStyle(SettingsStyle.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
            }
            UpdatesBox(updates: context.updates)
            SettingsSection(tr("Links")) {
                VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
                    LinkRow(symbol: "chevron.left.forwardslash.chevron.right", title: tr("Source code"),
                            detail: "github.com/giacolaiacomo/glancy", url: AboutInfo.repository)
                    LinkRow(symbol: "sparkles", title: tr("Release notes"), detail: nil, url: AboutInfo.releases)
                    LinkRow(symbol: "exclamationmark.bubble", title: tr("Report an issue"), detail: nil, url: AboutInfo.issues)
                }
            }
            CrashesBox(crashes: crashes)
            HStack {
                Spacer()
                Button(tr("Quit Glancy")) { context.quit() }
            }
        }
        .onAppear { crashes.load() }
    }
}

/// Version, links and the icon shown on About. The renderer pins the version and the icon.
@MainActor
enum AboutInfo {
    static var versionOverride: String?
    static var iconOverride: NSImage?

    /// "0.4.0 (4000)" as the bundle states it; "dev" outside Glancy.app.
    static var version: String {
        if let versionOverride { return versionOverride }
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, build != short else { return short }
        return "\(short) (\(build))"
    }

    static var icon: NSImage { iconOverride ?? NSApp.applicationIconImage ?? NSImage() }

    static let repository = URL(string: "https://github.com/giacolaiacomo/glancy")!
    static let releases = URL(string: "https://github.com/giacolaiacomo/glancy/releases")!
    static let issues = URL(string: "https://github.com/giacolaiacomo/glancy/issues")!
}

/// Sparkle's switch and check (Updates/UpdatesViews.swift).
private struct UpdatesBox: View {
    let updates: AppUpdates?

    var body: some View {
        SettingsSection(tr("Updates")) {
            VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
                UpdatesSettingsRows(updates: updates)
            }
        }
    }
}

/// A row that opens a web page.
private struct LinkRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let url: URL
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsStyle.secondary)
                    .frame(width: 18)
                Text(verbatim: title)
                    .font(SettingsStyle.font(.m))
                    .foregroundStyle(SettingsStyle.primary)
                if let detail {
                    Text(verbatim: detail)
                        .font(SettingsStyle.font(.s))
                        .foregroundStyle(SettingsStyle.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hover ? Color.accentColor : SettingsStyle.faint)
            }
            .frame(minHeight: 22)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(url.absoluteString)
        .settingsRow()
    }
}

/// Glancy's crash summaries on this Mac (App/CrashReports.swift): the latest few, Show in Finder.
private struct CrashesBox: View {
    let crashes: CrashLog

    var body: some View {
        let entries = crashes.entries ?? []
        SettingsSection(tr("Crash reports"),
                        footer: tr("When Glancy quits unexpectedly it keeps a short summary on this Mac. Nothing is sent anywhere.")) {
            VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
                if crashes.entries == nil {
                    SettingsRow(tr("Looking…")) { EmptyView() }
                } else if entries.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(SettingsStyle.done)
                        Text(verbatim: tr("No crashes recorded")).font(SettingsStyle.font(.m)).foregroundStyle(SettingsStyle.primary)
                        Spacer()
                    }
                    .frame(minHeight: 22)
                    .padding(.vertical, 6)
                    .settingsRow()
                } else {
                    ForEach(entries.prefix(3)) { e in
                        SettingsRow(e.date, note: e.exception) {
                            Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([e.url]) }
                        }
                    }
                    if entries.count > 3 {
                        SettingsRow(L10n.tr("%d more", entries.count - 3)) {
                            Button(tr("Open Folder")) { NSWorkspace.shared.open(CrashLog.directory) }
                        }
                    }
                }
            }
        }
    }
}

/// The crash summaries, read when About appears (off the main thread; a short folder listing).
@MainActor @Observable
final class CrashLog {
    struct Entry: Identifiable, Equatable, Sendable {
        var id: String { url.lastPathComponent }
        let date: String
        let exception: String
        let url: URL
    }

    /// nil until read.
    private(set) var entries: [Entry]?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let source: @Sendable () -> [Entry]

    nonisolated static var directory: URL { CrashReports.summariesDirectory }

    init(source: @escaping @Sendable () -> [Entry] = { CrashLog.read() }) { self.source = source }

    /// Fixed entries (the renderer, tests).
    static func fixed(_ entries: [Entry]) -> CrashLog { CrashLog { entries } }

    func load() {
        guard loading == nil else { return }
        let source = source
        loading = Task { [weak self] in
            let read = await Task.detached(priority: .utility) { source() }.value
            self?.entries = read
            self?.loading = nil
        }
    }

    /// Brings the summaries up to date (reports are only read, as at launch), newest first.
    nonisolated static func read(reports: URL = CrashReports.reportsDirectory, out: URL = CrashReports.summariesDirectory) -> [Entry] {
        _ = CrashReports.collect(reports: reports, out: out, since: nil)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".txt") }
        return names.sorted(by: >).compactMap { name in
            let url = out.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return entry(text, url: url)
        }
    }

    /// "Glancy 0.4.0 (4000) crashed 2026-10-06 00:12:06.00 +0200" / os / exception.
    nonisolated static func entry(_ summary: String, url: URL) -> Entry {
        let lines = summary.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let head = lines.first ?? ""
        var date = head.range(of: " crashed ").map { String(head[$0.upperBound...]) } ?? url.deletingPathExtension().lastPathComponent
        if let dot = date.firstIndex(of: "."), date[dot...].count <= 9 { date = String(date[..<dot]) }   // drop fractions and zone
        let version = head.hasPrefix("Glancy ") ? head.dropFirst(7).components(separatedBy: " crashed").first ?? "" : ""
        let exception = lines.count > 2 ? lines[2] : ""
        return Entry(date: date, exception: version.isEmpty ? exception : "Glancy \(version) · \(exception)", url: url)
    }
}
