import Foundation

// "Where it went" (ported from Burny): token usage from the CLIs' own local logs, split by project
// and model. Claude Code logs each reply with its token usage in ~/.claude/projects/**/*.jsonl;
// Codex logs token counts in its rollouts. They are added up per hour, project and model, weighted
// by API list price, to split the official % by project. Only numbers, model names, timestamps and
// the project folder's name are kept. Each file is read from where the last look stopped; the
// totals live in ~/Library/Caches/Glancy/usage.json. The reading runs in a short-lived child
// (`Glancy --usage-scan`), only while the page is open, so its memory goes away when it exits.

/// $ per million tokens: input, output, cache read. Cache writes cost 1.25× input (5 min) or 2× (1 h).
func claudePrice(_ model: String) -> (Double, Double, Double)? {
    let m = model.lowercased()
    guard m.hasPrefix("claude") else { return nil }   // e.g. "<synthetic>": not a real API call
    if m.contains("fable") || m.contains("mythos") { return m.contains("5-1") ? (10, 50, 0.25) : (10, 50, 1) }
    if m.contains("opus-5-5") { return (4, 20, 0.2) }
    if m.contains("opus") { return (5, 25, 0.5) }
    if m.contains("haiku") { return (1, 5, 0.1) }
    return (3, 15, 0.3)   // Sonnet and anything newer
}

