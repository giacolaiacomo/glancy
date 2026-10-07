import Foundation

// What the plan limits show where (pure, tested): the Agents tab's limits column beside the
// sessions, and the Home card's few readings.

/// One service in the limits column.
struct LimitsColumnGroup: Equatable {
    enum Body: Equatable {
        /// The limits worth a row, each with the % to show (nil: not known any more, see
        /// `LimitsLayout.percent`).
        case limits([Row])
        /// No reading worth a number: why, or when it will come.
        case note(String)
    }

    struct Row: Equatable {
        let limit: UsageLimit
        let percent: Double?
        /// A model's bucket resetting with the all-models week shows no countdown of its own.
        let showsReset: Bool
    }

    let service: UsageService
    let plan: String?
    /// The reading is old (Claude > 30 min, Codex > 6 h): drawn dimmed, with its age.
    let stale: Bool
    /// "4 min ago", "13 d ago" (stale readings only).
    let ago: String?
    let body: Body
}

enum LimitsLayout {
    /// Rows per service in the column: Claude's session, week and its fullest model bucket; Codex's two.
    static let maxRows: [UsageService: Int] = [.claude: 3, .codex: 2]

    /// The % worth showing for a limit, nil when it isn't known any more: an old reading whose
    /// window has reset since (it restarted from 0, and what was used after is unknown), so a
    /// 13-day-old Codex reading never claims "0%".
    static func percent(_ l: UsageLimit, in r: UsageReading, now: Date) -> Double? {
        if r.isStale(at: now), let reset = l.resetsAt, reset <= now { return nil }
        return l.effective(at: now)
    }

    /// Claude: the session, the all-models week, then the model buckets fullest first. Codex: as read.
    static func ordered(_ r: UsageReading, now: Date) -> [UsageLimit] {
        guard r.service == .claude else { return r.limits }
        let session = r.limits.filter { $0.kind.isSession }
        let week = r.limits.filter { $0.kind.isAllModelsWeek }
        let rest = r.limits.filter { !$0.kind.isSession && !$0.kind.isAllModelsWeek }
            .sorted { $0.effective(at: now) > $1.effective(at: now) }
        return session + week + rest
    }

    /// The limits column beside the sessions: one group per service that is on (Claude first).
    /// Empty when no service is on: the sessions take the whole width.
    @MainActor static func columnGroups(_ limits: UsageLimitsStore, now: Date) -> [LimitsColumnGroup] {
        var out: [LimitsColumnGroup] = []
        if limits.claudeEnabled {
            out.append(group(.claude, limits.claude, now: now, note: LimitsPage.claudeNote(limits)))
        }
        if limits.codexEnabled {
            out.append(group(.codex, limits.codex, now: now, note: LimitsText.t("Updates when you use Codex.")))
        }
        return out
    }

    static func group(_ service: UsageService, _ reading: UsageReading?, now: Date, note: String) -> LimitsColumnGroup {
        guard let r = reading, !r.limits.isEmpty else {
            return LimitsColumnGroup(service: service, plan: reading?.plan, stale: false, ago: nil, body: .note(note))
        }
        let stale = r.isStale(at: now)
        let ago = stale ? LimitsText.ago(r.updated, now: now) : nil
        let rows = ordered(r, now: now).prefix(maxRows[service] ?? 3).map {
            LimitsColumnGroup.Row(limit: $0, percent: percent($0, in: r, now: now), showsReset: !r.sharesWeekReset($0))
        }
        // Nothing left worth a number (every window reset since an old reading): say when it comes back.
        guard rows.contains(where: { $0.percent != nil }) else {
            let why = service == .codex ? LimitsText.t("Updates when you use Codex.") : note
            return LimitsColumnGroup(service: service, plan: r.plan, stale: stale, ago: ago, body: .note(why))
        }
        return LimitsColumnGroup(service: service, plan: r.plan, stale: stale, ago: ago, body: .limits(Array(rows)))
    }

    // MARK: Home

    /// One reading on the Home card.
    struct HomeItem: Equatable {
        let service: UsageService
        let limit: UsageLimit
        let percent: Double
        let showsReset: Bool
        let stale: Bool
    }

    /// The Home card's readings, at most `limit`: Claude's session and week, then the fullest
    /// other limit (a Claude model bucket, Codex). Only numbers still known; empty = no card.
    static func homeItems(claude: UsageReading?, codex: UsageReading?, now: Date, limit: Int = 3) -> [HomeItem] {
        func items(_ r: UsageReading?) -> [HomeItem] {
            guard let r else { return [] }
            return ordered(r, now: now).compactMap { l in
                percent(l, in: r, now: now).map {
                    HomeItem(service: r.service, limit: l, percent: $0, showsReset: !r.sharesWeekReset(l), stale: r.isStale(at: now))
                }
            }
        }
        let c = items(claude), x = items(codex)
        // Claude's session and all-models week lead; Codex's two lead when Claude has nothing.
        let lead = c.isEmpty ? Array(x.prefix(2)) : Array(c.filter { $0.limit.kind.isSession || $0.limit.kind.isAllModelsWeek }.prefix(2))
        let rest = (c + x).filter { i in !lead.contains(i) }
            // A fresh reading before an old one, then the fullest.
            .sorted { a, b in a.stale != b.stale ? !a.stale : a.percent > b.percent }
        let out = Array((lead + rest.prefix(max(0, limit - lead.count))).prefix(limit))
        // The card reads left to right by service: Claude's, then Codex's.
        return out.filter { $0.service == .claude } + out.filter { $0.service == .codex }
    }
}
