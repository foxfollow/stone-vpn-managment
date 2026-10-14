import Foundation
import StoneVPNShared

/// Виконавець root-дій (helper або одноразовий osascript-запит пароля).
public protocol PrivilegedRunner: Sendable {
    func run(_ op: PrivOp) async -> PrivResult
}

public struct ActionError: LocalizedError {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// Route-fix на рівні профілю (Settings → профіль).
public enum RouteFixMode: Codable, Hashable, Sendable {
    case ask              // питати при кожному підключенні (як vpn-up.sh)
    case lanDefault       // поточний LAN default-шлюз
    case gateway(String)  // фіксований шлюз
    case off              // ніколи
}

public struct ProfileSettings: Codable, Hashable, Sendable {
    public var routeFix: RouteFixMode = .ask
    public var lastGateway: String?
    public init() {}
}

public struct RouteFixPlan: Sendable {
    public struct Target: Sendable, Hashable { public var host: String; public var ip: String }
    public var need: [Target] = []                       // потребують host-маршруту
    public var viaTunnel: [(target: Target, iface: String)] = []
    public var staleDeletes: [String] = []               // старі -host повз тунель
    public var candidates: [(label: String, gw: String)] = []
    public var isEmpty: Bool { need.isEmpty }
}

public final class Actions: @unchecked Sendable {
    let runner: PrivilegedRunner
    let reader: PrivilegedReader

    public init(runner: PrivilegedRunner, reader: PrivilegedReader) {
        self.runner = runner
        self.reader = reader
    }

    func priv(_ op: PrivOp) async throws -> String {
        let r = await runner.run(op)
        if !r.ok { throw ActionError(r.output.isEmpty ? "дію не виконано" : r.output) }
        return r.output
    }

    // MARK: route-fix (vpn-up.sh)

    public func routeFixPlan(hosts: [String], lastGateway: String) async -> RouteFixPlan {
        var plan = RouteFixPlan()
        let rows = Parse.netstat(await Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).out)
        for h in hosts {
            let ip = Interfaces.resolve(h) ?? h
            let t = RouteFixPlan.Target(host: h, ip: ip)
            if let tun = Parse.tunnelIface(for: ip, rows: rows) {
                plan.viaTunnel.append((t, tun))
                // Фактичний маршрут іде повз тунель статичним -host → прибрати залишок.
                let now = await Shell.run("/sbin/route", ["-n", "get", ip]).out
                let nowIf = Parse.firstMatch(#"interface: (\S+)"#, now)
                if nowIf != tun, now.contains("HOST"), now.contains("STATIC") { plan.staleDeletes.append(ip) }
            } else {
                plan.need.append(t)
            }
        }
        let own = Interfaces.liveUtuns()
        plan.candidates = Parse.lanGateways(rows).map { ("\($0.iface) · LAN", $0.gw) }
            + Parse.tunnelGateways(rows, ownAddresses: own).map { ("\($0.iface) · тунель", $0.gw) }
        if !lastGateway.isEmpty, !plan.candidates.contains(where: { $0.gw == lastGateway }) {
            plan.candidates.append(("останній", lastGateway))
        }
        return plan
    }

    /// Шлюз за політикою профілю, без питань. nil + .ask = треба спитати.
    public func resolveGateway(_ mode: RouteFixMode, plan: RouteFixPlan) -> (gw: String?, ask: Bool) {
        guard !plan.isEmpty else { return (nil, false) }
        switch mode {
        case .off: return (nil, false)
        case .gateway(let g): return (g, false)
        case .lanDefault: return (plan.candidates.first { $0.label.hasSuffix("LAN") }?.gw, false)
        case .ask: return (nil, true)
        }
    }

