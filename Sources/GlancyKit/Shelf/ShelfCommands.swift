import AppKit

// The Shelf in the command bar: fixed actions, and the items whose names match what was typed.

extension ShelfModule {
    public func commands() -> [GlancyCommand] {
        var out: [GlancyCommand] = [
            GlancyCommand(id: "shelf.open", module: .shelf, title: L10n.tr("Open Shelf"), symbol: "tray",
                          keywords: ["shelf", "files", "ripiano", "file"], closesPanel: false) { [weak self] in
                self?.openShelfTab()
            },
        ]
        let items = model.items
        if !items.isEmpty {
            out.append(GlancyCommand(id: "shelf.clear", module: .shelf, title: L10n.tr("Clear Shelf"),
                                     subtitle: ShelfText.count(items.count), symbol: "trash",
                                     keywords: ["clear", "empty", "remove", "svuota", "rimuovi"], closesPanel: false) { [weak self] in
                self?.clear()
            })
            if let last = items.first {
                out.append(GlancyCommand(id: "shelf.airdropLast", module: .shelf, title: L10n.tr("AirDrop Last Shelf Item"),
                                         subtitle: last.name, symbol: "dot.radiowaves.left.and.right",
                                         keywords: ["airdrop", "send", "invia", "share", "condividi"]) { [weak self] in
                    self?.airDrop([last])
                })
            }
            out.append(GlancyCommand(id: "shelf.zipAll", module: .shelf, title: L10n.tr("Zip Shelf"),
                                     subtitle: ShelfText.count(items.count), symbol: "doc.zipper",
                                     keywords: ["zip", "compress", "archive", "comprimi", "archivio"], closesPanel: false) { [weak self] in
                guard let self else { return }
                self.openShelfTab()
                self.zip(self.model.items)
            })
        }
        out.append(GlancyCommand(id: "shelf.lastScreenshot", module: .shelf, title: L10n.tr("Show Last Screenshot"),
                                 subtitle: model.lastScreenshot?.lastPathComponent, symbol: "camera.viewfinder",
                                 keywords: ["screenshot", "capture", "istantanea", "schermata"]) { [weak self] in
            self?.showLastScreenshot()
        })
        out.append(GlancyCommand(id: "shelf.lastDownload", module: .shelf, title: L10n.tr("Show Last Download"),
                                 subtitle: model.lastDownloads.last?.lastPathComponent, symbol: "arrow.down.circle",
                                 keywords: ["download", "downloads", "scaricato", "scaricati", "scarica"]) { [weak self] in
            self?.showLastDownload()
        })
        return out
    }

    /// Shelf items whose name contains the query (case and accent insensitive). Running one opens
    /// the Shelf with that item selected.
    public func results(for query: String) -> [GlancyCommand] {
        ShelfSearch.matches(query, in: model.items).prefix(6).map { match in
            let item = match.item
            return GlancyCommand(id: "shelf.item.\(item.id.uuidString)", module: .shelf, title: item.name,
                                 subtitle: L10n.tr("On the shelf"), symbol: "doc", rank: match.rank, closesPanel: false) { [weak self] in
                guard let self, self.model.items.contains(where: { $0.id == item.id }) else { return }
                self.model.selection = [item.id]
                self.openShelfTab()
            }
        }
    }
}

public enum ShelfSearch {
    public struct Match { public let item: ShelfItem; public let rank: Int }

    /// Prefix matches (of the name or of a word in it) rank above plain substring matches; the
    /// shelf's own order (newest first) breaks ties. Empty / one-letter queries match nothing.
    public static func matches(_ query: String, in items: [ShelfItem]) -> [Match] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= 2 else { return [] }
        var out: [Match] = []
        for item in items {
            let name = fold(item.name)
            guard let range = name.range(of: q) else { continue }
            let rank: Int
            if range.lowerBound == name.startIndex {
                rank = 80
            } else if let before = name[..<range.lowerBound].last, !before.isLetter && !before.isNumber {
                rank = 70
            } else {
                rank = 55
            }
            out.append(Match(item: item, rank: rank))
        }
        return out.enumerated().sorted { a, b in
            a.element.rank != b.element.rank ? a.element.rank > b.element.rank : a.offset < b.offset
        }.map(\.element)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
