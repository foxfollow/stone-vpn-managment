import SwiftUI
import StoneVPNCore

struct AdvancedTab: View {
    @Bindable var model: AppModel
    @State private var path = ""
    var body: some View {
        Form {
            Section("Configuration") {
                Toggle("Shared with the CLI Repository (main-vpn-manager.sh)", isOn: Binding(
                    get: { !model.prefs.standalone },
                    set: { shared in
                        if !shared, let repo = RepoConfig.detectRepo(explicit: model.prefs.repoPath) {
                            let copied = RepoConfig.importFromRepo(repo)
                            if !copied.isEmpty { model.toast = String(localized: "Moved to the app folder: \(copied.joined(separator: ", "))") }
                        }
                        model.prefs.standalone = !shared
                        model.reloadConfig()
                    }))
                    .settingsAnchor("advanced.shared")
                if !model.prefs.standalone {
                    TextField("Repository Folder", text: $path, prompt: Text("auto"))
                        .onSubmit { model.prefs.repoPath = path; model.reloadConfig() }
                }
                LabeledContent(model.config.sharedWithCLI ? "Repository" : "App Folder") {
                    Text(model.config.repo?.path ?? "—").font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                }
                .settingsAnchor("advanced.repoPath")
                Group {
                    if model.config.sharedWithCLI {
                        Text("config.env, state.env and auth.txt are the same ones main-vpn-manager.sh reads.")
                    } else if model.prefs.standalone {
                        Text("Standalone mode: the app doesn't depend on the repo; when it was turned off, the files were copied here.")
                    } else {
                        Text("Repository not found — the app runs on its own with its own folder.")
                    }
                }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let dir = model.config.repo {
                    HStack {
                        Button("Open config.env") {
                            let f = dir.appendingPathComponent("config.env")
                            if !FileManager.default.fileExists(atPath: f.path) { FileManager.default.createFile(atPath: f.path, contents: Data("# StoneVPN Manager\n".utf8)) }
                            NSWorkspace.shared.open(f)
                        }
                        Button("Show Folder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                    }
                    .settingsAnchor("advanced.openConfig")
                }
            }
            Section("Reset") {
                Button("Reset App Settings", role: .destructive) {
                    if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
                    model.toast = String(localized: "Settings reset — restart StoneVPN")
                }
                .settingsAnchor("advanced.reset")
            }
        }
        .formStyle(.grouped)
        .onAppear { path = model.prefs.repoPath }
    }
}
