import Foundation
import StoneVPNShared

/// Root-читання, що *ніколи* не питає пароль: повертає nil, якщо helper не встановлено.
public protocol PrivilegedReader: Sendable {
    func readIfAvailable(_ op: PrivOp) async -> PrivResult?
}

public enum Paths {
    public static let wgDirs = ["/opt/homebrew/etc/wireguard", "/usr/local/etc/wireguard", "/etc/wireguard"]
    public static let wgRun = "/var/run/wireguard"
    public static let ciscoCLI = ["/opt/cisco/secureclient/bin/vpn", "/opt/cisco/anyconnect/bin/vpn"]
    public static let defguardBundleCLI = "/Applications/Defguard.app/Contents/MacOS/defguard-client"

    /// dg_cli: спершу бандл, потім DEFGUARD_CLI / PATH; симлінки розгортаються —
    /// NetworkExtension шукає бандл за шляхом exec.
    public static func defguardCLI(_ configured: String) -> String? {
        for c in [defguardBundleCLI, configured, "/opt/homebrew/bin/defguard-client", "/usr/local/bin/defguard-client"] where !c.isEmpty {
            let real = URL(fileURLWithPath: c).resolvingSymlinksInPath().path
            if FileManager.default.isExecutableFile(atPath: real) { return real }
        }
        return nil
    }
}

/// Повільні джерела (defguard-client list ~1с, vpn -s hosts) — не частіше раз на хвилину.
actor SlowCache {
    private var dg: (at: Date, profiles: [Profile])?
    private var cisco: (at: Date, hosts: [String])?

    func defguard(_ cli: String, force: Bool) async -> [Profile] {
        if !force, let dg, Date().timeIntervalSince(dg.at) < 60 { return dg.profiles }
        let r = await Shell.run(cli, ["list", "--json"], timeout: 10)
        let p = Parse.defguardList(Data(r.out.utf8))
        dg = (Date(), p)
        return p
    }

    func ciscoHosts(_ cli: String, force: Bool) async -> [String] {
        if !force, let cisco, Date().timeIntervalSince(cisco.at) < 60 { return cisco.hosts }
        let h = Parse.ciscoHosts(await Shell.run(cli, ["-s", "hosts"], timeout: 10).out)
        cisco = (Date(), h)
        return h
    }
}

public final class StatusReader: @unchecked Sendable {
    public let store = SystemStore()
    private let cache = SlowCache()
    private let priv: PrivilegedReader

    public init(priv: PrivilegedReader) { self.priv = priv }

