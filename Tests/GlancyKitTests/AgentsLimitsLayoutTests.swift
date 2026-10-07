import Foundation
import Testing
@testable import GlancyKit

// Where the plan limits show: the Agents tab's column beside the sessions (which services, which
// rows, old readings never claiming 0%) and the Home card's readings.

private let hour: TimeInterval = 3600

@MainActor
private func store(claude: UsageReading?, codex: UsageReading?, now: Date) -> UsageLimitsStore {
    let s = UsageLimitsStore(fetcher: nil, cacheURL: nil, defaults: nil, codexPresent: { false })
    s.now = { now }
    s.seed(claude: claude, codex: codex)
    return s
}

/// The owner's real cache on 7 Oct: Claude read a minute ago, Codex read 14 days ago (both windows reset since).
private func ownersReadings(now: Date) -> (UsageReading, UsageReading) {
    let read = now.addingTimeInterval(-60)
    let claude = UsageReading(service: .claude, plan: "Max 20x", limits: [
        UsageLimit(kind: .session(hours: 5), percent: 2, resetsAt: now.addingTimeInterval(3.6 * hour), window: 5 * hour, measuredAt: read),
        UsageLimit(kind: .week(model: "all models"), percent: 51, resetsAt: now.addingTimeInterval(77 * hour), window: 7 * 86400, measuredAt: read),
        UsageLimit(kind: .week(model: "Fable"), percent: 14, resetsAt: now.addingTimeInterval(77 * hour), window: 7 * 86400, measuredAt: read),
    ], updated: read)
    let old = now.addingTimeInterval(-14 * 86400)
    let codex = UsageReading(service: .codex, plan: "Plus", limits: [
        UsageLimit(kind: .session(hours: 5), percent: 97, resetsAt: old.addingTimeInterval(4 * hour), window: 5 * hour, measuredAt: old),
        UsageLimit(kind: .week(model: nil), percent: 31, resetsAt: old.addingTimeInterval(6 * 86400), window: 7 * 86400, measuredAt: old),
    ], updated: old)
    return (claude, codex)
}

@MainActor @Test func columnOnlyForTheServicesThatAreOn() {
    let now = Date()
    // Nothing on: no column, the sessions take the whole width.
    #expect(LimitsLayout.columnGroups(store(claude: nil, codex: nil, now: now), now: now).isEmpty)
    let s = UsageLimitsStore.sampleReadings(now: now)
    let both = LimitsLayout.columnGroups(store(claude: s.claude, codex: s.codex, now: now), now: now)
    #expect(both.map(\.service) == [.claude, .codex])
    let claudeOnly = LimitsLayout.columnGroups(store(claude: s.claude, codex: nil, now: now), now: now)
    #expect(claudeOnly.map(\.service) == [.claude])
    let codexOnly = store(claude: nil, codex: s.codex, now: now)
    #expect(LimitsLayout.columnGroups(codexOnly, now: now).map(\.service) == [.codex])
    // Codex turned off: gone from the column.
    codexOnly.codexEnabled = false
    #expect(LimitsLayout.columnGroups(codexOnly, now: now).isEmpty)
}

@MainActor @Test func columnRowsSessionWeekThenTheFullestBucket() {
    let now = Date()
    var s = UsageLimitsStore.sampleReadings(now: now)
    s.claude.limits.append(UsageLimit(kind: .week(model: "Opus"), percent: 95, resetsAt: now.addingTimeInterval(76 * hour),
                                      window: 7 * 86400, measuredAt: now))
    let groups = LimitsLayout.columnGroups(store(claude: s.claude, codex: s.codex, now: now), now: now)
    guard case .limits(let claude) = groups[0].body, case .limits(let codex) = groups[1].body else {
        Issue.record("expected rows"); return
    }
    // Three Claude rows at most: the session, the all-models week, the fullest model bucket.
    #expect(claude.map(\.limit.kind) == [.session(hours: 5), .week(model: "all models"), .week(model: "Opus")])
    #expect(claude.map(\.percent) == [42, 58, 95])
    #expect(codex.map(\.limit.kind) == [.session(hours: 5), .week(model: nil)])
    #expect(!groups[0].stale && groups[0].ago == nil)
    // A bucket resetting with the week has no countdown of its own.
    #expect(claude[2].showsReset == false && claude[0].showsReset)
}

