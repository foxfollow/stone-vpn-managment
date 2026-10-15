import AppKit
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications
import StoneVPNCore
import StoneVPNShared

enum ProfileStatus: Equatable {
    case off
    case busy(String)          // наша дія триває
    case up
    case connecting            // сесія піднімається
    case retry(String)         // процес живий, але в retry-циклі з помилкою
    case unknown               // процес живий, лог недоступний
    case failed(String)        // остання спроба впала, сесії немає

    var isActive: Bool {
        switch self {
        case .off, .failed: false
        default: true
        }
    }
}

struct ProfileItem: Identifiable {
    var profile: Profile
    var session: Session?
    var status: ProfileStatus
    var id: String { profile.key }
}

struct ProviderRow: Identifiable {
    var backend: Backend
    var main: ProfileItem?
    var subs: [ProfileItem]
    var up: Int
    var total: Int
    var id: String { backend.rawValue }
}

struct ConnectRequest: Identifiable {
    let id = UUID()
    var profile: Profile
    var needsAuth = false
    var username = ""
    var password = ""
    var plan: RouteFixPlan?
    var askGateway = false
    var gateway = ""              // "" = пропустити route-fix
    var mfa = false
    var code = ""
    var guiRunning = false        // Defguard.app / Cisco GUI
    // Cisco
    var host = ""
    var hostOptions: [String] = []
    var group = ""
    var secondPassword = ""
    var banner: String?
    var groups: [String] = []
    var groupsLoading = false
    var groupsNote: String?
    var groupsFor = ""            // хост, для якого отримано список
    var steps: [String] = []
    var error: String?
    var running = false
}

enum DoctorPrompt {
    case defguard(name: String, iface: String)
    case kill(procs: [Actions.TunnelProc], iface: String, owner: String?)
}

enum IconTone { case idle, ok, busy, problem, foreign }

/// DNS активного тунелю — кандидат на основний DNS і підказка для split-правил.
struct DNSCandidate: Identifiable, Hashable {
    var id: String          // session id
    var label: String
    var servers: [String]
    var iface: String?
}

