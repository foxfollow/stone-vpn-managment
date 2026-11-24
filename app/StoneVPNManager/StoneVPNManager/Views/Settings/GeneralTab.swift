import SwiftUI
import StoneVPNCore

struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var autoUpdates = Updater.shared.automaticallyChecks
    @State private var language = AppLanguage.override
    @State private var languageChanged = false

    var body: some View {
        Form {
            Section("Language") {
                Picker("Interface Language", selection: $language) {
                    Text("Same as System").tag("")
                    ForEach(AppLanguage.available, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
                .onChange(of: language) {
                    AppLanguage.setOverride(language)
                    languageChanged = true
                }
                .settingsAnchor("general.language")
                if languageChanged {
                    HStack {
                        Text("The new language applies after a restart.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                }
            }
            Section("Updates") {
                LabeledContent("Version") { Text(verbatim: Updater.shared.version).textSelection(.enabled) }
                if Updater.shared.enabled {
                    Toggle("Automatically Check for Updates", isOn: $autoUpdates)
                        .onChange(of: autoUpdates) { Updater.shared.automaticallyChecks = autoUpdates }
                        .settingsAnchor("general.updates")
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                } else {
                    Text("A build from source — update it with git pull and make -C app install. Automatic updates come with releases (Homebrew / GitHub Releases).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .settingsAnchor("general.launchAtLogin")
                Toggle("Show in Cmd+Tab While a Window Is Open", isOn: $model.prefs.showInAppSwitcher)
                    .settingsAnchor("general.cmdTab")
                Text("Profiles, Settings, Connect. macOS only lists apps with a Dock icon in Cmd+Tab, so the icon appears meanwhile and goes away when you close the last window.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Menu Bar Icon") {
                Toggle("Coloured Icon", isOn: $model.prefs.iconColored)
                    .settingsAnchor("general.iconColored")
                Text("Off — a monochrome template; only the shape shows the state (outline / filled / “!” / dot).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Show the Number of Tunnels", isOn: $model.prefs.iconShowCount)
                    .settingsAnchor("general.iconCount")
                Toggle("Show the Active Tunnel’s Name", isOn: $model.prefs.iconShowName)
                    .settingsAnchor("general.iconName")
            }
            Section("Status Updates") {
                Picker("In the Background", selection: $model.prefs.backgroundInterval) {
                    Text("every 10 s").tag(10)
                    Text("every 30 s").tag(30)
                    Text("every minute").tag(60)
                    Text("every 5 min").tag(300)
                }
                .settingsAnchor("general.refresh")
                Text("Network changes (SystemConfiguration) update the status instantly; while the popover is open — every 3 s.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
