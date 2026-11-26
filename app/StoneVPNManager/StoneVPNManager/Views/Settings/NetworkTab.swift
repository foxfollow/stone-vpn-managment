import SwiftUI
import StoneVPNCore

struct NetworkTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Service Priority") {
                if model.services.isEmpty { ProgressView().controlSize(.small).settingsAnchor("network.order") }
                ForEach(model.services) { s in
                    HStack {
                        Text(verbatim: "\(s.order). \(s.name)").foregroundStyle(s.enabled ? .primary : .secondary)
                        Spacer()
                        if s.order > 1, s.enabled {
                            Button("To Top") { model.runAction(String(localized: "Order")) { try await model.actions.moveToTop(s.name); await model.loadServices(); return nil } }
                        }
                    }
                    .settingsAnchor(s.order == 1 ? "network.order" : "network.service.\(s.order)")
                }
            }
            Section("Automation") {
                Toggle("Auto-fix: Primary Without Internet → Move a Working One Up", isOn: $model.prefs.netAutoFix)
                    .settingsAnchor("network.autoFix")
                Text("Same as “net auto”. Runs in the background only with the helper installed (no password prompts).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.loadServices() }
    }
}