func claudeCost(model: String, usage u: [String: Any]) -> (cost: Double, tokens: Double)? {
    guard let (i, o, r) = claudePrice(model) else { return nil }
    func n(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
    let input = n(u, "input_tokens"), output = n(u, "output_tokens"), read = n(u, "cache_read_input_tokens")
    let write = n(u, "cache_creation_input_tokens")
    let write1h = min(write, n(u["cache_creation"] as? [String: Any] ?? [:], "ephemeral_1h_input_tokens"))
    let cost = input * i + output * o + read * r + (write - write1h) * i * 1.25 + write1h * i * 2
    return (cost / 1e6, input + output + read + write)
}

/// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5", "gpt-6-astra" → "GPT-6 Astra".
func usageModelName(_ id: String) -> String {
    var parts = id.split(separator: "-").map(String.init)
    if parts.first == "claude" { parts.removeFirst() }
    if parts.last.map({ $0.count == 8 && Int($0) != nil }) == true { parts.removeLast() }
    guard let family = parts.first else { return id }
    if family == "gpt", parts.count > 1 {
        return (["GPT-" + parts[1]] + parts.dropFirst(2).map(\.capitalized)).joined(separator: " ")
    }
    let rest = parts.dropFirst()
    let version = rest.allSatisfy { Int($0) != nil } ? rest.joined(separator: ".") : rest.map(\.capitalized).joined(separator: " ")
    return family.capitalized + (version.isEmpty ? "" : " " + version)
}

let usageTempProject = "(temp)"

/// A log's folder → the project's name (agent worktrees count for their project; temp folders together).
func usageProjectName(_ cwd: String?, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
    guard var cwd, !cwd.isEmpty else { return "?" }
    if let r = cwd.range(of: "/.claude/worktrees/") { cwd = String(cwd[..<r.lowerBound]) }
    if ["/private/var/", "/var/folders/", "/tmp", "/private/tmp"].contains(where: cwd.hasPrefix) { return usageTempProject }
    if cwd == home { return "~" }
    return URL(fileURLWithPath: cwd).lastPathComponent
}

final class UsageLedger {
    struct FileState: Codable {
        var offset: UInt64 = 0
        var lastID: String?, lastKey: String?, lastCost = 0.0, lastTokens = 0.0   // Claude: one reply is logged once per content block
        var project: String?, model: String?, totals: [Double]?                    // Codex: session folder, model, running token totals
    }
    struct Saved: Codable {
        var version = 2
        var files: [String: FileState] = [:]
        var buckets: [String: [Double]] = [:]   // "service\thour\tproject\tmodel" → [cost, tokens]
    }
    /// Only the totals (the app reads these; the per-file offsets stay with the scanner).
    struct Buckets: Decodable {
        var version: Int
        var buckets: [String: [Double]]
    }
    static let keepDays = 15.0
    static let hour: TimeInterval = 3600
    static let claudeName = "Claude Code", codexName = "Codex"

    nonisolated static let defaultCacheURL = UsageLimitsStore.defaultCacheDir.appendingPathComponent("usage.json")
    nonisolated static let defaultClaudeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    let claudeRoot: URL, codexRoot: URL, cacheURL: URL
    var saved = Saved()
    private let cutoff: Date
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    init(claudeRoot: URL = UsageLedger.defaultClaudeRoot, codexRoot: URL = CodexSource.defaultRoot,
         cacheURL: URL = UsageLedger.defaultCacheURL, now: Date = .now) {
        self.claudeRoot = claudeRoot; self.codexRoot = codexRoot; self.cacheURL = cacheURL
        cutoff = now.addingTimeInterval(-Self.keepDays * 86400)
        if let d = try? Data(contentsOf: cacheURL), let s = try? JSONDecoder().decode(Saved.self, from: d), s.version == Saved().version {
            saved = s
        }
    }

    /// Reads whatever the logs gained since last time, drops data older than `keepDays`, saves.
    func update() {
        var seen = Set<String>()
        for (service, root, needles) in [(Self.claudeName, claudeRoot, ["\"usage\":{"]),
                                         (Self.codexName, codexRoot, ["\"token_count\"", "\"session_meta\"", "\"turn_context\""])] {
            for (url, size) in logFiles(root) {
                let path = url.path
                seen.insert(path)
                var st = saved.files[path] ?? FileState()
                if size < st.offset { st = FileState() }   // rewritten: start over
                guard size > st.offset else { saved.files[path] = st; continue }
                st.offset = readLines(url, from: st.offset, needles: needles.map { Data($0.utf8) }) { line in
                    guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    if service == Self.codexName { codexLine(o, &st) } else { claudeLine(o, &st) }
                }
                saved.files[path] = st
            }
        }
        saved.files = saved.files.filter { seen.contains($0.key) }
        let oldest = Int(cutoff.timeIntervalSince1970 / Self.hour)
        saved.buckets = saved.buckets.filter { k, _ in
            let f = k.split(separator: "\t", omittingEmptySubsequences: false)
            return f.count == 4 && (Int(f[1]).map { $0 >= oldest } ?? false)
        }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: cacheURL, options: .atomic)
    }

    private func logFiles(_ root: URL) -> [(URL, UInt64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { item in
            guard let u = item as? URL, u.pathExtension == "jsonl", let v = try? u.resourceValues(forKeys: Set(keys)),
                  (v.contentModificationDate ?? .distantPast) >= cutoff else { return nil }
            return (u, UInt64(v.fileSize ?? 0))
        }
    }

    /// Calls `line` for each complete line after `from` containing one of `needles`; returns the offset after the last full line.
    private func readLines(_ url: URL, from: UInt64, needles: [Data], _ line: (Data) -> Void) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return from }
        defer { try? h.close() }
        try? h.seek(toOffset: from)
        var offset = from, carry = Data()
        while true {
            let more: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                let buf = carry + chunk
                var matches: [Data] = [], consumed = 0
                buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    while consumed < raw.count, let nl = memchr(base + consumed, 10, raw.count - consumed) {
                        let end = base.distance(to: UnsafeRawPointer(nl))
                        let hit = needles.contains { n in
                            n.withUnsafeBytes { memmem(base + consumed, end - consumed, $0.baseAddress, n.count) != nil }
                        }
                        if hit { matches.append(Data(bytes: base + consumed, count: end - consumed)) }
                        consumed = end + 1
                    }
                }
                for m in matches { autoreleasepool { line(m) } }
                offset += UInt64(consumed)
                carry = buf.subdata(in: consumed..<buf.count)
                return true
            }
            if !more { break }
        }
        return offset
    }

    private func add(_ key: String, _ cost: Double, _ tokens: Double) {
        var b = saved.buckets[key] ?? [0, 0]
        b[0] += cost; b[1] += tokens
        saved.buckets[key] = b
    }

    private func key(_ service: String, _ at: Date, _ project: String, _ model: String) -> String {
        "\(service)\t\(Int(at.timeIntervalSince1970 / Self.hour))\t\(project)\t\(model)"
    }

    private func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } }

    private func claudeLine(_ o: [String: Any], _ st: inout FileState) {
        guard o["type"] as? String == "assistant", let m = o["message"] as? [String: Any], let model = m["model"] as? String,
              let u = m["usage"] as? [String: Any], let c = claudeCost(model: model, usage: u),
              let at = date(o["timestamp"]), at >= cutoff else { return }
        let id = m["id"] as? String
        if let id, id == st.lastID, let k = st.lastKey {   // same reply again: keep only its latest numbers
            add(k, c.cost - st.lastCost, c.tokens - st.lastTokens)
        } else {
            let k = key(Self.claudeName, at, usageProjectName(o["cwd"] as? String), model)
            st.lastKey = k
            add(k, c.cost, c.tokens)
        }
        st.lastID = id; st.lastCost = c.cost; st.lastTokens = c.tokens
    }

    private func codexLine(_ o: [String: Any], _ st: inout FileState) {
        guard let p = o["payload"] as? [String: Any] else { return }
        switch o["type"] as? String {
        case "session_meta": st.project = usageProjectName(p["cwd"] as? String)
        case "turn_context": st.model = p["model"] as? String ?? st.model
        default:
            guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                  let t = info["total_token_usage"] as? [String: Any], let at = date(o["timestamp"]) else { return }
            let now = ["input_tokens", "cached_input_tokens", "output_tokens"].map { (t[$0] as? NSNumber)?.doubleValue ?? 0 }
            let prev = st.totals ?? [0, 0, 0]
            st.totals = now
            let d = now[0] >= prev[0] ? zip(now, prev).map { max(0, $0 - $1) } : now   // totals only grow within a session
            guard at >= cutoff, d.contains(where: { $0 > 0 }) else { return }
            // Relative weight at GPT list-price ratios (cached input 0.1×, output 8×); only shares are shown for Codex.
            let cost = ((d[0] - d[1]) * 1.25 + d[1] * 0.125 + d[2] * 10) / 1e6
            add(key(Self.codexName, at, st.project ?? "?", st.model ?? "codex"), cost, d[0] + d[2])
        }
    }

    // MARK: Totals (from the buckets only)

    /// Totals for a service between two dates, split by project and by model (largest first).
    static func split(_ buckets: [String: [Double]], _ service: String, from: Date, to: Date)
        -> (cost: Double, tokens: Double, projects: [(String, Double)], models: [(String, Double)]) {
        let lo = Int(from.timeIntervalSince1970 / hour), hi = Int(to.timeIntervalSince1970 / hour)
        var cost = 0.0, tokens = 0.0, projects: [String: Double] = [:], models: [String: Double] = [:]
        for (k, v) in buckets where v.count >= 2 {
            let f = k.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[0] == service, let h = Int(f[1]), h >= lo, h <= hi else { continue }
            cost += v[0]; tokens += v[1]
            projects[f[2], default: 0] += v[0]
            models[usageModelName(f[3]), default: 0] += v[0]
        }
        return (cost, tokens, projects.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
                models.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
    }

    func split(_ service: String, from: Date, to: Date) -> (cost: Double, tokens: Double, projects: [(String, Double)], models: [(String, Double)]) {
        Self.split(saved.buckets, service, from: from, to: to)
    }

    /// Reads the buckets the scanner saved (nil when there are none).
    static func loadBuckets(_ url: URL) -> [String: [Double]]? {
        guard let d = try? Data(contentsOf: url), let b = try? JSONDecoder().decode(Buckets.self, from: d),
              b.version == Saved().version else { return nil }
        return b.buckets
    }

    // MARK: The scan child

    /// `Glancy --usage-scan`: updates the cache from the logs and exits (run as a child by the app).
    static func runScanAndExit() -> Never {
        autoreleasepool { UsageLedger().update() }
        exit(0)
    }

    /// Runs `Glancy --usage-scan` (the app's own binary) and waits, at most `timeout`. Cancelling
    /// the task kills it.
    static func scanInChild(executable: String, timeout: TimeInterval = 120) async {
        let child = ChildRun()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    _ = child.run(executable, ["--usage-scan"],
                                  env: ProcessInfo.processInfo.environment.filter { ["HOME", "USER", "TMPDIR", "PATH", "CFFIXED_USER_HOME"].contains($0.key) },
                                  cwd: "/", timeout: timeout)
                    c.resume()
                }
            }
        } onCancel: {
            child.kill()
        }
    }

    /// The loader the app uses: the scan in a child, then the totals from its cache.
    static func childLoader(executable: String, cacheURL: URL = defaultCacheURL) -> @Sendable ([UsageWindowSpan]) async -> UsageBreakdown? {
        { spans in
            await scanInChild(executable: executable)
            guard !Task.isCancelled, let buckets = loadBuckets(cacheURL) else { return nil }
            return UsageBreakdown(buckets: buckets, windows: spans, now: .now)
        }
    }
}

