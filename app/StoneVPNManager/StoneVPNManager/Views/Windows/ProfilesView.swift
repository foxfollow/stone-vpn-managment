import SwiftUI
import StoneVPNCore

/// Вікно «Профілі»: провайдери → профілі → деталі + налаштування профілю (alias, обране, route-fix).
struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var addingHost = false
    @State private var newHost = ""

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.profilesBackend }, set: { if let b = $0 { model.profilesBackend = b; model.profilesSelection = nil } })) {
                Section("Провайдери") {
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
                    Section("Вимкнені (DISABLED_BACKENDS)") {
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
                                    Text("останній").font(.system(size: 9.5)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 4).background(.quaternary, in: Capsule())
                                }
                            }
                            Mono(it.profile.endpoint ?? it.profile.name, size: 10.5).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(it.id)
                    .contextMenu {
                        Button(it.status.isActive ? "Відключити" : "Підключити") { model.toggle(it) }
                        Button(model.prefs.isFavorite(it.id) ? "Прибрати з обраних" : "Додати в обрані") { model.prefs.toggleFavorite(it.id) }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Пошук")
            .overlay {
                if items.isEmpty { ContentUnavailableView("Немає профілів", systemImage: "shield.slash", description: Text(emptyHint)) }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let key = model.profilesSelection, let it = model.items(for: model.profilesBackend).first(where: { $0.id == key }) {
                ProfileDetail(model: model, item: it).id(it.id)
            } else {
                ContentUnavailableView("Оберіть профіль", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(manageCommands, id: \.0) { c in Button(c.0) { runInTerminal(c.1) } }
                    if model.profilesBackend == .cisco {
                        Button("Додати хост…") { newHost = CiscoPrefs.load().suggestedHost ?? ""; addingHost = true }
                    }
                    if model.profilesBackend == .defguard {
                        Button("Відкрити Defguard.app") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Defguard.app")) }
                    }
                } label: { Label("Керування", systemImage: "plus") }
                .help("Додати / імпорт / сертифікати")
            }
            ToolbarItem {
                Button { Task { await model.refresh(forceSlow: true) } } label: { Label("Оновити", systemImage: "arrow.clockwise") }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .alert("Новий Cisco-хост", isPresented: $addingHost) {
            TextField("host:port", text: $newHost)
            Button("Додати") { model.addCiscoHost(newHost) }
            Button("Скасувати", role: .cancel) {}
        } message: { Text("Можна з портом, напр. vpn.example.com:8448") }
    }

    private var emptyHint: String {
        switch model.profilesBackend {
        case .wireguard: "Конфіги *.conf у /opt/homebrew/etc/wireguard, /usr/local/etc/wireguard або /etc/wireguard (root-only теки видно після встановлення helper)."
        case .openvpn: "Профілі *.ovpn у \(model.config.ovpnProfilesDir)."
        case .defguard: "Локації додаються в Defguard.app."
        case .cisco: "Хости з профілю Cisco (vpn -s hosts)."
        }
    }

    /// Керування конфігами/сертифікатами — інтерактивні CLI-скрипти репо в Terminal.
    private var manageCommands: [(String, String)] {
        switch model.profilesBackend {
        case .wireguard: [("WireGuard: згенерувати / імпорт / видалити… (Terminal)", "cert wg")]
        case .openvpn: [("OpenVPN: додати / замінити сертифікат / видалити… (Terminal)", "cert openvpn")]
        default: []
        }
    }

    private func runInTerminal(_ args: String) {
        guard model.config.sharedWithCLI, let repo = model.config.repo else {
            model.toast = "Керування сертифікатами працює через CLI-репозиторій (Settings → Додатково)"; return
        }
        let cmd = "cd '\(repo.path)' && ./main-vpn-manager.sh \(args)"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        Task { _ = await Shell.run("/usr/bin/osascript", ["-e", script]) }
    }
}

struct ProfileDetail: View {
    @Bindable var model: AppModel
    var item: ProfileItem
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
                    Button(item.status.isActive ? "Відключити" : "Підключити") { model.toggle(item) }
                        .buttonStyle(.borderedProminent)
                        .tint(item.status.isActive ? .red : .accentColor)
                    let fav = model.prefs.isFavorite(item.id)
                    Button { model.prefs.toggleFavorite(item.id) } label: {
                        Label(fav ? "В обраних" : "В обрані", systemImage: fav ? "star.fill" : "star")
                    }
                    if let path = p.path {
                        Button("Показати у Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                    if p.backend == .openvpn, FileManager.default.fileExists(atPath: "/tmp/openvpn-\(p.name).log") {
                        Button("Лог") { NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/openvpn-\(p.name).log")) }
                    }
                }

                settings(p)
            }
            .padding(24)
        }
        .task { await loadInfo() }
        .onAppear {
            alias = model.prefs.aliases[p.key] ?? ""
            hostEdit = p.name
            if case .gateway(let g) = model.prefs.settings(for: p).routeFix { fixedGW = g }
        }
    }

    // MARK: налаштування профілю

    @ViewBuilder private func settings(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Налаштування профілю")
            Form {
                TextField("Псевдонім", text: $alias, prompt: Text(p.title ?? p.name))
                    .onSubmit { saveAlias(p) }
                    .onChange(of: alias) { saveAlias(p) }
                if p.backend == .cisco {
                    let custom = model.prefs.ciscoHosts.contains(p.name)
                    TextField("Хост", text: $hostEdit, prompt: Text("host:port"))
                        .onSubmit { model.editCiscoHost(p.name, to: hostEdit) }
                    HStack {
                        Text(custom ? "Власний хост StoneVPN (не з профілю Cisco)." : "З профілю Cisco (head-end перезаписує його) — зміна збереже копію у StoneVPN.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(custom ? "Зберегти" : "Зберегти копію") { model.editCiscoHost(p.name, to: hostEdit) }
                            .disabled(hostEdit.isEmpty || hostEdit == p.name)
                        if custom { Button("Видалити", role: .destructive) { model.removeCiscoHost(p.name) } }
                    }
                }
                if p.backend == .openvpn || p.backend == .wireguard {
                    Picker("Route-fix", selection: routeFixBinding(p)) {
                        Text("Питати при підключенні").tag(0)
                        Text("Поточний LAN-шлюз").tag(1)
                        Text("Фіксований шлюз").tag(2)
                        Text("Ніколи").tag(3)
                    }
                    if case .gateway = model.prefs.settings(for: p).routeFix {
                        TextField("Шлюз", text: $fixedGW, prompt: Text("192.168.0.1"))
                            .onSubmit { setMode(p, .gateway(fixedGW)) }
                            .onChange(of: fixedGW) { if Parse.ipv4(fixedGW) != nil { setMode(p, .gateway(fixedGW)) } }
                    }
                    if let last = model.prefs.settings(for: p).lastGateway {
                        LabeledContent("Останній вибір шлюзу") { Mono(last.isEmpty ? "пропущено" : last, size: 12) }
                    }
                    if p.backend == .openvpn, let u = model.prefs.settings(for: p).lastUsername, !u.isEmpty {
                        LabeledContent("Останній логін") {
                            HStack {
                                Mono(u, size: 12)
                                Button("Забути") {
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
            ? "Host-маршрут до VPN-сервера через LAN-шлюз, коли macOS веде його не тим інтерфейсом. Сервери, досяжні через інший тунель (VPN-у-VPN), пропускаються автоматично."
            : "Для WireGuard зазвичай не потрібен — wg-quick сам веде маршрут до Endpoint. Увімкни, якщо endpoint іде не тим інтерфейсом."
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
        case .up: "підключено"
        case .off: "вимкнено"
        case .busy(let t): t
        case .connecting: "підключається"
        case .retry: "повторює спроби"
        case .unknown: "стан невідомий"
        case .failed: "помилка"
        case .stale: "сесія протухла"
        }
    }

    private var rows: [(String, String)] {
        let p = item.profile, s = item.session
        var r: [(String, String)] = []
        if let s, let i = s.iface { r.append(("Interface", [i, s.address].compactMap { $0 }.joined(separator: " · "))) }
        if let e = s?.elapsed { r.append(("Час", e)) }
        if let pid = s?.pid { r.append(("PID", String(pid))) }
        if let s, !s.routes.isEmpty { r.append(("Маршрути", s.routes.joined(separator: ", "))) }
        if let s, !s.dnsServers.isEmpty { r.append(("DNS тунелю", s.dnsServers.joined(separator: " "))) }
        switch item.status {
        case .retry(let e), .failed(let e): r.append(("Помилка", e))
        default: break
        }
        r += info
        switch p.backend {
        case .openvpn:
            if !p.remotes.isEmpty { r.append(("Remote", p.endpoint ?? p.remotes.joined(separator: ", "))) }
            r.append(("Логін", p.needsAuth ? "auth-user-pass (логін + пароль/OTP)" : "без логіна"))
        case .defguard:
            if let e = p.endpoint { r.append(("Endpoint", e)) }
            r.append(("Тип", p.dgKind ?? "—"))
            r.append(("MFA", p.mfa ?? "ні"))
            if let a = p.allTraffic { r.append(("Маршрути", a ? "весь трафік" : "split")) }
        case .cisco:
            r.append(("Host", p.name))
        case .wireguard:
            break
        }
        if let path = p.path { r.append(("Файл", path)) }
        return r
    }

    private func loadInfo() async {
        let p = item.profile
        guard p.backend == .wireguard, let path = p.path else { return }
        var text = try? String(contentsOfFile: path, encoding: .utf8)
        if text == nil { text = await model.helper.readIfAvailable(.readWGConf(path: path))?.output }
        guard let text else { info = [("Endpoint", "конфіг root-only — встанови helper (Settings → Helper)")]; return }
        let c = Parse.wgConf(text)
        info = [("Endpoint", c.endpoint), ("Address", c.address), ("DNS", c.dns), ("AllowedIPs", c.allowedIPs)]
            .compactMap { k, v in v.map { (k, $0) } }
    }
}
