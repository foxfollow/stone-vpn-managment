import SwiftUI
import StoneVPNCore

struct GeneralTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускати при вході", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
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
