import Foundation
import ServiceManagement
import StoneVPNCore
import StoneVPNShared

/// Доступ до root: XPC до встановленого helper-демона, інакше — одноразовий запуск
/// того ж бінарника через `osascript … with administrator privileges` (пароль щоразу).
final class HelperClient: PrivilegedRunner, PrivilegedReader, @unchecked Sendable {
    let service = SMAppService.daemon(plistName: HelperConst.plistName)

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
        return await withCheckedContinuation { cont in
            let once = Once()
            let c = connection()
            let proxy = c.remoteObjectProxyWithErrorHandler { _ in once.run { cont.resume(returning: nil) } } as? HelperXPC
            guard let proxy else { once.run { cont.resume(returning: nil) }; return }
            proxy.version { v in once.run { cont.resume(returning: v) }; c.invalidate() }
        }
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
        guard let data = try? JSONEncoder().encode(op) else { return nil }
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
        guard let data = try? JSONEncoder().encode(op) else { return .fail("encode") }
        // Запит — у файлі 600 (а не в argv), бо там може бути пароль/OTP.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stonevpn-\(UUID().uuidString).json")
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: file) }
        let cmd = "\(shq(helperPath)) --run-file \(shq(file.path))"
        let script = "do shell script \"\(asq(cmd))\" with prompt \"StoneVPN: \(asq(Self.describe(op)))\" with administrator privileges"
        let r = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 180)
        if let res = try? JSONDecoder().decode(PrivResult.self, from: Data(r.out.utf8)) { return res }
        if r.err.contains("-128") { return .fail("скасовано") }
        return .fail(r.err.isEmpty ? "helper не відповів" : r.err)
    }

    static func describe(_ op: PrivOp) -> String {
        switch op {
        case .wgUp: "підключити WireGuard"
        case .wgDown: "відключити WireGuard"
        case .ovpnStart: "підключити OpenVPN"
        case .ovpnStop: "відключити OpenVPN"
        case .routeHostSet, .routeHostDelete: "змінити маршрут до VPN-сервера"
        case .dnsSet, .dnsPurge, .dnsFlush: "відремонтувати DNS"
        case .resolverSet, .resolverRemove: "змінити split-DNS"
        case .dnsOverride, .dnsOverrideClear: "перемкнути основний DNS"
        case .orderServices: "змінити порядок мережевих сервісів"
        case .killPid: "зупинити процес VPN-тунелю"
        case .batch(let ops): ops.first.map(describe) ?? "дія"
        default: "привілейована дія"
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
