import SwiftUI
import StoneVPNCore

struct NotificationsTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Показувати") {
                Toggle("Тунель підключено", isOn: $model.prefs.notifyConnected)
                Toggle("Тунель відключено", isOn: $model.prefs.notifyDisconnected)
                Toggle("Тунель упав неочікувано", isOn: $model.prefs.notifyDropped)
                Toggle("DNS не відповідає", isOn: $model.prefs.notifyDNS)
                Toggle("Сторонній VPN захопив маршрут", isOn: $model.prefs.notifyForeign)
            }
        }
        .formStyle(.grouped)
    }
}
