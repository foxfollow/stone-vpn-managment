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
    /// Основний DNS: власний Supplemental-резолвер для всіх доменів із SearchOrder 0 —
    /// випереджає Cisco/Defguard (вони ставлять 1). Clear прибирає запис.
    case dnsOverride(servers: [String])
    case dnsOverrideClear
    // Мережа / процеси
    case orderServices(names: [String])
    case killPid(pid: Int32)
    /// Кілька дій за один виклик (у fallback-режимі — один запит пароля).
    case batch([PrivOp])
}

public struct PrivResult: Codable, Sendable {
    public var ok: Bool
    public var output: String

    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }

    public static func fail(_ msg: String) -> PrivResult { PrivResult(ok: false, output: msg) }
}

public enum HelperConst {
    public static let label = "com.foxfollow.stonevpnmanager.helper"
    public static let plistName = "com.foxfollow.stonevpnmanager.helper.plist"
    public static let appBundleID = "com.foxfollow.stonevpnmanager"
    public static let helperExecutable = "StoneVPNManagerHelper"
    /// Підняти при зміні PrivOp — застосунок запропонує перевстановити helper.
    public static let version = 2
    /// State-ключ основного DNS, який публікує helper (service id не має Setup-запису, як і Cisco).
    public static let dnsOverrideService = "com.foxfollow.stonevpnmanager.dns"
    public static var dnsOverrideKey: String { "State:/Network/Service/\(dnsOverrideService)/DNS" }
}

@objc public protocol HelperXPC {
    func run(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func version(withReply reply: @escaping (Int) -> Void)
}
