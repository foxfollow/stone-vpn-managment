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
                    Text("Unknown names in DISABLED_BACKENDS: \(model.config.unknownDisabled.joined(separator: ", "))").foregroundStyle(.orange)
                }
            } header: { Text("Enabled (DISABLED_BACKENDS)") } footer: {
                Text("A disabled backend is neither shown nor probed. To hide it from the popover without disabling it, use “Edit” in the provider list.")
            }
            Section("Found Tools") {
                tool("wg-quick", Shell.which(["/opt/homebrew/bin/wg-quick", "/usr/local/bin/wg-quick"]))
                tool("openvpn", Shell.which(["/opt/homebrew/sbin/openvpn", "/usr/local/sbin/openvpn"]))
                tool("defguard-client", Paths.defguardCLI(model.config.defguardCLI))
                tool("Cisco vpn", Shell.which(Paths.ciscoCLI))
                tool(String(localized: "WG folder"), model.snap.wgDir)
            }
            Section("Paths") {
                ConfigField(model: model, label: "DEFGUARD_CLI", key: "DEFGUARD_CLI", value: model.config.defguardCLI,
                            prompt: Paths.defguardBundleCLI, hint: "Symlinks are resolved: NetworkExtension finds the bundle by the exec path.")
            }
        }
        .formStyle(.grouped)
    }

    private func tool(_ name: String, _ path: String?) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                StatusDot(color: path == nil ? .secondary : .green)
                Text(path ?? String(localized: "not found")).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(path == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
