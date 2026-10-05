import Foundation

// The Monitor in the command bar: open it (on CPU or memory), Activity Monitor; typed "cpu" / "ram"
// lists the top three apps; a running app's name offers Quit and Force quit (which asks first, in
// the Monitor tab).

extension MonitorModule {
    static let openKeywords = ["monitor", "system monitor", "activity", "task manager", "processes", "top", "usage", "load",
                               "monitor di sistema", "attività", "gestione attività", "processi", "utilizzo", "carico"]
    static let cpuWords: Set<String> = ["cpu", "top cpu", "processor", "processore"]
    static let memoryWords: Set<String> = ["ram", "memory", "memoria", "top memory", "top ram", "mem"]

    public func commands() -> [GlancyCommand] {
        // Baseline for typed "cpu", off the main thread: the next scan (a moment later) has rates.
        warmBar()
        return [
            GlancyCommand(id: "monitor.open", module: .monitor, title: MonitorText.t("System monitor"), symbol: "gauge.with.dots.needle.67percent",
                          keywords: Self.openKeywords + ["cpu", "ram", "memoria", "memory", "gpu"], closesPanel: false) { [weak self] in
                self?.open(on: nil)
            },
            GlancyCommand(id: "monitor.topCPU", module: .monitor, title: MonitorText.t("Top CPU"), subtitle: MonitorText.t("What's using the processor"),
                          symbol: "cpu", keywords: ["cpu", "processor", "processore", "top", "slow", "lento", "hot", "caldo", "fan", "ventola"],
                          closesPanel: false) { [weak self] in
                self?.open(on: .cpu)
            },
            GlancyCommand(id: "monitor.topMemory", module: .monitor, title: MonitorText.t("Top memory"), subtitle: MonitorText.t("What's using the RAM"),
                          symbol: "memorychip", keywords: ["ram", "memory", "memoria", "top", "swap"], closesPanel: false) { [weak self] in
                self?.open(on: .memory)
            },
            GlancyCommand(id: "monitor.activityMonitor", module: .monitor, title: MonitorText.t("Open Activity Monitor"),
                          symbol: "waveform.path.ecg", keywords: ["activity monitor", "monitoraggio attività", "task manager", "processes", "processi"]) { [weak self] in
                self?.openActivityMonitor()
            },
        ]
    }

    public func results(for query: String) -> [GlancyCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 3 else { return [] }
        if Self.cpuWords.contains(q) { return top(.cpu) }
        if Self.memoryWords.contains(q) { return top(.memory) }
        let apps = actions.runningApps(matching: q).prefix(2)
        guard !apps.isEmpty else { return [] }
        let rows = barApps()
        var out: [GlancyCommand] = []
        for t in apps {
            let row = rows.first { $0.bundlePath != nil && $0.bundlePath == t.bundlePath }
            let detail = row.map { MonitorText.usage($0, cpu: barHasRates) }
            let target = MonitorTarget(name: t.name, bundlePath: t.bundlePath, path: t.path, pids: row?.pids ?? t.pids)
            out.append(GlancyCommand(id: "monitor.quit.\(t.bundlePath ?? t.name)", module: .monitor, title: L10n.tr("Quit %@", t.name),
                                     subtitle: detail, symbol: "xmark.circle", keywords: [], rank: 50) { [weak self] in
                _ = self?.actions.quit(target)
            })
            out.append(GlancyCommand(id: "monitor.forceQuit.\(t.bundlePath ?? t.name)", module: .monitor,
                                     title: L10n.tr("Force quit %@…", t.name), subtitle: MonitorText.t("Asks first, in the Monitor tab"),
                                     symbol: "exclamationmark.octagon", keywords: [], rank: 45, closesPanel: false) { [weak self] in
                self?.open(on: nil, confirm: .forceQuit(target))
            })
        }
        return out
    }

    /// The three biggest apps for "cpu" / "ram". CPU needs two scans: the bar's first one is taken
    /// when it opens, so by the time "cpu" is typed there are rates.
    private func top(_ i: MonitorIndicator) -> [GlancyCommand] {
        // CPU needs a rate: rescan now when the cached scan has none yet.
        var rows = barApps(maxAge: i == .cpu ? (barHasRates ? 250_000_000 : 0) : 500_000_000)
        if i == .cpu, !barHasRates { rows = barApps(maxAge: 0) }   // typed before the warm-up landed
        let ranked = MonitorRanking.top(rows, by: i, limit: 3)
        return ranked.enumerated().map { n, row in
            GlancyCommand(id: "monitor.top.\(i.rawValue).\(n)", module: .monitor, title: MonitorText.rowName(row),
                          subtitle: MonitorText.usage(row, cpu: i == .cpu || barHasRates), symbol: i.symbol,
                          keywords: [], rank: 90 - n, closesPanel: false) { [weak self] in
                self?.open(on: i)
            }
        }
    }

    /// Opens the panel on the Monitor tab, on a gauge and, for a force quit from the bar, with the
    /// question already asked.
    func open(on i: MonitorIndicator?, confirm: MonitorConfirm? = nil) {
        pending = (i, confirm)
        if tabVisible { applyPending() } else { hub?.requestOpen(.monitor) }
    }
}
