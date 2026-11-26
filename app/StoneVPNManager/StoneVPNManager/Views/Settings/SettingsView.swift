import SwiftUI
import StoneVPNCore

/// Налаштування: бічна панель зі сторінками (за групами) і пошуком по всіх пунктах.
/// Вибраний результат відкриває сторінку, прокручує до рядка й на мить підсвічує його.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var section: SettingsSection = .general
    @State private var searchText = ""
    @State private var highlight = SettingsHighlight()

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(section: $section, results: results, onPick: pick)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPage(section: section, highlight: highlight) { page }
                .navigationTitle(section.title)
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .sidebar, prompt: Text("Search settings"))
        .onSubmit(of: .search) { if let first = results?.first { pick(first) } }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 540, idealHeight: 600)
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .general: GeneralTab(model: model)
        case .notifications: NotificationsTab(model: model)
        case .backends: BackendsTab(model: model)
        case .openvpn: OpenVPNTab(model: model)
        case .dns: DNSTab(model: model)
        case .network: NetworkTab(model: model)
        case .helper: HelperTab(model: model)
        case .advanced: AdvancedTab(model: model)
        }
    }

    /// nil, поки поле пошуку порожнє: тоді в панелі — сторінки.
    private var results: [SettingsSearchEntry]? {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : SettingsSearchIndex.search(searchText)
    }

    private func pick(_ entry: SettingsSearchEntry) {
        section = entry.section
        let picked = SettingsHighlight(anchors: [entry.id])
        highlight = picked
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if highlight.token == picked.token { highlight = SettingsHighlight() }
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var section: SettingsSection
    /// Не nil під час пошуку — показується замість сторінок.
    let results: [SettingsSearchEntry]?
    let onPick: (SettingsSearchEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let results {
                SettingsSearchResults(results: results, onPick: onPick)
            } else {
                List(selection: $section) {
                    ForEach(SettingsGroup.allCases) { group in
                        Section(group.title) {
                            ForEach(group.sections) { s in
                                Label(s.title, systemImage: s.systemImage).tag(s)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            HStack {
                Text(verbatim: "StoneVPN Manager \(Updater.shared.version)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 210)
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    }
}

private struct SettingsSearchResults: View {
    let results: [SettingsSearchEntry]
    let onPick: (SettingsSearchEntry) -> Void

    /// Сторінки в порядку панелі, у кожній — її результати за рангом.
    private var groups: [(section: SettingsSection, entries: [SettingsSearchEntry])] {
        SettingsSection.allCases.compactMap { s in
            let e = results.filter { $0.section == s }
            return e.isEmpty ? nil : (s, e)
        }
    }

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView("No settings found", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(groups, id: \.section) { g in
                    Section {
                        ForEach(g.entries) { entry in
                            Button { onPick(entry) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).lineLimit(2)
                                    Text(entry.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label(g.section.title, systemImage: g.section.systemImage)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

/// Поле, що пише ключ у config.env (спільний з CLI) після Enter або втрати фокусу.
struct ConfigField: View {
    @Bindable var model: AppModel
    var label: String
    var key: String
    var value: String
    var prompt = ""
    var hint: LocalizedStringKey?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(label, text: $text, prompt: Text(prompt))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .onAppear { text = value }
        .onChange(of: value) { if !focused { text = value } }
    }

    private func commit() {
        guard text != value else { return }
        model.updateConfig { $0.set(key, text.isEmpty ? "" : text) }
    }
}

struct RepoWarning: View {
    @Bindable var model: AppModel
    var body: some View {
        if !model.config.sharedWithCLI {
            Label("Standalone mode: settings live in the app folder; the CLI doesn’t see them (Advanced).", systemImage: "info.circle")
                .foregroundStyle(.secondary).font(.system(size: 12))
        }
    }
}
