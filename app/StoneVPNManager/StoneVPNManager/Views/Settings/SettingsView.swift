import SwiftUI
import StoneVPNCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("Загальні", systemImage: "gearshape") { GeneralTab(model: model) }
            Tab("Бекенди", systemImage: "square.stack.3d.up") { BackendsTab(model: model) }
            Tab("OpenVPN", systemImage: "lock.shield") { OpenVPNTab(model: model) }
            Tab("DNS", systemImage: "globe") { DNSTab(model: model) }
            Tab("Мережа", systemImage: "wifi") { NetworkTab(model: model) }
            Tab("Сповіщення", systemImage: "bell") { NotificationsTab(model: model) }
            Tab("Helper", systemImage: "checkmark.shield") { HelperTab(model: model) }
            Tab("Додатково", systemImage: "slider.horizontal.3") { AdvancedTab(model: model) }
        }
        .frame(width: 640, height: 520)
    }
}

/// Поле, що пише ключ у config.env (спільний з CLI) після Enter або втрати фокусу.
struct ConfigField: View {
    @Bindable var model: AppModel
    var label: String
    var key: String
    var value: String
    var prompt = ""
    var hint: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(label, text: $text, prompt: Text(prompt))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .onAppear { text = value }
        .onChange(of: value) { if !focused { text = value } }
    }

    private func commit() {
        guard text != value else { return }
        model.updateConfig { $0.set(key, text.isEmpty ? "" : text) }
    }
}

struct RepoWarning: View {
    @Bindable var model: AppModel
    var body: some View {
        if !model.config.sharedWithCLI {
            Label("Окремий режим: налаштування в теці застосунку, CLI їх не бачить (Додатково).", systemImage: "info.circle")
                .foregroundStyle(.secondary).font(.system(size: 12))
        }
    }
}
