import SwiftUI
import StoneVPNCore

struct AdvancedTab: View {
    @Bindable var model: AppModel
    @State private var path = ""
    var body: some View {
        Form {
            Section("Конфігурація") {
                Toggle("Спільно з CLI-репозиторієм (main-vpn-manager.sh)", isOn: Binding(
                    get: { !model.prefs.standalone },
                    set: { shared in
                        if !shared, let repo = RepoConfig.detectRepo(explicit: model.prefs.repoPath) {
                            let copied = RepoConfig.importFromRepo(repo)
                            if !copied.isEmpty { model.toast = "Перенесено в теку застосунку: \(copied.joined(separator: ", "))" }
                        }
                        model.prefs.standalone = !shared
                        model.reloadConfig()
                    }))
                if !model.prefs.standalone {
                    TextField("Тека репозиторію", text: $path, prompt: Text("авто"))
                        .onSubmit { model.prefs.repoPath = path; model.reloadConfig() }
                }
                LabeledContent(model.config.sharedWithCLI ? "Репозиторій" : "Тека застосунку") {
                    Text(model.config.repo?.path ?? "—").font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                }
                Text(model.config.sharedWithCLI
                     ? "config.env, state.env і auth.txt — ті самі, що читає main-vpn-manager.sh."
                     : (model.prefs.standalone ? "Окремий режим: застосунок не залежить від репо; при вимкненні файли скопійовано сюди." : "Репозиторій не знайдено — застосунок працює окремо зі своєю текою."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let dir = model.config.repo {
                    HStack {
                        Button("Відкрити config.env") {
                            let f = dir.appendingPathComponent("config.env")
                            if !FileManager.default.fileExists(atPath: f.path) { FileManager.default.createFile(atPath: f.path, contents: Data("# StoneVPN Manager\n".utf8)) }
                            NSWorkspace.shared.open(f)
                        }
                        Button("Показати теку") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                    }
                }
            }
            Section("Скинути") {
                Button("Скинути налаштування застосунку", role: .destructive) {
                    if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
                    model.toast = "Налаштування скинуто — перезапусти StoneVPN"
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { path = model.prefs.repoPath }
    }
}
