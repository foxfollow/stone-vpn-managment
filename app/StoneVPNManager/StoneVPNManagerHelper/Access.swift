import Foundation
import StoneVPNShared

/// Хто з користувачів Mac може користуватися демоном (протокол v7).
///
/// Підпис клієнта (cdhash / Team ID, шлях бандла) доводить лише, що підключився справжній
/// StoneVPN, а не *хто* його запустив: будь-який локальний користувач запускає той самий
/// /Applications/StoneVPNManager.app, імпортує .ovpn з `up /Users/<він>/x.sh` — і openvpn
/// (root, script-security 2) виконує його скрипт від root. Тому демон обслуговує лише власника
/// (і, якщо власник дозволив, адмінів або всіх).
///
/// Власник — uid, записаний у root-файлі `HelperAccessStore.file`. Перший запис — автоматично:
/// з'єднання від користувача, якому належить бандл (його ставлять brew cask або перетягування
/// в Applications від імені користувача). Бандл root-а (pkg / sudo) так нікого не призначає —
/// тоді лише `accessClaim` з паролем адміністратора. Шлях `--run-file` (osascript з паролем
/// адміністратора) не обмежується: той, хто знає пароль, і так може все.
enum Access {
    struct Stored: Codable, Equatable {
        var ownerUID: UInt32?
        var policy: HelperAccessPolicy = .owner
    }

    private static let lock = NSLock()

    /// Файл чужого власника / симлінк / не звичайний файл — ігнорується (нікого не обслуговуємо).
    static func load() -> Stored {
        let path = HelperAccessStore.file
        var st = stat()
        guard lstat(HelperAccessStore.dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == 0,
              lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == 0, st.st_mode & 0o022 == 0,
              let data = FileManager.default.contents(atPath: path),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return s
    }

    @discardableResult
    static func save(_ s: Stored) -> Bool {
        let fm = FileManager.default
        let dir = HelperAccessStore.dir
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])) != nil
            else { return false }
        } else if (st.st_mode & S_IFMT) != S_IFDIR || st.st_uid != 0 {
            return false                    // хтось підсунув теку/симлінк — не пишемо крізь нього
        }
        guard let data = try? JSONEncoder().encode(s) else { return false }
        let tmp = dir + "/.helper-access.\(getpid()).tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
        fchown(fd, 0, 0); fchmod(fd, 0o644)
        close(fd)
        guard ok, rename(tmp, HelperAccessStore.file) == 0 else { unlink(tmp); return false }
        return true
    }

    static func isAdmin(_ uid: uid_t) -> Bool {
        guard let pw = getpwuid(uid) else { return false }
        var n: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(n))
        while getgrouplist(pw.pointee.pw_name, Int32(pw.pointee.pw_gid), &groups, &n) == -1 {
            n *= 2; groups = [Int32](repeating: 0, count: Int(n))
            if n > 4096 { return false }
        }
        return groups.prefix(Int(n)).contains(80)     // admin
    }

    static func userName(_ uid: UInt32?) -> String? {
        guard let uid, let pw = getpwuid(uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    static func allows(_ uid: uid_t?, _ s: Stored) -> Bool {
        s.policy.permits(uid, owner: s.ownerUID, isAdmin: isAdmin)
    }

    /// Власника ще немає, а запитувач — власник бандла застосунку: записати його.
    static func current(claimingFor caller: uid_t?) -> Stored {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        guard s.ownerUID == nil, let caller, caller != 0, let app = enclosingApp() else { return s }
        var st = stat()
        guard lstat(app.path, &st) == 0, st.st_uid == caller else { return s }
        s.ownerUID = caller
        return save(s) ? s : load()
    }

    static func info(_ caller: uid_t?) -> HelperAccessInfo {
        let s = current(claimingFor: caller)
        return HelperAccessInfo(ownerUID: s.ownerUID, ownerName: userName(s.ownerUID), policy: s.policy,
                                callerUID: caller, callerAllowed: allows(caller, s))
    }

    /// Перевірка XPC-запиту до виконання. nil = можна.
    static func gate(_ op: PrivOp, caller: uid_t?) -> PrivResult? {
        switch op {
        case .ping, .accessInfo:
            return nil
        case .accessClaim:
            return .deny(L("Taking over the helper needs the administrator password"))
        case .accessSetPolicy:
            let s = current(claimingFor: caller)
            return s.ownerUID != nil && s.ownerUID == caller ? nil
                : .deny(L("Only the helper's owner can change who may use it"))
        case .batch(let ops):
            for o in ops { if let r = gate(o, caller: caller) { return r } }
            return nil
        default:
            let s = current(claimingFor: caller)
            if allows(caller, s) { return nil }
            if let name = userName(s.ownerUID) {
                return .deny(L("The helper belongs to \(name) — this action needs the administrator password"))
            }
            return .deny(L("The helper has no owner yet — this action needs the administrator password"))
        }
    }

    /// accessSetPolicy / accessClaim після gate (XPC) або з паролем адміністратора (--run-file).
    static func setPolicy(_ p: HelperAccessPolicy, caller: uid_t?) -> PrivResult {
        lock.lock(); defer { lock.unlock() }
        var s = load()
        if s.ownerUID == nil, let caller, caller != 0 { s.ownerUID = caller }
        s.policy = p
        return save(s) ? PrivResult(ok: true, output: "") : .fail(L("could not save the helper access settings"))
    }

    static func claim(caller: uid_t?) -> PrivResult {
        guard let caller, caller != 0 else { return .fail(L("unknown user")) }
        lock.lock(); defer { lock.unlock() }
        var s = load()
        s.ownerUID = caller
        return save(s) ? PrivResult(ok: true, output: "") : .fail(L("could not save the helper access settings"))
    }
}
