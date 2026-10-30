import SwiftUI
import StoneVPNCore

struct NetworkTab: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("Пріоритет сервісів") {
                ForEach(model.services) { s in
                    HStack {
                        Text("\(s.order). \(s.name)").foregroundStyle(s.enabled ? .primary : .secondary)
                        Spacer()
                        if s.order > 1, s.enabled {
                            Button("На верх") { model.runAction("Порядок") { try await model.actions.moveToTop(s.name); await model.loadServices(); return nil } }
                        }
                    }
                }
            }
            Section("Автоматика") {
                Toggle("Auto-fix: первинний без інтернету → підняти робочий", isOn: $model.prefs.netAutoFix)
                Text("Те саме, що «net auto». Працює у фоні лише з встановленим helper (без запитів пароля).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.loadServices() }
    }
}
