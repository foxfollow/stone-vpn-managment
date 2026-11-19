import Foundation
import Security
import StoneVPNShared

// StoneVPNManagerHelper — два режими:
//   • launchd-демон (SMAppService.daemon): XPC Mach service, приймає лише StoneVPNManager
//     з тим самим Team ID, а в ad-hoc збірках — саме той бандл, у якому лежить helper;
//   • `--run-file <json>` — одноразове виконання від root через osascript
//     (fallback, поки демон не встановлено/не схвалено).

/// Team ID власного підпису — клієнт мусить бути підписаний тим самим.
func ownTeamID() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

final class Service: NSObject, HelperXPC {
    let caller: uid_t
    init(caller: uid_t) { self.caller = caller }

    func run(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let result: PrivResult
        if let op = try? JSONDecoder().decode(PrivOp.self, from: request) {
            result = Executor.execute(op, waitAuthCleanup: false, caller: caller)
        } else {
            result = .fail("невідомий запит (оновіть helper)")
        }
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }

    func version(withReply reply: @escaping (Int) -> Void) { reply(HelperConst.version) }
}

/// Designated requirement застосунку, в бандлі якого лежить цей helper
/// (…/StoneVPNManager.app/Contents/MacOS/StoneVPNManagerHelper). Для ad-hoc підпису
/// це `cdhash H"…"` — його не підробиш, на відміну від `identifier`.
func enclosingAppRequirement() -> String? {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app" else { return nil }
    var sc: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &sc) == errSecSuccess, let sc else { return nil }
    var req: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(sc, [], &req) == errSecSuccess, let req else { return nil }
    var str: CFString?
    guard SecRequirementCopyString(req, [], &str) == errSecSuccess, let str else { return nil }
    return str as String
}

/// Вимога до клієнта XPC. З Team ID — той самий Team ID + bundle id застосунку.
/// Без нього (ad-hoc релізи з CI) голий `identifier "…"` поставить будь-хто
/// (`codesign -s - -i com.foxfollow.stonevpnmanager`), а helper запускає від root,
/// зокрема openvpn зі script-security 2. Тому — DR застосунку-власника з диска; рахується
/// на кожне з'єднання: після оновлення бандла старий демон приймає вже новий застосунок.
func clientRequirement() -> String? {
    if let team = ownTeamID() {
        return "anchor apple generic and identifier \"\(HelperConst.appBundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
    return enclosingAppRequirement().map { "identifier \"\(HelperConst.appBundleID)\" and (\($0))" }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Немає вимоги (helper не в бандлі застосунку / бандл без підпису) — нікого не приймаємо.
        guard let requirement = clientRequirement() else { return false }
        c.setCodeSigningRequirement(requirement)
        c.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        c.exportedObject = Service(caller: c.effectiveUserIdentifier)
        c.resume()
        return true
    }
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--run-file" {
    let path = args[2]
    // Запит пише застосунок від імені користувача (файл 600) — його власник і є запитувачем.
    var st = stat()
    let caller: uid_t? = lstat(path, &st) == 0 && st.st_uid != 0 ? st.st_uid : nil
    let data = FileManager.default.contents(atPath: path)
    try? FileManager.default.removeItem(atPath: path)
    let result: PrivResult
    if let data, let op = try? JSONDecoder().decode(PrivOp.self, from: data) {
        result = Executor.execute(op, waitAuthCleanup: true, caller: caller)
    } else {
        result = .fail("не прочитав запит")
    }
    FileHandle.standardOutput.write((try? JSONEncoder().encode(result)) ?? Data())
    // Завжди 0: інакше `do shell script` кидає помилку і JSON-результат губиться.
    exit(0)
}

let delegate = Delegate()
let listener = NSXPCListener(machServiceName: HelperConst.label)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
