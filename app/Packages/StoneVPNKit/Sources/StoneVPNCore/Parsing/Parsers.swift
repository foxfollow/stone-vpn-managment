import Foundation

/// Чисті парсери виводу системних утиліт. Кожен — порт відповідного awk/sed із
/// main-vpn-manager.sh / vpn-up.sh (назва bash-функції в коментарі).
public enum Parse {

    // MARK: netstat -rn -f inet

    public static func netstat(_ s: String) -> [RouteRow] {
        s.split(separator: "\n").compactMap { line in
            let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard p.count >= 4, let c = p[0].first, c.isNumber || p[0] == "default" else { return nil }
            return RouteRow(dest: p[0], gateway: p[1], flags: p[2], iface: p[3])
        }
    }

    /// route_split_default: інтерфейси, куди вказують 0/1 і 128.0/1.
    public static func splitDefault(_ rows: [RouteRow]) -> [String] {
        Array(Set(rows.filter { $0.dest == "0/1" || $0.dest == "128.0/1" }.map(\.iface))).sorted()
    }

    static func isNoise(_ dest: String) -> Bool {
        dest.range(of: #"^22[4-9]|^23[0-9]|^255\.255\.255\.255"#, options: .regularExpression) != nil
    }

    /// iface_routes / route_vpn_table: маршрути через інтерфейс, без власної адреси,
    /// multicast/broadcast і клонованих (W) записів. Scoped default позначено.
    public static func ifaceRoutes(_ rows: [RouteRow], iface: String, own: String?) -> [(dest: String, via: String?)] {
        rows.filter { $0.iface == iface && $0.dest != own && !$0.flags.contains("W") && !isNoise($0.dest) }
            .map { r in
                let d = (r.dest == "default" && r.flags.contains("I")) ? "default (scoped)" : r.dest
                let g = r.gateway
                let via: String? = (g.hasPrefix("link#") || g.hasPrefix("utun") || g == own) ? nil : g
                return (d, via)
            }
    }

    /// Статичні host-маршрути через шлюз на фізичному інтерфейсі = route-fix до VPN-серверів.
    public static func routeFixRows(_ rows: [RouteRow]) -> [RouteRow] {
        rows.filter { r in
            (r.dest.hasSuffix("/32") || r.flags.contains("H")) && r.flags.contains("G") && r.flags.contains("S")
                && !r.iface.hasPrefix("utun") && !r.iface.hasPrefix("lo")
        }
    }

    /// LAN default-шлюзи (не utun) — кандидати для route-fix.
    public static func lanGateways(_ rows: [RouteRow]) -> [(iface: String, gw: String)] {
        var seen = Set<String>()
        return rows.filter { $0.dest == "default" && ipv4($0.gateway) != nil && !$0.iface.hasPrefix("utun") }
            .compactMap { seen.insert($0.gateway).inserted ? ($0.iface, $0.gateway) : nil }
    }

    /// Шлюзи активних тунелів (сервер сидить за тунелем, але маршруту до нього немає).
    public static func tunnelGateways(_ rows: [RouteRow], ownAddresses: [String: String]) -> [(iface: String, gw: String)] {
        var seen = Set<String>()
        return rows.filter { $0.iface.hasPrefix("utun") && ipv4($0.gateway) != nil && $0.flags.contains("G") }
            .filter { ownAddresses[$0.iface] != $0.gateway }
            .compactMap { seen.insert("\($0.iface) \($0.gateway)").inserted ? ($0.iface, $0.gateway) : nil }
    }

    /// tunnel_iface_for (vpn-up.sh): utun з найдовшим префіксом до IP, або nil.
    /// Повний тунель (prefix ≤ 1: default, def1) не рахується; статичні -host
    /// маршрути повз utun (залишки route-fix) ігноруються.
    public static func tunnelIface(for ip: String, rows: [RouteRow]) -> String? {
        guard let target = ipv4(ip) else { return nil }
        var best: (plen: Int, iface: String)?
        for r in rows {
            guard let (net, plen) = network(r.dest) else { continue }
            let mask: UInt32 = plen == 0 ? 0 : ~UInt32(0) << UInt32(32 - plen)
            guard target & mask == net & mask else { continue }
            if r.flags.contains("H") && r.flags.contains("S") && !r.iface.hasPrefix("utun") { continue }
            if best == nil || plen > best!.plen { best = (plen, r.iface) }
        }
        guard let b = best, b.plen > 1, b.iface.hasPrefix("utun") else { return nil }
        return b.iface
    }

    /// netstat-нотація: "default", "10.8/16", "10.8.0" (класовий), "1.2.3.4" (host).
    static func network(_ dest: String) -> (UInt32, Int)? {
        if dest == "default" { return (0, 0) }
        let parts = dest.split(separator: "/", maxSplits: 1).map(String.init)
        let octs = parts[0].split(separator: ".").map(String.init)
        guard (1...4).contains(octs.count) else { return nil }
        let padded = (octs + ["0", "0", "0", "0"]).prefix(4).joined(separator: ".")
        guard let addr = ipv4(padded) else { return nil }
        let plen = parts.count > 1 ? Int(parts[1]) : 8 * octs.count
        guard let plen, (0...32).contains(plen) else { return nil }
        return (addr, plen)
    }

    public static func ipv4(_ s: String) -> UInt32? {
        let o = s.split(separator: ".", omittingEmptySubsequences: false)
        guard o.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in o {
            guard let n = UInt32(x), n <= 255 else { return nil }
            v = v << 8 | n
        }
        return v
    }

    // MARK: ps -axww -o pid=,etime=,command=

    public struct PSRow: Sendable {
        public var pid: Int32
        public var elapsed: String
        public var command: String
        public var exeName: String {
            let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return (first as NSString).lastPathComponent
        }
    }

    public static func ps(_ s: String) -> [PSRow] {
        s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard p.count == 3, let pid = Int32(p[0]) else { return nil }
            return PSRow(pid: pid, elapsed: String(p[1]), command: String(p[2]))
        }
    }

