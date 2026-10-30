import SwiftUI
import StoneVPNCore

struct OpenVPNTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            RepoWarning(model: model)
            Section("Профілі") {
                ConfigField(model: model, label: "OVPN_PROFILES_DIR", key: "OVPN_PROFILES_DIR", value: model.config.ovpnProfilesDir,
                            hint: "Спільна з OpenVPN Connect тека (файли названі ms-timestamp — дай псевдоніми у вікні профілів).")
            }
            Section("Логін") {
                ConfigField(model: model, label: "OVPN_USERNAME", key: "OVPN_USERNAME", value: model.config.ovpnUsername,
                            hint: "Пріоритет: логін цього профілю → config.env → auth.txt (спільний LAST_USERNAME зі state.env — лише для CLI). OTP не зберігається ніколи.")
                Toggle("Запам'ятовувати логін окремо для кожного профілю OpenVPN і хоста Cisco (+ state.env для CLI)", isOn: $model.prefs.rememberUser)
            }
            Section("Route-fix") {
                ConfigField(model: model, label: "LAN_GATEWAY", key: "LAN_GATEWAY", value: model.config.lanGateway, prompt: "192.168.0.1",
                            hint: "Типовий шлюз для host-маршрутів до VPN-сервера.")
                Toggle("Запам'ятовувати вибір шлюзу для кожного профілю (+ state.env)", isOn: $model.prefs.rememberGateway)
                RouteFixList(model: model)
            }
            Section("Підключення") {
                Stepper("Таймаут: \(model.prefs.ovpnTimeout) с", value: $model.prefs.ovpnTimeout, in: 15...180, step: 5)
            }
        }
        .formStyle(.grouped)
    }
}

/// Політика route-fix для кожного профілю (дублює налаштування з вікна профілів).
struct RouteFixList: View {
    @Bindable var model: AppModel
    var body: some View {
        let profiles = (model.snap.profiles[.openvpn] ?? []) + (model.snap.profiles[.wireguard] ?? [])
        if profiles.isEmpty {
            Text("Профілів немає").foregroundStyle(.secondary)
        }
        ForEach(profiles) { p in
            Picker(selection: Binding(get: { tag(model.prefs.settings(for: p).routeFix) }, set: { v in
                var s = model.prefs.settings(for: p)
                switch v {
                case "ask": s.routeFix = .ask
                case "lan": s.routeFix = .lanDefault
                case "off": s.routeFix = .off
                default: s.routeFix = .gateway(String(v.dropFirst(3)))
                }
                model.prefs.setSettings(s, for: p)
            })) {
                Text("Питати").tag("ask")
                Text("LAN-шлюз").tag("lan")
                Text("Ніколи").tag("off")
                if case .gateway(let g) = model.prefs.settings(for: p).routeFix { Text("Шлюз \(g)").tag("gw:\(g)") }
                if !model.config.defaultGateway.isEmpty { Text("Шлюз \(model.config.defaultGateway)").tag("gw:\(model.config.defaultGateway)") }
            } label: {
                HStack { BackendBadge(backend: p.backend, size: 16); Text(model.prefs.display(p)) }
            }
        }
    }

    private func tag(_ m: RouteFixMode) -> String {
        switch m {
        case .ask: "ask"
        case .lanDefault: "lan"
        case .off: "off"
        case .gateway(let g): "gw:\(g)"
        }
    }
}
