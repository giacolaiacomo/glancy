import Foundation

// The Control module in the command bar: one command per toggle and tool (EN + IT keywords), plus
// typed results ("awake 2h", "#ff8800").

extension ControlModule {
    static let keywords: [ControlTile: [String]] = [
        .keepAwake: ["caffeinate", "caffeine", "awake", "keep awake", "no sleep", "amphetamine", "insomnia",
                     "tieni sveglio", "sveglio", "caffè", "non dormire", "stop sleep"],
        .darkMode: ["dark mode", "light mode", "appearance", "theme", "night",
                    "modalità scura", "modalità chiara", "tema", "aspetto", "scuro", "chiaro"],
        .wifi: ["wifi", "wi-fi", "wireless", "network", "airport", "rete", "senza fili"],
        .desktopIcons: ["desktop", "icons", "hide desktop", "clean desktop", "presentation",
                        "scrivania", "icone", "nascondi scrivania", "presentazione"],
        .hiddenFiles: ["hidden files", "dotfiles", "show hidden", "invisible files", "file nascosti", "mostra nascosti"],
        .lock: ["lock", "lock screen", "blocca", "blocca schermo", "bloccare"],
        .displaySleep: ["display off", "sleep display", "screen off", "turn off display", "monitor",
                        "spegni schermo", "schermo spento", "display spento"],
        .screenSaver: ["screensaver", "screen saver", "salvaschermo"],
        .screenshot: ["screenshot", "capture", "screen capture", "snip", "cattura", "schermata", "istantanea"],
        .colorPicker: ["color picker", "colour picker", "eyedropper", "picker", "pick color", "hex",
                       "contagocce", "colore", "selettore colore"],
        .mirror: ["mirror", "camera", "webcam", "selfie", "check hair", "specchio", "fotocamera", "videocamera"],
        .emptyTrash: ["empty trash", "trash", "bin", "svuota cestino", "cestino", "svuota"],
        .eject: ["eject", "unmount", "disks", "drives", "usb", "espelli", "dischi", "smonta"],
    ]

    public func commands() -> [GlancyCommand] {
        refreshStates()
        var out: [GlancyCommand] = []
        for tile in ControlTile.allCases {
            out.append(command(for: tile))
        }
        // Keep awake with a length, so "awake" offers every choice.
        for d in AwakeDuration.allCases {
            out.append(GlancyCommand(id: "control.keepAwake.\(d.rawValue)", module: .control,
                                     title: ControlText.awakeFor(d), symbol: "cup.and.saucer.fill",
                                     keywords: Self.keywords[.keepAwake] ?? [], rank: 0, closesPanel: true) { [weak self] in
                self?.startAwake(d)
            })
        }
        out.append(GlancyCommand(id: "control.screenshot.desktop", module: .control, title: ControlText.t("Screenshot to Desktop"),
                                 symbol: "camera.viewfinder", keywords: Self.keywords[.screenshot] ?? [], closesPanel: true) { [weak self] in
            self?.screenshot(.desktop)
        })
        return out
    }

    private func command(for tile: ControlTile) -> GlancyCommand {
        let title: String
        var subtitle: String?
        var closes = true
        switch tile {
        case .keepAwake:
            title = model.awake.isOn ? ControlText.t("Stop keeping awake") : ControlText.t("Keep awake")
            subtitle = model.awake.isOn ? ControlText.awakeState(model.awake) : ControlText.awakeFor(settings.awakeDefault)
        case .darkMode:
            title = model.darkMode ? ControlText.t("Turn Dark mode off") : ControlText.t("Turn Dark mode on")
            closes = false
        case .wifi:
            title = model.wifi == true ? ControlText.t("Turn Wi-Fi off") : ControlText.t("Turn Wi-Fi on")
            closes = false
        case .desktopIcons:
            title = model.desktopIconsHidden ? ControlText.t("Show desktop icons") : ControlText.t("Hide desktop icons")
            subtitle = ControlText.t("Finder restarts")
            closes = false
        case .hiddenFiles:
            title = model.hiddenFilesShown ? ControlText.t("Hide hidden files") : ControlText.t("Show hidden files")
            subtitle = ControlText.t("Finder restarts")
            closes = false
        case .lock: title = ControlText.t("Lock screen")
        case .displaySleep: title = ControlText.t("Turn display off")
        case .screenSaver: title = ControlText.t("Start screen saver")
        case .screenshot: title = ControlText.t("Screenshot an area")
            subtitle = settings.screenshotTarget == .desktop ? ControlText.t("To the Desktop") : ControlText.t("To the clipboard")
        case .colorPicker: title = ControlText.t("Pick a color")
            subtitle = ControlText.t("Copies the HEX")
        case .mirror: title = ControlText.t("Camera mirror")
            closes = false
        case .emptyTrash: title = ControlText.t("Empty Trash")
            closes = false
        case .eject: title = ControlText.t("Eject all disks")
            subtitle = model.ejectable.isEmpty ? ControlText.t("Nothing to eject") : model.ejectable.joined(separator: ", ")
        }
        return GlancyCommand(id: "control.\(tile.rawValue)", module: .control, title: title, subtitle: subtitle,
                             symbol: tile.symbol, keywords: [ControlText.t(tile.title), tile.title] + (Self.keywords[tile] ?? []),
                             rank: 0, closesPanel: closes) { [weak self] in
            guard let self else { return }
            // From the bar, the Control tab carries the confirmation or the mirror.
            switch tile {
            case .desktopIcons, .hiddenFiles, .mirror, .emptyTrash:
                hub?.requestOpen(.control)
                Task { @MainActor [weak self] in self?.toggle(tile) }
            default:
                toggle(tile)
            }
        }
    }

    public func results(for query: String) -> [GlancyCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [] }
        if let rgb = ControlQuery.color(q) {
            return [
                GlancyCommand(id: "control.color.\(rgb.hex)", module: .control, title: rgb.hex,
                              subtitle: rgb.rgbString + " · " + ControlText.t("Copy HEX"), symbol: "paintpalette.fill",
                              keywords: [], rank: 90, closesPanel: true) { [weak self] in self?.picked(rgb) },
                GlancyCommand(id: "control.color.rgb.\(rgb.hex)", module: .control, title: rgb.rgbString,
                              subtitle: ControlText.t("Copy RGB"), symbol: "paintpalette",
                              keywords: [], rank: 85, closesPanel: true) { [weak self] in
                    self?.picked(rgb)
                    self?.actions.copy(rgb.rgbString)
                },
            ]
        }
        if let wanted = ControlQuery.awake(q) {
            let seconds = wanted
            let preset = AwakeDuration.allCases.first { $0.seconds == seconds }
            let title = seconds.map { ControlText.awakeFor(seconds: $0) } ?? ControlText.awakeFor(.forever)
            return [GlancyCommand(id: "control.keepAwake.custom", module: .control, title: title,
                                  subtitle: seconds.map { ControlText.until(Date.now.addingTimeInterval($0)) },
                                  symbol: "cup.and.saucer.fill", keywords: [], rank: 95, closesPanel: true) { [weak self] in
                self?.startAwake(seconds: seconds, duration: preset)
            }]
        }
        return []
    }
}