/// One service's current session and week, and their official % used.
public struct UsageWindowSpan: Sendable, Equatable {
    public var service: UsageService
    public var sessionStart: Date
    public var sessionPercent: Double?
    public var weekStart: Date
    public var weekPercent: Double?
}

/// What the page shows for one service and window.
public struct UsagePart: Sendable, Identifiable {
    public let service: UsageService
    public let percent: Double?              // the official % used in this window, when known
    public let cost: Double, tokens: Double
    public let projects: [UsageShare]
    public let models: [UsageShare]
    public let previous: Double?             // week only: cost at the same point of last week's window
    public var id: UsageService { service }

    /// The top projects, the rest folded into "Other"; each with its share of the cost.
    func rows(limit: Int) -> [UsageShare] {
        guard cost > 0 else { return [] }
        var r = projects.prefix(limit).map { UsageShare(name: $0.name, cost: $0.cost / cost) }
        let rest = projects.dropFirst(limit).reduce(0) { $0 + $1.cost }
        if rest > 0 { r.append(UsageShare(name: UsageShare.other, cost: rest / cost)) }
        return r
    }
}

public struct UsageShare: Sendable, Equatable {
    public var name: String
    public var cost: Double
    static let other = "\u{1}other"
}

public struct UsageBreakdown: Sendable {
    public var bySession: [UsagePart] = []
    public var byWeek: [UsagePart] = []

