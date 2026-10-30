import Foundation

/// Повернення DNS сервісів після VPN. wg-quick ставить DNS тунелю на *всі* сервіси і мав би
/// повернути старі значення на down, але це ламається (кілл, сон, down з іншого місця) —
/// і Wi-Fi лишається з мертвим резолвером тунелю. Тому застосунок сам тримає еталон:
/// DNS кожного сервісу, знятий, коли WG-тунелів немає і резолвер відповідає.
public enum DNSGuard {
    /// Оновити еталон поточними значеннями. Значення, що містить DNS якогось тунелю,
    /// не приймається (це залишок VPN, а не вибір користувача) — лишається попереднє.
    public static func learn(baseline: [String: [String]], current: [String: [String]],
                             tunnelDNS: Set<String>) -> [String: [String]] {
        var b = baseline
        for (svc, servers) in current where tunnelDNS.isDisjoint(with: servers) {
            b[svc] = servers
        }
        return b
    }

    /// Що переписати: сервіс → потрібні сервери ([] = empty/DHCP).
    /// З еталоном — лише сервіси, що від нього відрізняються *і* тримають DNS тунелю
    /// (ручну зміну без тунельного DNS не відкочуємо). Без еталону — тунельний DNS → fallback.
    public static func plan(current: [String: [String]], baseline: [String: [String]],
                            tunnelDNS: Set<String>, fallback: [String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (svc, servers) in current where !tunnelDNS.isDisjoint(with: servers) {
            let want = baseline[svc].map { tunnelDNS.isDisjoint(with: $0) ? $0 : fallback } ?? fallback
            if want != servers { out[svc] = want }
        }
        return out
    }
}
