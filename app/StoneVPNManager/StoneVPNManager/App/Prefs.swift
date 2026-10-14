import Foundation
import Observation
import StoneVPNCore

/// Налаштування лише застосунку (UserDefaults). Спільні з CLI — у config.env (RepoConfig).
@Observable @MainActor
final class Prefs {
    private let d = UserDefaults.standard

    // Іконка
    var iconColored: Bool { didSet { d.set(iconColored, forKey: "iconColored") } }
    var iconShowCount: Bool { didSet { d.set(iconShowCount, forKey: "iconShowCount") } }
    var iconShowName: Bool { didSet { d.set(iconShowName, forKey: "iconShowName") } }
    // Оновлення
    var backgroundInterval: Int { didSet { d.set(backgroundInterval, forKey: "backgroundInterval") } }
    // Список провайдерів у поповері
    var favorites: [String] { didSet { d.set(favorites, forKey: "favorites") } }
    var providerOrder: [String] { didSet { d.set(providerOrder, forKey: "providerOrder") } }
    var hiddenProviders: [String] { didSet { d.set(hiddenProviders, forKey: "hiddenProviders") } }
    var lastProfile: [String: String] { didSet { d.set(lastProfile, forKey: "lastProfile") } }
    var aliases: [String: String] { didSet { d.set(aliases, forKey: "aliases") } }
    var profileSettings: [String: ProfileSettings] {
        didSet { d.set(try? JSONEncoder().encode(profileSettings), forKey: "profileSettings") }
    }
    // Поведінка
    var autoRestoreDNS: Bool { didSet { d.set(autoRestoreDNS, forKey: "autoRestoreDNS") } }
    var dnsWatch: Bool { didSet { d.set(dnsWatch, forKey: "dnsWatch") } }
    var netAutoFix: Bool { didSet { d.set(netAutoFix, forKey: "netAutoFix") } }
    var rememberUser: Bool { didSet { d.set(rememberUser, forKey: "rememberUser") } }
    var rememberGateway: Bool { didSet { d.set(rememberGateway, forKey: "rememberGateway") } }
    var ovpnTimeout: Int { didSet { d.set(ovpnTimeout, forKey: "ovpnTimeout") } }
    var repoPath: String { didSet { d.set(repoPath, forKey: "repoPath") } }
    /// Не використовувати репо CLI навіть якщо воно є (окремий .app).
    var standalone: Bool { didSet { d.set(standalone, forKey: "standalone") } }
    /// Без жодного VPN і з мертвим DNS — запускати DNS Fix самостійно.
    var autoDNSFix: Bool { didSet { d.set(autoDNSFix, forKey: "autoDNSFix") } }
    // Cisco: власні хости (з портом) — профіль head-end перезаписує, тож тримаємо свої
    var ciscoHosts: [String] { didSet { d.set(ciscoHosts, forKey: "ciscoHosts") } }
    var ciscoLastUser: String { didSet { d.set(ciscoLastUser, forKey: "ciscoLastUser") } }
    var ciscoLastGroup: String { didSet { d.set(ciscoLastGroup, forKey: "ciscoLastGroup") } }
    // Сповіщення
    var notifyConnected: Bool { didSet { d.set(notifyConnected, forKey: "notifyConnected") } }
    var notifyDisconnected: Bool { didSet { d.set(notifyDisconnected, forKey: "notifyDisconnected") } }
    var notifyDropped: Bool { didSet { d.set(notifyDropped, forKey: "notifyDropped") } }
    var notifyDNS: Bool { didSet { d.set(notifyDNS, forKey: "notifyDNS") } }
    var notifyForeign: Bool { didSet { d.set(notifyForeign, forKey: "notifyForeign") } }

    init() {
        d.register(defaults: [
            "iconColored": true, "iconShowCount": true, "iconShowName": false,
            "backgroundInterval": 30,
            "autoRestoreDNS": true, "dnsWatch": true, "netAutoFix": false,
            "rememberUser": true, "rememberGateway": true, "ovpnTimeout": 45,
            "notifyConnected": true, "notifyDisconnected": false, "notifyDropped": true,
            "notifyDNS": true, "notifyForeign": true,
        ])
        iconColored = d.bool(forKey: "iconColored")
        iconShowCount = d.bool(forKey: "iconShowCount")
        iconShowName = d.bool(forKey: "iconShowName")
        backgroundInterval = d.integer(forKey: "backgroundInterval")
        favorites = d.stringArray(forKey: "favorites") ?? []
        providerOrder = d.stringArray(forKey: "providerOrder") ?? Backend.allCases.map(\.rawValue)
        hiddenProviders = d.stringArray(forKey: "hiddenProviders") ?? []
        lastProfile = d.dictionary(forKey: "lastProfile") as? [String: String] ?? [:]
        aliases = d.dictionary(forKey: "aliases") as? [String: String] ?? [:]
        profileSettings = (d.data(forKey: "profileSettings")).flatMap { try? JSONDecoder().decode([String: ProfileSettings].self, from: $0) } ?? [:]
        autoRestoreDNS = d.bool(forKey: "autoRestoreDNS")
        dnsWatch = d.bool(forKey: "dnsWatch")
        netAutoFix = d.bool(forKey: "netAutoFix")
        rememberUser = d.bool(forKey: "rememberUser")
        rememberGateway = d.bool(forKey: "rememberGateway")
        ovpnTimeout = d.integer(forKey: "ovpnTimeout")
        repoPath = d.string(forKey: "repoPath") ?? ""
        standalone = d.bool(forKey: "standalone")
        autoDNSFix = d.bool(forKey: "autoDNSFix")
        ciscoHosts = d.stringArray(forKey: "ciscoHosts") ?? []
        ciscoLastUser = d.string(forKey: "ciscoLastUser") ?? ""
        ciscoLastGroup = d.string(forKey: "ciscoLastGroup") ?? ""
        notifyConnected = d.bool(forKey: "notifyConnected")
        notifyDisconnected = d.bool(forKey: "notifyDisconnected")
        notifyDropped = d.bool(forKey: "notifyDropped")
        notifyDNS = d.bool(forKey: "notifyDNS")
        notifyForeign = d.bool(forKey: "notifyForeign")
    }

    var orderedBackends: [Backend] {
        let known = providerOrder.compactMap(Backend.init(rawValue:))
        return known + Backend.allCases.filter { !known.contains($0) }
    }

    func isFavorite(_ key: String) -> Bool { favorites.contains(key) }
    func toggleFavorite(_ key: String) {
        if let i = favorites.firstIndex(of: key) { favorites.remove(at: i) } else { favorites.append(key) }
    }

    func display(_ p: Profile) -> String { aliases[p.key].flatMap { $0.isEmpty ? nil : $0 } ?? p.name }

    /// Route-fix за замовчуванням: OpenVPN — питати (як vpn-up.sh); WireGuard — ні
    /// (wg-quick сам веде маршрут до endpoint); NE-бекенди route-fix не мають.
    func settings(for p: Profile) -> ProfileSettings {
        if let s = profileSettings[p.key] { return s }
        var s = ProfileSettings()
        s.routeFix = p.backend == .openvpn ? .ask : .off
        return s
    }

    func setSettings(_ s: ProfileSettings, for p: Profile) { profileSettings[p.key] = s }
}
