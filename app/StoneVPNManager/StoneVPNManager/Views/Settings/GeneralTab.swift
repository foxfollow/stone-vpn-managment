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
                if languageChanged {
                    HStack {
                        Text("The new language applies after a restart.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                }
            }
            Section("Version \(Updater.shared.version)") {
                if Updater.shared.enabled {
                    Toggle("Automatically Check for Updates", isOn: $autoUpdates)
                        .onChange(of: autoUpdates) { Updater.shared.automaticallyChecks = autoUpdates }
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                } else {
                    Text("A build from source — update it with git pull and make -C app install. Automatic updates come with releases (Homebrew / GitHub Releases).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Show in Cmd+Tab While a Window Is Open", isOn: $model.prefs.showInAppSwitcher)
                Text("Profiles, Settings, Connect. macOS only lists apps with a Dock icon in Cmd+Tab, so the icon appears meanwhile and goes away when you close the last window.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Menu Bar Icon") {
                Toggle("Coloured Icon", isOn: $model.prefs.iconColored)
                Text("Off — a monochrome template; only the shape shows the state (outline / filled / “!” / dot).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Show the Number of Tunnels", isOn: $model.prefs.iconShowCount)
                Toggle("Show the Active Tunnel’s Name", isOn: $model.prefs.iconShowName)
            }
            Section("Status Updates") {
                Picker("In the Background", selection: $model.prefs.backgroundInterval) {
                    Text("every 10 s").tag(10)
                    Text("every 30 s").tag(30)
                    Text("every minute").tag(60)
                    Text("every 5 min").tag(300)
                }
                Text("Network changes (SystemConfiguration) update the status instantly; while the popover is open — every 3 s.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
