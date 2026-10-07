import SwiftUI

// Plan limits in the Agents tab: a column beside the sessions (bars, %, the even-pace tick, the
// reset countdown, a flame when on pace to run out), a Limits page and a "Where it went" page
// behind it; the Home card; the alert drop-down and the used-up wing. Theme only, nothing animates.

extension UsageService {
    var tint: Color { agent.tint }
    var symbol: String { agent.symbol }
}

/// Burny's levels: orange from 75%, red from 90%, else the service's colour.
func limitColor(_ p: Double, _ service: UsageService) -> Color {
    p >= 90 ? Theme.failed : p >= 75 ? Theme.waiting : (service == .codex ? Theme.working : service.tint)
}

/// A bar with the even-pace tick.
struct LimitBar: View {
    let percent: Double
    let pace: Double?
    let color: Color
    var height: CGFloat = 4.ui

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                if percent > 0 {
                    Capsule().fill(color)
                        .frame(width: max(height, g.size.width * min(percent, 100) / 100))
                }
                if let pace {
                    RoundedRectangle(cornerRadius: 0.5.ui)
                        .fill(Color.white.opacity(0.70))
                        .frame(width: 1.5.ui, height: height + 4.ui)
                        .offset(x: g.size.width * pace - 0.75.ui)
                }
            }
        }
        .frame(height: height)
    }
}

/// The pages of the Agents tab.
public enum AgentsTabPage: String, Sendable, CaseIterable {
    case sessions, limits, whereItWent
}

/// The Agents tab: the sessions board with the limits column beside it, or a limits page.
struct AgentsTab: View {
    let model: AgentsModel
    let limits: UsageLimitsStore
    @State var page: AgentsTabPage

    var body: some View {
        switch page {
        case .sessions:
            let groups = LimitsLayout.columnGroups(limits, now: limits.clock)
            if groups.isEmpty {
                AgentsBoard(model: model)
            } else {
                AgentsBoard(model: model, compact: true) {
                    LimitsColumn(groups: groups, now: limits.clock) { page = .limits }
                        .frame(width: LimitsColumn.width)
                }
            }
        case .limits, .whereItWent:
            LimitsPage(limits: limits, page: $page)
        }
    }
}

// MARK: Column

/// The limits beside the sessions: per service its glyph, then a row per limit (label, reset
/// countdown, flame, %, the bar with the even-pace tick). The whole column opens the Limits page.
struct LimitsColumn: View {
    let groups: [LimitsColumnGroup]
    let now: Date
    let open: () -> Void
    @State private var hover = false

    /// About 36% of the page: the sessions keep the rest.
    static var width: CGFloat { 222.ui }

