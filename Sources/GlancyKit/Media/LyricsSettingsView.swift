import SwiftUI

/// Settings → Media: the lyrics switches, what they cost, and what leaves the Mac.
struct LyricsSettingsRows: View {
    let module: MediaModule
    @State private var cached: Int?

    var body: some View {
        @Bindable var settings = module.lyrics.settings
        VStack(alignment: .leading, spacing: SettingsStyle.rowSpacing) {
            SettingsGroupTitle(L10n.tr("Lyrics"))
                .padding(.top, 8)
            SettingsRow(L10n.tr("Lyrics in the Media tab"), note: L10n.tr("Track names go to lrclib.net, once per song")) {
                NotchSwitch(isOn: Binding(get: { settings.tabEnabled },
                                          set: { settings.tabEnabled = $0; module.lyricsSettingsChanged() }))
            }
            SettingsRow(L10n.tr("Lyrics in the wing"), note: L10n.tr("The sung line beside the notch, while playing")) {
                NotchSwitch(isOn: Binding(get: { settings.wingEnabled },
                                          set: { settings.wingEnabled = $0; module.lyricsSettingsChanged() }))
            }
            if settings.wingEnabled {
                SettingsNote(L10n.tr("Wakes Glancy once per line while music plays (a few times a minute): a small CPU cost. Nothing runs when paused."))
            }
            SettingsNote(L10n.tr("Title, artist, album and length of the playing track are sent to lrclib.net to find its lyrics, once per track. Nothing else leaves your Mac."),
                         color: settings.anyEnabled ? SettingsStyle.secondary : SettingsStyle.tertiary)
            SettingsRow(L10n.tr("Lyrics cache"), note: cached.map { L10n.tr("%d songs on this Mac", $0) }) {
                NotchTextButton(L10n.tr("Clear")) {
                    Task {
                        await module.lyrics.clearCache()
                        cached = 0
                    }
                }
            }
        }
        .task { cached = await module.lyrics.cachedCount() }
    }
}
