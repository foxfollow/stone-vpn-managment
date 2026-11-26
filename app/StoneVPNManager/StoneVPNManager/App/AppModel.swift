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
    case stale                 // Defguard «Connected», але gateway не приймає сесію (MFA протухла)

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
    var rememberGateway = false   // зберегти вибір як політику профілю й більше не питати
    var mfa = false
    var code = ""
    var guiRunning = false        // Defguard.app / Cisco GUI
    var reconnect = false         // Defguard: сесія протухла — спершу down, потім up з новим кодом
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
    /// Хост живої Cisco-сесії на момент відкриття вікна. Агент тримає лише одну сесію,
    /// тож підключення до іншого хоста спершу розриває цю.
    var ciscoActive: String?
    /// Хост живої сесії, яку доведеться розірвати (інший, ніж у полі Host).
    var ciscoSwitchFrom: String? { ciscoActive.flatMap { Prefs.ciscoSame($0, hostKey) ? nil : $0 } }
    /// Хост без пробілів/переносів (вставлений з буфера часто має хвіст) — ключ для груп.
    var hostKey: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    var steps: [String] = []
    var error: String?
    var running = false
}

enum DoctorPrompt {
    case defguard(name: String, iface: String)
    case kill(procs: [Actions.TunnelProc], iface: String, owner: String?)
}

enum IconTone { case idle, ok, busy, problem, foreign, question }

/// Кандидат на основний DNS: DNS активного тунелю (наш або сторонній VPN) або фіксований
/// (Cloudflare, свій). DNS тунелів — ще й підказка для split-правил.
struct DNSCandidate: Identifiable, Hashable {
    enum Kind { case tunnel, foreign, fixed }
    var id: String          // session id | "public:cloudflare" | "custom"
    var label: String
    var servers: [String]
    var iface: String?
    var kind: Kind = .tunnel
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
    /// Defguard-сесії (за назвою), які NE показує Connected, а gateway вже не приймає.
    var dgStale: Set<String> = []
    /// Основний DNS, який ми поставили, бо резолвер протухлої Defguard-сесії мертвий.
    var dnsFailover: [String]?
    /// Сервери наших VPN, які забрав повний тунель стороннього (AppModel+Routes).
    var routeIssues: [RouteIssue] = []
    /// Сторонні VPN (Session.id), чий банер закрито хрестиком — до перезапуску.
    var foreignDismissed: Set<String> = []
    @ObservationIgnored var lastRouteCheck = Date.distantPast
    @ObservationIgnored var wgEndpointCache: [String: String] = [:]
    @ObservationIgnored var resolveCache: [String: (ip: String, at: Date)] = [:]
    @ObservationIgnored var directAttempts: [String: Date] = [:]

    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored private var stopping: Set<String> = []
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var groupsProbeTask: Task<Void, Never>?
    @ObservationIgnored private var groupsProbeSeq = 0
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
    @ObservationIgnored private var dgConnectedAt: [String: Date] = [:]
    @ObservationIgnored private var lastStaleCheck = Date.distantPast
    @ObservationIgnored private var lastStaleLog = Date.distantPast
    @ObservationIgnored private var failoverPrev: [String]?
    @ObservationIgnored private var failoverNoHelperNotified = false

    // MARK: життєвий цикл

    func start() {
        guard !started else { return }
        started = true
        reloadConfig()
        AppSwitcherPolicy.shared.start(enabled: prefs.showInAppSwitcher)
        reader.store.watch { Task { @MainActor in AppModel.shared.scheduleRefresh() } }
        NotificationHandler.shared.install()
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
        await checkDefguardStale()
        await loadDNSCandidates()
        if loaded { await checkRoutesIfDue(old: old) }
        await applyDNSFailover()
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
        if wasHealthy == true, dnsHealthy == false, prefs.notifyDNS, !prefs.autoDNSFix, guardTask == nil, busy.isEmpty, dgStale.isEmpty {
            notify(String(localized: "DNS is not responding"), String(localized: "Resolver \(servers.joined(separator: ", ")) is silent. Open StoneVPN → DNS → Fix."))
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
            notify(String(localized: "Auto DNS fix skipped"), String(localized: "DNS is not responding, but repairing it without a password needs the helper (Settings → Helper)."))
            return
        }
        await runDNSFix()
        if prefs.notifyDNS {
            notify(dnsHealthy == true ? String(localized: "DNS repaired automatically") : String(localized: "Auto DNS fix did not help"),
                   doctorLog.last ?? "")
        }
    }

    func checkPrimaryOnline() async {
        guard let p = snap.network.primaryIface, !Parse.isTunnelIface(p) else { primaryOnline = nil; return }
        primaryOnline = await actions.ifaceOnline(p)
        if primaryOnline == false, prefs.netAutoFix, helper.isEnabled {
            if let msg = try? await actions.netAuto(primaryIface: p) { notify(String(localized: "Network"), msg) }
        }
    }

    // MARK: стан для UI

    var tone: IconTone {
        let n = snap.network
        if let f = primaryForeign, !isQuietForeign(f) { return .foreign }
        // Під час підключення/повернення DNS мертвий резолвер — очікуваний проміжний стан.
        if !busy.isEmpty || dnsGuardActive { return .busy }
        if !dgStale.isEmpty { return .problem }
        if snap.erroredCount > 0 || dnsHealthy == false || primaryOnline == false { return .problem }
        if !routeIssues.isEmpty { return .question }
        if snap.connectingCount > 0 { return .busy }
        return snap.upCount > 0 ? .ok : .idle
    }

