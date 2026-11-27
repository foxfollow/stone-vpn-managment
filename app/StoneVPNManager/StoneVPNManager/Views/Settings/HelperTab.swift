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
            if let a = model.helperAccess { accessSection(a) }
        }
        .formStyle(.grouped)
        .task { await model.checkHelper() }
    }

    @ViewBuilder private func accessSection(_ a: HelperAccessInfo) -> some View {
        Section {
            LabeledContent("Owner") {
                if let name = a.ownerName {
                    Text(a.callerIsOwner ? String(localized: "\(name) (you)") : name)
                } else {
                    Text("nobody yet")
                }
            }
            Picker("Who May Use It", selection: Binding(
                get: { a.policy },
                set: { p in Task { await model.setHelperAccess(p) } })) {
                Text("Only the owner").tag(HelperAccessPolicy.owner)
                Text("The owner and administrators").tag(HelperAccessPolicy.admins)
                Text("All users of this Mac").tag(HelperAccessPolicy.everyone)
            }
            .disabled(!a.callerIsOwner)
            .settingsAnchor("helper.access")
            if !a.callerIsOwner {
                if !a.callerAllowed {
                    Label("The helper doesn't serve you, so privileged actions ask for the administrator password.",
                          systemImage: "lock.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Take Over…") { Task { await model.claimHelper() } }
                }
            }
        } header: { Text("Access") } footer: {
            Text("The helper runs actions as root, including OpenVPN profile scripts, so it serves only its owner unless the owner allows more. The owner is the user who installed the app; another user can take it over with the administrator password. OpenVPN profiles must belong to the user who connects them.")
        }
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
