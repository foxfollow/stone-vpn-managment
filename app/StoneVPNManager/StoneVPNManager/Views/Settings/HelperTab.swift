import ServiceManagement
import SwiftUI
import StoneVPNCore
import StoneVPNShared

struct HelperTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                LabeledContent("Стан") {
                    HStack(spacing: 6) { StatusDot(color: statusColor); Text(statusText) }
                }
                if let v = model.helperVersion {
                    LabeledContent("Версія") { Text("\(v)" + (v != HelperConst.version ? " (застаріла — перевстанови)" : "")) }
                }
                HStack {
                    Button(model.helperStatus == .enabled ? "Перевстановити" : "Встановити") {
                        if model.helperStatus == .enabled {
                            Task { try? await model.helper.unregister(); model.installHelper() }
                        } else { model.installHelper() }
                    }
                    Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    Spacer()
                    Button("Видалити", role: .destructive) { model.uninstallHelper() }.disabled(model.helperStatus != .enabled)
                }
            } header: { Text("Privileged helper") } footer: {
                Text("Root-демон для wg-quick / openvpn / DNS / маршрутів без запиту пароля щоразу. Приймає з'єднання лише від StoneVPN з тим самим підписом і виконує фіксований набір перевірених дій. Без нього кожна дія питає пароль адміністратора.")
            }
        }
        .formStyle(.grouped)
        .task { await model.checkHelper() }
    }

    private var statusText: String {
        switch model.helperStatus {
        case .enabled: "встановлено · активний"
        case .requiresApproval: "чекає схвалення в System Settings → Login Items"
        case .notRegistered: "не встановлено"
        case .notFound: "не знайдено в бандлі (зберіть через make app)"
        @unknown default: "невідомо"
        }
    }

    private var statusColor: Color {
        switch model.helperStatus {
        case .enabled: .green
        case .requiresApproval: .orange
        default: .secondary
        }
    }
}
