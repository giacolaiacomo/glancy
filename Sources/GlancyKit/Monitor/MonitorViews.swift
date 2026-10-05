import AppKit
import SwiftUI

// The Monitor tab: on the left, the gauges in two columns (one selected); on the right, the top
// five apps or processes for that gauge. Fits the panel's 156 pt page.

private enum Metrics {
    static let gaugesWidth: CGFloat = 304
    static let gap: CGFloat = 5
    static let radius: CGFloat = 11
    static let rowHeight: CGFloat = 22
    static let rows = 5
    static let valueWidth: CGFloat = 62
    static let barWidth: CGFloat = 46
}

private struct Caption: View {
    let text: String
    var color: Color = Theme.tertiary
    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct MonitorTabView: View {
    let module: MonitorModule
    let model: MonitorModel
    let settings: MonitorSettings
    let sampler: MonitorSampler

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GaugeGrid(module: module, model: model, snap: sampler.snapshot, history: sampler.history, sparklines: settings.sparklines)
                .frame(width: Metrics.gaugesWidth)
            TopList(module: module, model: model, snap: sampler.snapshot, network: sampler.history[.network] ?? [])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Gauges

private struct GaugeGrid: View {
    let module: MonitorModule
    let model: MonitorModel
    let snap: MonitorSnapshot
    let history: [MonitorIndicator: [Double]]
    let sparklines: Bool

    var body: some View {
        let list = module.available
        let pairs = stride(from: 0, to: list.count, by: 2).map { Array(list[$0..<min($0 + 2, list.count)]) }
        VStack(spacing: Metrics.gap) {
            ForEach(pairs, id: \.self) { pair in
                HStack(spacing: Metrics.gap) {
                    ForEach(pair, id: \.self) { i in
                        GaugeTile(indicator: i, number: (list.firstIndex(of: i) ?? 0) + 1, selected: model.selected == i,
                                  reading: GaugeReading(i, snap), history: history[i] ?? [], sparklines: sparklines) {
                            module.select(i)
                        }
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// What a tile shows: the figure, the line under it, the sparkline's scale and tint.
struct GaugeReading {
    var value: String
    var detail: String
    /// Sparkline scale: fractions are drawn against 1, rates against their own peak.
    var isFraction: Bool
    var tint: Color = Theme.secondary

    @MainActor init(_ i: MonitorIndicator, _ s: MonitorSnapshot) {
        let dash = "—"
        switch i {
        case .cpu:
            value = s.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? dash
            detail = s.cpuUser.flatMap { u in s.cpuSystem.map { (u, $0) } }.map { u, sys in
                L10n.tr("user %@ · sys %@", "\(Int((u * 100).rounded()))%", "\(Int((sys * 100).rounded()))%")
            } ?? ""
            isFraction = true
            if let c = s.cpu, c >= 0.85 { tint = Theme.waiting }
        case .memory:
            value = s.memory.map { MonitorText.gb($0.used) } ?? dash
            let total = s.memory.map { "\(Int((Double($0.total) / 1_073_741_824).rounded())) GB" } ?? dash
            if s.memory == nil {
                detail = ""
            } else if let sw = s.swap, sw.used > 0 {
                detail = L10n.tr("of %@ · swap %@", total, MonitorText.bytes(sw.used))
            } else {
                detail = L10n.tr("of %@", total)
            }
            isFraction = true
            switch s.memory?.pressure ?? 1 {
            case 4...: tint = Theme.failed; detail = MonitorText.t("Pressure critical")
            case 2...: tint = Theme.waiting; detail = MonitorText.t("Pressure high")
            default: break
            }
        case .gpu:
            value = s.gpu.map { "\(Int(($0 * 100).rounded()))%" } ?? dash
            detail = s.gpu == nil ? "" : MonitorText.t("Utilisation")
            isFraction = true
        case .disk:
            value = s.disk.map { L10n.tr("%@ free", MonitorText.disk($0.free)) } ?? dash
            detail = s.diskRead.map { L10n.tr("R %@ · W %@", MonitorText.rate($0), MonitorText.rate(s.diskWrite ?? 0)) } ?? ""
            isFraction = false
        case .network:
            // The figure and the sparkline are the same thing: down + up.
            value = s.down.map { MonitorText.rate($0 + (s.up ?? 0)) } ?? dash
            detail = s.down.map { "↓ " + MonitorText.rate($0) + " · ↑ " + MonitorText.rate(s.up ?? 0) } ?? ""
            isFraction = false
        case .energy:
            value = s.power.map { MonitorText.watts($0.watts) } ?? MonitorText.thermal(s.thermal)
            let source = s.power.map { $0.onBattery ? MonitorText.t("On battery") : MonitorText.t("From the adapter") }
            detail = [source, s.power == nil ? nil : MonitorText.thermal(s.thermal)].compactMap { $0 }.joined(separator: " · ")
            isFraction = false
            if s.thermal >= 3 { tint = Theme.failed } else if s.thermal == 2 { tint = Theme.waiting }
        }
    }
}

private struct GaugeTile: View {
    let indicator: MonitorIndicator
    let number: Int
    let selected: Bool
    let reading: GaugeReading
    let history: [Double]
    let sparklines: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: indicator.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(selected ? Theme.primary : Theme.tertiary)
                        .frame(width: 12)
                    Caption(text: MonitorText.t(indicator.title), color: selected ? Theme.secondary : Theme.tertiary)
                    Spacer(minLength: 4)
                    Text(verbatim: reading.value)
                        .font(Theme.font(.m, .semibold)).monospacedDigit()
                        .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(verbatim: reading.detail)
                    .font(Theme.font(.xs)).monospacedDigit()
                    .foregroundStyle(reading.tint == Theme.secondary ? Theme.tertiary : reading.tint)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if sparklines {
                    Sparkline(values: history, isFraction: reading.isFraction,
                              color: reading.tint == Theme.secondary ? (selected ? Theme.primary : Theme.tertiary) : reading.tint)
                        .frame(height: 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .fill(selected ? Theme.hairline : hover ? Theme.card.opacity(1.6) : Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .strokeBorder(selected ? Theme.tertiary.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(MonitorText.t(indicator.title)) · \(number)")
        .accessibilityLabel(MonitorText.t(indicator.title))
        .accessibilityValue(reading.value)
    }
}

/// The last minute as a line with a faint fill. Fractions against 1, rates against their peak.
struct Sparkline: View {
    let values: [Double]
    let isFraction: Bool
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                Rectangle().fill(Theme.hairline.opacity(0.6)).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                if pts.count >= 2 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for q in pts { p.addLine(to: q) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.18))
                    Path { p in
                        p.move(to: pts[0])
                        for q in pts.dropFirst() { p.addLine(to: q) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// Right-aligned: the newest value at the right edge, one step per sample of the last minute.
    private func points(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let peak = isFraction ? 1 : max(values.max() ?? 0, 1)
        let step = size.width / CGFloat(MonitorSampler.historyLength - 1)
        let start = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let f = CGFloat(min(1, max(0, v / peak)))
            return CGPoint(x: start + CGFloat(i) * step, y: size.height - 1 - f * (size.height - 2))
        }
    }
}

// MARK: - Top five

private struct TopList: View {
    let module: MonitorModule
    let model: MonitorModel
    let snap: MonitorSnapshot
    let network: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let c = model.confirm {
                ConfirmCard(module: module, confirm: c)
            } else if model.selected == .network {
                NetworkPanel(snap: snap, history: network)
            } else {
                rows
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).fill(Theme.card))
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let note = model.note {
                Text(verbatim: note).font(Theme.font(.xs, .medium)).foregroundStyle(Theme.waiting).lineLimit(1)
            } else {
                Caption(text: MonitorText.header(model.selected))
                    .help(model.selected == .energy ? MonitorText.t("The kernel's estimate of the energy each process spent on the CPU.")
                          : model.selected == .gpu ? MonitorText.t("Each app's share of the GPU's time.") : "")
            }
            if model.selected == .cpu, model.note == nil, !snap.cores.isEmpty {
                CoreBars(cores: snap.cores)
            }
            Spacer(minLength: 4)
            if model.selected != .network {
                MiniSegments(selection: Binding(get: { model.grouping }, set: { model.grouping = $0 }),
                             options: [(.apps, MonitorText.t("Apps")), (.processes, MonitorText.t("Processes"))])
            }
            Button { module.openActivityMonitor() } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(MonitorText.t("Open Activity Monitor"))
        }
        .frame(height: 18)
    }

    @ViewBuilder private var rows: some View {
        let i = model.selected
        let top = MonitorRanking.top(snap.rows(model.grouping), by: i, limit: Metrics.rows)
        let peak = top.first?.value(i) ?? 0
        VStack(spacing: 0) {
            ForEach(0..<Metrics.rows, id: \.self) { n in
                if n < top.count {
                    ProcessRowView(module: module, row: top[n], indicator: i, fraction: peak > 0 ? top[n].value(i) / peak : 0)
                } else if n == 0 {
                    Text(verbatim: module.sampler.samples < 2 && i != .memory ? MonitorText.t("Measuring…") : MonitorText.t("Nothing busy"))
                        .font(Theme.font(.s)).foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                } else {
                    Color.clear.frame(height: Metrics.rowHeight)
                }
            }
        }
    }
}

private struct ProcessRowView: View {
    let module: MonitorModule
    let row: MonitorRow
    let indicator: MonitorIndicator
    let fraction: Double
    @State private var hover = false

    var body: some View {
        let actionable = !row.isRemainder && MonitorTarget(row).isActionable
        HStack(spacing: 7) {
            RowIcon(row: row)
            Text(verbatim: MonitorText.rowName(row))
                .font(Theme.font(.s, .medium))
                .foregroundStyle(row.isRemainder ? Theme.secondary : Theme.primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hover, actionable {
                HStack(spacing: 2) {
                    RowButton(symbol: "xmark.circle", help: MonitorText.t("Quit")) { module.quit(row) }
                    RowButton(symbol: "exclamationmark.octagon", help: MonitorText.t("Force Quit…")) { module.askForceQuit(row) }
                    if row.bundlePath ?? row.path != nil {
                        RowButton(symbol: "folder", help: MonitorText.t("Reveal in Finder")) { module.reveal(row) }
                    }
                }
                .frame(width: Metrics.barWidth + 8, alignment: .trailing)
            } else {
                Bar(fraction: fraction)
                    .frame(width: Metrics.barWidth, height: 3)
                    .padding(.leading, 8)
            }
            Text(verbatim: MonitorText.value(row, indicator))
                .font(Theme.font(.s, .medium)).monospacedDigit()
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .frame(width: Metrics.valueWidth, alignment: .trailing)
        }
        .frame(height: Metrics.rowHeight)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Theme.card : .clear))
        .padding(.horizontal, -4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(row.isRemainder ? MonitorText.t("Other users' processes (root daemons, WindowServer): their CPU, measured as what's left.") : "")
        .contextMenu {
            if actionable {
                Button(MonitorText.t("Quit")) { module.quit(row) }
                Button(MonitorText.t("Force Quit…")) { module.askForceQuit(row) }
                if row.bundlePath ?? row.path != nil {
                    Button(MonitorText.t("Reveal in Finder")) { module.reveal(row) }
                }
                Divider()
            }
            Button(MonitorText.t("Open Activity Monitor")) { module.openActivityMonitor() }
        }
    }
}

private struct RowIcon: View {
    let row: MonitorRow
    var body: some View {
        Group {
            if let image = MonitorIcons.icon(row.bundlePath) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: row.isRemainder ? "gearshape.2" : "terminal")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.card))
            }
        }
        .frame(width: 16, height: 16)
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hover ? Theme.primary : Theme.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct Bar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(Theme.secondary).frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
    }
}

/// One small bar per core, filled to its load.
private struct CoreBars: View {
    let cores: [Double]
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(cores.indices, id: \.self) { i in
                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.hairline)
                    Capsule().fill(cores[i] >= 0.85 ? Theme.waiting : Theme.secondary)
                        .frame(height: max(1.5, 11 * min(1, max(0, cores[i]))))
                }
                .frame(width: 3, height: 11)
            }
        }
        .help(cores.enumerated().map { "\($0.offset + 1): \(Int(($0.element * 100).rounded()))%" }.joined(separator: "  "))
    }
}