@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    var prefs = Prefs()
    @ObservationIgnored let helper = HelperClient()
    @ObservationIgnored lazy var reader = StatusReader(priv: helper)
    @ObservationIgnored lazy var actions = Actions(runner: helper, reader: helper)

    var config = RepoConfig()
    var snap = Snapshot()
    var loaded = false
    var dnsProbes: [String: Bool] = [:]
    var dnsHealthy: Bool?
    var primaryOnline: Bool?
    var busy: [String: String] = [:]
    var errors: [String: String] = [:]
    var toast: String?
    var connect: ConnectRequest?
    var popoverOpen = false
    var profilesBackend: Backend = .wireguard
    var profilesSelection: String?
    var editingList = false
    var openTool: String?
    var doctorLog: [String] = []
    var doctorRunning = false
    var doctorPrompt: DoctorPrompt?
    var services: [NetworkService] = []
    var serviceOnline: [String: Bool] = [:]
    var serviceDNS: [String: [String]] = [:]
    var splitRules: [(domain: String, servers: [String])] = []
    var dnsCandidates: [DNSCandidate] = []
    var helperStatus: SMAppService.Status = .notRegistered
    var helperVersion: Int?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Після down WireGuard: вікно, в якому застосунок стежить за DNS і повертає еталон.
    var dnsGuardActive = false

    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var stopping: Set<String> = []
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var lastOnlineProbe = Date.distantPast
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastAutoFix = Date.distantPast
    @ObservationIgnored private var wgDNSCache: [String: [String]] = [:]
    @ObservationIgnored private var guardTask: Task<Void, Never>?
    @ObservationIgnored private var lastLearn = Date.distantPast
    @ObservationIgnored private var lastGuardCheck = Date.distantPast
    @ObservationIgnored private var guardNoHelperNotified = false
    @ObservationIgnored private var reassertTimes: [Date] = []
    @ObservationIgnored private var reassertNotified = false

    // MARK: життєвий цикл

    func start() {
        guard !started else { return }
        started = true
        reloadConfig()
        reader.store.watch { Task { @MainActor in AppModel.shared.scheduleRefresh() } }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await checkHelper() }
        Task { await refresh(forceSlow: true) }
        Task {
            while true {
                let s = (popoverOpen || !busy.isEmpty) ? 3 : max(5, prefs.backgroundInterval)
                try? await Task.sleep(for: .seconds(s))
                await refresh()
            }
        }
    }

    func reloadConfig() {
        config = RepoConfig.load(explicitRepo: prefs.repoPath, standalone: prefs.standalone)
    }

    /// Запис у config.env (спільний з CLI), потім перечитати.
    func updateConfig(_ edit: (inout EnvFile) -> Void) {
        do { try config.saveConfig(edit) } catch { toast = "config.env: \(error.localizedDescription)" }
        reloadConfig()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { await refresh() }
        }
    }

    func refresh(forceSlow: Bool = false) async {
        if refreshing { pendingRefresh = true; return }
        refreshing = true
        let old = snap
        let new = await reader.snapshot(config: config, forceSlow: forceSlow)
        snap = new
        helperStatus = helper.status
        // Активне Cisco-з'єднання (напр. з GUI на :8448) зберігаємо як профіль.
        for s in new.sessions where s.backend == .cisco {
            let known = (new.profiles[.cisco] ?? []).contains { $0.name == s.name } || prefs.ciscoHosts.contains(s.name)
            if !known { prefs.ciscoHosts.append(s.name) }
        }
        if loaded { notifyDiff(old: old, new: new) }
        await loadDNSCandidates()
        await dropStalePrimaryDNS()
        await reassertPrimaryDNS()
        // WG-тунель зник (з app, CLI, сну, падіння) — стежимо за DNS, поки не стане здоровим.
        let hadWG = old.sessions.contains { $0.backend == .wireguard }
        if loaded, hadWG, !wgActive, guardTask == nil { armDNSGuard() }
        loaded = true
        if prefs.dnsWatch, Date().timeIntervalSince(lastProbe) > 30 || new.network.dnsServers != old.network.dnsServers {
            lastProbe = Date()
            await probeDNS()
        }
        if Date().timeIntervalSince(lastOnlineProbe) > 60 || new.network.primaryIface != old.network.primaryIface {
            lastOnlineProbe = Date()
            await checkPrimaryOnline()
        }
        await maintainDNSBaseline()
        refreshing = false
        if pendingRefresh { pendingRefresh = false; await refresh() }
    }

    func probeDNS() async {
        let servers = snap.network.dnsServers
        guard !servers.isEmpty else { dnsHealthy = nil; dnsProbes = [:]; return }
        let wasHealthy = dnsHealthy
        dnsProbes = await actions.probeAll(servers)
        dnsHealthy = dnsProbes.values.contains(true)
        if wasHealthy == true, dnsHealthy == false, prefs.notifyDNS, !prefs.autoDNSFix, guardTask == nil, busy.isEmpty {
            notify("DNS не відповідає", "Резолвер \(servers.joined(separator: ", ")) мовчить. Відкрий StoneVPN → DNS → Fix.")
        }
        if dnsHealthy == false { await autoFixDNSIfIdle() }
    }

    /// Auto DNS fix: лише коли жодного VPN немає (наших сесій, сторонніх, живих utun) —
    /// тоді мертвий DNS це залишок тунелю, і doctor лагодить його без питань.
    /// Тільки з helper (без нього кожна спроба питала б пароль) і не частіше раз на 2 хв.
    func autoFixDNSIfIdle() async {
        guard prefs.autoDNSFix, !doctorRunning, busy.isEmpty, guardTask == nil,
              snap.sessions.isEmpty, snap.foreign.isEmpty, snap.routeGroups.isEmpty,
              Date().timeIntervalSince(lastAutoFix) > 120 else { return }
        lastAutoFix = Date()
        guard helper.isEnabled else {
            notify("Auto DNS fix пропущено", "DNS не відповідає, але для ремонту без пароля потрібен helper (Settings → Helper).")
            return
        }
        await runDNSFix()
        if prefs.notifyDNS {
            notify(dnsHealthy == true ? "DNS відремонтовано автоматично" : "Auto DNS fix не допоміг",
                   doctorLog.last ?? "")
        }
    }

    func checkPrimaryOnline() async {
        guard let p = snap.network.primaryIface, !p.hasPrefix("utun") else { primaryOnline = nil; return }
        primaryOnline = await actions.ifaceOnline(p)
        if primaryOnline == false, prefs.netAutoFix, helper.isEnabled {
            if let msg = try? await actions.netAuto(primaryIface: p) { notify("Мережа", msg) }
        }
    }

    // MARK: стан для UI

    var tone: IconTone {
        let n = snap.network
        if n.primaryIsTunnel, snap.foreign.contains(where: { $0.iface == n.primaryIface }) { return .foreign }
        // Під час підключення/повернення DNS мертвий резолвер — очікуваний проміжний стан.
        if !busy.isEmpty || dnsGuardActive { return .busy }
        if snap.erroredCount > 0 || dnsHealthy == false || primaryOnline == false { return .problem }
        if snap.connectingCount > 0 { return .busy }
        return snap.upCount > 0 ? .ok : .idle
    }

    var headline: String {
        let up = snap.upCount, conn = snap.connectingCount + busy.count
        if tone == .foreign { return "Мережу тримає сторонній VPN" }
        if dnsGuardActive, busy.isEmpty { return "Повертаю DNS після VPN…" }
        if dnsHealthy == false, busy.isEmpty { return "Проблема з DNS" }
        if primaryOnline == false { return "Немає інтернету" }
        if up == 0 && conn == 0 { return "Немає активних тунелів" }
        let tunnels = up == 1 ? "1 тунель активний" : "\(up) тунелі активні"
        return conn > 0 ? (up > 0 ? "\(tunnels) · \(conn) підключається" : "Підключення…") : tunnels
    }

    func items(for b: Backend) -> [ProfileItem] {
        var profiles = snap.profiles[b] ?? []
        if b == .cisco {
            for h in prefs.ciscoHosts where !profiles.contains(where: { $0.name == h }) {
                profiles.append(Profile(backend: .cisco, name: h, endpoint: h))
            }
        }
        // Сесії без профілю у списку (запуск з іншого шляху) — показати все одно.
        for s in snap.sessions where s.backend == b && !profiles.contains(where: { $0.key == s.profileKey }) {
            profiles.append(Profile(backend: b, name: s.name, endpoint: s.iface))
        }
        return profiles.map { p in
            let s = snap.session(for: p.key)
            return ProfileItem(profile: p, session: s, status: status(p, s))
        }
    }

    func status(_ p: Profile, _ s: Session?) -> ProfileStatus {
        if let b = busy[p.key] { return .busy(b) }
        if let s {
            switch s.state {
            case .up: return .up
            case .unknown: return .unknown
            case .connecting(let e): return (e?.isEmpty == false) ? .retry(e!) : .connecting
            }
        }
        if let e = errors[p.key] { return .failed(e) }
        return .off
    }

    var rows: [ProviderRow] {
        prefs.orderedBackends.filter { config.isOn($0) && !prefs.hiddenProviders.contains($0.rawValue) }.map { b in
            let items = items(for: b)
            let active = items.first { $0.status.isActive }
            let last = prefs.lastProfile[b.rawValue].flatMap { k in items.first { $0.id == k } }
            let main = active ?? last ?? items.first
            let subs = items.filter { $0.id != main?.id && (prefs.isFavorite($0.id) || $0.status.isActive) }
            return ProviderRow(backend: b, main: main, subs: subs,
                               up: items.filter { $0.status == .up }.count, total: items.count)
        }
    }

    var hiddenBackends: [Backend] {
        prefs.orderedBackends.filter { config.isOn($0) && prefs.hiddenProviders.contains($0.rawValue) }
    }

    // MARK: підключення

    func toggle(_ item: ProfileItem) {
        Task {
            if item.status.isActive { await disconnect(item.profile, session: item.session) }
            else { await connect(item.profile) }
        }
    }

    func connect(_ p: Profile) async {
        errors[p.key] = nil
        busy[p.key] = "перевірка DNS…"
        await prepareDNS(for: p)
        await checkEndpointResolves(p)
        busy[p.key] = nil
        var r = ConnectRequest(profile: p)
        let s = prefs.settings(for: p)
        switch p.backend {
        case .wireguard, .openvpn:
            busy[p.key] = "перевірка маршруту…"
            var hosts = p.remotes
            if p.backend == .wireguard, s.routeFix != .off, let h = await actions.wgEndpointHost(p) { hosts = [h] }
            if s.routeFix != .off, !hosts.isEmpty {
                let plan = await actions.routeFixPlan(hosts: hosts, lastGateway: s.lastGateway ?? config.defaultGateway)
                let g = actions.resolveGateway(s.routeFix, plan: plan)
                r.plan = plan
                r.askGateway = g.ask
                r.gateway = g.gw ?? (g.ask ? (s.lastGateway ?? config.defaultGateway) : "")
            }
            busy[p.key] = nil
            if p.backend == .openvpn, p.needsAuth {
                r.needsAuth = true
                r.username = config.defaultUsername
            }
        case .defguard:
            if p.mfa != nil {
                r.mfa = true
                r.guiRunning = await actions.dgGUIRunning()
            }
        case .cisco:
            r.guiRunning = await actions.ciscoGUIRunning()
            let cp = CiscoPrefs.load()
            var opts = items(for: .cisco).map(\.profile.name)
            if let s = cp.suggestedHost, !opts.contains(s) { opts.insert(s, at: 0) }
            r.hostOptions = opts
            // Обраний профіль; якщо в нього немає порту, а Cisco пам'ятає той самий хост з портом — пропонуємо з портом.
            r.host = p.name
            if !p.name.contains(":"), let s = cp.suggestedHost, s.hasPrefix(p.name + ":") { r.host = s }
            r.username = prefs.ciscoLastUser.isEmpty ? cp.user : prefs.ciscoLastUser
            r.group = prefs.ciscoLastGroup.isEmpty ? cp.group : prefs.ciscoLastGroup
        }
        if r.needsAuth || r.askGateway || r.mfa || p.backend == .cisco {
            connect = r
            openWindow("connect")
            if p.backend == .cisco { await probeCiscoGroups() }
        } else {
            _ = await perform(r)
        }
    }

    /// Власне підключення (з панелі або напряму). true = успіх.
    func perform(_ r: ConnectRequest) async -> Bool {
        let p = r.profile
        busy[p.key] = "підключається…"
        defer { busy[p.key] = nil }
        func step(_ s: String) { busy[p.key] = s; connect?.steps.append(s) }
        do {
            if let plan = r.plan, !plan.isEmpty || !plan.staleDeletes.isEmpty {
                step("Route-fix")
                _ = try await actions.applyRouteFix(plan, gateway: r.gateway.isEmpty ? nil : r.gateway)
                if !r.gateway.isEmpty, !plan.isEmpty {
                    var s = prefs.settings(for: p)
                    s.lastGateway = r.gateway
                    prefs.setSettings(s, for: p)
                    if prefs.rememberGateway { config.setState("LAST_GATEWAY", r.gateway) }
                }
            }
            switch p.backend {
            case .wireguard:
                step("wg-quick up")
                try await actions.wgUp(p)
            case .openvpn:
                if r.needsAuth, prefs.rememberUser, !r.username.isEmpty { config.setState("LAST_USERNAME", r.username) }
                let key = p.key
                _ = try await actions.ovpnUp(p, username: r.username, password: r.password, timeout: prefs.ovpnTimeout) { s in
                    Task { @MainActor in
                        AppModel.shared.busy[key] = s
                        AppModel.shared.connect?.steps.append(s)
                    }
                }
            case .defguard:
                step("defguard-client connect")
                try await actions.dgUp(p, code: r.code, cliPath: config.defguardCLI)
            case .cisco:
                if r.guiRunning { step("Закриваю GUI Cisco"); await actions.ciscoQuitGUI() }
                let host = r.host.trimmingCharacters(in: .whitespaces)
                guard !host.isEmpty else { throw ActionError("вкажи хост") }
                let creds = CiscoCredentials(host: host, group: r.group, user: r.username, password: r.password, secondPassword: r.secondPassword)
                try await actions.ciscoConnect(creds) { ev in
                    Task { @MainActor in
                        switch ev {
                        case .step(let s): AppModel.shared.connect?.steps.append(s); AppModel.shared.busy[p.key] = s
                        case .banner(let b): AppModel.shared.connect?.banner = b
                        }
                    }
                }
                prefs.ciscoLastUser = r.username
                prefs.ciscoLastGroup = r.group
                if !(snap.profiles[.cisco] ?? []).contains(where: { $0.name == host }), !prefs.ciscoHosts.contains(host) {
                    prefs.ciscoHosts.append(host)
                }
                prefs.lastProfile[p.backend.rawValue] = "cisco:\(host)"
                await refresh()
                if prefs.notifyConnected { notify("Підключено", "Cisco · \(host)") }
                return true
            }
            prefs.lastProfile[p.backend.rawValue] = p.key
            reloadConfig()
            await refresh()
            if prefs.notifyConnected { notify("Підключено", "\(p.backend.title) · \(prefs.display(p))") }
            return true
        } catch {
            errors[p.key] = error.localizedDescription
            connect?.error = error.localizedDescription
            await refresh()
            return false
        }
    }

    // MARK: Cisco-хости (власні, з портом)

    func addCiscoHost(_ h: String) {
        let host = h.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !items(for: .cisco).contains(where: { $0.profile.name == host }) else { return }
        prefs.ciscoHosts.append(host)
        profilesSelection = "cisco:\(host)"
    }

    /// Власний хост — перейменувати (з перенесенням alias/обраного/останнього); з профілю Cisco — зберегти копію.
    func editCiscoHost(_ old: String, to new: String) {
        let host = new.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, host != old else { return }
        if let i = prefs.ciscoHosts.firstIndex(of: old) {
            prefs.ciscoHosts[i] = host
            let ok = "cisco:\(old)", nk = "cisco:\(host)"
            if let a = prefs.aliases.removeValue(forKey: ok) { prefs.aliases[nk] = a }
            if let f = prefs.favorites.firstIndex(of: ok) { prefs.favorites[f] = nk }
            if prefs.lastProfile["cisco"] == ok { prefs.lastProfile["cisco"] = nk }
        } else if !prefs.ciscoHosts.contains(host) {
            prefs.ciscoHosts.append(host)
        }
        profilesSelection = "cisco:\(host)"
    }

    func removeCiscoHost(_ h: String) {
        prefs.ciscoHosts.removeAll { $0 == h }
        prefs.favorites.removeAll { $0 == "cisco:\(h)" }
        profilesSelection = nil
    }

    /// Підтягнути групи з сервера для поточного хоста у вікні підключення.
    func probeCiscoGroups(closeGUI: Bool = false) async {
        guard let host = connect?.host.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return }
        if connect?.guiRunning == true {
            guard closeGUI else { connect?.groupsNote = "GUI Cisco відкритий — CLI не може отримати групи"; return }
            await actions.ciscoQuitGUI()
            connect?.guiRunning = false
        }
        connect?.groupsLoading = true
        connect?.groupsNote = nil
        defer { if connect?.host == host { connect?.groupsLoading = false } }
        do {
            let r = try await actions.ciscoProbeGroups(host)
            guard connect?.host == host else { return }      // хост змінили, поки чекали
            connect?.groupsFor = host
            connect?.groups = r.groups
            if !r.asksGroup {
                connect?.group = ""
                connect?.groupsNote = "Сервер не пропонує вибору групи"
            } else if let cur = connect?.group, r.groups.contains(cur) {
                // залишаємо обрану (з минулого разу)
            } else {
                connect?.group = r.defaultGroup ?? r.groups.first ?? ""
            }
        } catch {
            guard connect?.host == host else { return }
            connect?.groupsNote = error.localizedDescription
        }
    }

    func ciscoInTerminal(_ host: String) {
        Task {
            do { try await actions.ciscoConnectInTerminal(host) } catch { connect?.error = error.localizedDescription }
        }
    }

    func disconnect(_ p: Profile, session: Session?) async {
        stopping.insert(p.key)
        busy[p.key] = "відключається…"
        errors[p.key] = nil
        do {
            switch p.backend {
            case .wireguard:
                var prof = p
                if prof.path == nil, let d = snap.wgDir { prof.path = "\(d)/\(p.name).conf" }
                try await actions.wgDown(prof)
            case .openvpn:
                guard let pid = session?.pid else { throw ActionError("PID невідомий") }
                try await actions.ovpnDown(pid: pid)
            case .defguard:
                try await actions.dgDown(p.name, kind: p.dgKind, cliPath: config.defguardCLI)
            case .cisco:
                try await actions.ciscoDisconnect()
            }
            // DNS після down: Defguard/Cisco відновлюють свій самі → лише flush.
            if p.backend.restoresOwnDNS {
                if helper.isEnabled { try? await actions.dnsFlush() }
            } else if p.backend == .wireguard, prefs.dnsGuard {
                // wg-quick відновлює DNS сам, але не завжди — guard перевіряє й повертає еталон.
                busy[p.key] = nil
                await refresh()
                if !wgActive { armDNSGuard() }
            } else if prefs.autoRestoreDNS, !config.restoreDNS.isEmpty {
                try? await actions.restoreDNS(config, orphans: reader.store.network().orphanDNS)
            }
            if prefs.notifyDisconnected { notify("Відключено", "\(p.backend.title) · \(prefs.display(p))") }
        } catch {
            errors[p.key] = error.localizedDescription
            stopping.remove(p.key)
        }
        busy[p.key] = nil
        await refresh()
    }

    func disconnectAll() {
        Task {
            for b in Backend.allCases where config.isOn(b) {
                for it in items(for: b) where it.status.isActive { await disconnect(it.profile, session: it.session) }
            }
        }
    }

    // MARK: DNS doctor (cmd_dns_fix)

    func runDNSFix() async {
        doctorRunning = true
        doctorLog = []
        doctorPrompt = nil
        defer { doctorRunning = false }
        let net = reader.store.network()
        let probes = await actions.probeAll(net.dnsServers)
        dnsProbes = probes
        let alive = probes.values.contains(true)
        doctorLog.append("первинний: \(net.primaryIface ?? "немає") · резолвер: " +
                         (net.dnsServers.isEmpty ? "(порожньо)" : net.dnsServers.map { "\($0) \(probes[$0] == true ? "✓" : "✗")" }.joined(separator: " ")))
        if let iface = net.primaryIface, net.primaryIsTunnel {
            if alive { doctorLog.append("Первинний — VPN-тунель (\(iface)), і його DNS відповідає. Лагодити нічого."); return }
            doctorLog.append("Первинний — VPN-тунель (\(iface)), але його резолвери не відповідають: чорна діра для всього трафіку. Правки DNS не допоможуть — тунель треба опустити.")
            let owner = snap.routeGroups.first { $0.iface == iface }?.owner
            if let owner, owner.hasPrefix("Defguard ") {
                doctorPrompt = .defguard(name: String(owner.dropFirst("Defguard ".count)), iface: iface)
            } else {
                doctorPrompt = .kill(procs: await actions.tunnelProcs().filter { !$0.isDaemon }, iface: iface, owner: owner)
            }
            return
        }
        if alive, net.orphanDNS.isEmpty {
            doctorLog.append("Все здорове: резолвер відповідає, осиротілих записів немає.")
            dnsHealthy = true
            return
        }
        await repairDNS()
    }

    /// «Розірвати…» на рядку стороннього VPN — показати процеси і чекати підтвердження.
    func offerTakeDown(_ s: Session) async {
        openTool = "dns"
        doctorLog = ["\(s.name) (\(s.iface ?? "")) — сторонній тунель, керується своїм застосунком."]
        doctorPrompt = .kill(procs: await actions.tunnelProcs().filter { !$0.isDaemon }, iface: s.iface ?? "", owner: s.name)
    }

    func confirmTakeDown() async {
        guard let prompt = doctorPrompt else { return }
        doctorPrompt = nil
        doctorRunning = true
        defer { doctorRunning = false }
        do {
            switch prompt {
            case .defguard(let name, _):
                try await actions.dgDown(name, kind: nil, cliPath: config.defguardCLI)
            case .kill(let procs, _, _):
                try await actions.killProcs(procs.map(\.pid))
            }
        } catch {
            doctorLog.append("Не вдалося: \(error.localizedDescription)")
            return
        }
        // macOS відпускає маршрут+DNS тунелю асинхронно — чекаємо, а не фіксовану паузу.
        doctorLog.append("чекаю, поки тунель відпустить мережу…")
        for _ in 0..<20 {
            if !reader.store.network().primaryIsTunnel { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if reader.store.network().primaryIsTunnel {
            doctorLog.append("Тунель досі первинний — розширення, схоже, перезапустилось. Відключи VPN у його застосунку і повтори.")
            return
        }
        await repairDNS()
    }

    func repairDNS(want: [String]? = nil) async {
        let net = reader.store.network()
        let svcs = await actions.services()
        var svc = svcs.first { !$0.device.isEmpty && $0.device == net.primaryIface }?.name
        if svc == nil { svc = config.dnsServices.first { n in svcs.contains { $0.name == n } } }
        guard let svc else { doctorLog.append("Не знайшов реального сервісу для ремонту (DNS_SERVICES у config.env)."); return }
        // Еталон > RESTORE_DNS > поточний (якщо це не DNS тунелю) > 1.1.1.1.
        let tun = await tunnelDNS()
        var servers = want ?? []
        if servers.isEmpty, let b = prefs.dnsBaseline[svc], !b.isEmpty, tun.isDisjoint(with: b) { servers = b }
        if servers.isEmpty { servers = config.restoreServers }
        if servers.isEmpty { servers = await actions.serviceDNS(svc).filter { !tun.contains($0) } }
        if servers.isEmpty { servers = ["1.1.1.1"] }
        doctorLog.append("ремонтую через «\(svc)»: \(servers.joined(separator: " "))")
        do {
            let out = try await actions.repairDNS(service: svc, servers: servers, orphans: net.orphanDNS)
            if !out.isEmpty { doctorLog.append(out) }
        } catch {
            doctorLog.append("Не вдалося: \(error.localizedDescription)")
            return
        }
        // Чесна перевірка: правильна конфігурація ще не означає робочий DNS.
        try? await Task.sleep(for: .seconds(1))
        let after = reader.store.network()
        dnsProbes = await actions.probeAll(after.dnsServers)
        dnsHealthy = dnsProbes.values.contains(true)
        if dnsHealthy == true {
            doctorLog.append("Готово — DNS відповідає.")
        } else {
            doctorLog.append("Резолвер досі не відповідає. Конфігурацію виправлено, тож проблема нижче — маршрути/мережа." +
                             (after.primaryIsTunnel ? " Первинний досі \(after.primaryIface ?? "") — VPN не відпустив мережу." : ""))
        }
        await refresh()
    }

    func flushDNS() {
        Task {
            do { try await actions.dnsFlush(); toast = "DNS-кеш очищено" } catch { toast = error.localizedDescription }
        }
    }

    func loadSplit() { splitRules = actions.splitRules() }

    // MARK: повернення DNS після WireGuard (DNSGuard)

    /// WG-тунель живий або саме піднімається/опускається — Setup-DNS тоді належить wg-quick.
    var wgActive: Bool {
        snap.sessions.contains { $0.backend == .wireguard } || busy.keys.contains { $0.hasPrefix("wireguard:") }
    }

    /// Жодного тунелю: ні наших сесій, ні сторонніх, ні живих utun.
    private var noTunnels: Bool { snap.sessions.isEmpty && snap.foreign.isEmpty && snap.routeGroups.isEmpty }

    /// Публічні резолвери не вважаються «DNS тунелю», навіть якщо стоять у WG-конфігу:
    /// вони працюють і без VPN, а користувач часто тримає їх на Wi-Fi.
    private static let publicResolvers: Set<String> = [
        "1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112", "208.67.222.222", "208.67.220.220",
    ]

    /// DNS, які wg-quick міг розкидати по сервісах: `DNS =` усіх WG-конфігів (+ колись бачені).
    /// Cisco/Defguard пишуть State-шар, а не сервіси, — їх тут немає навмисно.
    func tunnelDNS() async -> Set<String> {
        var s = Set(prefs.wgDNSSeen)
        for p in snap.profiles[.wireguard] ?? [] { s.formUnion(await wgDNS(p.name)) }
        s = s.filter { Parse.ipv4($0) != nil || $0.contains(":") }.subtracting(Self.publicResolvers)
        if !s.isSubset(of: prefs.wgDNSSeen) { prefs.wgDNSSeen = s.sorted() }
        return s
    }

    /// Раз на хвилину, поки WG немає і резолвер живий, — оновити еталон; і перевірити, чи не
    /// лишився DNS тунелю на сервісах (застосунок запустили після збою, down з іншого місця).
    private func maintainDNSBaseline() async {
        guard prefs.dnsGuard, !wgActive, busy.isEmpty, guardTask == nil else { return }
        if dnsHealthy == true, Date().timeIntervalSince(lastLearn) > 60 {
            lastLearn = Date()
            let b = DNSGuard.learn(baseline: prefs.dnsBaseline, current: reader.store.setupDNS(), tunnelDNS: await tunnelDNS())
            if b != prefs.dnsBaseline { prefs.dnsBaseline = b }
        }
        if Date().timeIntervalSince(lastGuardCheck) > 60 {
            lastGuardCheck = Date()
            if await restoreServiceDNS(background: true) { armDNSGuard() }
        }
    }

    /// Переписати сервіси, що тримають DNS тунелю, на еталон. true = щось змінено.
    /// background: лише через helper (не питати пароль без дії користувача).
    @discardableResult
    func restoreServiceDNS(background: Bool) async -> Bool {
        guard prefs.dnsGuard, !wgActive else { return false }
        var plan = DNSGuard.plan(current: reader.store.setupDNS(), baseline: prefs.dnsBaseline,
                                 tunnelDNS: await tunnelDNS(), fallback: config.restoreServers)
        guard !plan.isEmpty else { return false }
        // У Setup бувають сервіси, яких networksetup не знає (старі адаптери) — helper їх відхилить.
        let known = Set(await actions.services().map(\.name))
        plan = plan.filter { known.contains($0.key) }
        guard !plan.isEmpty else { return false }
        if background, !helper.isEnabled {
            if !guardNoHelperNotified {
                guardNoHelperNotified = true
                notify("На сервісах лишився DNS тунелю", "\(plan.keys.sorted().joined(separator: ", ")). Повернути без пароля може лише helper (Settings → Helper); або відкрий DNS → Fix.")
            }
            return false
        }
        let orphans = noTunnels ? reader.store.network().orphanDNS : []
        do {
            try await actions.restoreServiceDNS(plan, orphans: orphans)
        } catch {
            toast = "Повернення DNS: \(error.localizedDescription)"
            return false
        }
        let what = plan.keys.sorted().map { "\($0) → \(plan[$0]!.isEmpty ? "DHCP" : plan[$0]!.joined(separator: " "))" }
        toast = "DNS повернуто після VPN: " + what.joined(separator: ", ")
        loadServicesDNSIfShown()
        return true
    }

    /// Вікно спостереження після down WG: wg-quick відновлює DNS асинхронно (і інколи — старим
    /// забрудненим значенням), тож перевіряємо кілька разів, а не один.
    func armDNSGuard() {
        guard prefs.dnsGuard, guardTask == nil else { return }
        dnsGuardActive = true
        guardTask = Task { [weak self] in
            await self?.runDNSGuard()
            guard !Task.isCancelled else { return }     // скасовано prepareDNS — він уже скинув стан
            self?.dnsGuardActive = false
            self?.guardTask = nil
            await self?.refresh()
        }
    }

    private func runDNSGuard() async {
        try? await Task.sleep(for: .seconds(2))          // дати wg-quick шанс відновити самому
        var deadTicks = 0
        var cleanTicks = 0
        for _ in 0..<30 {                                  // ~60 с
            if Task.isCancelled || wgActive { return }      // уже піднімається інший WG — далі prepareDNS
            if await restoreServiceDNS(background: true) {
                cleanTicks = 0
                try? await Task.sleep(for: .seconds(1))
            }
            let net = reader.store.network()
            dnsProbes = await actions.probeAll(net.dnsServers)
            dnsHealthy = net.dnsServers.isEmpty ? nil : dnsProbes.values.contains(true)
            if dnsHealthy == false {
                deadTicks += 1
                cleanTicks = 0
                // Сервіси вже чисті, а резолвер мовчить — осиротілий State-запис: doctor.
                if deadTicks == 3, noTunnels, busy.isEmpty, helper.isEnabled {
                    await runDNSFix()
                    if dnsHealthy == true { return }
                }
            } else {
                deadTicks = 0
                cleanTicks += 1
                if cleanTicks >= 3 { return }               // ~6 с стабільно здоровий
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if dnsHealthy == false, prefs.notifyDNS {
            notify("DNS не відновився після VPN", "Резолвер \(snap.network.dnsServers.joined(separator: ", ")) мовчить. Відкрий StoneVPN → DNS → Fix.")
        }
    }

    /// Перед підключенням: залишок попереднього VPN не має заважати резолвити адресу нового.
    /// Це дія користувача, тож без helper один запит пароля тут доречний.
    private func prepareDNS(for p: Profile) async {
        guardTask?.cancel()
        guardTask = nil
        dnsGuardActive = false
        if await restoreServiceDNS(background: false) {
            try? await Task.sleep(for: .seconds(1))
        }
        // Cisco/Defguard/OpenVPN, що вже тримають DNS, — не наша справа: лише коли тунелів немає.
        guard noTunnels else { return }
        let net = reader.store.network()
        let probes = await actions.probeAll(net.dnsServers)
        dnsProbes = probes
        guard !net.dnsServers.isEmpty, !probes.values.contains(true) else { dnsHealthy = net.dnsServers.isEmpty ? nil : true; return }
        busy[p.key] = "ремонт DNS перед підключенням…"
        openTool = "dns"
        await runDNSFix()
    }

    /// Адреса сервера резолвиться? Інакше підключення впаде по таймауту без пояснень.
    private func checkEndpointResolves(_ p: Profile) async {
        var hosts: [String]
        switch p.backend {
        case .wireguard: hosts = await actions.wgEndpointHost(p).map { [$0] } ?? []
        case .openvpn: hosts = p.remotes
        case .cisco: hosts = [String(p.name.split(separator: ":").first ?? "")]
        case .defguard: hosts = []
        }
        hosts = hosts.filter { !$0.isEmpty && Parse.ipv4($0) == nil }
        guard !hosts.isEmpty else { return }
        let ok = await Task.detached { hosts.contains { Interfaces.resolve($0) != nil } }.value
        if !ok {
            toast = "\(hosts.joined(separator: ", ")) не резолвиться (DNS: \(snap.network.dnsServers.joined(separator: " "))) — підключення, найімовірніше, не вдасться. DNS → Fix або split-правило."
        }
    }

    private func loadServicesDNSIfShown() {
        guard openTool == "net" else { return }
        Task { await loadServices() }
    }

    // MARK: DNS тунелів, основний DNS, перевірка split

    func loadDNSCandidates() async {
        var out: [DNSCandidate] = []
        for s in snap.sessions where s.state == .up {
            guard let b = s.backend else { continue }
            var servers: [String]
            switch b {
            case .wireguard: servers = await wgDNS(s.name)
            case .cisco: servers = reader.store.serviceDNS("com.cisco.anyconnect")
            case .defguard: servers = s.dnsServers
            case .openvpn: servers = []      // brew openvpn не застосовує pushed DNS
            }
            servers = servers.filter { Parse.ipv4($0) != nil || $0.contains(":") }
            guard !servers.isEmpty else { continue }
            let prof = snap.profiles[b]?.first { $0.key == s.profileKey }
            out.append(DNSCandidate(id: s.id, label: "\(b.title) · \(prof.map(prefs.display) ?? s.name)", servers: servers, iface: s.iface))
        }
        dnsCandidates = out
    }

    /// `DNS =` з WG-конфігу (там можуть бути й search-домени — лишаємо лише адреси).
    private func wgDNS(_ name: String) async -> [String] {
        if let c = wgDNSCache[name] { return c }
        guard let path = (snap.profiles[.wireguard]?.first { $0.name == name })?.path ?? snap.wgDir.map({ "\($0)/\(name).conf" }) else { return [] }
        var text = try? String(contentsOfFile: path, encoding: .utf8)
        if text == nil { text = await helper.readIfAvailable(.readWGConf(path: path))?.output }
        guard let text else { return [] }
        let dns = (Parse.wgConf(text).dns ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        wgDNSCache[name] = dns
        return dns
    }

    /// Який кандидат зараз основний (nil = як вирішила система).
    var primaryDNSChoice: String? {
        guard let ov = snap.network.dnsOverride else { return nil }
        if let id = prefs.primaryDNSChoice, dnsCandidates.contains(where: { $0.id == id && $0.servers == ov }) { return id }
        return dnsCandidates.first { $0.servers == ov }?.id ?? "custom"
    }

    func setPrimaryDNS(_ c: DNSCandidate?) {
        prefs.primaryDNSChoice = c?.id
        reassertTimes = []
        reassertNotified = false
        runAction("Основний DNS") {
            try await self.actions.setPrimaryDNS(c?.servers)
            try? await Task.sleep(for: .milliseconds(700))
            await self.refresh()
            await self.probeDNS()
            let n = self.snap.network
            guard let c else { return "Основний DNS: як вирішила система (\(n.dnsOwnerLabel ?? "—"))" }
            if n.dnsOwner != HelperConst.dnsOverrideService {
                if self.helperVersion.map({ $0 < HelperConst.version }) ?? false {
                    return "Helper застарий (v\(self.helperVersion ?? 0), треба v\(HelperConst.version)) — Settings → Helper → Перевстановити"
                }
                return "Записано, але першим лишився \(n.dnsOwnerLabel ?? "інший резолвер")" +
                    (n.catchAllOthers.isEmpty ? "" : " — його клієнт одразу повернув свій запис")
            }
            let moved = n.displacedDNS.map { n.dnsServiceLabels[$0] ?? $0 }
            return "Основний DNS: \(c.label) (\(c.servers.joined(separator: " ")))" +
                (moved.isEmpty ? "" : ". Тимчасово відсунуто: \(moved.joined(separator: ", "))")
        }
    }

    /// Клієнт VPN повернув свій catch-all запис (перепідключення, зміна мережі, Defguard з новим
    /// UUID) — наш основний DNS знову не єдиний, тож витісняємо ще раз. Захист від пінг-понгу:
    /// не більше 6 разів за хвилину, далі — одне сповіщення.
    private func reassertPrimaryDNS() async {
        let n = snap.network
        guard let ov = n.dnsOverride, !n.catchAllOthers.isEmpty, busy.isEmpty else { return }
        guard helper.isEnabled, (helperVersion ?? 0) >= HelperConst.version else {
            if !reassertNotified {
                reassertNotified = true
                notify("Основний DNS перебито", "\(n.catchAllOthers.map { n.dnsServiceLabels[$0] ?? $0 }.joined(separator: ", ")) повернув свій DNS. Тримати вибір без пароля може лише актуальний helper (Settings → Helper).")
            }
            return
        }
        let now = Date()
        reassertTimes = reassertTimes.filter { now.timeIntervalSince($0) < 60 }
        guard reassertTimes.count < 6 else {
            if !reassertNotified {
                reassertNotified = true
                notify("Основний DNS не втримати", "Клієнт VPN постійно повертає свій DNS. Для його внутрішніх доменів — split DNS.")
            }
            return
        }
        reassertTimes.append(now)
        try? await actions.setPrimaryDNS(ov)
        scheduleRefresh()
    }

    /// Обраний тунель упав — не лишати мертвий основний DNS.
    private func dropStalePrimaryDNS() async {
        guard let ov = snap.network.dnsOverride, busy.isEmpty,
              !dnsCandidates.contains(where: { !Set($0.servers).isDisjoint(with: ov) }) else { return }
        guard helper.isEnabled else { return }          // без helper не питати пароль у фоні
        try? await actions.setPrimaryDNS(nil)
        prefs.primaryDNSChoice = nil
        notify("Основний DNS скинуто", "Тунель із DNS \(ov.joined(separator: " ")) більше не активний — DNS знову обирає система.")
    }

    /// Типові помилки split-правила (адреса інтерфейсу замість DNS, «домен» = назва інтерфейсу).
    func splitWarnings(domain: String, servers: [String]) -> [String] {
        var w: [String] = []
        let ifs = Interfaces.ipv4()
        for s in servers {
            if Parse.ipv4(s) == nil && !s.contains(":") { w.append("«\(s)» — не IP-адреса"); continue }
            if let i = ifs.first(where: { $0.value == s })?.key {
                let hint = dnsCandidates.first { $0.iface == i }.map { " DNS цього тунелю: \($0.servers.joined(separator: ", "))." } ?? ""
                w.append("\(s) — адреса інтерфейсу \(i), а не DNS-сервер.\(hint)")
            }
        }
        if !domain.contains(".") {
            w.append(domain.range(of: #"^(utun|en|bridge|lo|awdl|llw|anpi|gif|stf)\d+$"#, options: .regularExpression) != nil
                     ? "«\(domain)» — назва інтерфейсу, а не домен: правило ловить лише імена *.\(domain)"
                     : "домен без крапки — правило ловить лише імена *.\(domain)")
        }
        return w
    }

    func saveSplit(old: String?, domain: String, servers: [String]) {
        runAction("Split") {
            if let old { try await self.actions.splitReplace(old: old, domain: domain, servers: servers) }
            else { try await self.actions.splitAdd(domain, servers) }
            self.loadSplit()
            return "*.\(domain) → \(servers.joined(separator: " "))"
        }
    }

    func removeSplit(_ domain: String) {
        runAction("Split") { try await self.actions.splitRemove(domain); self.loadSplit(); return "Прибрано \(domain)" }
    }

    // MARK: мережа

    func loadServices() async {
        services = await actions.services()
        let ips = Interfaces.ipv4()
        await withTaskGroup(of: (String, Bool).self) { g in
            for s in services where s.enabled && !s.device.isEmpty && ips[s.device] != nil {
                g.addTask { (s.name, await self.actions.ifaceOnline(s.device)) }
            }
            for await (n, ok) in g { serviceOnline[n] = ok }
        }
        for s in services where s.enabled { serviceDNS[s.name] = await actions.serviceDNS(s.name) }
    }

    func runAction(_ label: String, _ f: @escaping () async throws -> String?) {
        Task {
            do { toast = try await f() ?? "\(label): готово" } catch { toast = "\(label): \(error.localizedDescription)" }
            await refresh()
        }
    }

    // MARK: helper / login

    func checkHelper() async {
        helperStatus = helper.status
        helperVersion = await helper.version()
    }

    func installHelper() {
        do {
            try helper.register()
        } catch {
            toast = "Helper: \(error.localizedDescription)"
        }
        helperStatus = helper.status
        if helperStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        Task { try? await Task.sleep(for: .seconds(1)); await checkHelper() }
    }

    func uninstallHelper() {
        Task {
            try? await helper.unregister()
            await checkHelper()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { toast = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: вікна / сповіщення

    func openWindow(_ id: String) {
        NSApp.activate()
        openWindowAction?(id: id)
    }

    func openProfiles(_ b: Backend, select: String? = nil) {
        profilesBackend = b
        profilesSelection = select
        openWindow("profiles")
    }

    private func notifyDiff(old: Snapshot, new: Snapshot) {
        let oldUp = Set(old.sessions.filter { $0.state == .up }.map(\.id))
        let newUp = Set(new.sessions.filter { $0.state == .up }.map(\.id))
        for id in oldUp.subtracting(newUp) {
            if stopping.remove(id) == nil, prefs.notifyDropped {
                notify("Тунель упав", id.replacingOccurrences(of: ":", with: " · "))
            }
        }
        let oldF = Set(old.foreign.map(\.id)), newF = Set(new.foreign.map(\.id))
        if prefs.notifyForeign, new.network.primaryIsTunnel, !newF.subtracting(oldF).isEmpty,
           let f = new.foreign.first(where: { $0.iface == new.network.primaryIface }) {
            notify("Сторонній VPN тримає мережу", "\(f.name) (\(f.iface ?? "")) став первинним")
        }
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
