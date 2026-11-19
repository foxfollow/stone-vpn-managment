import SwiftUI
import StoneVPNCore

struct GeneralTab: View {
    @Bindable var model: AppModel
    @State private var autoUpdates = Updater.shared.automaticallyChecks

    var body: some View {
        Form {
            Section("Версія \(Updater.shared.version)") {
                if Updater.shared.enabled {
                    Toggle("Автоматично перевіряти оновлення", isOn: $autoUpdates)
                        .onChange(of: autoUpdates) { Updater.shared.automaticallyChecks = autoUpdates }
                    Button("Перевірити оновлення…") { Updater.shared.checkForUpdates() }
                } else {
                    Text("Збірка з вихідного коду — оновлюється через git pull і make -C app install. Автооновлення є в релізах (Homebrew / GitHub Releases).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Запуск") {
                Toggle("Запускати при вході", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Показувати в Cmd+Tab, поки відкрите вікно", isOn: $model.prefs.showInAppSwitcher)
                Text("Профілі, Налаштування, Підключення. macOS пускає в Cmd+Tab лише застосунки з іконкою в Dock, тож на цей час вона з'являється і зникає, коли закриваєш останнє вікно.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Іконка в menubar") {
                Toggle("Кольорова іконка", isOn: $model.prefs.iconColored)
                Text("Вимкнено — template-монохром; стан передає лише форма (контур / заповнений / «!» / крапка).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Показувати кількість тунелів", isOn: $model.prefs.iconShowCount)
                Toggle("Показувати назву активного тунелю", isOn: $model.prefs.iconShowName)
            }
            Section("Оновлення") {
                Picker("У фоні", selection: $model.prefs.backgroundInterval) {
                    Text("кожні 10 с").tag(10)
                    Text("кожні 30 с").tag(30)
                    Text("кожну хвилину").tag(60)
                    Text("кожні 5 хв").tag(300)
                }
                Text("Зміни мережі (SystemConfiguration) оновлюють статус миттєво; поки поповер відкритий — кожні 3 с.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
