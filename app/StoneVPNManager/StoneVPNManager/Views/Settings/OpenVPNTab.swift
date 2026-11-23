import SwiftUI
import StoneVPNCore

struct OpenVPNTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            RepoWarning(model: model)
            Section("Profiles") {
                ConfigField(model: model, label: "OVPN_PROFILES_DIR", key: "OVPN_PROFILES_DIR", value: model.config.ovpnProfilesDir,
                            hint: "A folder shared with OpenVPN Connect (files are named by ms timestamp — give them aliases in the Profiles window).")
            }
            Section("Login") {
                ConfigField(model: model, label: "OVPN_USERNAME", key: "OVPN_USERNAME", value: model.config.ovpnUsername,
                            hint: "Priority: this profile’s username → config.env → auth.txt (the shared LAST_USERNAME from state.env is for the CLI only). OTP is never stored.")
                Toggle("Remember the Username per OpenVPN Profile and Cisco Host (+ state.env for the CLI)", isOn: $model.prefs.rememberUser)
            }
            Section("Route-fix") {
                ConfigField(model: model, label: "LAN_GATEWAY", key: "LAN_GATEWAY", value: model.config.lanGateway, prompt: "192.168.0.1",
                            hint: "The default gateway for host routes to the VPN server.")
                Toggle("Remember the Gateway Choice per Profile (+ state.env)", isOn: $model.prefs.rememberGateway)
                RouteFixList(model: model)
            }
            Section("Connection") {
                Stepper("Timeout: \(model.prefs.ovpnTimeout) s", value: $model.prefs.ovpnTimeout, in: 15...180, step: 5)
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
            Text("No profiles").foregroundStyle(.secondary)
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
                Text("Ask").tag("ask")
                Text("LAN Gateway").tag("lan")
                Text("Never").tag("off")
                if case .gateway(let g) = model.prefs.settings(for: p).routeFix { Text("Gateway \(g)").tag("gw:\(g)") }
                if !model.config.defaultGateway.isEmpty { let g = model.config.defaultGateway; Text("Gateway \(g)").tag("gw:\(g)") }
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