    public struct OvpnInstance: Sendable {
        public var pid: Int32
        public var id: String
        public var config: String?
        public var log: String?
        public var elapsed: String
    }

    /// ovpn_instances: процеси openvpn + профіль з --config і лог з --log.
    public static func ovpnInstances(_ rows: [PSRow]) -> [OvpnInstance] {
        rows.filter { $0.exeName == "openvpn" }.map { r in
            let cfg = firstMatch(#".*--config (.*\.ovpn)"#, r.command)
            let log = firstMatch(#"--log ([^ ]*)"#, r.command)
            let id = cfg.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "?"
            return OvpnInstance(pid: r.pid, id: id, config: cfg, log: log, elapsed: r.elapsed)
        }
    }

    /// etime "[[dd-]hh:]mm:ss" → компактно "1:42:10" / "12:03" / "2д 03:04".
    public static func prettyElapsed(_ e: String) -> String {
        if let dash = e.firstIndex(of: "-") {
            return "\(e[..<dash])д \(e[e.index(after: dash)...].prefix(5))"
        }
        return e.hasPrefix("00:") && e.count == 8 ? String(e.dropFirst(3)) : e
    }

    // MARK: OpenVPN

    public struct OvpnLogState: Equatable, Sendable {
        public var up: Bool
        public var dev: String?
        public var error: String?
    }

    /// ovpn_state: up — якщо «Initialization Sequence Completed» після останнього рестарту.
    public static func ovpnLog(_ text: String) -> OvpnLogState {
        var up = 0, rs = 0
        var dev: String?, err: String?
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let n = i + 1
            if line.contains("Initialization Sequence Completed") { up = n }
            if line.range(of: "process restarting|Restart pause|SIGUSR1|SIGHUP", options: .regularExpression) != nil { rs = n }
            if line.contains("Opened utun device") { dev = line.split(separator: " ").last.map(String.init) }
            if line.range(of: "TLS Error|AUTH_FAILED|ERROR|Connection refused|unreachable|Exiting", options: .regularExpression) != nil {
                err = line.replacingOccurrences(of: #"^[0-9-]+ [0-9:]+ "#, with: "", options: .regularExpression)
            }
        }
        let isUp = up > 0 && up > rs
        return OvpnLogState(up: isUp, dev: dev, error: isUp ? nil : err)
    }

    /// Шаблон невдачі з vpn-up.sh (опитування після старту).
    public static let ovpnFailPattern = "AUTH_FAILED|auth-failure|fatal error|TLS Error|TLS handshake failed|Exiting due to fatal|SIGTERM received|Connection refused|Network unreachable"

    public struct OvpnProfileInfo: Sendable {
        public var remotes: [(host: String, port: String, proto: String?)]
        public var needsAuth: Bool
        public var hasDev: Bool
    }

    public static func ovpnProfile(_ text: String) -> OvpnProfileInfo {
        var remotes: [(String, String, String?)] = []
        var needsAuth = false, hasDev = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let k = p.first else { continue }
            if k == "remote", p.count >= 2 { remotes.append((p[1], p.count > 2 ? p[2] : "1194", p.count > 3 ? p[3] : nil)) }
            if k == "auth-user-pass", p.count == 1 { needsAuth = true }
            if k == "dev" { hasDev = true }
        }
        return OvpnProfileInfo(remotes: remotes, needsAuth: needsAuth, hasDev: hasDev)
    }

    /// Назви профілів з config.json OpenVPN Connect (redux-persist: `persist:root` → `status` —
    /// JSON-рядки всередині JSON). Повертає id → назва. Секретні поля не читаються.
    public static func ovpnConnectTitles(_ json: Data) -> [String: String] {
        func obj(_ v: Any?) -> [String: Any]? {
            if let d = v as? [String: Any] { return d }
            guard let s = v as? String, let data = s.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let root = obj(try? JSONSerialization.jsonObject(with: json)),
              let persist = obj(root["persist:root"]),
              let status = obj(persist["status"]),
              let profiles = obj(status["profiles"]) else { return [:] }
        var out: [String: String] = [:]
        for (id, v) in profiles {
            guard let p = v as? [String: Any] else { continue }
            let raw = [p["profileDisplayName"], p["name"], p["profileName"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            if let raw, let t = ovpnConnectTitle(raw) { out[id] = t }
        }
        return out
    }

    /// GUI іменує імпорт як «host [ім'я-файлу]» — host і так видно в remote, тож назва = ім'я файлу.
    /// Перейменований у GUI профіль (без дужок) лишається як є.
    public static func ovpnConnectTitle(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let inner = firstMatch(#"^.*? \[(.+)\]$"#, s) { return inner }
        return s.isEmpty ? nil : s
    }

    // MARK: Defguard (scutil --nc)

    public struct NCSession: Sendable, Equatable {
        public var state: String
        public var uuid: String
        public var name: String
    }

    /// dg_sessions: рядки `scutil --nc list` з [VPN:net.defguard].
    public static func ncList(_ s: String, tag: String = "[VPN:net.defguard]") -> [NCSession] {
        s.split(separator: "\n").compactMap { l in
            let line = String(l)
            guard line.contains(tag) else { return nil }
            let state = firstMatch(#"\(([^)]*)\)"#, line) ?? ""
            let name = firstMatch(#""([^"]*)""#, line) ?? ""
            let uuid = firstMatch(#"([0-9A-F]+-[0-9A-F]+-[0-9A-F]+-[0-9A-F-]+)"#, line) ?? ""
            return NCSession(state: state, uuid: uuid, name: name)
        }
    }

    /// dg_info: InterfaceName, перша адреса, DNSServers.
    public static func ncStatus(_ s: String) -> (iface: String?, address: String?, dns: [String]) {
        var ifc: String?, addr: String?, dns: [String] = []
        var blk = ""
        for l in s.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("InterfaceName :"), ifc == nil { ifc = t.split(separator: " ").last.map(String.init) }
            if t.hasPrefix("Addresses :") { blk = "a"; continue }
            if t.hasPrefix("DNSServers :") { blk = "d"; continue }
            if !blk.isEmpty, t.hasPrefix("}") { blk = ""; continue }
            if t.range(of: #"^[0-9]+ :"#, options: .regularExpression) != nil, let v = t.split(separator: " ").last.map(String.init) {
                if blk == "a", addr == nil { addr = v }
                if blk == "d" { dns.append(v) }
            }
        }
        return (ifc, addr, dns)
    }

    /// dg_targets: `defguard-client list --json` → профілі.
    public static func defguardList(_ data: Data) -> [Profile] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [Profile] = []
        for (kind, key) in [("location", "locations"), ("tunnel", "tunnels")] {
            for item in obj[key] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                var p = Profile(backend: .defguard, name: name, endpoint: item["endpoint"] as? String)
                p.dgKind = kind
                if kind == "location", (item["mfa_enabled"] as? Bool) == true {
                    p.mfa = (item["mfa_method"] as? String) ?? "yes"
                }
                p.allTraffic = item["route_all_traffic"] as? Bool
                out.append(p)
            }
        }
        return out
    }

    // MARK: Cisco

    public static func ciscoConnectedHost(_ s: String) -> String? {
        for l in s.split(separator: "\n") {
            if let h = firstMatch(#"Connected to (.*)\.$"#, String(l)) { return h }
        }
        return nil
    }

    public static func ciscoHosts(_ s: String) -> [String] {
        var inHosts = false
        var out: [String] = []
        for l in s.split(separator: "\n") {
            if l.contains("[hosts]:") { inHosts = true; continue }
            let t = l.trimmingCharacters(in: .whitespaces)
            if inHosts, t.hasPrefix("> ") { out.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
        }
        return out
    }

    // MARK: networksetup -listnetworkserviceorder

    public static func serviceOrder(_ s: String) -> [NetworkService] {
        let lines = s.split(separator: "\n").map(String.init)
        var out: [NetworkService] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.range(of: #"^\(([0-9]+|\*)\) "#, options: .regularExpression) != nil {
                let enabled = !l.hasPrefix("(*)")
                let name = l.replacingOccurrences(of: #"^\([0-9*]+\) "#, with: "", options: .regularExpression)
                var hw = "", dev = ""
                if i + 1 < lines.count {
                    let d = lines[i + 1]
                    hw = firstMatch(#"Hardware Port: (.*?), Device:"#, d) ?? ""
                    dev = firstMatch(#"Device: ([^)]*)\)"#, d) ?? ""
                    i += 1
                }
                out.append(NetworkService(order: out.count + 1, enabled: enabled, name: name, hwPort: hw, device: dev))
            }
            i += 1
        }
        return out
    }

    // MARK: WireGuard

    public struct WGConfInfo: Sendable {
        public var endpoint: String?
        public var address: String?
        public var dns: String?
        public var allowedIPs: String?
    }

    public static func wgConf(_ s: String) -> WGConfInfo {
        var info = WGConfInfo()
        for raw in s.split(separator: "\n") {
            let kv = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "endpoint": info.endpoint = info.endpoint ?? kv[1]
            case "address": info.address = kv[1]
            case "dns": info.dns = kv[1]
            case "allowedips": info.allowedIPs = [info.allowedIPs, kv[1]].compactMap { $0 }.joined(separator: ", ")
            default: break
            }
        }
        return info
    }

    // MARK: DNS owner

    /// dns_global_owner: "Supplemental: com.cisco.anyconnect 0" → com.cisco.anyconnect.
    public static func configOwner(_ v: String?) -> String? {
        guard let v else { return nil }
        let f = v.split(separator: " ").map(String.init)
        guard let first = f.first else { return nil }
        return first.hasSuffix(":") ? (f.count > 1 ? f[1] : nil) : first
    }

    public static func isUUID(_ s: String) -> Bool {
        s.range(of: #"^[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+$"#, options: .regularExpression) != nil
    }

    // MARK: helpers

    public static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