@MainActor @Test func anOldReadingNeverClaimsZero() {
    let now = Date()
    let (claude, codex) = ownersReadings(now: now)
    let groups = LimitsLayout.columnGroups(store(claude: claude, codex: codex, now: now), now: now)
    #expect(groups.count == 2)
    // Codex read 14 days ago, every window reset since: a note with its age, no "0%".
    #expect(groups[1].stale && groups[1].ago == LimitsText.ago(codex.updated, now: now))
    #expect(groups[1].body == .note(LimitsText.t("Updates when you use Codex.")))
    for l in codex.limits { #expect(LimitsLayout.percent(l, in: codex, now: now) == nil) }
    // A fresh reading whose window just reset: 0% is what it is.
    var fresh = claude
    fresh.limits[0].resetsAt = now.addingTimeInterval(-60)
    #expect(LimitsLayout.percent(fresh.limits[0], in: fresh, now: now) == 0)
    // An old reading with the week still running: the week keeps its number, the session is unknown.
    var stale = codex
    stale.updated = now.addingTimeInterval(-2 * 86400)
    stale.limits[0].resetsAt = now.addingTimeInterval(-86400)
    stale.limits[1].resetsAt = now.addingTimeInterval(3 * 86400)
    let g = LimitsLayout.group(.codex, stale, now: now, note: "")
    #expect(g.stale)
    #expect(g.body == .limits([.init(limit: stale.limits[0], percent: nil, showsReset: true),
                               .init(limit: stale.limits[1], percent: 31, showsReset: true)]))
}

@MainActor @Test func columnNotesWithoutAReading() {
    let now = Date()
    let s = store(claude: nil, codex: nil, now: now)
    s.claudeEnabled = true
    s.codexEnabled = true
    let groups = LimitsLayout.columnGroups(s, now: now)
    #expect(groups.map(\.service) == [.claude, .codex])
    #expect(groups.allSatisfy { if case .note = $0.body { true } else { false } })
}

@MainActor @Test func homeItemsAreTheMostRelevantKnownReadings() {
    let now = Date()
    let s = UsageLimitsStore.sampleReadings(now: now)
    // Claude's session and week, then the fullest other one (the 92% Fable bucket).
    let items = LimitsLayout.homeItems(claude: s.claude, codex: s.codex, now: now)
    #expect(items.map(\.limit.kind) == [.session(hours: 5), .week(model: "all models"), .week(model: "Fable")])
    #expect(items.map(\.percent) == [42, 58, 92])
    // Codex alone: its two windows.
    #expect(LimitsLayout.homeItems(claude: nil, codex: s.codex, now: now).map(\.service) == [.codex, .codex])
    // The owner's cache: Claude's three, never the 14-day-old Codex.
    let (claude, codex) = ownersReadings(now: now)
    let real = LimitsLayout.homeItems(claude: claude, codex: codex, now: now)
    #expect(real.map(\.service) == [.claude, .claude, .claude])
    #expect(real.map(\.percent) == [2, 51, 14])
    // Only the 14-day-old Codex: no card.
    #expect(LimitsLayout.homeItems(claude: nil, codex: codex, now: now).isEmpty)
    #expect(LimitsLayout.homeItems(claude: nil, codex: nil, now: now).isEmpty)
    // Two at most when asked.
    #expect(LimitsLayout.homeItems(claude: s.claude, codex: s.codex, now: now, limit: 2).count == 2)
}

@Test func compactRowNamesTheToolAWaitingSessionAsksFor() {
    var store = AgentSessionStore()
    let now = Date()
    store.apply(AgentEvent(ts: now.addingTimeInterval(-30), kind: .userPromptSubmit, sessionID: "s", cwd: "/p/api", prompt: "Run it"))
    store.apply(AgentEvent(ts: now, kind: .permissionRequest, sessionID: "s", cwd: "/p/api", toolName: "Bash"))
    guard let s = store.board.first else { Issue.record("no row"); return }
    #expect(s.state == .waiting)
    #expect(AgentRow.compactText(s) == "Bash · Run it")
    #expect(AgentRow.text(s) == "Run it")
}
