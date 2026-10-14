import Foundation

public enum Backend: String, CaseIterable, Codable, Identifiable, Sendable {
    case wireguard, openvpn, defguard, cisco

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wireguard: "WireGuard"
        case .openvpn: "OpenVPN"
        case .defguard: "Defguard"
        case .cisco: "Cisco"
        }
    }

    public var badge: String {
        switch self {
        case .wireguard: "WG"
        case .openvpn: "OV"
        case .defguard: "DG"
        case .cisco: "CS"
        }
    }

    /// Синоніми як у backend_canon (wg/ovpn/dg/anyconnect).
    public static func canon(_ s: String) -> Backend? {
        switch s.lowercased() {
        case "wg", "wireguard": .wireguard
        case "ovpn", "openvpn": .openvpn
        case "dg", "defguard": .defguard
        case "cisco", "anyconnect": .cisco
        default: nil
        }
    }

    /// Після down цей бекенд сам відновлює DNS (Defguard, Cisco) — лише flush.
    public var restoresOwnDNS: Bool { self == .defguard || self == .cisco }
}

/// Профіль = те, до чого можна підключитись. `key` стабільний між запусками:
/// "wireguard:office", "openvpn:1712345678901", "defguard:prod", "cisco:vpn.corp".
public struct Profile: Identifiable, Hashable, Sendable {
    public var backend: Backend
    public var name: String                 // сирий ідентифікатор (ім'я конфігу/локації/хост)
    public var endpoint: String?
    public var path: String?
    public var needsAuth = false            // OpenVPN: голий auth-user-pass
    public var remotes: [String] = []       // OpenVPN: хости з remote-рядків
    public var mfa: String?                 // Defguard: метод MFA або nil
    public var dgKind: String?              // Defguard: location | tunnel
    public var allTraffic: Bool?

    public var key: String { "\(backend.rawValue):\(name)" }
    public var id: String { key }

    public init(backend: Backend, name: String, endpoint: String? = nil, path: String? = nil) {
        self.backend = backend
        self.name = name
        self.endpoint = endpoint
        self.path = path
    }
}

public enum SessionState: Equatable, Sendable {
    case up
    case connecting(String?)    // необов'язкова остання помилка з логу
    case unknown                // процес живий, лог недоступний
}

/// Живий (або той, що підключається) тунель.
public struct Session: Identifiable, Hashable, Sendable {
    public var backend: Backend?            // nil = сторонній VPN (ClearVPN тощо)
    public var name: String
    public var state: SessionState
    public var iface: String?
    public var address: String?
    public var pid: Int32?
    public var elapsed: String?
    public var routes: [String] = []
    public var dnsServers: [String] = []

    public var profileKey: String? { backend.map { "\($0.rawValue):\(name)" } }
    public var id: String { profileKey ?? "foreign:\(name):\(iface ?? "")" }

    public static func == (a: Session, b: Session) -> Bool { a.id == b.id && a.state == b.state && a.iface == b.iface }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public init(backend: Backend?, name: String, state: SessionState, iface: String? = nil, address: String? = nil) {
        self.backend = backend
        self.name = name
        self.state = state
        self.iface = iface
        self.address = address
    }
}

public struct RouteRow: Hashable, Sendable {
    public var dest: String
    public var gateway: String
    public var flags: String
    public var iface: String
}

public struct RouteGroup: Identifiable, Hashable, Sendable {
    public var iface: String
    public var address: String
    public var owner: String?
    public var routes: [(dest: String, via: String?)]

    public var id: String { iface }
    public static func == (a: RouteGroup, b: RouteGroup) -> Bool { a.iface == b.iface && a.owner == b.owner && a.routes.map(\.dest) == b.routes.map(\.dest) }
    public func hash(into h: inout Hasher) { h.combine(iface) }
}

public struct NetworkService: Identifiable, Hashable, Sendable {
    public var order: Int
    public var enabled: Bool
    public var name: String
    public var hwPort: String
    public var device: String          // порожньо = VPN-сервіс
    public var id: String { name }
    public var isVPN: Bool { device.isEmpty }
}

public struct NetworkInfo: Sendable, Equatable {
    public var primaryService: String?
    public var primaryIface: String?
    public var primaryUUID: String?
    public var router: String?
    public var dnsServers: [String] = []
    public var dnsOwner: String?            // __CONFIGURATION_ID__ (UUID або reverse-DNS)
    public var dnsOwnerLabel: String?       // людська назва власника, якщо відома
    public var orphanDNS: [String] = []
    public var dnsOverride: [String]?        // наш основний DNS, якщо встановлено
    public var defaultRouteIface: String?
    public var defaultRouteGateway: String?
    public var splitDefault: [String] = []  // 0/1 + 128.0/1 → utunN
    public var primaryIsTunnel: Bool { primaryIface?.hasPrefix("utun") ?? false }
}

public struct Snapshot: Sendable {
    public var profiles: [Backend: [Profile]] = [:]
    public var sessions: [Session] = []
    public var foreign: [Session] = []
    public var network = NetworkInfo()
    public var routeGroups: [RouteGroup] = []
    public var routeFixRoutes: [RouteRow] = []
    public var disabled: Set<Backend> = []
    public var wgDir: String?
    public var updated = Date()

    public init() {}

    public func session(for key: String) -> Session? { sessions.first { $0.profileKey == key } }
    public var upCount: Int { sessions.filter { $0.state == .up }.count }
    public var connectingCount: Int { sessions.filter { if case .connecting = $0.state { true } else { false } }.count }
    public var erroredCount: Int {
        sessions.filter { if case .connecting(let e?) = $0.state, !e.isEmpty { true } else { false } }.count
    }
}