    public func applyRouteFix(_ plan: RouteFixPlan, gateway: String?) async throws -> [String] {
        var ops: [PrivOp] = plan.staleDeletes.map { .routeHostDelete(ip: $0) }
        var log = plan.viaTunnel.map { "\($0.target.host) доступний через \($0.iface) — route-fix не потрібен" }
        if let gw = gateway, !gw.isEmpty {
            for t in plan.need {
                let cur = Parse.firstMatch(#"gateway: (\S+)"#, await Shell.run("/sbin/route", ["-n", "get", t.ip]).out)
                if cur != gw { ops.append(.routeHostSet(ip: t.ip, gateway: gw)) }
                log.append("route-fix: \(t.host) (\(t.ip)) → \(gw)")
            }
        } else if !plan.need.isEmpty {
            log.append("route-fix пропущено")
        }
        if !ops.isEmpty { _ = try await priv(.batch(ops)) }
        return log
    }

    // MARK: WireGuard

    public func wgEndpointHost(_ p: Profile) async -> String? {
        guard let path = p.path else { return nil }
        var text = try? String(contentsOfFile: path, encoding: .utf8)
        if text == nil { text = await reader.readIfAvailable(.readWGConf(path: path))?.output }
        guard let ep = text.flatMap({ Parse.wgConf($0).endpoint }) else { return nil }
        // host:port або [v6]:port
        if ep.hasPrefix("[") { return nil }
        return ep.split(separator: ":").first.map(String.init)
    }

    public func wgUp(_ p: Profile) async throws {
        guard let path = p.path else { throw ActionError("не знайдено конфіг \(p.name).conf") }
        _ = try await priv(.wgUp(confPath: path))
    }

    public func wgDown(_ p: Profile) async throws {
        guard let path = p.path else { throw ActionError("не знайдено конфіг \(p.name).conf") }
        _ = try await priv(.wgDown(confPath: path))
    }

    // MARK: OpenVPN

    public func ovpnUp(_ p: Profile, username: String?, password: String?, timeout: Int,
                       progress: @escaping @Sendable (String) -> Void) async throws -> String? {
        guard let path = p.path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ActionError("профіль недоступний")
        }
        let info = Parse.ovpnProfile(text)
        progress("Запуск openvpn")
        let logPath = try await priv(.ovpnStart(profilePath: path, username: info.needsAuth ? username : nil,
                                                password: info.needsAuth ? password : nil, addDev: !info.hasDev))
        let log = logPath.hasPrefix("/tmp/") ? logPath : "/tmp/openvpn-\(p.name).log"
        progress("TLS handshake")
        let fail = try NSRegularExpression(pattern: Parse.ovpnFailPattern)
        for _ in 0..<timeout {
            try await Task.sleep(for: .seconds(1))
            var t = try? String(contentsOfFile: log, encoding: .utf8)
            if t == nil { t = await reader.readIfAvailable(.readLog(path: log))?.output }
            guard let t else { continue }
            if t.contains("Initialization Sequence Completed") {
                return Parse.ovpnLog(t).dev
            }
            if fail.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil {
                let lines = t.split(separator: "\n").filter {
                    $0.range(of: Parse.ovpnFailPattern + "|ERROR", options: .regularExpression) != nil
                }.suffix(3)
                // Процес у retry-циклі тримав би --connect-retry-max; зупиняємо, щоб не висів.
                if let pid = ovpnPid(p.name) { _ = await runner.run(.ovpnStop(pid: pid)) }
                throw ActionError(lines.joined(separator: "\n"))
            }
        }
        throw ActionError("тунель не піднявся за \(timeout) с (лог: \(log))")
    }

