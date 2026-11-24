import ServiceManagement
import SwiftUI
import StoneVPNCore
import StoneVPNShared

struct HelperTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) { StatusDot(color: statusColor); Text(statusText) }
                }
                .settingsAnchor("helper.status")
                if let v = model.helperVersion {
                    LabeledContent("Version") { v != HelperConst.version ? Text("\(v) (outdated — reinstall)") : Text(verbatim: "\(v)") }
                }
                if let p = model.helperProblem {
                    Label(p.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(model.helperStatus == .enabled ? "Reinstall" : "Install") {
                        if model.helperStatus == .enabled {
                            Task { await model.reinstallHelper() }
                        } else { model.installHelper() }
                    }
                    .disabled(model.helperReinstalling)
                    Button("Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    Spacer()
                    Button("Remove", role: .destructive) { model.uninstallHelper() }.disabled(model.helperStatus != .enabled)
                }
                .settingsAnchor("helper.install")
            } header: { Text("Privileged helper") } footer: {
                Text("A root daemon for wg-quick / openvpn / DNS / routes without asking for a password every time. It accepts connections only from StoneVPN with the same signature and runs a fixed set of checked actions. Without it, every such action asks for the administrator password.")
            }
        }
        .formStyle(.grouped)
        .task { await model.checkHelper() }
    }

    private var statusText: String {
        switch model.helperStatus {
        case .enabled: String(localized: "installed · active")
        case .requiresApproval: String(localized: "waiting for approval in System Settings → Login Items")
        case .notRegistered: String(localized: "not installed")
        case .notFound: String(localized: "not found in the bundle (build it with make -C app)")
        @unknown default: String(localized: "unknown")
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
