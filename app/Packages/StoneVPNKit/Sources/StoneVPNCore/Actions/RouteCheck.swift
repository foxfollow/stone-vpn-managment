import Foundation
import StoneVPNShared

/// Сервер нашого VPN, до якого трафік забирає *чужий повний* тунель (напр. Defguard усередині
/// ClearVPN): працює, але це тунель у тунелі — менший MTU, інший вихідний IP, і кожне
/// перепідключення зовнішнього VPN рве внутрішній. Користувач вирішує: лишити чи напряму.
public struct RouteIssue: Identifiable, Hashable, Sendable {
    public var profileKey: String
    public var label: String          // «Defguard · core»
    public var host: String
    public var ip: String
    public var via: String            // ipsec0 / utunN
    public var viaOwner: String       // ClearVPN
    public var gateway: String?       // LAN-шлюз для маршруту напряму
    /// Поточна локальна мережа (MAC роутера) і її підпис; nil — не визначено.
    public var network: String?
    public var networkLabel: String?

    /// Рішення пам'ятаємо за профілем, власником тунелю (номери utun/ipsec змінюються) і мережею:
    /// вдома «напряму», у кафе «через ClearVPN». Без мережі — загальне (старий формат).
    public var decisionKey: String { Self.decisionKey(profileKey, viaOwner, network) }
    public var globalKey: String { Self.decisionKey(profileKey, viaOwner, nil) }
    public var id: String { "\(profileKey)|\(ip)" }

    public static func decisionKey(_ profile: String, _ owner: String, _ network: String?) -> String {
        "\(profile)|\(owner)" + (network.map { "|net:\($0)" } ?? "")
    }

    /// decisionKey → складові (власник/мережа без «|», MAC — з «:» усередині, тож ріжемо за «|»).
    public static func parseDecisionKey(_ k: String) -> (profile: String, owner: String, network: String?) {
        let p = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let net = p.count > 2 && p[2].hasPrefix("net:") ? String(p[2].dropFirst(4)) : nil
        return (p.first ?? k, p.count > 1 ? p[1] : "", net)
    }

    public init(profileKey: String, label: String, host: String, ip: String, via: String, viaOwner: String, gateway: String?,
                network: String? = nil, networkLabel: String? = nil) {
        self.profileKey = profileKey
        self.label = label
        self.host = host
        self.ip = ip
        self.via = via
        self.viaOwner = viaOwner
        self.gateway = gateway
        self.network = network
        self.networkLabel = networkLabel
    }
}

extension Actions {
    /// `host:port` / `[v6]:port` / `host` → host.
    public static func bareHost(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") { return String(t.dropFirst().prefix { $0 != "]" }) }
        return t.split(separator: ":").first.map(String.init) ?? t
    }

    /// -host маршрут до сервера VPN через LAN-шлюз (повз повний тунель іншого VPN).
    public func setDirectRoute(ip: String, gateway: String) async throws {
        _ = try await priv(.routeHostSet(ip: ip, gateway: gateway))
    }

    public func deleteDirectRoute(ip: String) async throws {
        _ = try await priv(.routeHostDelete(ip: ip))
    }
}
