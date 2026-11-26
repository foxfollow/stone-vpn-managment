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

    var status: SMAppService.Status { service.status }
    var isEnabled: Bool { service.status == .enabled }

    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(HelperConst.helperExecutable)").path }

    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }

    // MARK: PrivilegedRunner / Reader

    func run(_ op: PrivOp) async -> PrivResult {
        if isEnabled, let r = await xpc(op) { return r }
        return await viaAppleScript(op)
    }

    func readIfAvailable(_ op: PrivOp) async -> PrivResult? {
        guard isEnabled else { return nil }
        return await xpc(op)
    }

    func version() async -> Int? {
        guard isEnabled else { return nil }
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