    func ovpnPid(_ id: String) -> Int32? {
        (try? String(contentsOfFile: "/tmp/openvpn-\(id).pid", encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func ovpnDown(pid: Int32) async throws {
        _ = try await priv(.ovpnStop(pid: pid))
    }

    // MARK: Defguard

    public func dgGUIRunning() async -> Bool {
        let rows = Parse.ps(await Shell.run("/bin/ps", ["-axww", "-o", "pid=,etime=,command="]).out)
        return rows.contains { $0.command == Paths.defguardBundleCLI }
    }

    public func dgSessionState(_ name: String) async -> String? {
        Parse.ncList(await Shell.run("/usr/sbin/scutil", ["--nc", "list"]).out).first { $0.name == name }?.state
    }

    public func dgUp(_ p: Profile, code: String?, cliPath: String) async throws {
        guard let cli = Paths.defguardCLI(cliPath) else { throw ActionError("defguard-client не знайдено") }
        if await dgSessionState(p.name) == "Connected" { return }
        var args = ["connect", p.name]
        if p.dgKind == "tunnel" { args.append("--tunnel") }
        if let code, !code.isEmpty { args += ["--code", code] }
        let r = await Shell.run(cli, args, timeout: 60)
        if !r.ok { throw ActionError("defguard-client: " + (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)) }
        // CLI друкує «Connected to…» одразу; правду каже лише стан сесії (dg_wait).
        var idle = 0
        var ok = false
        for _ in 0..<20 {
            let st = await dgSessionState(p.name)
            if st == "Connected" { ok = true; break }
            if st == "Disconnected" { idle += 1; if idle >= 3 { break } } else { idle = 0 }
            try await Task.sleep(for: .seconds(1))
        }
        guard ok else { throw ActionError("сесія '\(p.name)' не піднялась (стан: \(await dgSessionState(p.name) ?? "?"))") }
        // GUI зупиняє CLI-MFA-сесію за мить після Connected.
        if p.mfa != nil, await dgGUIRunning() {
            try await Task.sleep(for: .seconds(2))
            if await dgSessionState(p.name) != "Connected" {
                throw ActionError("Defguard.app зупинив '\(p.name)' і просить MFA у своєму вікні")
            }
        }
    }

    public func dgDown(_ name: String, kind: String?, cliPath: String) async throws {
        if let cli = Paths.defguardCLI(cliPath) {
            var args = ["disconnect", name]
            if kind == "tunnel" { args.append("--tunnel") }
            let r = await Shell.run(cli, args, timeout: 30)
            if !r.ok { throw ActionError(r.err.isEmpty ? r.out : r.err) }
            return
        }
        // Без CLI — scutil --nc stop (GUI може показувати застарілий стан).
        if let s = Parse.ncList(await Shell.run("/usr/sbin/scutil", ["--nc", "list"]).out).first(where: { $0.name == name }) {
            _ = await Shell.run("/usr/sbin/scutil", ["--nc", "stop", s.uuid])
        }
    }

    // MARK: Cisco

    public func ciscoGUIRunning() async -> Bool {
        let rows = Parse.ps(await Shell.run("/bin/ps", ["-axww", "-o", "pid=,etime=,command="]).out)
        return rows.contains { $0.command.contains("Cisco Secure Client.app/Contents/MacOS/Cisco Secure Client") }
    }

    public func ciscoQuitGUI() async {
        _ = await Shell.run("/usr/bin/osascript", ["-e", "quit app \"Cisco Secure Client\""])
        try? await Task.sleep(for: .seconds(1))
    }

    /// Підключення в застосунку: `vpn -s` + відповіді на його запити.
    public func ciscoConnect(_ c: CiscoCredentials, onEvent: @escaping @Sendable (CiscoDriver.Event) -> Void) async throws {
        guard let cli = Shell.which(Paths.ciscoCLI) else { throw ActionError("Cisco CLI не знайдено") }
        try await CiscoDriver.connect(cli: cli, c, onEvent: onEvent)
    }

    /// Групи з сервера до автентифікації. Після обриву скидаємо агент із «connecting»,
    /// але ніколи не чіпаємо живу сесію.
    public func ciscoProbeGroups(_ host: String) async throws -> CiscoDriver.GroupProbe {
        guard let cli = Shell.which(Paths.ciscoCLI) else { throw ActionError("Cisco CLI не знайдено") }
        if Parse.ciscoConnectedHost(await Shell.run(cli, ["-s", "state"], timeout: 8).out) != nil {
            throw ActionError("Cisco вже підключений — групи не перевіряю, щоб не розірвати сесію")
        }
        defer {
            Task {
                let st = await Shell.run(cli, ["-s", "state"], timeout: 8).out
                if Parse.ciscoConnectedHost(st) == nil, !st.contains("state: Disconnected") {
                    _ = await Shell.run(cli, ["-s", "disconnect"], timeout: 15)
                }
            }
        }
        return try await CiscoDriver.probeGroups(cli: cli, host: host)
    }

    /// Запасний шлях: інтерактивно в Terminal (vpn сам питає group/user/password/banner).
    public func ciscoConnectInTerminal(_ host: String) async throws {
        guard let cli = Shell.which(Paths.ciscoCLI) else { throw ActionError("Cisco CLI не знайдено") }
        let cmd = "\(shq(cli)) connect \(shq(host))"
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nend tell"
        let r = await Shell.run("/usr/bin/osascript", ["-e", script])
        if !r.ok { throw ActionError(r.err) }
    }

    public func ciscoDisconnect() async throws {
        guard let cli = Shell.which(Paths.ciscoCLI) else { throw ActionError("Cisco CLI не знайдено") }
        let r = await Shell.run(cli, ["disconnect"], timeout: 30)
        if !r.ok { throw ActionError(r.out + r.err) }
    }

    // MARK: DNS

    /// restore_dns: RESTORE_DNS на DNS_SERVICES + purge осиротілих + flush.
    public func restoreDNS(_ c: RepoConfig, orphans: [String]) async throws {
        guard !c.restoreDNS.isEmpty else { return }
        let available = await services().map(\.name)
        var ops: [PrivOp] = c.dnsServices.filter(available.contains).map { .dnsSet(service: $0, servers: c.restoreServers) }
        if !orphans.isEmpty { ops.append(.dnsPurge(uuids: orphans)) }
        ops.append(.dnsFlush)
        _ = try await priv(.batch(ops))
    }

    public func dnsFlush() async throws { _ = try await priv(.dnsFlush) }

    /// Хвіст cmd_dns_fix: purge осиротілих + bounce реального сервісу + flush — одним запитом.
    public func repairDNS(service: String, servers: [String], orphans: [String]) async throws -> String {
        var ops: [PrivOp] = []
        if !orphans.isEmpty { ops.append(.dnsPurge(uuids: orphans)) }
        ops += [.dnsSet(service: service, servers: servers), .dnsFlush]
        return try await priv(.batch(ops))
    }

    public func setDNS(services: [String], servers: [String]) async throws {
        _ = try await priv(.batch(services.map { .dnsSet(service: $0, servers: servers) } + [.dnsFlush]))
    }

    public func dnsProbe(_ server: String) async -> Bool {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/dig") {
            return await Shell.run("/usr/bin/dig", ["+time=2", "+tries=1", "+short", "@\(server)", "apple.com"], timeout: 5).ok
        }
        return await Shell.run("/usr/bin/nslookup", ["-timeout=2", "-retry=1", "apple.com", server], timeout: 5).ok
    }

    public func probeAll(_ servers: [String]) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self) { g in
            for s in servers { g.addTask { (s, await self.dnsProbe(s)) } }
            var out: [String: Bool] = [:]
            for await (s, ok) in g { out[s] = ok }
            return out
        }
    }