    public func snapshot(config c: RepoConfig, forceSlow: Bool = false) async -> Snapshot {
        var s = Snapshot()
        s.disabled = c.disabled
        async let netstatOut = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        async let psOut = Shell.run("/bin/ps", ["-axww", "-o", "pid=,etime=,command="])
        let utuns = Interfaces.liveUtuns()
        let rows = Parse.netstat(await netstatOut.out)
        let procs = Parse.ps(await psOut.out)
        s.network = store.network()
        s.network.splitDefault = Parse.splitDefault(rows)
        if let d = rows.first(where: { $0.dest == "default" && !$0.flags.contains("I") }) ?? rows.first(where: { $0.dest == "default" }) {
            s.network.defaultRouteIface = d.iface
            s.network.defaultRouteGateway = Parse.ipv4(d.gateway) != nil ? d.gateway : nil
        }

        var owners: [String: String] = [:]   // utun → підпис власника

        // ── WireGuard ──
        if c.isOn(.wireguard) {
            let (dir, names) = await wgConfigs()
            s.wgDir = dir
            s.profiles[.wireguard] = names.map { n in Profile(backend: .wireguard, name: n, path: dir.map { "\($0)/\(n).conf" }) }
            for (name, iface) in await wgActive() {
                var ses = Session(backend: .wireguard, name: name, state: .up, iface: iface, address: iface.flatMap { utuns[$0] })
                if let iface {
                    owners[iface] = "WireGuard \(name)"
                    ses.routes = Parse.ifaceRoutes(rows, iface: iface, own: utuns[iface]).map(\.dest)
                    if let m = (try? FileManager.default.attributesOfItem(atPath: "\(Paths.wgRun)/\(iface).sock"))?[.modificationDate] as? Date {
                        ses.elapsed = Self.since(m)
                    }
                }
                s.sessions.append(ses)
            }
        }

        // ── OpenVPN ──
        if c.isOn(.openvpn) {
            s.profiles[.openvpn] = ovpnProfiles(c.ovpnProfilesDir)
            for inst in Parse.ovpnInstances(procs) {
                var text: String?
                if let log = inst.log {
                    text = try? String(contentsOfFile: log, encoding: .utf8)
                    if text == nil { text = await priv.readIfAvailable(.readLog(path: log))?.output }
                }
                var ses = Session(backend: .openvpn, name: inst.id, state: .unknown)
                ses.pid = inst.pid
                ses.elapsed = Parse.prettyElapsed(inst.elapsed)
                if let text {
                    let st = Parse.ovpnLog(text)
                    ses.state = st.up ? .up : .connecting(st.error)
                    if st.up, let dev = st.dev {
                        ses.iface = dev
                        ses.address = utuns[dev]
                        owners[dev] = "OpenVPN \(inst.id)"
                        ses.routes = Parse.ifaceRoutes(rows, iface: dev, own: utuns[dev]).map(\.dest)
                    }
                }
                s.sessions.append(ses)
            }
        }

        // ── Defguard ──
        if c.isOn(.defguard) {
            if let cli = Paths.defguardCLI(c.defguardCLI) {
                s.profiles[.defguard] = await cache.defguard(cli, force: forceSlow)
            }
            let list = Parse.ncList(await Shell.run("/usr/sbin/scutil", ["--nc", "list"]).out)
            for nc in list where nc.state != "Disconnected" {
                var ses = Session(backend: .defguard, name: nc.name, state: nc.state == "Connected" ? .up : .connecting(nil))
                if nc.state == "Connected" {
                    let info = Parse.ncStatus(await Shell.run("/usr/sbin/scutil", ["--nc", "status", nc.uuid]).out)
                    ses.iface = info.iface
                    ses.address = info.address
                    ses.dnsServers = info.dns
                    if let i = info.iface {
                        owners[i] = "Defguard \(nc.name)"
                        ses.routes = Parse.ifaceRoutes(rows, iface: i, own: utuns[i]).map(\.dest)
                    }
                }
                s.sessions.append(ses)
            }
        }

        // ── Cisco ──
        if c.isOn(.cisco), let cli = Shell.which(Paths.ciscoCLI) {
            let hosts = await cache.ciscoHosts(cli, force: forceSlow)
            s.profiles[.cisco] = hosts.map { Profile(backend: .cisco, name: $0, endpoint: $0) }
            if let host = Parse.ciscoConnectedHost(await Shell.run(cli, ["-s", "state"], timeout: 8).out) {
                // Хости в профілі можуть мати :port — порівнюємо без нього.
                let name = hosts.first { $0.split(separator: ":").first.map(String.init) == host } ?? host
                var ses = Session(backend: .cisco, name: name, state: .up)
                if let i = store.ciscoInterface {
                    ses.iface = i
                    ses.address = utuns[i]
                    owners[i] = "Cisco Secure Client"
                    ses.routes = Parse.ifaceRoutes(rows, iface: i, own: utuns[i]).map(\.dest)
                }
                s.sessions.append(ses)
            }
        }

        // ── Сторонні тунелі та таблиця маршрутів ──
        for (u, ip) in utuns.sorted(by: { $0.key < $1.key }) {
            if owners[u] == nil, let f = store.foreignOwner(of: u) {
                owners[u] = f
                var ses = Session(backend: nil, name: f, state: .up, iface: u, address: ip)
                ses.routes = Parse.ifaceRoutes(rows, iface: u, own: ip).map(\.dest)
                s.foreign.append(ses)
            }
            s.routeGroups.append(RouteGroup(iface: u, address: ip, owner: owners[u],
                                            routes: Parse.ifaceRoutes(rows, iface: u, own: ip)))
        }
        s.routeFixRoutes = Parse.routeFixRows(rows)

        // Власник глобального резолвера людською мовою (dns_owner_hint).
        if let o = s.network.dnsOwner {
            if o == "com.cisco.anyconnect" { s.network.dnsOwnerLabel = "Cisco Secure Client" }
            else if Parse.isUUID(o) {
                if let i = store.dnsInterface(uuid: o), i.hasPrefix("utun") { s.network.dnsOwnerLabel = owners[i] ?? "тунель \(i)" }
                else { s.network.dnsOwnerLabel = store.serviceName(o) }
            } else { s.network.dnsOwnerLabel = o }
        }
        s.updated = Date()
        return s
    }