    public init(parts: [UsagePart]) { bySession = parts; byWeek = parts }
    public init(bySession: [UsagePart], byWeek: [UsagePart]) { self.bySession = bySession; self.byWeek = byWeek }

    init(buckets: [String: [Double]], windows: [UsageWindowSpan], now: Date) {
        for w in windows {
            let name = w.service == .claude ? UsageLedger.claudeName : UsageLedger.codexName
            let s = UsageLedger.split(buckets, name, from: w.sessionStart, to: now)
            let k = UsageLedger.split(buckets, name, from: w.weekStart, to: now)
            let prev = UsageLedger.split(buckets, name, from: w.weekStart.addingTimeInterval(-UsageLimit.week),
                                         to: now.addingTimeInterval(-UsageLimit.week)).cost
            func shares(_ l: [(String, Double)]) -> [UsageShare] { l.map { UsageShare(name: $0.0, cost: $0.1) } }
            bySession.append(UsagePart(service: w.service, percent: w.sessionPercent, cost: s.cost, tokens: s.tokens,
                                       projects: shares(s.projects), models: shares(s.models), previous: nil))
            byWeek.append(UsagePart(service: w.service, percent: w.weekPercent, cost: k.cost, tokens: k.tokens,
                                    projects: shares(k.projects), models: shares(k.models), previous: prev > 0 ? prev : nil))
        }
    }
}

extension UsageBreakdown {
    /// Made-up, realistic numbers (Burny's demo): no real project name ever shows in an image.
    static var sample: UsageBreakdown {
        func part(_ s: UsageService, _ percent: Double, _ cost: Double, _ tokens: Double, _ projects: [(String, Double)],
                  _ models: [(String, Double)], previous: Double? = nil) -> UsagePart {
            UsagePart(service: s, percent: percent, cost: cost, tokens: tokens,
                      projects: projects.map { UsageShare(name: $0.0, cost: $0.1 * cost) },
                      models: models.map { UsageShare(name: $0.0, cost: $0.1 * cost) }, previous: previous)
        }
        return UsageBreakdown(
            bySession: [
                part(.claude, 42, 96.4, 2.1e8, [("acme-web", 0.58), ("api-server", 0.31), ("docs-site", 0.11)], [("Opus 5.5", 0.7), ("Fable 5.1", 0.3)]),
                part(.codex, 18, 0.9, 6.2e6, [("mobile-app", 1)], [("GPT-6 Astra", 1)]),
            ],
            byWeek: [
                part(.claude, 58, 1284.5, 2.9e9,
                     [("acme-web", 0.40), ("api-server", 0.24), ("mobile-app", 0.15), ("docs-site", 0.08), ("infra", 0.05), ("playground", 0.03), ("scratch", 0.05)],
                     [("Opus 5.5", 0.64), ("Fable 5.1", 0.26), ("Sonnet 5", 0.10)], previous: 1052),
                part(.codex, 31, 3.1, 1.8e7, [("mobile-app", 0.62), ("api-server", 0.38)], [("GPT-6 Astra", 0.8), ("GPT-6 Luna", 0.2)], previous: 2.6),
            ])
    }
}