    var headline: String {
        let up = snap.upCount, conn = snap.connectingCount + busy.count
        if tone == .foreign { return String(localized: "A foreign VPN owns the network") }
        if dnsGuardActive, busy.isEmpty { return String(localized: "Restoring DNS after VPN…") }
        if let n = dgStale.sorted().first, busy.isEmpty { return String(localized: "Defguard “\(n)”: session expired") }
        if dnsHealthy == false, busy.isEmpty { return String(localized: "DNS problem") }
        if primaryOnline == false { return String(localized: "No internet") }
        if let i = routeIssues.first, busy.isEmpty { return String(localized: "Route in question: \(i.label)") }
        if up == 0 && conn == 0 { return String(localized: "No active tunnels") }
        let tunnels = String(localized: "\(up) tunnels up", locale: .app)
        if conn == 0 { return tunnels }
        return up > 0 ? String(localized: "\(tunnels) · \(conn) connecting", locale: .app) : String(localized: "Connecting…")
    }

    /// Сторонній VPN, що зараз первинний (тримає default route).
    var primaryForeign: Session? {
        let n = snap.network
        return n.primaryIsTunnel ? snap.foreign.first { $0.iface == n.primaryIface } : nil
    }

    /// Дозволено явно або неявно: рішення щодо маршруту повз цей VPN (погодити / напряму) —
    /// уже свідомий вибір працювати поряд з ним.
    func isAllowedForeign(_ s: Session) -> Bool {
        prefs.allowedForeign.contains(s.name) || prefs.routeDecisions.keys.contains { RouteIssue.parseDecisionKey($0).owner == s.name }
    }

    /// Фіолетове попередження про цей сторонній VPN приховано (×) до перезапуску застосунку.
    func isQuietForeign(_ s: Session) -> Bool { isAllowedForeign(s) || foreignDismissed.contains(s.id) }

