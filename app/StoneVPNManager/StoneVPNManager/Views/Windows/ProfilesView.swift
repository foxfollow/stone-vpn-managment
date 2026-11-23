import SwiftUI
import StoneVPNCore
import UniformTypeIdentifiers

/// Вікно «Профілі»: провайдери → профілі → деталі + налаштування профілю (alias, обране, route-fix).
struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var addingHost = false
    @State private var newHost = ""
    @State private var pendingDelete: Profile?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.profilesBackend }, set: { if let b = $0 { model.profilesBackend = b; model.profilesSelection = nil } })) {
                Section("Providers") {
                    ForEach(Backend.allCases.filter { model.config.isOn($0) }) { b in
                        let items = model.items(for: b)
                        HStack(spacing: 9) {
                            BackendBadge(backend: b, size: 22)
                            Text(b.title)
                            Spacer()
                            let up = items.filter { $0.status == .up }.count
                            Text("\(up)/\(items.count)").monospacedDigit().foregroundStyle(up > 0 ? .green : .secondary)
                        }
                        .tag(b)
                    }
                }
                let off = Backend.allCases.filter { !model.config.isOn($0) }
                if !off.isEmpty {
                    Section("Disabled (DISABLED_BACKENDS)") {
                        ForEach(off) { b in Text(b.title).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            let items = model.items(for: model.profilesBackend).filter {
                search.isEmpty || model.prefs.display($0.profile).localizedCaseInsensitiveContains(search) || ($0.profile.endpoint ?? "").localizedCaseInsensitiveContains(search)
            }
            List(selection: $model.profilesSelection) {
                ForEach(items) { it in
                    HStack(spacing: 10) {
                        Circle().fill(it.status == .up ? Color.green : .clear)
                            .overlay(Circle().stroke(it.status.isActive ? it.status.color : .secondary, lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(model.prefs.display(it.profile)).fontWeight(.medium)
                                if model.prefs.isFavorite(it.id) { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                                if model.prefs.lastProfile[it.profile.backend.rawValue] == it.id {
                                    Text("last used").font(.system(size: 9.5)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 4).background(.quaternary, in: Capsule())
                                }
                            }
                            Mono(it.profile.endpoint ?? it.profile.name, size: 10.5).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(it.id)
                    .contextMenu {
                        Button(it.status.isActive ? "Disconnect" : "Connect") { model.toggle(it) }
                        Button(model.prefs.isFavorite(it.id) ? "Remove from Favourites" : "Add to Favourites") { model.prefs.toggleFavorite(it.id) }
                        if it.profile.backend == .openvpn || it.profile.backend == .wireguard {
                            Divider()
                            Button("Delete…", role: .destructive) { pendingDelete = it.profile }
                                .disabled(it.status.isActive)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .overlay {
                if items.isEmpty { ContentUnavailableView("No Profiles", systemImage: "shield.slash", description: Text(emptyHint)) }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let key = model.profilesSelection, let it = model.items(for: model.profilesBackend).first(where: { $0.id == key }) {
                ProfileDetail(model: model, item: it, onDelete: { pendingDelete = it.profile }).id(it.id)
            } else {
                ContentUnavailableView("Select a Profile", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    if model.profilesBackend == .openvpn {
                        Button("Add Profile (.ovpn)…") {
                            if let u = pickFile(ovpn: true, title: String(localized: "New OpenVPN Profile")) { Task { await model.ovpnImport(u) } }
                        }
                        Divider()
                    }
                    ForEach(manageCommands, id: \.0) { c in Button(c.0) { runInTerminal(c.1) } }
                    if model.profilesBackend == .cisco {
                        Button("Add Host…") { newHost = CiscoPrefs.load().suggestedHost ?? ""; addingHost = true }
                    }
                    if model.profilesBackend == .defguard {
                        Button("Open Defguard.app") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Defguard.app")) }
                    }
                } label: { Label("Manage", systemImage: "plus") }
                .help("Add / import / certificates")
            }
            ToolbarItem {
                Button { Task { await model.refresh(forceSlow: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                HStack(spacing: 8) {
                    Text(t).font(.system(size: 12)).lineLimit(3)
                    Button { model.toast = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { p in
            Button("Delete", role: .destructive) { Task { await model.deleteProfile(p) } }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            if p.backend == .openvpn {
                let file = p.path.map { ($0 as NSString).lastPathComponent } ?? p.name
                Text("The file \(file) will go to the Trash (it can be restored). The profile's alias and settings will be forgotten.")
            } else {
                let conf = p.path ?? p.name
                Text("The config \(conf) will be deleted permanently (needs root — asks for a password if the helper isn't installed), together with its private key.")
            }
        }
        .alert("New Cisco Host", isPresented: $addingHost) {
            TextField(text: $newHost) { Text(verbatim: "host:port") }
            Button("Add") { model.addCiscoHost(newHost) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A port is allowed, e.g. vpn.example.com:8448") }
    }

    private var emptyHint: String {
        switch model.profilesBackend {
        case .wireguard: String(localized: "*.conf configs in /opt/homebrew/etc/wireguard, /usr/local/etc/wireguard or /etc/wireguard (root-only folders become visible once the helper is installed).")
        case .openvpn: String(localized: "*.ovpn profiles in \(model.config.ovpnProfilesDir).")
        case .defguard: String(localized: "Locations are added in Defguard.app.")
        case .cisco: String(localized: "Hosts from the Cisco profile (vpn -s hosts).")
        }
    }

    private var deleteTitle: String {
        pendingDelete.map { String(localized: "Delete “\(model.prefs.display($0))”?") } ?? ""
    }

    /// Керування конфігами/сертифікатами — інтерактивні CLI-скрипти репо в Terminal.
    private var manageCommands: [(String, String)] {
        switch model.profilesBackend {
        case .wireguard: [(String(localized: "WireGuard: generate / import / delete… (Terminal)"), "cert wg")]
        case .openvpn: [(String(localized: "OpenVPN: script menu (Terminal)"), "cert openvpn")]
        default: []
        }
    }

    private func runInTerminal(_ args: String) {
        guard model.config.sharedWithCLI, let repo = model.config.repo else {
            model.toast = String(localized: "Certificate management works through the CLI repository (Settings → Advanced)"); return
        }
        let cmd = "cd '\(repo.path)' && ./main-vpn-manager.sh \(args)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        Task { _ = await Shell.run("/usr/bin/osascript", ["-e", script]) }
    }
}

/// Діалог вибору файлу (.ovpn або будь-який — для PEM).
@MainActor func pickFile(ovpn: Bool, title: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if ovpn { panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data, .text] }
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
}

struct ProfileDetail: View {
    @Bindable var model: AppModel
    var item: ProfileItem
    var onDelete: () -> Void = {}
    @State private var blocks: [String] = []
    @State private var info: [(String, String)] = []
    @State private var alias = ""
    @State private var fixedGW = ""
    @State private var hostEdit = ""

    var body: some View {
        let p = item.profile
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    BackendBadge(backend: p.backend, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.prefs.display(p)).font(.system(size: 19, weight: .bold))
                        Text("\(p.backend.title) · " + (p.title != nil ? "ID \(p.name)" : p.name)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) { StatusDot(color: item.status.color); Text(statusText) }
                        .font(.system(size: 12)).foregroundStyle(item.status.color)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Mono(r.1, size: 12).textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))

                HStack(spacing: 8) {
                    Button(item.status.isActive ? "Disconnect" : "Connect") { model.toggle(item) }
                        .buttonStyle(.borderedProminent)
                        .tint(item.status.isActive ? .red : .accentColor)
                    let fav = model.prefs.isFavorite(item.id)
                    Button { model.prefs.toggleFavorite(item.id) } label: {
                        Label(fav ? "In Favourites" : "Favourite", systemImage: fav ? "star.fill" : "star")
                    }
                    if let path = p.path {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    if p.backend == .openvpn, FileManager.default.fileExists(atPath: "/tmp/openvpn-\(p.name).log") {
                        Button("Log") { NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/openvpn-\(p.name).log")) }
                    }
                    if p.backend == .openvpn, p.path != nil {
                        Menu("Replace") {
                            Button("Whole Profile (.ovpn)…") {
                                if let u = pickFile(ovpn: true, title: String(localized: "New .ovpn for “\(model.prefs.display(p))”")) {
                                    Task { await model.ovpnReplace(p, with: u); loadBlocks() }
                                }
                            }
                            if !blocks.isEmpty {
                                Divider()
                                ForEach(blocks, id: \.self) { tag in
                                    Button(Self.blockTitle(tag)) {
                                        if let u = pickFile(ovpn: false, title: String(localized: "PEM for <\(tag)> in “\(model.prefs.display(p))”")) {
                                            Task { await model.ovpnReplace(p, with: u, block: tag) }
                                        }
                                    }
                                }
                            }
                        }
                        .fixedSize()
                        .help("Replaces exactly this file; the old version stays next to it as .ovpn.bak")
                    }
                    if p.backend == .openvpn || p.backend == .wireguard {
                        Spacer()
                        Button("Delete…", role: .destructive, action: onDelete)
                            .disabled(item.status.isActive)
                            .help(item.status.isActive ? "Disconnect first" : "Delete the profile")
                    }
                }

                settings(p)
            }
            .padding(24)
        }
        .task { await loadInfo(); loadBlocks() }
        .onAppear {
            alias = model.prefs.aliases[p.key] ?? ""
            hostEdit = p.name
            if case .gateway(let g) = model.prefs.settings(for: p).routeFix { fixedGW = g }
        }
    }

    // MARK: налаштування профілю

    @ViewBuilder private func settings(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Profile Settings")
            Form {
                TextField("Alias", text: $alias, prompt: Text(verbatim: p.title ?? p.name))
                    .onSubmit { saveAlias(p) }
                    .onChange(of: alias) { saveAlias(p) }
                if p.backend == .cisco {
                    let custom = model.prefs.ciscoHosts.contains(p.name)
                    TextField("Host", text: $hostEdit, prompt: Text(verbatim: "host:port"))
                        .onSubmit { model.editCiscoHost(p.name, to: hostEdit) }
                    HStack {
                        Text(custom ? "A StoneVPN host (not from the Cisco profile)." : "From the Cisco profile (the head-end rewrites it) — editing saves a copy in StoneVPN.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(custom ? "Save" : "Save a Copy") { model.editCiscoHost(p.name, to: hostEdit) }
                            .disabled(hostEdit.isEmpty || hostEdit == p.name)
                        if custom { Button("Delete", role: .destructive) { model.removeCiscoHost(p.name) } }
                    }
                    if let u = model.prefs.ciscoUsers[Prefs.ciscoKey(p.name)], !u.isEmpty {
                        LabeledContent("Last Username") {
                            HStack {
                                Mono(u, size: 12)
                                Button("Forget") { model.prefs.ciscoUsers.removeValue(forKey: Prefs.ciscoKey(p.name)) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if p.backend == .openvpn || p.backend == .wireguard {
                    Picker("Route-fix", selection: routeFixBinding(p)) {
                        Text("Ask When Connecting").tag(0)
                        Text("Current LAN Gateway").tag(1)
                        Text("Fixed Gateway").tag(2)
                        Text("Never").tag(3)
                    }
                    if case .gateway = model.prefs.settings(for: p).routeFix {
                        TextField("Gateway", text: $fixedGW, prompt: Text(verbatim: "192.168.0.1"))
                            .onSubmit { setMode(p, .gateway(fixedGW)) }
                            .onChange(of: fixedGW) { if Parse.ipv4(fixedGW) != nil { setMode(p, .gateway(fixedGW)) } }
                    }
                    if let last = model.prefs.settings(for: p).lastGateway {
                        LabeledContent("Last Gateway Choice") { Mono(last.isEmpty ? String(localized: "skipped") : last, size: 12) }
                    }
                    if p.backend == .openvpn, let u = model.prefs.settings(for: p).lastUsername, !u.isEmpty {
                        LabeledContent("Last Username") {
                            HStack {
                                Mono(u, size: 12)
                                Button("Forget") {
                                    var s = model.prefs.settings(for: p)
                                    s.lastUsername = nil
                                    model.prefs.setSettings(s, for: p)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    Text(routeFixHint(p)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(minHeight: p.backend == .openvpn || p.backend == .wireguard ? 220 : (p.backend == .cisco ? 150 : 70))
        }
    }

    private func routeFixHint(_ p: Profile) -> String {
        p.backend == .openvpn
            ? String(localized: "A host route to the VPN server via the LAN gateway, for when macOS sends it out the wrong interface. Servers reachable through another tunnel (VPN-in-VPN) are skipped automatically.")
            : String(localized: "Usually not needed for WireGuard — wg-quick routes to the Endpoint itself. Turn it on if the endpoint goes out the wrong interface.")
    }

    private func routeFixBinding(_ p: Profile) -> Binding<Int> {
        Binding(get: {
            switch model.prefs.settings(for: p).routeFix {
            case .ask: 0
            case .lanDefault: 1
            case .gateway: 2
            case .off: 3
            }
        }, set: { v in
            setMode(p, [RouteFixMode.ask, .lanDefault, .gateway(fixedGW.isEmpty ? model.config.defaultGateway : fixedGW), .off][v])
        })
    }

    private func setMode(_ p: Profile, _ m: RouteFixMode) {
        var s = model.prefs.settings(for: p)
        s.routeFix = m
        model.prefs.setSettings(s, for: p)
    }

    private func saveAlias(_ p: Profile) {
        let a = alias.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { model.prefs.aliases.removeValue(forKey: p.key) } else { model.prefs.aliases[p.key] = a }
    }

    // MARK: інформація

    private var statusText: String {
        switch item.status {
        case .up: String(localized: "connected")
        case .off: String(localized: "off")
        case .busy(let t): t
        case .connecting: String(localized: "connecting")
        case .retry: String(localized: "retrying")
        case .unknown: String(localized: "state unknown")
        case .failed: String(localized: "error")
        case .stale: String(localized: "session expired")
        }
    }

    private var rows: [(String, String)] {
        let p = item.profile, s = item.session
        var r: [(String, String)] = []
        if let s, let i = s.iface { r.append((String(localized: "Interface"), [i, s.address].compactMap { $0 }.joined(separator: " · "))) }
        if let e = s?.elapsed { r.append((String(localized: "Uptime"), e)) }
        if let pid = s?.pid { r.append(("PID", String(pid))) }
        if let s, !s.routes.isEmpty { r.append((String(localized: "Routes"), s.routes.joined(separator: ", "))) }
        if let s, !s.dnsServers.isEmpty { r.append((String(localized: "Tunnel DNS"), s.dnsServers.joined(separator: " "))) }
        switch item.status {
        case .retry(let e), .failed(let e): r.append((String(localized: "Error"), e))
        default: break
        }
        r += info
        switch p.backend {
        case .openvpn:
            if !p.remotes.isEmpty { r.append(("Remote", p.endpoint ?? p.remotes.joined(separator: ", "))) }
            r.append((String(localized: "Login"), p.needsAuth ? String(localized: "auth-user-pass (username + password/OTP)") : String(localized: "no login")))
        case .defguard:
            if let e = p.endpoint { r.append(("Endpoint", e)) }
            r.append((String(localized: "Type"), p.dgKind ?? "—"))
            r.append(("MFA", p.mfa ?? String(localized: "no")))
            if let a = p.allTraffic { r.append((String(localized: "Routes"), a ? String(localized: "all traffic") : "split")) }
        case .cisco:
            r.append(("Host", p.name))
        case .wireguard:
            break
        }
        if let path = p.path { r.append((String(localized: "File"), path)) }
        return r
    }

    static func blockTitle(_ tag: String) -> String {
        switch tag {
        case "cert": String(localized: "Certificate <cert>…")
        case "key": String(localized: "Private Key <key>…")
        case "ca": "CA <ca>…"
        default: "<\(tag)>…"
        }
    }

    /// Які вбудовані блоки є у профілі — лише їх пропонуємо замінити.
    private func loadBlocks() {
        guard item.profile.backend == .openvpn, let path = item.profile.path,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { blocks = []; return }
        blocks = OvpnFiles.blockTags.filter { text.contains("<\($0)>") }
    }

    private func loadInfo() async {
        let p = item.profile
        guard p.backend == .wireguard, let path = p.path else { return }
        var text = try? String(contentsOfFile: path, encoding: .utf8)
        if text == nil { text = await model.helper.readIfAvailable(.readWGConf(path: path))?.output }
        guard let text else { info = [("Endpoint", String(localized: "root-only config — install the helper (Settings → Helper)"))]; return }
        let c = Parse.wgConf(text)
        info = [("Endpoint", c.endpoint), (String(localized: "Address"), c.address), ("DNS", c.dns), ("AllowedIPs", c.allowedIPs)]
            .compactMap { k, v in v.map { (k, $0) } }
    }
}
