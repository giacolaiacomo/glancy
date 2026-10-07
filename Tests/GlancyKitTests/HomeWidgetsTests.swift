import Foundation
import Testing
@testable import GlancyKit

// Configurable Home: the saved choice and order, which cards make it and how they share the page,
// and when the plan limits card is there.

@MainActor
private func freshSettings() -> (AppSettings, UserDefaults, String) {
    let suite = "glancy.test.home.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    return (AppSettings(defaults: d), d, suite)
}

@MainActor @Test func homeDefaultsToEveryWidgetInTodaysOrder() {
    let (s, _, suite) = freshSettings()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    #expect(s.homeOrder == HomeWidget.defaultOrder)
    #expect(HomeWidget.allCases.allSatisfy { s.isShownOnHome($0) })
    // Sessions first, the limits right after them.
    #expect(Array(s.homeOrder.prefix(2)) == [.agents, .limits])
}

@MainActor @Test func homeChoiceAndOrderPersist() {
    let (s, d, suite) = freshSettings()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    s.moveOnHome(.media, by: -1)
    s.moveOnHome(.media, by: -1)
    s.moveOnHome(.agents, by: -1)          // already first: nothing moves
    s.moveOnHome(.power, by: 1)            // already last: nothing moves
    s.setShownOnHome(.calendar, false)
    let again = AppSettings(defaults: d)
    #expect(again.homeOrder == [.agents, .media, .limits, .calendar, .timer, .notes, .shelf, .control, .power])
    #expect(!again.isShownOnHome(.calendar) && again.isShownOnHome(.media))
    again.resetHome()
    #expect(AppSettings(defaults: d).homeOrder == HomeWidget.defaultOrder)
    #expect(AppSettings(defaults: d).homeHidden.isEmpty)
}

@Test func savedOrderKeepsEveryWidgetOnce() {
    // An older save without the limits widget, with a duplicate and an unknown name dropped earlier.
    let n = HomeLayout.normalized([.calendar, .agents, .calendar, .media])
    #expect(n.count == HomeWidget.allCases.count && Set(n) == Set(HomeWidget.allCases))
    // The new widget lands after the one that precedes it by default (limits after agents).
    #expect(Array(n.prefix(4)) == [.calendar, .agents, .limits, .media])
    #expect(HomeLayout.normalized([]) == HomeWidget.defaultOrder)
}

@Test func layoutAdaptsToOneTwoThreeFourCards() {
    typealias A = HomeLayout.Arrangement
    #expect(HomeLayout.arrange([]) == A(columns: [], tileLast: false))
    #expect(HomeLayout.arrange([.agents]) == A(columns: [[.agents]], tileLast: false))
    #expect(HomeLayout.arrange([.agents, .limits]) == A(columns: [[.agents, .limits]], tileLast: false))
    #expect(HomeLayout.arrange([.agents, .limits, .calendar]) == A(columns: [[.agents, .limits], [.calendar]], tileLast: false))
    #expect(HomeLayout.arrange([.agents, .limits, .calendar, .timer])
            == A(columns: [[.agents, .limits], [.calendar, .timer]], tileLast: false))
    // The media tile goes right, wherever it is in the order, beside at most two rows.
    #expect(HomeLayout.arrange([.media, .agents, .limits]) == A(columns: [[.agents, .limits], [.media]], tileLast: true))
    #expect(HomeLayout.arrange([.media]) == A(columns: [[.media]], tileLast: false))
    // Never a hole: every column has a card.
    for n in 1...4 {
        #expect(HomeLayout.arrange(Array(HomeWidget.defaultOrder.filter { $0 != .media }.prefix(n))).columns.allSatisfy { !$0.isEmpty })
    }
}

@Test func theMostUrgentMakeTheCutAndShowInTheUsersOrder() {
    let order = HomeWidget.defaultOrder
    // Calm: the user's order decides; four rows fit.
    let calm = HomeLayout.pick([.power, .calendar, .agents, .limits, .notes], order: order) { _ in 0 }
    #expect(calm == [.agents, .limits, .calendar, .notes])
    // A meeting starting now beats the limits, but is still drawn in its place in the order.
    let urgent = HomeLayout.pick([.agents, .limits, .calendar, .notes, .power], order: order) { $0 == .power ? 85 : 0 }
    #expect(urgent == [.agents, .limits, .calendar, .power])
    // Music playing: the tile plus two rows.
    let playing = HomeLayout.pick([.agents, .limits, .calendar, .media], order: order) { w in
        w == .agents ? 50 : w == .media ? 30 : 0
    }
    #expect(playing == [.agents, .limits, .media])
    // The user's own order: limits before the sessions.
    var mine = order
    mine.swapAt(0, 1)
    #expect(HomeLayout.pick([.agents, .limits], order: mine) { _ in 0 } == [.limits, .agents])
}

@MainActor @Test func limitsCardOnlyWithAReadingWorthANumber() {
    let module = AgentsModule.renderEmpty()
    #expect(module.homeWidgets().isEmpty)
    let now = Date()
    module.seedLimitsSample(now: now)
    let w = module.homeWidgets()
    #expect(w.map(\.widget) == [.limits])
    // The sample's Fable bucket is at 92%: the card goes before calm ones.
    #expect(w.first?.priority == 70)
    // Only a 14-day-old Codex reading: no card.
    let old = now.addingTimeInterval(-14 * 86400)
    module.seedLimits(claude: nil, codex: UsageReading(service: .codex, plan: "Plus", limits: [
        UsageLimit(kind: .session(hours: 5), percent: 97, resetsAt: old.addingTimeInterval(3600), window: 5 * 3600, measuredAt: old),
    ], updated: old), breakdown: nil)
    #expect(module.homeWidgets().isEmpty)
    // Sessions too: both cards, the sessions first.
    let busy = AgentsModule.renderSample(now: now)
    busy.seedLimitsSample(now: now)
    #expect(busy.homeWidgets().map(\.widget) == [.agents, .limits])
}

@MainActor @Test func homeTicksTheCountdownsOnlyWhileShowingAReading() {
    let store = UsageLimitsStore(fetcher: nil, cacheURL: nil, defaults: nil, codexPresent: { false })
    store.visibilityChanged(.expanded(nil))
    #expect(!store.ticksClock)   // nothing to show
    let s = UsageLimitsStore.sampleReadings(now: .now)
    store.seed(claude: s.claude, codex: nil)
    store.visibilityChanged(.expanded(nil))
    #expect(store.ticksClock)
    store.visibilityChanged(.expanded(.calendar))
    #expect(!store.ticksClock)
    store.visibilityChanged(.collapsed)
    #expect(!store.ticksClock)
}
