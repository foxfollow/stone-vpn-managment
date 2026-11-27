import Foundation

/// Одна привілейована дія. Застосунок лише *просить*; helper (root) валідує кожен
/// аргумент і виконує фіксовану команду — довільного exec немає.
public enum PrivOp: Codable, Sendable, Equatable {
    case ping
    // WireGuard
    case wgUp(confPath: String)
    case wgDown(confPath: String)
    case wgRuntime                       // /var/run/wireguard/*.name → "name utunN"
    case wgConfigs                       // "dir\nname\nname…" (теки бувають root-only)
    case readWGConf(path: String)        // без PrivateKey/PresharedKey
    case wgDelete(confPath: String)      // лише неактивний тунель (v4)
    // OpenVPN
    case ovpnStart(profilePath: String, username: String?, password: String?, addDev: Bool)
    case ovpnStop(pid: Int32)
    case readLog(path: String)           // лише /tmp/openvpn*.log
    // Маршрути
    case routeHostSet(ip: String, gateway: String)
    case routeHostDelete(ip: String)
    // DNS
    case dnsSet(service: String, servers: [String])   // bounce: empty → значення; [] = empty
    case dnsPurge(uuids: [String])
    case dnsFlush
    case resolverSet(domain: String, servers: [String])
    case resolverRemove(domain: String)
    /// Основний DNS: власний catch-all Supplemental-резолвер + "" прибирається з чужих
    /// catch-all записів (див. CatchAllDNS), оригінали — у dnsDisplacedKey. Clear повертає все.
    case dnsOverride(servers: [String])
    case dnsOverrideClear
    // Мережа / процеси
    case orderServices(names: [String])
    case killPid(pid: Int32)
    // Доступ (v7): хто з користувачів Mac може користуватися helper-ом
    case accessInfo                                  // → JSON HelperAccessInfo; дозволено всім
    case accessSetPolicy(policy: HelperAccessPolicy) // лише власник (або пароль адміністратора)
    case accessClaim                                 // зробити запитувача власником; лише з паролем адміністратора
    /// Кілька дій за один виклик (у fallback-режимі — один запит пароля).
    case batch([PrivOp])
}

/// Запит до helper-а (протокол v6+): операція + мова інтерфейсу застосунку. Демон живе з
/// мовою системи (root), тому повідомлення локалізує мовою клієнта, а не своєю.
/// Старі клієнти шлють голий `PrivOp` — helper приймає обидва формати.
public struct PrivRequest: Codable, Sendable {
    public var op: PrivOp
    /// Код локалізації (`Bundle.main.preferredLocalizations.first`): "en", "uk"…
    public var lang: String?

    public init(op: PrivOp, lang: String?) {
        self.op = op
        self.lang = lang
    }
}

public struct PrivResult: Codable, Sendable {
    public var ok: Bool
    public var output: String
    /// v7: helper відмовив, бо запитувачу не дозволено ним користуватися (HelperAccessPolicy).
    /// Застосунок тоді виконує дію з паролем адміністратора, а не показує помилку.
    public var denied: Bool?

    public init(ok: Bool, output: String, denied: Bool? = nil) {
        self.ok = ok
        self.output = output
        self.denied = denied
    }

    public static func fail(_ msg: String) -> PrivResult { PrivResult(ok: false, output: msg) }
    public static func deny(_ msg: String) -> PrivResult { PrivResult(ok: false, output: msg, denied: true) }
}

public enum HelperConst {
    public static let label = "com.foxfollow.stonevpnmanager.helper"
    public static let plistName = "com.foxfollow.stonevpnmanager.helper.plist"
    public static let appBundleID = "com.foxfollow.stonevpnmanager"
    public static let helperExecutable = "StoneVPNManagerHelper"
    /// Підняти при зміні PrivOp — застосунок запропонує перевстановити helper.
    public static let version = 7   // 5: WGConfGuard; 6: PrivRequest (мова відповідей); 7: доступ за uid
    /// State-ключ основного DNS, який публікує helper (service id не має Setup-запису, як і Cisco).
    public static let dnsOverrideService = "com.foxfollow.stonevpnmanager.dns"
    public static var dnsOverrideKey: String { "State:/Network/Service/\(dnsOverrideService)/DNS" }
    /// Оригінальні MatchDomains витіснених записів: [State-ключ DNS: backup]. Поза Service/,
    /// щоб IPMonitor його не розбирав.
    public static let dnsDisplacedKey = "State:/Network/StoneVPNManager/DisplacedDNS"
}

@objc public protocol HelperXPC {
    func run(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func version(withReply reply: @escaping (Int) -> Void)
}
