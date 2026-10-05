import AppKit

// Rows computed from the query: a calculation, a unit or currency conversion. ⏎ copies the result.

@MainActor
enum PaletteAnswers {
    static func calculation(_ q: String, decimalComma: Bool, locale: Locale) -> PaletteItem? {
        // A calculation that fails (1/0, sqrt(-1), "3+" mid-typing) shows nothing.
        guard let r = try? Calculator.evaluate(q, decimalComma: decimalComma) else { return nil }
        let display = PaletteFormat.number(r.value, locale: locale)
        let plain = PaletteFormat.number(r.value, locale: locale, grouping: false)
        var title = display, copy = plain
        var subtitle = q.trimmingCharacters(in: .whitespaces)
        let bare = Units.leadingNumber(q, decimalComma: decimalComma)?.1.isEmpty == true
        if bare, !r.usedBaseLiteral {
            // A bare number: show its other forms instead of repeating it.
            let forms = [PaletteFormat.based(r.value, .hex), PaletteFormat.based(r.value, .bin)].compactMap { $0 }
            subtitle = forms.isEmpty ? subtitle : forms.joined(separator: " · ")
        } else if let base = r.base, base != .dec, let b = PaletteFormat.based(r.value, base) {
            title = b; copy = b
            subtitle += " · " + display
        } else if r.usedBaseLiteral || r.base == .dec, let h = PaletteFormat.based(r.value, .hex), let b = PaletteFormat.based(r.value, .bin) {
            subtitle += " · " + h + " · " + b
        }
        let expression = subtitle
        return PaletteItem(id: "calc", title: title, subtitle: expression, icon: .symbol("equal"), tag: CommandText.t("Calculator"),
                           kind: .answer, learns: false, primary: CommandText.t("Copy"),
                           secondary: PaletteAction(title: CommandText.t("Copy expression")) {
                               PaletteActions.copy(q.trimmingCharacters(in: .whitespaces) + " = " + copy)
                           }) {
            PaletteActions.copy(copy)
        }
    }

    static func conversion(_ c: UnitConversion, locale: Locale) -> PaletteItem {
        let value = format(c.result, locale: locale, grouping: true)
        let plain = format(c.result, locale: locale, grouping: false)
        let title = value + " " + c.to.symbol
        let subtitle = format(c.value, locale: locale, grouping: true) + " " + c.from.symbol
        return PaletteItem(id: "units", title: title, subtitle: subtitle, icon: .symbol(symbol(c.to.category)),
                           tag: CommandText.t("Units"), kind: .answer, learns: false, primary: CommandText.t("Copy"),
                           secondary: PaletteAction(title: CommandText.t("Copy with unit")) { PaletteActions.copy(plain + " " + c.to.symbol) }) {
            PaletteActions.copy(plain)
        }
    }

    static func currency(_ c: CurrencyQuery, rates: CurrencyRates, locale: Locale) -> PaletteItem {
        let to = c.target
        let tag = CommandText.t("Currency")
        guard let table = rates.table, let result = table.convert(c.amount, from: c.from, to: to) else {
            let loading = rates.status == .loading
            let title = loading ? CommandText.t("Fetching exchange rates…")
                : rates.table == nil ? CommandText.t("Exchange rates unavailable offline") : L10n.tr(CommandText.t("No rate for %@"), to)
            return PaletteItem(id: "currency", title: title, subtitle: CommandText.t("Euro foreign exchange reference rates (ECB)"),
                               icon: .symbol(loading ? "arrow.triangle.2.circlepath" : "wifi.slash"), tag: tag, kind: .notice,
                               learns: false, primary: "", run: nil)
        }
        let shown = money(result, to, locale: locale)
        let plain = PaletteFormat.number((result * 100).rounded() / 100, locale: locale, grouping: false, fraction: 2)
        var subtitle = money(c.amount, c.from, locale: locale) + " · " + L10n.tr(CommandText.t("ECB rates of %@"), date(table.date, locale: locale))
        if !rates.isFresh, rates.status == .failed { subtitle += " · " + CommandText.t("offline") }
        return PaletteItem(id: "currency", title: shown, subtitle: subtitle, icon: .symbol("arrow.left.arrow.right"), tag: tag,
                           kind: .answer, learns: false, primary: CommandText.t("Copy"),
                           secondary: PaletteAction(title: CommandText.t("Copy with currency")) { PaletteActions.copy(shown) }) {
            PaletteActions.copy(plain)
        }
    }

