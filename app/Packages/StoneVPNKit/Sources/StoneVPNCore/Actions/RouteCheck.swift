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

    /// Рішення пам'ятаємо за профілем і власником тунелю (номери utun/ipsec змінюються).
    public var decisionKey: String { "\(profileKey)|\(viaOwner)" }
    public var id: String { "\(profileKey)|\(ip)" }

    public init(profileKey: String, label: String, host: String, ip: String, via: String, viaOwner: String, gateway: String?) {
        self.profileKey = profileKey
        self.label = label
        self.host = host
        self.ip = ip
        self.via = via
        self.viaOwner = viaOwner
        self.gateway = gateway
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