/// A smaller `NotchSegments` for the list's header.
private struct MiniSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let on = value == selection
                Button { selection = value } label: {
                    Text(verbatim: label)
                        .font(Theme.font(.xs, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Theme.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(Capsule().fill(on ? Theme.primary : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1.5)
        .background(Capsule().fill(Theme.card))
        .animation(Theme.peek, value: selection)
    }
}

private struct NetworkPanel: View {
    let snap: MonitorSnapshot
    let history: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                figure("arrow.down", MonitorText.t("Download"), snap.down)
                figure("arrow.up", MonitorText.t("Upload"), snap.up)
            }
            .padding(.top, 4)
            Sparkline(values: history, isFraction: false, color: Theme.secondary)
                .frame(maxHeight: .infinity)
            Text(verbatim: MonitorText.t("Per-app network use needs a private macOS API: the Mac's total is shown."))
                .font(Theme.font(.xs)).foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func figure(_ symbol: String, _ label: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                Caption(text: label)
            }
            .foregroundStyle(Theme.tertiary)
            Text(verbatim: v.map(MonitorText.rate) ?? "—")
                .font(Theme.font(.xl, .semibold)).monospacedDigit()
                .foregroundStyle(Theme.primary)
        }
    }
}

private struct ConfirmCard: View {
    let module: MonitorModule
    let confirm: MonitorConfirm

    var body: some View {
        let (target, text, button): (MonitorTarget, String, String) = switch confirm {
        case .forceQuit(let t): (t, L10n.tr("Force quit %@? Unsaved changes are lost.", t.name), MonitorText.t("Force quit"))
        case .quitProcess(let t): (t, L10n.tr("Quit %@? It's not an app: it gets a terminate signal.", t.name), MonitorText.t("Quit"))
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RowIcon(row: MonitorRow(id: "confirm", name: target.name, bundlePath: target.bundlePath))
                    .scaleEffect(1.25)
                    .frame(width: 20, height: 20)
                Text(verbatim: text)
                    .font(Theme.font(.s, .medium)).foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            HStack(spacing: 8) {
                Spacer()
                pill(MonitorText.t("Cancel"), fill: Theme.card, ink: Theme.secondary) { module.cancelConfirm() }
                pill(button, fill: Theme.failed, ink: Theme.primary) { module.confirmAction() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func pill(_ title: String, fill: Color, ink: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(Theme.font(.s, .semibold)).foregroundStyle(ink)
                .padding(.horizontal, 12).frame(height: 24)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
