import SwiftUI
import StoneVPNCore

struct BackendsTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            RepoWarning(model: model)
            Section {
                ForEach(Backend.allCases) { b in
                    Toggle(isOn: Binding(get: { model.config.isOn(b) }, set: { on in
                        var d = model.config.disabled
                        if on { d.remove(b) } else { d.insert(b) }
                        model.updateConfig { $0.set("DISABLED_BACKENDS", Backend.allCases.filter(d.contains).map(\.rawValue).joined(separator: " ")) }
                    })) {
                        HStack { BackendBadge(backend: b, size: 20); Text(b.title) }
                    }
                }
                if !model.config.unknownDisabled.isEmpty {
                    Text("Невідомі назви в DISABLED_BACKENDS: \(model.config.unknownDisabled.joined(separator: ", "))").foregroundStyle(.orange)
                }
            } header: { Text("Увімкнені (DISABLED_BACKENDS)") } footer: {
                Text("Вимкнений бекенд не показується і не опитується. Приховати з поповера, не вимикаючи, — «Змінити» у списку провайдерів.")
            }
            Section("Знайдені інструменти") {
                tool("wg-quick", Shell.which(["/opt/homebrew/bin/wg-quick", "/usr/local/bin/wg-quick"]))
                tool("openvpn", Shell.which(["/opt/homebrew/sbin/openvpn", "/usr/local/sbin/openvpn"]))
                tool("defguard-client", Paths.defguardCLI(model.config.defguardCLI))
                tool("Cisco vpn", Shell.which(Paths.ciscoCLI))
                tool("WG тека", model.snap.wgDir)
            }
            Section("Шляхи") {
                ConfigField(model: model, label: "DEFGUARD_CLI", key: "DEFGUARD_CLI", value: model.config.defguardCLI,
                            prompt: Paths.defguardBundleCLI, hint: "Симлінки розгортаються: NetworkExtension шукає бандл за шляхом exec.")
            }
        }
        .formStyle(.grouped)
    }

    private func tool(_ name: String, _ path: String?) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                StatusDot(color: path == nil ? .secondary : .green)
                Text(path ?? "не знайдено").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