    /// Дозволити сторонньому VPN (ClearVPN…) тримати мережу поряд з нашими тунелями.
    func allowForeign(_ name: String, _ on: Bool = true) {
        prefs.allowedForeign.removeAll { $0 == name }
        if on { prefs.allowedForeign.append(name) }
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
            case .up: return s.backend == .defguard && dgStale.contains(s.name) ? .stale : .up
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
        busy[p.key] = String(localized: "checking DNS…")
        await prepareDNS(for: p)
        busy[p.key] = String(localized: "checking the route…")
        await purgeDeadRoutes(await endpointHosts(p))
        await checkEndpointResolves(p)
        busy[p.key] = nil
        var r = ConnectRequest(profile: p)
        let s = prefs.settings(for: p)
        switch p.backend {
        case .wireguard, .openvpn:
            busy[p.key] = String(localized: "checking the route…")
            var hosts = p.remotes
            if p.backend == .wireguard, s.routeFix != .off, let h = await actions.wgEndpointHost(p) { hosts = [h] }
            if s.routeFix != .off, !hosts.isEmpty {
                // Вибір профілю (включно з «пропустити») важливіший за глобальний LAST_GATEWAY.
                let last = s.lastGateway ?? config.defaultGateway
                let plan = await actions.routeFixPlan(hosts: hosts, lastGateway: last.isEmpty ? config.defaultGateway : last)
                let g = actions.resolveGateway(s.routeFix, plan: plan)
                r.plan = plan
                r.askGateway = g.ask
                r.gateway = g.gw ?? (g.ask ? last : "")
            }
            busy[p.key] = nil
            if p.backend == .openvpn, p.needsAuth {
                r.needsAuth = true
                r.username = s.lastUsername.flatMap { $0.isEmpty ? nil : $0 } ?? config.configuredUsername
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
            (r.username, r.group) = ciscoLogin(for: r.host, cp)
            r.ciscoActive = snap.sessions.first { $0.backend == .cisco }?.name
        }
        if r.needsAuth || r.askGateway || r.mfa || p.backend == .cisco {
            connect = r
            openWindow("connect")
            if p.backend == .cisco { await probeCiscoGroups() }
        } else {
            _ = await perform(r)
        }
    }

    /// Хости, до яких піде підключення (для перевірки мертвих host-маршрутів).
    func endpointHosts(_ p: Profile) async -> [String] {
        switch p.backend {
        case .openvpn: p.remotes
        case .wireguard: await actions.wgEndpointHost(p).map { [$0] } ?? []
        case .cisco: [p.name]
        case .defguard: p.endpoint.map { [$0] } ?? []
        }
    }

    /// Мертвий route-fix з попередньої мережі (шлюз не on-link) — прибрати перед підключенням.
    /// Дія користувача, тож запит пароля без helper допустимий.
    func purgeDeadRoutes(_ hosts: [String]) async {
        guard !hosts.isEmpty else { return }
        do {
            let log = try await actions.purgeDeadHostRoutes(hosts)
            if !log.isEmpty { toast = log.joined(separator: "\n") }
        } catch { toast = String(localized: "Could not remove a dead route: \(error.localizedDescription)") }
    }

    /// Власне підключення (з панелі або напряму). true = успіх.
    func perform(_ r: ConnectRequest) async -> Bool {
        let p = r.profile
        busy[p.key] = String(localized: "connecting…")
        defer { busy[p.key] = nil }
        func step(_ s: String) { busy[p.key] = s; connect?.steps.append(s) }
        do {
            if let plan = r.plan, !plan.isEmpty || !plan.staleDeletes.isEmpty {
                step("Route-fix")
                _ = try await actions.applyRouteFix(plan, gateway: r.gateway.isEmpty ? nil : r.gateway)
                if !plan.isEmpty {
                    var s = prefs.settings(for: p)
                    if prefs.rememberGateway || r.rememberGateway { s.lastGateway = r.gateway }
                    if r.askGateway, r.rememberGateway {
                        let lan = plan.candidates.contains { $0.gw == r.gateway && $0.kind == .lan }
                        s.routeFix = r.gateway.isEmpty ? .off : (lan ? .lanDefault : .gateway(r.gateway))
                    }
                    prefs.setSettings(s, for: p)
                    if prefs.rememberGateway, !r.gateway.isEmpty { config.setState("LAST_GATEWAY", r.gateway) }
                }
            }
            switch p.backend {
            case .wireguard:
                step("wg-quick up")
                try await actions.wgUp(p)
            case .openvpn:
                if r.needsAuth, prefs.rememberUser, !r.username.isEmpty {
                    var s = prefs.settings(for: p)
                    s.lastUsername = r.username
                    prefs.setSettings(s, for: p)
                    config.setState("LAST_USERNAME", r.username)
                }
                let key = p.key
                _ = try await actions.ovpnUp(p, username: r.username, password: r.password, timeout: prefs.ovpnTimeout) { s in
                    Task { @MainActor in
                        AppModel.shared.busy[key] = s
                        AppModel.shared.connect?.steps.append(s)
                    }
                }
            case .defguard:
                if r.guiRunning, p.mfa != nil { step(String(localized: "Closing Defguard.app")); await actions.dgQuitGUI() }
                // Повтор після невдалого коду: сесія вже відключена — лише up.
                if r.reconnect, let st = await actions.dgSessionState(p.name), st != "Disconnected" {
                    step("defguard-client disconnect")
                    stopping.insert(p.key)
                    try await actions.dgDown(p.name, kind: p.dgKind, cliPath: config.defguardCLI)
                }
                step("defguard-client connect")
                try await actions.dgUp(p, code: r.code, cliPath: config.defguardCLI)
                // Старі reasserting-и в лозі належать попередній сесії.
                dgConnectedAt[p.name] = Date()
                dgStale.remove(p.name)
                stopping.remove(p.key)
            case .cisco:
                await cancelGroupsProbe()
                if r.guiRunning { step(String(localized: "Closing the Cisco GUI")); await actions.ciscoQuitGUI() }
                let host = r.hostKey
                guard !host.isEmpty else { throw ActionError(String(localized: "enter a host")) }
                let k = Prefs.ciscoKey(host)
                // Агент тримає одну сесію: стару розриваємо явно (і бачимо, якщо не вийшло),
                // а не покладаємось на те, що `vpn connect` перемкне її сам.
                // `vpn -s state` пише хост без порту, а сесія названа за записом `hosts` (з :port) —
                // беремо її назву, інакше host:8448 ≠ host і ключ у stopping не збігається з id.
                if let bare = await actions.ciscoConnectedHost() {
                    let ses = snap.sessions.first { $0.backend == .cisco && $0.name.split(separator: ":").first.map(String.init) == bare }
                    let live = ses?.name ?? bare
                    if !Prefs.ciscoSame(live, host) {
                        step(String(localized: "Disconnecting Cisco from \(live)"))
                        stopping.insert(ses?.id ?? "cisco:\(live)")   // не «тунель обірвався» — ми самі
                        try await actions.ciscoDisconnect()
                        await refresh()
                    }
                }
                for l in try await actions.purgeDeadHostRoutes([host]) { step(l) }
                let creds = CiscoCredentials(host: host, group: r.group, user: r.username, password: r.password,
                                             secondPassword: r.secondPassword, expectsMFA: prefs.ciscoMFA[k])
                let usedMFA = try await actions.ciscoConnect(creds) { ev in
                    Task { @MainActor in
                        switch ev {
                        case .step(let s): AppModel.shared.connect?.steps.append(s); AppModel.shared.busy[p.key] = s
                        case .banner(let b): AppModel.shared.connect?.banner = b
                        case .secondFactor: AppModel.shared.prefs.ciscoMFA[k] = true
                        }
                    }
                }
                // «Без MFA» — лише після успіху: «Login failed» приходить ще до Duo.
                prefs.ciscoMFA[k] = usedMFA
                if prefs.rememberUser, !r.username.isEmpty { prefs.ciscoUsers[k] = r.username }
                prefs.ciscoGroups[k] = r.group
                if !(snap.profiles[.cisco] ?? []).contains(where: { $0.name == host }), !prefs.ciscoHosts.contains(host) {
                    prefs.ciscoHosts.append(host)
                }
                prefs.lastProfile[p.backend.rawValue] = "cisco:\(host)"
                await refresh()
                if prefs.notifyConnected { notify(String(localized: "Connected"), "Cisco · \(host)") }
                return true
            }
            prefs.lastProfile[p.backend.rawValue] = p.key
            reloadConfig()
            await refresh()
            if prefs.notifyConnected { notify(String(localized: "Connected"), "\(p.backend.title) · \(prefs.display(p))") }
            return true
        } catch {
            if r.reconnect { stopping.remove(p.key) }
            errors[p.key] = error.localizedDescription
            connect?.error = error.localizedDescription
            await refresh()
            return false
        }
    }

    /// «Оновити» протухлу Defguard-сесію: MFA-локація питає лише код, решту (закрити GUI,
    /// down, чекати, up) робить perform.
    func renewDefguard(_ name: String) {
        guard let p = items(for: .defguard).first(where: { $0.profile.name == name })?.profile else { return }
        Task {
            var r = ConnectRequest(profile: p)
            r.reconnect = true
            if p.mfa != nil {
                r.mfa = true
                r.guiRunning = await actions.dgGUIRunning()
                connect = r
                openWindow("connect")
            } else {
                _ = await perform(r)
            }
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
        // Логін/група їдуть за хостом (копія профілю Cisco — копіюються, власний — переносяться).
        let ok = Prefs.ciscoKey(old), nk = Prefs.ciscoKey(host), moved = !prefs.ciscoHosts.contains(old)
        if prefs.ciscoUsers[nk] == nil, let u = prefs.ciscoUsers[ok] { prefs.ciscoUsers[nk] = u }
        if prefs.ciscoGroups[nk] == nil, let g = prefs.ciscoGroups[ok] { prefs.ciscoGroups[nk] = g }
        if prefs.ciscoMFA[nk] == nil, let m = prefs.ciscoMFA[ok] { prefs.ciscoMFA[nk] = m }
        if moved, ok != nk { prefs.ciscoUsers[ok] = nil; prefs.ciscoGroups[ok] = nil; prefs.ciscoMFA[ok] = nil }
        profilesSelection = "cisco:\(host)"
    }

    func removeCiscoHost(_ h: String) {
        prefs.ciscoHosts.removeAll { $0 == h }
        prefs.favorites.removeAll { $0 == "cisco:\(h)" }
        prefs.ciscoUsers[Prefs.ciscoKey(h)] = nil
        prefs.ciscoGroups[Prefs.ciscoKey(h)] = nil
        prefs.ciscoMFA[Prefs.ciscoKey(h)] = nil
        profilesSelection = nil
    }

    // MARK: файли профілів (OpenVPN — тека користувача; WireGuard — через helper)

    /// Додати .ovpn як новий профіль (ім'я — ms-мітка, як у OpenVPN Connect).
    func ovpnImport(_ url: URL) async {
        do {
            let id = try OvpnFiles.importProfile(from: url, into: config.ovpnProfilesDir)
            await refresh(forceSlow: true)
            profilesSelection = "openvpn:\(id)"
            toast = String(localized: "Added profile \(url.lastPathComponent)")
        } catch { toast = error.localizedDescription }
    }

    /// Замінити саме цей профіль (весь .ovpn або один блок) — ID, alias і налаштування лишаються.
    func ovpnReplace(_ p: Profile, with url: URL, block tag: String? = nil) async {
        guard let path = p.path else { toast = String(localized: "Profile file unknown"); return }
        do {
            if let tag { try OvpnFiles.replaceBlock(at: path, tag: tag, pemFile: url) }
            else { try OvpnFiles.replaceProfile(at: path, with: url) }
            errors[p.key] = nil
            let active = items(for: .openvpn).first { $0.id == p.key }?.status.isActive == true
            let what = tag.map { String(localized: "<\($0)> updated") } ?? String(localized: "Profile replaced")
            let backup = "\((path as NSString).lastPathComponent).bak"
            toast = active ? String(localized: "\(what) — reconnect to apply (old version: \(backup))")
                           : String(localized: "\(what) (old version: \(backup))")
        } catch { toast = error.localizedDescription }
        await refresh(forceSlow: true)
    }

    /// Видалити профіль: OpenVPN — у Кошик; WireGuard — через helper (конфіги root-only).
    func deleteProfile(_ p: Profile) async {
        if items(for: p.backend).first(where: { $0.id == p.key })?.status.isActive == true {
            toast = String(localized: "Disconnect \(prefs.display(p)) first"); return
        }
        do {
            switch p.backend {
            case .openvpn:
                guard let path = p.path else { throw ActionError(String(localized: "profile file unknown")) }
                try OvpnFiles.delete(at: path)
            case .wireguard:
                var prof = p
                if prof.path == nil, let d = snap.wgDir { prof.path = "\(d)/\(p.name).conf" }
                try await actions.wgDelete(prof)
            default:
                return
            }
            prefs.aliases.removeValue(forKey: p.key)
            prefs.favorites.removeAll { $0 == p.key }
            prefs.profileSettings.removeValue(forKey: p.key)
            if prefs.lastProfile[p.backend.rawValue] == p.key { prefs.lastProfile.removeValue(forKey: p.backend.rawValue) }
            errors[p.key] = nil
            if profilesSelection == p.key { profilesSelection = nil }
            toast = p.backend == .openvpn ? String(localized: "Profile moved to the Trash") : String(localized: "Config deleted")
        } catch { toast = error.localizedDescription }
        await refresh(forceSlow: true)
    }

    /// Підтягнути групи з сервера для поточного хоста у вікні підключення.
    /// Кожен виклик скасовує попередній: два `vpn -s` одночасно змагаються за connect capability
    /// агента, а відповідь застарілого не повинна ні ставити групи, ні гасити спінер нового.
    /// Спінер гасить лише останній запуск — незалежно від того, чи змінився хост (раніше умова
    /// «хост той самий» лишала «Отримую групи…» назавжди, якщо поле відрізнялось хоч пробілом).
    func probeCiscoGroups(closeGUI: Bool = false) async {
        guard let host = connect?.hostKey, !host.isEmpty else { return }
        // Probe = `connect`; поверх живої сесії він її перепідніме. Беремо запам'ятовану групу.
        if connect?.ciscoActive != nil {
            connect?.groupsNote = String(localized: "Groups aren't fetched while Cisco is connected — the remembered group is used")
            return
        }
        groupsProbeTask?.cancel()
        groupsProbeSeq += 1
        let id = groupsProbeSeq
        let t = Task { await runGroupsProbe(id: id, host: host, closeGUI: closeGUI) }
        groupsProbeTask = t
        await t.value
    }

    /// Зупинити перевірку груп (перед підключенням: probe тримає connect capability агента).
    func cancelGroupsProbe() async {
        guard let t = groupsProbeTask else { return }
        groupsProbeSeq += 1
        t.cancel()
        await t.value
        groupsProbeTask = nil
        connect?.groupsLoading = false
    }

    private func runGroupsProbe(id: Int, host: String, closeGUI: Bool) async {
        func latest() -> Bool { groupsProbeSeq == id && !Task.isCancelled }
        if connect?.guiRunning == true {
            guard closeGUI else { connect?.groupsNote = String(localized: "The Cisco GUI is open — the CLI can't fetch groups"); return }
            await actions.ciscoQuitGUI()
            connect?.guiRunning = false
        }
        guard latest() else { return }
        connect?.groupsLoading = true
        connect?.groupsNote = nil
        defer { if groupsProbeSeq == id { connect?.groupsLoading = false } }
        await purgeDeadRoutes([host])
        guard latest() else { return }
        do {
            let r = try await actions.ciscoProbeGroups(host)
            guard latest(), connect?.hostKey == host else { return }      // хост змінили / новий запуск
            connect?.groupsFor = host
            connect?.groups = r.groups
            if !r.asksGroup {
                connect?.group = ""
                connect?.groupsNote = String(localized: "The server offers no group choice")
            } else if let cur = connect?.group, r.groups.contains(cur) {
                // залишаємо обрану (з минулого разу)
            } else {
                connect?.group = r.defaultGroup ?? r.groups.first ?? ""
            }
            if let sso = r.ssoGroup {
                // Група сервера за замовчуванням — SAML/SSO: з CLI в неї не увійти, її прибрано зі списку.
                let name = sso.isEmpty ? String(localized: "the server's default group") : "“\(sso)”"
                connect?.groupsNote = String(localized: "\(name) signs in through a browser (SSO) — not possible via the Cisco CLI")
            }
        } catch {
            guard latest(), connect?.hostKey == host else { return }
            connect?.groupsNote = error.localizedDescription
        }
    }

    /// Збережений логін/група цього хоста; інакше — дефолти самого Cisco, але лише якщо вони про той самий хост.
    func ciscoLogin(for host: String, _ cp: CiscoPrefs = .load()) -> (user: String, group: String) {
        let k = Prefs.ciscoKey(host)
        func bare(_ h: String) -> String { String(Prefs.ciscoKey(h).split(separator: ":").first ?? "") }
        let same = !cp.hostName.isEmpty && bare(cp.hostName) == bare(host)
        return (prefs.ciscoUsers[k] ?? (same ? cp.user : ""), prefs.ciscoGroups[k] ?? (same ? cp.group : ""))
    }

    /// Хост у вікні підключення змінено — підставити логін і групу саме цього хоста.
    func selectCiscoHost(_ host: String) async {
        guard connect != nil else { return }
        connect?.host = host
        let l = ciscoLogin(for: host)
        connect?.username = l.user
        connect?.group = l.group
        await probeCiscoGroups()
    }

    func ciscoInTerminal(_ host: String) {
        Task {
            do { try await actions.ciscoConnectInTerminal(host) } catch { connect?.error = error.localizedDescription }
        }
    }

    func disconnect(_ p: Profile, session: Session?) async {
        stopping.insert(p.key)
        busy[p.key] = String(localized: "disconnecting…")
        errors[p.key] = nil
        do {
            switch p.backend {
            case .wireguard:
                var prof = p
                if prof.path == nil, let d = snap.wgDir { prof.path = "\(d)/\(p.name).conf" }
                try await actions.wgDown(prof)
            case .openvpn:
                guard let pid = session?.pid else { throw ActionError(String(localized: "PID unknown")) }
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
            if prefs.notifyDisconnected { notify(String(localized: "Disconnected"), "\(p.backend.title) · \(prefs.display(p))") }
        } catch {
            errors[p.key] = error.localizedDescription
            stopping.remove(p.key)
            // Сесія жива → рядок показує її стан, а не errors[]; без тосту невдача була б невидимою.
            toast = "\(p.backend.title) · \(prefs.display(p)): \(error.localizedDescription)"
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

    // MARK: протухла Defguard-сесія

    /// MFA-локація Defguard після сну, довшого за поріг gateway: пір видалено на сервері, а NE
    /// лишається Connected — адаптер кожні 90 с пише ConnectionExpired, сесія reasserting → connected,
    /// трафік (і DNS тунелю) у чорну діру. Ознака: DNS сесії мовчить + reasserting у лозі після
    /// нашого підключення, що не минув за 15 с (здоровий пір відповідає на хендшейк одразу);
    /// без DNS у сесії — ≥2 reasserting-и (два 90-секундні цикли поспіль).
    private func checkDefguardStale() async {
        let live = snap.sessions.filter { $0.backend == .defguard && $0.state == .up }
        dgStale.formIntersection(live.map(\.name))
        guard !live.isEmpty else { return }
        let interval: TimeInterval = dgStale.isEmpty && dnsHealthy != false ? 30 : 10
        guard Date().timeIntervalSince(lastStaleCheck) > interval else { return }
        lastStaleCheck = Date()
        var log: [String: [Date]]?
        func reasserts(_ name: String) async -> [Date] {
            if log == nil { log = await actions.dgReasserts(lastSeconds: 240) }
            let since = dgConnectedAt[name] ?? .distantPast
            return (log?[name] ?? []).filter { $0 > since }
        }
        var stale: Set<String> = []
        for s in live {
            if s.dnsServers.isEmpty {
                guard Date().timeIntervalSince(lastStaleLog) > 60 else {
                    if dgStale.contains(s.name) { stale.insert(s.name) }
                    continue
                }
                if await reasserts(s.name).count >= 2 { stale.insert(s.name) }
                continue
            }
            if await actions.probeAll(s.dnsServers).values.contains(true) { continue }
            if primaryOnline == false { continue }          // немає інтернету — сесія не винна
            if dgStale.contains(s.name) { stale.insert(s.name); continue }
            let ev = await reasserts(s.name)
            if ev.count >= 2 || (ev.last.map { Date().timeIntervalSince($0) > 15 } ?? false) { stale.insert(s.name) }
        }
        if log != nil { lastStaleLog = Date() }
        let added = stale.subtracting(dgStale)
        dgStale = stale
        if prefs.notifyDropped {
            for n in added.sorted() {
                notify(String(localized: "Defguard “\(n)”: session expired"),
                       String(localized: "The gateway no longer accepts the tunnel (slept longer than the threshold). DNS switched to another resolver; StoneVPN → Renew."))
            }
        }
    }

    /// Резолвер протухлої сесії — catch-all №1, тож без цього «не працює весь DNS». Ставимо
    /// основним DNS живого тунелю (або системний) — той самий механізм, що й ручний вибір.
    private func applyDNSFailover() async {
        guard !dgStale.isEmpty else { await endDNSFailover(); return }
        let dead = Set(snap.sessions.filter { $0.backend == .defguard && dgStale.contains($0.name) }.flatMap(\.dnsServers))
        let n = snap.network
        guard !dead.isEmpty, !dead.isDisjoint(with: n.dnsOverride ?? n.dnsServers), busy.isEmpty else { return }
        guard helper.isEnabled, (helperVersion ?? 0) >= HelperConst.version else {
            if !failoverNoHelperNotified {
                failoverNoHelperNotified = true
                notify(String(localized: "DNS of an expired Defguard session"), String(localized: "Only an up-to-date helper can switch DNS to another resolver without a password (Settings → Helper). Or press “Renew”."))
            }
            return
        }
        var servers = (dnsCandidates.first { $0.id == prefs.primaryDNSChoice } ?? dnsCandidates.first { $0.kind != .fixed })?.servers ?? []
        if servers.isEmpty, let u = n.primaryUUID, !n.primaryIsTunnel { servers = reader.store.serviceDNS(u).filter { !dead.contains($0) } }
        if servers.isEmpty { servers = config.restoreServers }
        if servers.isEmpty { servers = ["1.1.1.1"] }
        if dnsFailover == nil { failoverPrev = n.dnsOverride }
        do { try await actions.setPrimaryDNS(servers) } catch { toast = "DNS failover: \(error.localizedDescription)"; return }
        dnsFailover = servers
        try? await actions.dnsFlush()
        toast = String(localized: "DNS temporarily on \(servers.joined(separator: " ")) — the resolver of the expired Defguard session is silent")
        scheduleRefresh()
    }

    /// Сесію оновлено або відключено — повернути основний DNS, як був до failover.
    private func endDNSFailover() async {
        guard let f = dnsFailover, busy.isEmpty else { return }
        if snap.network.dnsOverride == f {
            let prev = failoverPrev.flatMap { pv in dnsCandidates.contains { $0.servers == pv } ? pv : nil }
            do { try await actions.setPrimaryDNS(prev) } catch { return }
            try? await actions.dnsFlush()
            scheduleRefresh()
        }
        dnsFailover = nil
        failoverPrev = nil
    }

    // MARK: DNS doctor (cmd_dns_fix)

    func runDNSFix() async {
        doctorRunning = true
        doctorLog = []
        doctorPrompt = nil
        defer { doctorRunning = false }
        if !dgStale.isEmpty {
            let names = dgStale.sorted().map { String(localized: "“\($0)”") }.joined(separator: ", ")
            doctorLog.append(String(localized: "Defguard \(names): the tunnel says “Connected”, but the gateway doesn't answer the handshake — the (MFA) session was dropped on the server. DNS edits won't help: press “Renew” with a new code."))
            await applyDNSFailover()
            if let f = dnsFailover { doctorLog.append(String(localized: "DNS temporarily switched to \(f.joined(separator: " ")).")) }
            await probeDNS()
            return
        }
        let net = reader.store.network()
        let probes = await actions.probeAll(net.dnsServers)
        dnsProbes = probes
        let alive = probes.values.contains(true)
        let resolvers = net.dnsServers.isEmpty ? String(localized: "(empty)")
            : net.dnsServers.map { "\($0) \(probes[$0] == true ? "✓" : "✗")" }.joined(separator: " ")
        doctorLog.append(String(localized: "primary: \(net.primaryIface ?? String(localized: "none")) · resolver: \(resolvers)"))
        if let iface = net.primaryIface, net.primaryIsTunnel {
            if alive { doctorLog.append(String(localized: "The primary is a VPN tunnel (\(iface)) and its DNS responds. Nothing to fix.")); return }
            doctorLog.append(String(localized: "The primary is a VPN tunnel (\(iface)), but its resolvers don't respond: a black hole for all traffic. DNS edits won't help — the tunnel has to go down."))
            let owner = snap.routeGroups.first { $0.iface == iface }?.owner
            if let owner, owner.hasPrefix("Defguard ") {
                doctorPrompt = .defguard(name: String(owner.dropFirst("Defguard ".count)), iface: iface)
            } else {
                doctorPrompt = .kill(procs: await actions.tunnelProcs().filter { !$0.isDaemon }, iface: iface, owner: owner)
            }
            return
        }
        if alive, net.orphanDNS.isEmpty {
            doctorLog.append(String(localized: "All healthy: the resolver responds, no orphaned entries."))
            dnsHealthy = true
            return
        }
        await repairDNS()
    }

    /// «Розірвати…» на рядку стороннього VPN — показати процеси і чекати підтвердження.
    func offerTakeDown(_ s: Session) async {
        openTool = "dns"
        doctorLog = [String(localized: "\(s.name) (\(s.iface ?? "")) — a foreign tunnel, managed by its own app.")]
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
            doctorLog.append(String(localized: "Failed: \(error.localizedDescription)"))
            return
        }
        // macOS відпускає маршрут+DNS тунелю асинхронно — чекаємо, а не фіксовану паузу.
        doctorLog.append(String(localized: "waiting for the tunnel to release the network…"))
        for _ in 0..<20 {
            if !reader.store.network().primaryIsTunnel { break }
            try? await Task.sleep(for: .seconds(1))
        }
        if reader.store.network().primaryIsTunnel {
            doctorLog.append(String(localized: "The tunnel is still primary — the extension seems to have restarted. Disconnect the VPN in its app and try again."))
            return
        }
        await repairDNS()
    }

    func repairDNS(want: [String]? = nil) async {
        let net = reader.store.network()
        let svcs = await actions.services()
        var svc = svcs.first { !$0.device.isEmpty && $0.device == net.primaryIface }?.name
        if svc == nil { svc = config.dnsServices.first { n in svcs.contains { $0.name == n } } }
        guard let svc else { doctorLog.append(String(localized: "No real service found to repair (DNS_SERVICES in config.env).")); return }
        // Еталон > RESTORE_DNS > поточний (якщо це не DNS тунелю) > 1.1.1.1.
        let tun = await tunnelDNS()
        var servers = want ?? []
        if servers.isEmpty, let b = prefs.dnsBaseline[svc], !b.isEmpty, tun.isDisjoint(with: b) { servers = b }
        if servers.isEmpty { servers = config.restoreServers }
        if servers.isEmpty { servers = await actions.serviceDNS(svc).filter { !tun.contains($0) } }
        if servers.isEmpty { servers = ["1.1.1.1"] }
        doctorLog.append(String(localized: "repairing via “\(svc)”: \(servers.joined(separator: " "))"))
        do {
            let out = try await actions.repairDNS(service: svc, servers: servers, orphans: net.orphanDNS)
            if !out.isEmpty { doctorLog.append(out) }
        } catch {
            doctorLog.append(String(localized: "Failed: \(error.localizedDescription)"))
            return
        }
        // Чесна перевірка: правильна конфігурація ще не означає робочий DNS.
        try? await Task.sleep(for: .seconds(1))
        let after = reader.store.network()
        dnsProbes = await actions.probeAll(after.dnsServers)
        dnsHealthy = dnsProbes.values.contains(true)
        if dnsHealthy == true {
            doctorLog.append(String(localized: "Done — DNS responds."))
        } else {
            doctorLog.append(String(localized: "The resolver still doesn't respond. The configuration is fixed, so the problem is lower — routes/network."))
            if after.primaryIsTunnel {
                doctorLog.append(String(localized: "The primary is still \(after.primaryIface ?? "") — the VPN did not release the network."))
            }
        }
        await refresh()
    }

    func flushDNS() {
        Task {
            do { try await actions.dnsFlush(); toast = String(localized: "DNS cache flushed") } catch { toast = error.localizedDescription }
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
                notify(String(localized: "Tunnel DNS left on services"), String(localized: "\(plan.keys.sorted().joined(separator: ", ")). Only the helper can restore them without a password (Settings → Helper); or open DNS → Fix."))
            }
            return false
        }
        let orphans = noTunnels ? reader.store.network().orphanDNS : []
        do {
            try await actions.restoreServiceDNS(plan, orphans: orphans)
        } catch {
            toast = String(localized: "DNS restore: \(error.localizedDescription)")
            return false
        }
        let what = plan.keys.sorted().map { "\($0) → \(plan[$0]!.isEmpty ? "DHCP" : plan[$0]!.joined(separator: " "))" }
        toast = String(localized: "DNS restored after VPN: \(what.joined(separator: ", "))")
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
            notify(String(localized: "DNS did not recover after VPN"), String(localized: "Resolver \(snap.network.dnsServers.joined(separator: ", ")) is silent. Open StoneVPN → DNS → Fix."))
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
        busy[p.key] = String(localized: "repairing DNS before connecting…")
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
            toast = String(localized: "\(hosts.joined(separator: ", ")) does not resolve (DNS: \(snap.network.dnsServers.joined(separator: " "))) — the connection will most likely fail. DNS → Fix or a split rule.")
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
            guard let b = s.backend, !(b == .defguard && dgStale.contains(s.name)) else { continue }
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
        // DNS стороннього VPN (ClearVPN тощо) — з його State-сервісу.
        for f in snap.foreign {
            let servers = f.dnsServers.filter { Parse.ipv4($0) != nil || $0.contains(":") }
            if !servers.isEmpty { out.append(DNSCandidate(id: f.id, label: f.name, servers: servers, iface: f.iface, kind: .foreign)) }
        }
        out.append(DNSCandidate(id: "public:cloudflare", label: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"], kind: .fixed))
        if !prefs.customDNS.isEmpty {
            out.append(DNSCandidate(id: "custom", label: String(localized: "Custom"), servers: prefs.customDNS, kind: .fixed))
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
        dnsFailover = nil          // ручний вибір важливіший за автоматичний failover
        failoverPrev = nil
        reassertTimes = []
        reassertNotified = false
        runAction(String(localized: "Primary DNS")) {
            try await self.actions.setPrimaryDNS(c?.servers)
            try? await Task.sleep(for: .milliseconds(700))
            await self.refresh()
            await self.probeDNS()
            let n = self.snap.network
            guard let c else { return String(localized: "Primary DNS: chosen by the system (\(n.dnsOwnerLabel ?? "—"))") }
            if n.dnsOwner != HelperConst.dnsOverrideService {
                if self.helperVersion.map({ $0 < HelperConst.version }) ?? false {
                    return String(localized: "The helper is outdated (v\(self.helperVersion ?? 0), needs v\(HelperConst.version)) — Settings → Helper → Reinstall")
                }
                let first = n.dnsOwnerLabel ?? String(localized: "another resolver")
                return n.catchAllOthers.isEmpty
                    ? String(localized: "Written, but \(first) stayed first")
                    : String(localized: "Written, but \(first) stayed first — its client put its entry back right away")
            }
            let moved = n.displacedDNS.map { n.dnsServiceLabels[$0] ?? $0 }
            let set = String(localized: "Primary DNS: \(c.label) (\(c.servers.joined(separator: " ")))")
            return moved.isEmpty ? set : String(localized: "\(set). Temporarily displaced: \(moved.joined(separator: ", "))")
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
                notify(String(localized: "Primary DNS overridden"), String(localized: "\(n.catchAllOthers.map { n.dnsServiceLabels[$0] ?? $0 }.joined(separator: ", ")) put its DNS back. Only an up-to-date helper can hold your choice without a password (Settings → Helper)."))
            }
            return
        }
        let now = Date()
        reassertTimes = reassertTimes.filter { now.timeIntervalSince($0) < 60 }
        guard reassertTimes.count < 6 else {
            if !reassertNotified {
                reassertNotified = true
                notify(String(localized: "Can't hold the primary DNS"), String(localized: "The VPN client keeps putting its DNS back. Use split DNS for its internal domains."))
            }
            return
        }
        reassertTimes.append(now)
        try? await actions.setPrimaryDNS(ov)
        scheduleRefresh()
    }

    /// Обраний тунель упав — не лишати мертвий основний DNS.
    private func dropStalePrimaryDNS() async {
        guard dnsFailover == nil, let ov = snap.network.dnsOverride, busy.isEmpty,
              !dnsCandidates.contains(where: { !Set($0.servers).isDisjoint(with: ov) }) else { return }
        guard helper.isEnabled else { return }          // без helper не питати пароль у фоні
        try? await actions.setPrimaryDNS(nil)
        prefs.primaryDNSChoice = nil
        notify(String(localized: "Primary DNS reset"), String(localized: "The tunnel with DNS \(ov.joined(separator: " ")) is no longer active — the system picks DNS again."))
    }

    /// Типові помилки split-правила (адреса інтерфейсу замість DNS, «домен» = назва інтерфейсу).
    func splitWarnings(domain: String, servers: [String]) -> [String] {
        var w: [String] = []
        let ifs = Interfaces.ipv4()
        for s in servers {
            if Parse.ipv4(s) == nil && !s.contains(":") { w.append(String(localized: "“\(s)” is not an IP address")); continue }
            if let i = ifs.first(where: { $0.value == s })?.key {
                w.append(String(localized: "\(s) is the address of interface \(i), not a DNS server."))
                if let c = dnsCandidates.first(where: { $0.iface == i }) {
                    w.append(String(localized: "This tunnel's DNS: \(c.servers.joined(separator: ", ")).")) }
            }
        }
        if !domain.contains(".") {
            w.append(domain.range(of: #"^(utun|en|bridge|lo|awdl|llw|anpi|gif|stf)\d+$"#, options: .regularExpression) != nil
                     ? String(localized: "“\(domain)” is an interface name, not a domain: the rule only catches names *.\(domain)")
                     : String(localized: "a domain without a dot — the rule only catches names *.\(domain)"))
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
        runAction("Split") { try await self.actions.splitRemove(domain); self.loadSplit(); return String(localized: "Removed \(domain)") }
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
            do { toast = try await f() ?? String(localized: "\(label): done") } catch { toast = "\(label): \(error.localizedDescription)" }
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
                notify(String(localized: "Tunnel dropped"), id.replacingOccurrences(of: ":", with: " · "))
            }
        }
        let oldF = Set(old.foreign.map(\.id)), newF = Set(new.foreign.map(\.id))
        if prefs.notifyForeign, new.network.primaryIsTunnel, !newF.subtracting(oldF).isEmpty,
           let f = new.foreign.first(where: { $0.iface == new.network.primaryIface }), !isQuietForeign(f) {
            notify(String(localized: "A foreign VPN holds the network"), String(localized: "\(f.name) (\(f.iface ?? "")) became primary"))
        }
    }

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
