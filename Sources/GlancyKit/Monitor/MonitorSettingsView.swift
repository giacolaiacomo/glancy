import SwiftUI

/// Settings → Monitor: the gauge it opens on, apps or processes, sparklines, refresh rate.
struct MonitorSection: View {
    let module: MonitorModule

    var body: some View {
        @Bindable var settings = module.settings
        VStack(alignment: .leading, spacing: 4.ui) {
            SettingsRow(MonitorText.t("Opens on"), note: MonitorText.t("The gauge selected when the tab opens")) {
                NotchSegments(selection: $settings.indicator,
                              options: MonitorIndicator.allCases.map { ($0, MonitorText.t($0.title)) })
            }
            SettingsRow(MonitorText.t("List"), note: MonitorText.t("Apps sum their helpers; processes show each one")) {
                NotchSegments(selection: $settings.grouping,
                              options: [(.apps, MonitorText.t("Apps")), (.processes, MonitorText.t("Processes"))])
            }
            SettingsRow(MonitorText.t("Sparklines"), note: MonitorText.t("The last minute under each gauge")) {
                NotchSwitch(isOn: $settings.sparklines)
            }
            SettingsRow(MonitorText.t("Refresh"), note: MonitorText.t("Only while this tab is open")) {
                NotchSegments(selection: Binding(get: { settings.rate }, set: { settings.rate = $0; module.settingsChanged() }),
                              options: [(.s1, MonitorText.t("1 s")), (.s2, MonitorText.t("2 s"))])
            }
            HStack(alignment: .top) {
                SettingsNote(MonitorText.t("Processes of other users can't be read without administrator rights: their CPU shows as \"System processes\". Quit and Force quit act only on your click; Force quit asks first."))
                Spacer()
                if !settings.isDefault {
                    NotchTextButton(tr("Reset")) { settings.reset(); module.settingsChanged() }
                }
            }
            .padding(.top, 6.ui)
        }
    }
}