    var body: some View {
        Button(action: open) {
            // Three Claude rows and two Codex rows fit the 128 pt beside the sessions at every size.
            VStack(alignment: .leading, spacing: 8.ui) {
                ForEach(groups, id: \.service) { g in
                    LimitsColumnGroupView(group: g, now: now)
                }
            }
            .padding(.leading, 8.ui)
            .padding(.trailing, 10.ui)
            .padding(.vertical, 6.ui)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous)
                .fill(hover ? Color.white.opacity(0.09) : Color.white.opacity(0.045)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(LimitsText.t("Plan limits: open for the details and where they went.") + "\n"
              + LimitsText.t("The tick on each bar shows where you'd be at an even pace."))
    }
}

private struct LimitsColumnGroupView: View {
    let group: LimitsColumnGroup
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 6.ui) {
            Image(systemName: group.service.symbol)
                .font(.system(size: 9.ui, weight: .bold))
                .foregroundStyle(group.service.tint)
                .frame(width: 12.ui, height: 13.ui)
                .help([group.service.name, group.plan, group.ago].compactMap { $0 }.joined(separator: " · "))
            switch group.body {
            case .limits(let rows):
                VStack(alignment: .leading, spacing: 4.ui) {
                    ForEach(Array(rows.enumerated()), id: \.element.limit.id) { i, row in
                        LimitCell(limit: row.limit, service: group.service, now: now, showsReset: row.showsReset,
                                  percent: row.percent, ago: i == 0 ? group.ago : nil, spacing: 2.ui)
                    }
                }
                .opacity(group.stale ? 0.5 : 1)
            case .note(let text):
                Text(verbatim: [group.ago, text].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One limit: "5h · 2h18 ………… 42%" over a thin bar (the column, the Home card).
struct LimitCell: View {
    let limit: UsageLimit
    let service: UsageService
    let now: Date
    /// A model's bucket resetting with the all-models week shows no countdown of its own.
    var showsReset = true
    /// The % to show; nil = not known any more (an old reading reset since): "–", no bar.
    var percent: Double?? = .none
    /// An old reading's age, in place of the countdown.
    var ago: String? = nil
    /// Between the text and the bar.
    var spacing: CGFloat = 3.ui

    var body: some View {
        let p: Double? = percent ?? limit.effective(at: now)
        let eta = p == nil ? nil : limit.runsOutAt(now: now)
        VStack(alignment: .leading, spacing: spacing) {
            HStack(spacing: 3.ui) {
                Text(LimitsText.short(limit.kind))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                if let ago {
                    Text("· \(ago)").foregroundStyle(Theme.waiting).lineLimit(1).layoutPriority(1)
                } else if showsReset, p != nil, let c = LimitsText.compactUntil(limit.resetsAt, now: now) {
                    Text("· \(c)").foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize().layoutPriority(1)
                }
                Spacer(minLength: 2.ui)
                if eta != nil {
                    Image(systemName: "flame.fill").font(.system(size: 8.ui)).foregroundStyle(Theme.waiting)
                }
                Text(p.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(Theme.font(.xs, .semibold).monospacedDigit())
                    .foregroundStyle(p == nil ? Theme.tertiary : eta != nil ? Theme.waiting : p! >= 75 ? limitColor(p!, service) : Theme.primary)
                    .fixedSize()
                    .layoutPriority(2)
            }
            .font(Theme.font(.xs, .medium).monospacedDigit())
            LimitBar(percent: p ?? 0, pace: p == nil ? nil : limit.pace(at: now), color: limitColor(p ?? 0, service), height: 3.ui)
        }
        .frame(maxWidth: .infinity)
        .help(tooltip(p: p, eta: eta))
    }

    private func tooltip(p: Double?, eta: Date?) -> String {
        var lines = ["\(service.name) · \(LimitsText.label(limit.kind)): " + (p.map { "\(Int($0.rounded()))%" } ?? LimitsText.t("Reset"))]
        if let ago { lines.append(LimitsText.t("Last read") + " " + ago) }
        let reset = LimitsText.resetLine(limit.resetsAt, now: now)
        if p != nil, !reset.isEmpty { lines.append(reset) }
        if let eta { lines.append(LimitsText.runsOut(limit, eta: eta, now: now)) }
        else if p != nil, let b = limit.dailyBudget(at: now) { lines.append(LimitsText.dailyBudget(b)) }
        return lines.joined(separator: "\n")
    }
}

// MARK: Pages

struct LimitsPage: View {
    let limits: UsageLimitsStore
    @Binding var page: AgentsTabPage
    @State private var window = "week"

    static func claudeNote(_ limits: UsageLimitsStore) -> String {
        switch limits.claudeStatus {
        case .notInstalled: return LimitsText.t("Claude Code CLI not found.")
        case .notGenuine: return LimitsText.t("The claude binary isn't signed by Anthropic, so Glancy won't run it.")
        case .unexpectedOutput: return LimitsText.t("The claude CLI answered unexpectedly, so Glancy stopped calling it. Turn Claude Code limits off and on after updating.")
        case .failed: return LimitsText.t("Couldn't read /usage this time.")
        case .unknown, .ok: return limits.fetching ? LimitsText.t("Updating…") : LimitsText.t("No reading yet: open this tab again in a moment.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8.ui) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10.ui) {
                    if page == .limits {
                        ForEach(services, id: \.self) { s in
                            LimitsServiceCard(limits: limits, service: s)
                        }
                    } else {
                        WhereItWent(limits: limits, window: window)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var services: [UsageService] {
        UsageService.allCases.filter { $0 == .claude ? limits.claudeEnabled : limits.codexEnabled }
    }

    private var header: some View {
        HStack(spacing: 8.ui) {
            Button { page = .sessions } label: {
                HStack(spacing: 4.ui) {
                    Image(systemName: "chevron.left").font(.system(size: 9.ui, weight: .semibold))
                    Text(LimitsText.t("Sessions")).font(Theme.font(.xs, .medium))
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 8.ui)
                .frame(height: 20.ui)
                .background(Capsule().fill(Theme.card))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            NotchSegments(selection: $page, options: [(.limits, LimitsText.t("Limits")), (.whereItWent, LimitsText.t("Where it went"))])
            Spacer(minLength: 6.ui)
            if page == .whereItWent {
                NotchSegments(selection: $window, options: [("session", LimitsText.t("Session")), ("week", LimitsText.t("Week"))])
            } else if limits.claudeEnabled {
                if limits.fetching {
                    Text(LimitsText.t("Updating…")).font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                }
                Button { limits.refresh(.manual) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.ui, weight: .semibold))
                        .foregroundStyle(limits.fetching ? Theme.tertiary : Theme.secondary)
                        .frame(width: 22.ui, height: 20.ui)
                        .background(Capsule().fill(Theme.card))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(limits.fetching)
                .help(LimitsText.t("Refresh now"))
            }
        }
        .frame(height: 22.ui)
    }
}

/// One service on the Limits page: its plan, when it was read, every limit (label, reset, %, the
/// bar with the even-pace tick), then what deserves a line: a forecast, a model switch, the daily
/// budget of the week.
struct LimitsServiceCard: View {
    let limits: UsageLimitsStore
    let service: UsageService

    var body: some View {
        let now = limits.clock
        let reading = service == .claude ? limits.claude : limits.codex
        VStack(alignment: .leading, spacing: 4.ui) {
            HStack(spacing: 6.ui) {
                Image(systemName: service.symbol)
                    .font(.system(size: 9.ui, weight: .bold))
                    .foregroundStyle(service.tint)
                Text(service.name).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                if let plan = reading?.plan {
                    Text(plan)
                        .font(Theme.font(.xs, .semibold))
                        .foregroundStyle(service.tint)
                        .padding(.horizontal, 5.ui)
                        .frame(height: 14.ui)
                        .background(Capsule().fill(service.tint.opacity(0.16)))
                }
                Spacer(minLength: 4.ui)
                if let r = reading {
                    Text(LimitsText.ago(r.updated, now: now))
                        .font(Theme.font(.xs))
                        .foregroundStyle(r.isStale(at: now) ? Theme.waiting : Theme.tertiary)
                }
            }
            if let r = reading, !r.limits.isEmpty {
                VStack(alignment: .leading, spacing: 4.ui) {
                    ForEach(r.limits) { l in LimitDetailRow(limit: l, service: service, now: now) }
                }
                .opacity(r.isStale(at: now) ? 0.5 : 1)
                ForEach(notes(r, now: now), id: \.text) { n in
                    Label(n.text, systemImage: n.symbol)
                        .font(Theme.font(.xs, n.warn ? .medium : .regular))
                        .foregroundStyle(n.warn ? Theme.waiting : Theme.tertiary)
                        .lineLimit(1)
                        .help(n.text)
                }
            } else {
                Text(service == .claude ? LimitsPage.claudeNote(limits) : LimitsText.t("No data yet: use it once and it will show up here."))
                    .font(Theme.font(.s)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10.ui)
        .padding(.vertical, 7.ui)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous).fill(Theme.card))
    }

    struct Note { let text: String; let symbol: String; let warn: Bool }

    /// At most two lines: forecasts first, then a model switch, then the week's daily budget.
    func notes(_ r: UsageReading, now: Date) -> [Note] {
        var out: [Note] = []
        if r.isStale(at: now) {
            if service == .codex { out.append(Note(text: LimitsText.t("Updates when you use Codex."), symbol: "clock", warn: false)) }
            return out
        }
        for l in r.limits {
            if let eta = l.runsOutAt(now: now) {
                out.append(Note(text: LimitsText.short(l.kind) + ": " + LimitsText.runsOut(l, eta: eta, now: now).lowercasedFirst,
                                symbol: "flame.fill", warn: true))
            }
        }
        if let hint = r.switchHint(at: now), let m = hint.limit.kind.bucketModel {
            out.append(Note(text: LimitsText.switchHint(m, left: hint.left), symbol: "arrow.triangle.swap", warn: true))
        }
        if let week = r.limits.first(where: { $0.kind.isAllModelsWeek }), let b = week.dailyBudget(at: now) {
            out.append(Note(text: LimitsText.dailyBudget(b), symbol: "calendar", warn: false))
        }
        return Array(out.prefix(2))
    }
}

/// "Week · all models   3d 3h · Sat 10 · 03:08   58%" over the bar.
struct LimitDetailRow: View {
    let limit: UsageLimit
    let service: UsageService
    let now: Date

    var body: some View {
        let p = limit.effective(at: now)
        VStack(alignment: .leading, spacing: 2.ui) {
            HStack(alignment: .firstTextBaseline, spacing: 6.ui) {
                Text(LimitsText.label(limit.kind)).font(Theme.font(.s)).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 4.ui)
                Text(LimitsText.resetShort(limit.resetsAt, now: now))
                    .font(Theme.font(.xs).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .help(LimitsText.resetLine(limit.resetsAt, now: now))
                Text("\(Int(p.rounded()))%")
                    .font(Theme.font(.m, .semibold).monospacedDigit())
                    .foregroundStyle(limit.runsOutAt(now: now) != nil ? Theme.waiting : p >= 75 ? limitColor(p, service) : Theme.primary)
                    .frame(minWidth: 34.ui, alignment: .trailing)
            }
            LimitBar(percent: p, pace: limit.pace(at: now), color: limitColor(p, service), height: 4.ui)
        }
    }
}

/// "Where it went": per service, the split of the session or the week by project (as points of
/// the official %), the models, and what it would cost at API prices.
struct WhereItWent: View {
    let limits: UsageLimitsStore
    let window: String

    var body: some View {
        Group {
            if let b = limits.breakdown {
                let parts = (window == "week" ? b.byWeek : b.bySession).filter { p in
                    p.service == .claude ? limits.claudeEnabled : limits.codexEnabled
                }
                if parts.isEmpty {
                    note(LimitsText.t("Not available here."))
                } else {
                    ForEach(parts) { UsagePartCard(part: $0, isWeek: window == "week") }
                }
            } else {
                note(LimitsText.t("Reading local logs…"))
            }
        }
        .onAppear { limits.loadBreakdown() }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, minHeight: 60.ui)
    }
}

struct UsagePartCard: View {
    let part: UsagePart
    let isWeek: Bool

    /// With the official % known, a project's share is shown as points of that limit.
    private func value(_ share: Double) -> String {
        let v = share * (part.percent ?? 100)
        return v < 1 ? "<1%" : (part.percent == nil ? "" : "≈ ") + "\(Int(v.rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4.ui) {
            HStack(spacing: 6.ui) {
                Image(systemName: part.service.symbol)
                    .font(.system(size: 9.ui, weight: .bold))
                    .foregroundStyle(part.service.tint)
                Text(part.service.name).font(Theme.font(.m, .semibold)).foregroundStyle(Theme.primary)
                Spacer(minLength: 4.ui)
                if part.service == .claude, part.cost > 0 {
                    Text(LimitsText.dollars(part.cost))
                        .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                        .help(LimitsText.t("What the same usage would cost on the API, at list prices."))
                }
            }
            if part.cost <= 0 {
                Text(LimitsText.t("No usage in this window.")).font(Theme.font(.s)).foregroundStyle(Theme.secondary)
            } else {
                HStack(spacing: 6.ui) {
                    Text(LimitsText.usedTokens(part.percent, part.tokens))
                    if isWeek, let prev = part.previous {
                        let delta = Int(((part.cost / prev - 1) * 100).rounded())
                        Text("· " + LimitsText.versusLastWeek(delta)).foregroundStyle(delta > 15 ? Theme.waiting : Theme.tertiary)
                    }
                }
                .font(Theme.font(.xs).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                ForEach(part.rows(limit: 2), id: \.name) { row in
                    HStack(spacing: 6.ui) {
                        Text(LimitsText.project(row.name))
                            .font(Theme.font(.s)).foregroundStyle(Theme.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: 96.ui, alignment: .leading)
                        LimitBar(percent: row.cost * 100, pace: nil, color: part.service.tint.opacity(0.8), height: 3.ui)
                        Text(value(row.cost))
                            .font(Theme.font(.xs, .semibold).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 36.ui, alignment: .trailing)
                    }
                }
                Text(part.models.filter { $0.cost / part.cost >= 0.005 }.prefix(3).map { "\($0.name) \(Int(($0.cost / part.cost * 100).rounded()))%" }.joined(separator: " · "))
                    .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10.ui)
        .padding(.vertical, 8.ui)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10.ui, style: .continuous).fill(Theme.card))
        .help(LimitsText.t("Estimated from Claude Code's and Codex's local logs, weighted by API price. The official % comes from the CLIs. Nothing leaves your Mac."))
    }
}

// MARK: Peek and wing (closed surface: static, nothing animates)

struct LimitsPeekView: View {
    let text: String
    let service: UsageService
    let percent: Double?

    var body: some View {
        HStack(spacing: 7.ui) {
            Image(systemName: service.symbol)
                .font(.system(size: 9.ui, weight: .bold))
                .foregroundStyle(service.tint)
            Text(text)
                .font(Theme.font(.m, .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360.ui, alignment: .leading)
            if let percent, percent > 0 {
                LimitBar(percent: percent, pace: nil, color: limitColor(percent, service), height: 4.ui)
                    .frame(width: 40.ui)
            }
        }
        .fixedSize()
    }
}

struct LimitsWingLeft: View {
    let service: UsageService

    var body: some View {
        HStack(spacing: 4.ui) {
            Image(systemName: service.symbol)
                .font(.system(size: 9.ui, weight: .bold))
                .foregroundStyle(service.tint)
            Text("100%")
                .font(Theme.font(.s, .semibold).monospacedDigit())
                .foregroundStyle(Theme.failed)
        }
        .fixedSize()
    }
}

struct LimitsWingRight: View {
    let reset: Date

    var body: some View {
        // Static: the time it comes back, never a ticking countdown.
        Text(LimitsText.until(reset, now: .now))
            .font(Theme.font(.s, .medium).monospacedDigit())
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}