    public struct TunnelProc: Hashable, Sendable {
        public var pid: Int32
        public var command: String
        public var label: String
        public var isDaemon: Bool
    }

    /// vpn_tunnel_procs + vpn_proc_role.
    public func tunnelProcs() async -> [TunnelProc] {
        let rows = Parse.ps(await Shell.run("/bin/ps", ["-axww", "-o", "pid=,etime=,command="]).out)
        return rows.filter {
            $0.command.range(of: #"SystemExtensions/.*(vpn|wireguard|tunnel|anyconnect)|vpnagentd"#, options: [.regularExpression, .caseInsensitive]) != nil
                && !$0.command.lowercased().contains("security-monitor")
        }.map { r in
            let c = r.command.lowercased()
            let (label, daemon): (String, Bool) =
                c.contains("vpnagentd") || c.contains("acsockext") || c.contains("anyconnect") ? ("Cisco-демон (фоновий)", true)
                : c.contains("clearvpn") ? ("ClearVPN", false)
                : c.contains("wireguard") ? ("NE WireGuard-тунель", false)
                : c.contains("forti") ? ("FortiClient", false)
                : ("NE VPN-тунель", false)
            return TunnelProc(pid: r.pid, command: r.command, label: label, isDaemon: daemon)
        }
    }

    public func killProcs(_ pids: [Int32]) async throws {
        _ = try await priv(.batch(pids.map { .killPid(pid: $0) }))
    }

    public func splitRules() -> [(domain: String, servers: [String])] {
        let dir = "/etc/resolver"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().map { f in
            let t = (try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8)) ?? ""
            let s = t.split(separator: "\n").compactMap { l -> String? in
                let p = l.split(separator: " ")
                return p.first == "nameserver" && p.count > 1 ? String(p[1]) : nil
            }
            return (f, s)
        }
    }

