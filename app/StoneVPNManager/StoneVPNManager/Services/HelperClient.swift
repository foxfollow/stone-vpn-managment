import Foundation
import ServiceManagement
import StoneVPNCore
import StoneVPNShared

/// Доступ до root: XPC до встановленого helper-демона, інакше — одноразовий запуск
/// того ж бінарника через `osascript … with administrator privileges` (пароль щоразу).
final class HelperClient: PrivilegedRunner, PrivilegedReader, @unchecked Sendable {
    let service = SMAppService.daemon(plistName: HelperConst.plistName)
    /// Версія встановленого демона (з останнього `version()`): до v6 він не знає PrivRequest.
    private let lock = NSLock()
    private var daemonVersion: Int?
    /// v7: демон обслуговує лише власника (або адмінів / всіх — HelperAccessPolicy). Не дозволено →
    /// дії йдуть через пароль адміністратора, а фонові (лише через helper) не виконуються.
    private var denied = false

    var status: SMAppService.Status { service.status }
    /// Демон встановлено *і* він обслуговує цього користувача: лише тоді дії без пароля.
    var isEnabled: Bool { service.status == .enabled && !lock.withLock { denied } }

    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(HelperConst.helperExecutable)").path }

    /// Викликається, коли зареєстрований демон не відповідає по XPC (дія тоді питає пароль).
    var onUnreachable: (@Sendable () -> Void)? {
        get { lock.withLock { unreachableHandler } }
        set { lock.withLock { unreachableHandler = newValue } }
    }
    private var unreachableHandler: (@Sendable () -> Void)?

    private static let registeredHashKey = "helperRegisteredHash"
    private static let wantedKey = "helperWanted"

