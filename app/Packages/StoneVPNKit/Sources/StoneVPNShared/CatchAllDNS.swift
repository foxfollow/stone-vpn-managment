import Foundation

/// Резолвери «для всіх доменів» (SupplementalMatchDomains містить "").
///
/// configd сортує резолвери компаратором `compareDomain` (Plugins/IPMonitor/dns-configuration.c),
/// який для записів *без домену* завжди повертає «менше» — тож між кількома catch-all записами
/// SearchOrder нічого не вирішує, перемагає порядок вставки (хеш-порядок ID сервісів).
/// Єдиний детермінований спосіб зробити свій запис першим — лишити його єдиним catch-all:
/// на час вибору прибрати "" з чужих записів (Cisco, Defguard…) і повернути потім.
public enum CatchAllDNS {
    public static let domainsKey = "SupplementalMatchDomains"
    public static let ordersKey = "SupplementalMatchOrders"

    public static func isCatchAll(_ dns: [String: Any]) -> Bool {
        (dns[domainsKey] as? [String])?.contains("") == true
    }

    /// Копія без "" (і відповідного елемента MatchOrders). nil — запис не catch-all.
    public static func displaced(_ dns: [String: Any]) -> [String: Any]? {
        guard let domains = dns[domainsKey] as? [String], domains.contains("") else { return nil }
        var out = dns
        let keep = domains.indices.filter { domains[$0] != "" }
        out[domainsKey] = keep.map { domains[$0] }
        if let orders = dns[ordersKey] as? [Any], orders.count == domains.count {
            out[ordersKey] = keep.map { orders[$0] }
        }
        return out
    }

    /// Що зберегти, щоб потім повернути: оригінальні MatchDomains/MatchOrders.
    public static func backup(_ dns: [String: Any]) -> [String: Any] {
        dns.filter { $0.key == domainsKey || $0.key == ordersKey }
    }

    /// Повернути оригінал. nil — нічого робити (клієнт уже сам повернув "").
    public static func restored(current: [String: Any], backup: [String: Any]) -> [String: Any]? {
        guard !isCatchAll(current) else { return nil }
        var out = current
        out[domainsKey] = backup[domainsKey]
        out[ordersKey] = backup[ordersKey]
        return out
    }
}
