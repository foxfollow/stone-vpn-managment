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

/// v6+: `PrivRequest` (операція + мова відповіді); старі клієнти шлють голий `PrivOp`.
func decodeRequest(_ data: Data) -> (PrivOp, String?)? {
    if let r = try? JSONDecoder().decode(PrivRequest.self, from: data) { return (r.op, r.lang) }
    if let op = try? JSONDecoder().decode(PrivOp.self, from: data) { return (op, nil) }
    return nil
}

final class Service: NSObject, HelperXPC {
    let caller: uid_t
    init(caller: uid_t) { self.caller = caller }

    func run(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let result: PrivResult
        if let (op, lang) = decodeRequest(request) {
            result = HelperL10n.with(lang) {
                // Підпис каже, *що* підключилося; Access — *хто* (власник / адміни / всі).
                Access.gate(op, caller: caller) ?? Executor.execute(op, waitAuthCleanup: false, caller: caller)
            }
        } else {
            result = .fail(L("unknown request (update the helper)"))
        }
        reply((try? JSONEncoder().encode(result)) ?? Data())
    }

    func version(withReply reply: @escaping (Int) -> Void) { reply(HelperConst.version) }
}

/// Бандл застосунку, в якому лежить цей helper (…/StoneVPNManager.app/Contents/MacOS/StoneVPNManagerHelper).
func enclosingApp() -> URL? {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app.standardizedFileURL : nil
}

/// Designated requirement застосунку-власника. Для ad-hoc підпису це `cdhash H"…"` —
/// його не підробиш, на відміну від `identifier`.
func enclosingAppRequirement() -> String? {
    guard let app = enclosingApp() else { return nil }
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

/// Бандл, з якого запущено процес-клієнт — за audit token з'єднання. Без нього nil (відмова):
/// pid можна перевикористати, тож відкату на нього немає.
func peerBundle(_ c: NSXPCConnection) -> URL? {
    // `auditToken` — приватна властивість NSXPCConnection; без responds(to:) KVC кинув би виняток.
    guard c.responds(to: NSSelectorFromString("auditToken")),
          let v = c.value(forKey: "auditToken") as? NSValue else { return nil }
    var token = audit_token_t()
    v.getValue(&token, size: MemoryLayout<audit_token_t>.size)
    let attrs = [kSecGuestAttributeAudit as String: withUnsafeBytes(of: &token) { Data($0) }]
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess, let code else { return nil }
    var sc: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &sc) == errSecSuccess, let sc else { return nil }
    var url: CFURL?
    guard SecCodeCopyPath(sc, [], &url) == errSecSuccess, let url else { return nil }
    return (url as URL).resolvingSymlinksInPath().standardizedFileURL
}

/// Жорстке посилання на головний бінарник у чужу копію бандла могло б повернути з ядра
/// шлях /Applications для процесу, що вантажить фреймворки з копії.
func appExecutableHasOneLink(_ app: URL) -> Bool {
    guard let exe = Bundle(url: app)?.executableURL else { return false }
    var st = stat()
    return lstat(exe.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink == 1
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Немає вимоги (helper не в бандлі застосунку / бандл без підпису) — нікого не приймаємо.
        guard let requirement = clientRequirement() else { return false }
        // Ad-hoc реліз підписано з disable-library-validation (інакше не вантажиться Sparkle без
        // Team ID). cdhash покриває лише головний бінарник: копія бандла деінде (інший користувач,
        // ~/x/StoneVPNManager.app) з підміненим Sparkle.framework пройшла б вимогу. Тому клієнт
        // мусить бути запущений саме з бандла, в якому лежить цей helper (/Applications — його
        // може змінити лише власник, а той і так керує helper-ом). Team-збірки — з library
        // validation, там підмінений фреймворк не завантажиться (і Debug із DerivedData працює).
        if ownTeamID() == nil {
            guard let app = enclosingApp(), let peer = peerBundle(c), peer.path == app.path,
                  appExecutableHasOneLink(app) else { return false }
        }
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
    if let data, let (op, lang) = decodeRequest(data) {
        result = HelperL10n.with(lang) { Executor.execute(op, waitAuthCleanup: true, caller: caller) }
    } else {
        result = .fail(L("could not read the request"))
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