    public func splitAdd(_ domain: String, _ servers: [String]) async throws { _ = try await priv(.resolverSet(domain: domain, servers: servers)) }
    public func splitRemove(_ domain: String) async throws { _ = try await priv(.resolverRemove(domain: domain)) }

    // MARK: Мережа

    public func services() async -> [NetworkService] {
        Parse.serviceOrder(await Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).out)
    }

    public func serviceDNS(_ svc: String) async -> [String] {
        let o = await Shell.run("/usr/sbin/networksetup", ["-getdnsservers", svc]).out
        return o.contains("aren't any") ? [] : o.split(separator: "\n").map(String.init)
    }

    /// net_iface_online: ping через інтерфейс, фолбек HTTP (ICMP подекуди ріжуть).
    public func ifaceOnline(_ dev: String) async -> Bool {
        guard !dev.isEmpty else { return false }
        for t in ["1.1.1.1", "8.8.8.8"] where await Shell.run("/sbin/ping", ["-c1", "-W", "1200", "-b", dev, t], timeout: 4).ok {
            return true
        }
        return await Shell.run("/usr/bin/curl", ["-sfm", "3", "--interface", dev, "http://captive.apple.com/hotspot-detect.html"], timeout: 5).ok
    }

    public func moveToTop(_ name: String) async throws {
        let all = await services().map(\.name)
        guard all.contains(name) else { throw ActionError("немає сервісу \(name)") }
        _ = try await priv(.orderServices(names: [name] + all.filter { $0 != name }))
    }

    /// net_auto. Повертає текст результату.
    public func netAuto(primaryIface: String?) async throws -> String {
        guard let primary = primaryIface else { throw ActionError("первинного інтерфейсу немає — мережа не піднята") }
        if primary.hasPrefix("utun") { throw ActionError("default тримає VPN-тунель \(primary) — це не порядок сервісів (див. DNS Fix)") }
        if await ifaceOnline(primary) { return "Первинний \(primary) має інтернет — нічого міняти" }
        let ips = Interfaces.ipv4()
        for s in await services() where s.enabled && !s.device.isEmpty && s.device != primary && ips[s.device] != nil {
            if await ifaceOnline(s.device) {
                try await moveToTop(s.name)
                return "«\(s.name)» піднято на верх порядку сервісів"
            }
        }
        throw ActionError("жоден інший інтерфейс теж не бачить мережу")
    }

    func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
