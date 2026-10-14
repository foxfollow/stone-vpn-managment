import Foundation
import StoneVPNShared
import SystemConfiguration

/// Прямий доступ до SystemConfiguration (замість парсингу `scutil`).
/// Ground truth для DNS — State:/Network/Global/DNS, ніколи не networksetup.
public final class SystemStore: @unchecked Sendable {
    private let store: SCDynamicStore?

    public init() {
        store = SCDynamicStoreCreate(nil, "StoneVPN" as CFString, nil, nil)
    }

    public func value(_ key: String) -> [String: Any]? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    public func keys(_ pattern: String) -> [String] {
        guard let store else { return [] }
        return (SCDynamicStoreCopyKeyList(store, pattern as CFString) as? [String]) ?? []
    }

    /// UUID-и сервісів, що мають State-ключ kind (DNS | IPv4) — sc_service_uuids.
    public func serviceUUIDs(_ kind: String) -> [String] {
        keys("State:/Network/Service/.*/\(kind)").compactMap {
            Parse.firstMatch("^State:/Network/Service/(.*)/\(kind)$", $0)
        }
    }

    public func serviceName(_ uuid: String) -> String? {
        value("Setup:/Network/Service/\(uuid)")?["UserDefinedName"] as? String
    }

    public func network() -> NetworkInfo {
        var n = NetworkInfo()
        let ipv4 = value("State:/Network/Global/IPv4")
        n.primaryIface = ipv4?["PrimaryInterface"] as? String
        n.primaryUUID = ipv4?["PrimaryService"] as? String
        n.router = ipv4?["Router"] as? String
        if let u = n.primaryUUID { n.primaryService = serviceName(u) }
        let dns = value("State:/Network/Global/DNS")
        n.dnsServers = dns?["ServerAddresses"] as? [String] ?? []
        n.dnsOwner = Parse.configOwner(dns?["__CONFIGURATION_ID__"] as? String)
        // dns_orphan_uuids: State-DNS без State-IPv4, крім первинного.
        let live = Set(serviceUUIDs("IPv4"))
        // Наш основний DNS теж «DNS без IPv4», але він живий навмисно — не осиротілий.
        n.orphanDNS = serviceUUIDs("DNS").filter { $0 != n.primaryUUID && !live.contains($0) && $0 != HelperConst.dnsOverrideService }
        n.dnsOverride = value(HelperConst.dnsOverrideKey)?["ServerAddresses"] as? [String]
        return n
    }

    /// InterfaceName State-DNS сервісу (NE-тунелі пишуть DNS під UUID).
    public func dnsInterface(uuid: String) -> String? {
        value("State:/Network/Service/\(uuid)/DNS")?["InterfaceName"] as? String
    }

    /// Сторонній VPN, що володіє utun: State-сервіс з IPv4.InterfaceName == utun.
    public func foreignOwner(of utun: String) -> String? {
        for key in keys("State:/Network/Service/.*/IPv4") {
            guard (value(key)?["InterfaceName"] as? String) == utun else { continue }
            let svc = key.replacingOccurrences(of: "State:/Network/Service/", with: "").replacingOccurrences(of: "/IPv4", with: "")
            if svc == "com.cisco.anyconnect" { return "Cisco Secure Client" }
            return serviceName(svc) ?? "VPN-сервіс \(svc)"
        }
        return nil
    }

    /// ServerAddresses State-DNS сервісу (напр. com.cisco.anyconnect) — DNS тунелю.
    public func serviceDNS(_ id: String) -> [String] {
        value("State:/Network/Service/\(id)/DNS")?["ServerAddresses"] as? [String] ?? []
    }

    /// Setup-шар DNS кожного сервісу за іменем (те, що пише `networksetup -setdnsservers`
    /// і що wg-quick перезаписує на всіх сервісах). [] = DNS не задано (DHCP).
    public func setupDNS() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for key in keys("Setup:/Network/Service/[^/]+") where !key.dropFirst("Setup:/Network/Service/".count).contains("/") {
            guard let name = value(key)?["UserDefinedName"] as? String else { continue }
            out[name] = value(key + "/DNS")?["ServerAddresses"] as? [String] ?? []
        }
        return out
    }

    public var ciscoInterface: String? {
        value("State:/Network/Service/com.cisco.anyconnect/IPv4")?["InterfaceName"] as? String
    }

    // MARK: зміни

    private var watchStore: SCDynamicStore?

    /// Викликає onChange (на головній черзі) при будь-якій зміні мережевого стану.
    public func watch(_ onChange: @escaping @Sendable () -> Void) {
        final class Box { let f: @Sendable () -> Void; init(_ f: @escaping @Sendable () -> Void) { self.f = f } }
        let box = Unmanaged.passRetained(Box(onChange))
        var ctx = SCDynamicStoreContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().f()
        }
        guard let s = SCDynamicStoreCreate(nil, "StoneVPN.watch" as CFString, callback, &ctx) else { return }
        let patterns = ["State:/Network/Global/.*", "State:/Network/Service/.*", "State:/Network/Interface/.*/IPv4"] as CFArray
        SCDynamicStoreSetNotificationKeys(s, nil, patterns)
        SCDynamicStoreSetDispatchQueue(s, .main)
        watchStore = s
    }
}

/// IPv4-адреси інтерфейсів через getifaddrs (замість парсингу ifconfig).
public enum Interfaces {
    public static func ipv4() -> [String: String] {
        var out: [String: String] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0,
                   out[name] == nil {
                    out[name] = String(cString: host)
                }
            }
            p = ifa.ifa_next
        }
        return out
    }

    /// Живі utun = utun з IPv4 (utun лише з link-local IPv6 — не тунель).
    public static func liveUtuns() -> [String: String] { ipv4().filter { $0.key.hasPrefix("utun") } }

    public static func resolve(_ host: String) -> String? {
        if Parse.ipv4(host) != nil { return host }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buf)
    }
}
