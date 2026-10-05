import Foundation

// The Agents entries in the command bar: open the board, go to the session that needs you, lay
// out the sessions; and, for what is typed, every session of every source matched by project,
// title, prompt, agent or app → bring it forward.

extension AgentsModule {
    public func commands() -> [GlancyCommand] {
        var out: [GlancyCommand] = []
        out.append(GlancyCommand(
            id: "agents.show", module: .agents, title: AgentsText.t("Show agent sessions"),
            subtitle: AgentsText.live(model.dots.count), symbol: Self.symbol,
            keywords: ["agents", "sessions", "claude", "codex", "opencode", "agenti", "sessioni"],
            closesPanel: false, run: { [weak self] in self?.model.hub?.requestOpen(.agents) }))
        if let s = model.highlights(limit: 1).first, s.state == .waiting {
            out.append(GlancyCommand(
                id: "agents.needsYou", module: .agents, title: AgentsText.needsYou([s.label]),
                subtitle: Self.subtitle(s), symbol: "exclamationmark.bubble",
                keywords: ["waiting", "permission", "needs", "attesa", "permesso"], rank: 20,
                run: { [weak self] in self?.model.jump(to: s.rowID) }))
        }
        if model.tilingAvailability == .ready, !model.dots.isEmpty {
            out.append(GlancyCommand(
                id: "agents.layOut", module: .agents, title: AgentsText.t("Lay out sessions"), symbol: "rectangle.split.2x2",
                keywords: ["tile", "terminals", "arrange", "affianca", "disponi"], closesPanel: false,
                run: { [weak self] in
                    self?.model.hub?.requestOpen(.agents)
                    self?.model.layOutSessions()
                }))
        }
        return out
    }

    public func results(for query: String) -> [GlancyCommand] {
        AgentsSearch.match(model.sessions, query: query).map { hit in
            let s = hit.session
            return GlancyCommand(
                id: "agents.session.\(s.rowID)", module: .agents, title: s.label,
                subtitle: Self.subtitle(s), symbol: s.agent.symbol, rank: hit.score,
                run: { [weak self] in self?.model.jump(to: s.rowID) })
        }
    }

    /// "Codex · VS Code · waiting · Fix the login test".
    static func subtitle(_ s: AgentSession) -> String {
        var parts = [s.agent.name]
        if let h = s.host, h.kind != .unknown { parts.append(h.name) }
        parts.append(AgentsText.state(s.state))
        let text = AgentRow.text(s)
        if !text.isEmpty { parts.append(String(text.prefix(60))) }
        return parts.joined(separator: " · ")
    }
}

/// Session search for the command bar. Pure; under a millisecond for the capped boards.
enum AgentsSearch {
    struct Hit {
        let session: AgentSession
        let score: Int
    }

    static func match(_ sessions: [AgentSession], query raw: String) -> [Hit] {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var hits: [Hit] = []
        for s in sessions {
            let label = s.label.lowercased()
            var score = 0
            if label.hasPrefix(q) { score = 100 }
            else if label.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { score = 90 }
            else if label.contains(q) { score = 80 }
            else if [s.title, s.lastPrompt, s.lastMessage].contains(where: { $0?.lowercased().contains(q) ?? false }) { score = 70 }
            else if s.projectPath.lowercased().contains(q) { score = 60 }
            else if s.agent.name.lowercased().hasPrefix(q) || (s.host?.name.lowercased().hasPrefix(q) ?? false) { score = 50 }
            guard score > 0 else { continue }
            // What needs you ranks first among equals; ended rows last.
            score += s.state == .waiting ? 5 : s.state == .working ? 3 : s.state == .ended ? -10 : 0
            hits.append(Hit(session: s, score: score))
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : AgentSession.attentionOrder($0.session, $1.session) }
            .prefix(8))
    }
}
