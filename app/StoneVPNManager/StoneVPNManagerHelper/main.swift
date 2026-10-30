import Foundation
import Security
import StoneVPNShared

// StoneVPNManagerHelper — два режими:
//   • launchd-демон (SMAppService.daemon): XPC Mach service, приймає лише StoneVPNManager
//     з тим самим Team ID;
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
    func run(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let result: PrivResult
        if let op = try? JSONDecoder().decode(PrivOp.self, from: request) {
            result = Executor.execute(op, waitAuthCleanup: false)
        } else {
            result = .fail("невідомий запит (оновіть helper)")
        }
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }

    func version(withReply reply: @escaping (Int) -> Void) { reply(HelperConst.version) }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    let requirement: String

    override init() {
        if let team = ownTeamID() {
            requirement = "anchor apple generic and identifier \"\(HelperConst.appBundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        } else {
            requirement = "identifier \"\(HelperConst.appBundleID)\""
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.setCodeSigningRequirement(requirement)
        c.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        c.exportedObject = Service()
        c.resume()
        return true
    }
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--run-file" {
    let path = args[2]
    let data = FileManager.default.contents(atPath: path)
    try? FileManager.default.removeItem(atPath: path)
    let result: PrivResult
    if let data, let op = try? JSONDecoder().decode(PrivOp.self, from: data) {
        result = Executor.execute(op, waitAuthCleanup: true)
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