    /// Чи хоче користувач helper: true після встановлення, false після «Remove», nil — ще не вирішив.
    /// Заміна бандла (`make install`, оновлення) скидає реєстрацію в launchd — тоді за цим
    /// прапорцем застосунок реєструє демона знову сам.
    var wanted: Bool? {
        get { UserDefaults.standard.object(forKey: Self.wantedKey) as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: Self.wantedKey) }
    }

    /// Реєстрація launchd належить конкретному бінарнику helper-а: після оновлення чи перезбирання
    /// застосунку новий бінарник не запускається (taskgated: «Disallowing … no eligible provisioning
    /// profiles»), доки демона не перереєструвати, а XPC мовчки падає — і все питає пароль.
    /// Тому пам'ятаємо cdhash бінарника, з яким реєстрували.
    var registeredForThisBuild: Bool {
        guard let current = Self.cdhash(atPath: helperPath) else { return true }  // непідписана збірка — не знаємо
        return UserDefaults.standard.string(forKey: Self.registeredHashKey) == current
    }

    func register() throws {
        try service.register()
        UserDefaults.standard.set(Self.cdhash(atPath: helperPath), forKey: Self.registeredHashKey)
        wanted = true
    }

    /// «Remove» у налаштуваннях: більше не ставити самому.
    func remove() async throws {
        wanted = false
        try await unregister()
    }

    func unregister() async throws {
        try await service.unregister()
        UserDefaults.standard.removeObject(forKey: Self.registeredHashKey)
    }

    /// Перереєструвати демона з бінарником цього бандла (без пароля, якщо його вже схвалено).
    func reinstall() async throws {
        if service.status != .notRegistered { try? await service.unregister() }
        lock.withLock { daemonVersion = nil; denied = false }
        try register()
    }

    static func cdhash(atPath path: String) -> String? {
        var sc: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &sc) == errSecSuccess, let sc else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(sc, [], &info) == errSecSuccess,
              let d = info as? [String: Any], let h = d[kSecCodeInfoUnique as String] as? Data else { return nil }
        return h.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: PrivilegedRunner / Reader

    func run(_ op: PrivOp) async -> PrivResult {
        if isEnabled {
            if let r = await xpc(op) {
                guard r.denied == true else { return r }
                lock.withLock { denied = true }       // не наш демон — пароль адміністратора
            } else {
                onUnreachable?()
            }
        }
        return await viaAppleScript(op)
    }

    func readIfAvailable(_ op: PrivOp) async -> PrivResult? {
        guard isEnabled else { return nil }
        let r = await xpc(op)
        if r == nil { onUnreachable?() }
        if r?.denied == true { lock.withLock { denied = true }; return nil }
        return r
    }

    /// Хто власник демона і чи можна цьому користувачу (v7+). Оновлює `isEnabled`.
    func accessInfo() async -> HelperAccessInfo? {
        guard service.status == .enabled, (lock.withLock { daemonVersion } ?? 0) >= 7 else {
            lock.withLock { denied = false }          // старий демон про доступ не знає
            return nil
        }
        guard let r = await xpc(.accessInfo), r.ok,
              let info = try? JSONDecoder().decode(HelperAccessInfo.self, from: Data(r.output.utf8)) else { return nil }
        lock.withLock { denied = !info.callerAllowed }
        return info
    }

    /// Власник — через демон; інший користувач — з паролем адміністратора.
    func setAccessPolicy(_ p: HelperAccessPolicy) async -> PrivResult {
        guard service.status == .enabled else { return .fail(String(localized: "the helper is not installed")) }
        if let r = await xpc(.accessSetPolicy(policy: p)), r.denied != true { return r }
        return await viaAppleScript(.accessSetPolicy(policy: p))
    }

    /// Стати власником демона: лише з паролем адміністратора (XPC це завжди відхиляє).
    func claimAccess() async -> PrivResult {
        await viaAppleScript(.accessClaim)
    }

    func version() async -> Int? {
        guard service.status == .enabled else { return nil }
        let v: Int? = await withCheckedContinuation { cont in
            let once = Once()
            let c = connection()
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in once.run { cont.resume(returning: nil) } } as? HelperXPC
            guard let proxy else { once.run { cont.resume(returning: nil) }; return }
            proxy.version { v in once.run { cont.resume(returning: v) }; c.invalidate() }
        }
        lock.withLock { daemonVersion = v }
        return v
    }

    /// Запит мовою інтерфейсу: helper (root, мова системи) відповідає нею ж. Демону до v6 —
    /// голий PrivOp, який він розуміє (повідомлення тоді будуть його мовою).
    private func encode(_ op: PrivOp, envelope: Bool) -> Data? {
        guard envelope else { return try? JSONEncoder().encode(op) }
        return try? JSONEncoder().encode(PrivRequest(op: op, lang: Bundle.main.preferredLocalizations.first))
    }

    // MARK: XPC

    private func connection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: HelperConst.label, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
        if let team = Self.ownTeamID() {
            c.setCodeSigningRequirement("anchor apple generic and identifier \"\(HelperConst.label)\" and certificate leaf[subject.OU] = \"\(team)\"")
        }
        c.resume()
        return c
    }

    private func xpc(_ op: PrivOp) async -> PrivResult? {
        let envelope = (lock.withLock { daemonVersion } ?? 0) >= 6
        guard let data = encode(op, envelope: envelope) else { return nil }
        return await withCheckedContinuation { cont in
            let once = Once()
            let c = connection()
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in once.run { cont.resume(returning: nil) } } as? HelperXPC
            guard let proxy else { once.run { cont.resume(returning: nil) }; return }
            proxy.run(data) { reply in
                once.run { cont.resume(returning: try? JSONDecoder().decode(PrivResult.self, from: reply)) }
                c.invalidate()
            }
        }
    }

    // MARK: fallback

    private func viaAppleScript(_ op: PrivOp) async -> PrivResult {
        // Одноразовий запуск — бінарник із цього ж бандла, тож завжди v6+.
        guard let data = encode(op, envelope: true) else { return .fail("encode") }
        // Запит — у файлі 600 (а не в argv), бо там може бути пароль/OTP.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stonevpn-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: file) }
        let cmd = "\(shq(helperPath)) --run-file \(shq(file.path))"
        let prompt = String(localized: "StoneVPN: \(Self.describe(op))", comment: "Administrator password prompt; the argument is the action, e.g. “connect WireGuard”")
        let script = "do shell script \"\(asq(cmd))\" with prompt \"\(asq(prompt))\" with administrator privileges"
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 180)
        if let res = try? JSONDecoder().decode(PrivResult.self, from: Data(r.out.utf8)) { return res }
        if r.err.contains("-128") { return .fail(String(localized: "cancelled")) }
        return .fail(r.err.isEmpty ? String(localized: "the helper did not respond") : r.err)
    }

    static func describe(_ op: PrivOp) -> String {
        switch op {
        case .wgUp: String(localized: "connect WireGuard")
        case .wgDown: String(localized: "disconnect WireGuard")
        case .wgDelete: String(localized: "delete a WireGuard config")
        case .ovpnStart: String(localized: "connect OpenVPN")
        case .ovpnStop: String(localized: "disconnect OpenVPN")
        case .routeHostSet, .routeHostDelete: String(localized: "change the route to a VPN server")
        case .dnsSet, .dnsPurge, .dnsFlush: String(localized: "repair DNS")
        case .resolverSet, .resolverRemove: String(localized: "change split DNS")
        case .dnsOverride, .dnsOverrideClear: String(localized: "switch the primary DNS")
        case .orderServices: String(localized: "change the network service order")
        case .killPid: String(localized: "stop a VPN tunnel process")
        case .accessSetPolicy: String(localized: "change who may use the helper")
        case .accessClaim: String(localized: "take over the helper")
        case .batch(let ops): ops.first.map(describe) ?? String(localized: "action")
        default: String(localized: "privileged action")
        }
    }

    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var sc: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &sc) == errSecSuccess, let sc else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func asq(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}

/// Гарантує один resume continuation (reply і errorHandler можуть прийти обидва).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}