    // MARK: WireGuard

    /// wg_config_dir + wg_list_configs; root-only теки — через helper (якщо є).
    func wgConfigs() async -> (String?, [String]) {
        let fm = FileManager.default
        func confs(_ d: String) -> [String]? {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { return nil }
            return items.filter { $0.hasSuffix(".conf") }.map { String($0.dropLast(5)) }.sorted()
        }
        var unreadable = false
        for d in Paths.wgDirs where fm.fileExists(atPath: d) {
            if let c = confs(d) { if !c.isEmpty { return (d, c) } } else { unreadable = true }
        }
        if unreadable, let r = await priv.readIfAvailable(.wgConfigs), r.ok, !r.output.isEmpty {
            let l = r.output.split(separator: "\n").map(String.init)
            return (l.first, Array(l.dropFirst()))
        }
        return (Paths.wgDirs.first { fm.fileExists(atPath: $0) }, [])
    }

    /// wg_active_map: <name>.name містить utunN. Файли бувають root 400 — тоді
    /// helper, інакше ім'я відоме, лише коли тунель один (як utun_owner у bash).
    func wgActive() async -> [(String, String?)] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: Paths.wgRun) else {
            if let r = await priv.readIfAvailable(.wgRuntime), r.ok { return Self.parseRuntime(r.output) }
            return []
        }
        let names = items.filter { $0.hasSuffix(".name") }.map { String($0.dropLast(5)) }.sorted()
        let socks = items.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) }
        var out: [(String, String?)] = []
        var unread: [String] = []
        for n in names {
            if let c = try? String(contentsOfFile: "\(Paths.wgRun)/\(n).name", encoding: .utf8) {
                out.append((n, c.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else { unread.append(n) }
        }
        if !unread.isEmpty {
            if let r = await priv.readIfAvailable(.wgRuntime), r.ok { return Self.parseRuntime(r.output) }
            let known = Set(out.compactMap(\.1))
            let freeSocks = socks.filter { !known.contains($0) }
            for n in unread { out.append((n, unread.count == 1 && freeSocks.count == 1 ? freeSocks[0] : nil)) }
        }
        return out
    }

    static func parseRuntime(_ s: String) -> [(String, String?)] {
        s.split(separator: "\n").compactMap { l in
            let p = l.split(separator: " ").map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }
    }

    // MARK: OpenVPN

    func ovpnProfiles(_ dir: String) -> [Profile] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return items.filter { $0.hasSuffix(".ovpn") }.sorted().map { f in
            let path = "\(dir)/\(f)"
            var p = Profile(backend: .openvpn, name: String(f.dropLast(5)), path: path)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let info = Parse.ovpnProfile(text)
                p.needsAuth = info.needsAuth
                p.remotes = Array(Set(info.remotes.map(\.host))).sorted()
                if let r = info.remotes.first { p.endpoint = "\(r.host):\(r.port)" + (r.proto.map { " \($0)" } ?? "") }
            }
            return p
        }
    }

    static func since(_ d: Date) -> String {
        let t = Int(Date().timeIntervalSince(d))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        if h >= 24 { return "\(h / 24)д \(String(format: "%02d:%02d", h % 24, m))" }
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