    // MARK: Formatting

    /// Up to 4 decimals for small numbers, 2 for large, trailing zeros dropped.
    static func format(_ v: Double, locale: Locale, grouping: Bool) -> String {
        let a = abs(v)
        let fraction = a >= 1000 ? 2 : a >= 1 ? 3 : 6
        return PaletteFormat.number(v, locale: locale, grouping: grouping, fraction: fraction)
    }

    static func money(_ v: Double, _ code: String, locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = code
        if abs(v) < 1, v != 0 { f.maximumFractionDigits = 4 }
        return f.string(from: NSNumber(value: v)) ?? "\(v) \(code)"
    }

    /// "2026-10-02" → "2 Oct 2026" / "2 ott 2026".
    static func date(_ iso: String, locale: Locale) -> String {
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f.string(from: d)
    }

    static func symbol(_ c: UnitCategory) -> String {
        switch c {
        case .length: "ruler"
        case .mass: "scalemass"
        case .temperature: "thermometer.medium"
        case .volume: "drop"
        case .speed: "speedometer"
        case .data: "internaldrive"
        case .time: "clock"
        case .area: "square.dashed"
        }
    }
}

// MARK: Built-in commands

@MainActor
enum BuiltinCommands {
    static func items(model: CommandModel) -> [PaletteItem] {
        let glancy = "Glancy"
        var out: [PaletteItem] = [
            PaletteItem(id: "glancy.settings", title: CommandText.t("Glancy Settings"), icon: .symbol("gearshape"), tag: glancy,
                        keywords: ["preferences", "settings", "impostazioni", "preferenze", "options", "opzioni"],
                        closesPanel: false, primary: CommandText.t("Open")) { SurfaceRoute.openSettings?(nil) },
            PaletteItem(id: "glancy.settings.command", title: CommandText.t("Command Bar Settings"), icon: .symbol("command"), tag: glancy,
                        keywords: ["hotkey", "shortcut", "scorciatoia", "launcher", "barra dei comandi"],
                        closesPanel: false, primary: CommandText.t("Open")) { SurfaceRoute.openSettings?(.module(.command)) },
            PaletteItem(id: "glancy.quit", title: CommandText.t("Quit Glancy"), icon: .symbol("power"), tag: glancy,
                        keywords: ["exit", "close", "esci", "chiudi"], primary: CommandText.t("Quit")) { NSApp.terminate(nil) },
            PaletteItem(id: "system.lock", title: CommandText.t("Lock Screen"), icon: .symbol("lock"), tag: CommandText.t("System"),
                        keywords: ["lock", "blocca", "blocca schermo", "lock screen"], primary: CommandText.t("Run")) { PaletteActions.lockScreen() },
            PaletteItem(id: "system.sleep", title: CommandText.t("Sleep"), icon: .symbol("moon"), tag: CommandText.t("System"),
                        keywords: ["sleep", "stop", "sospendi", "metti in stop", "riposo"], primary: CommandText.t("Run")) { PaletteActions.sleep() },
            PaletteItem(id: "system.displaysleep", title: CommandText.t("Turn Off Displays"), icon: .symbol("display"), tag: CommandText.t("System"),
                        keywords: ["display sleep", "screen off", "spegni schermo", "monitor"], primary: CommandText.t("Run")) { PaletteActions.sleepDisplays() },
        ]
        // Every tab on the strip.
        let open = model.openTab
        for m in model.enabledSources() {
            guard let tab = m.tab, !SurfaceContext.hiddenFromStrip.contains(tab.module) else { continue }
            let name = tr(SurfaceContext.name(tab.module))
            let english = SurfaceContext.name(tab.module)
            out.append(PaletteItem(id: "tab." + tab.module.rawValue, title: L10n.tr(CommandText.t("Open %@"), name), icon: .symbol(tab.symbol),
                                   tag: glancy, keywords: [english, name, "tab", "scheda"], closesPanel: false,
                                   primary: CommandText.t("Open")) { open(tab.module) })
        }
        out.append(PaletteItem(id: "tab.home", title: L10n.tr(CommandText.t("Open %@"), tr("Home")), icon: .symbol("house"), tag: glancy,
                               keywords: ["home", "tab"], closesPanel: false, primary: CommandText.t("Open")) { open(nil) })
        return out
    }
}
