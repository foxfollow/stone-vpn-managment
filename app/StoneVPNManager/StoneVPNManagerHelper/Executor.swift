import Foundation
import StoneVPNShared
import SystemConfiguration

/// Виконує PrivOp від root. Кожен аргумент перевіряється тут, а не в застосунку:
/// helper довіряє лише підпису клієнта, не його даним.
enum Executor {
    static let env: [String: String] = [
        "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
    ]
    static let wgDirs = WGPaths.dirs
    static let wgRun = "/var/run/wireguard"

    /// `waitAuthCleanup`: у CLI-режимі (одноразовий запуск через osascript) процес
    /// не живе далі, тож тимчасовий auth-файл прибираємо синхронно.
    /// `caller` — uid того, хто надіслав запит (XPC peer / власник файлу запиту); nil = невідомо.
    static func execute(_ op: PrivOp, waitAuthCleanup: Bool, caller: uid_t?) -> PrivResult {
        switch op {
        case .ping:
            return PrivResult(ok: true, output: "pong \(HelperConst.version)")

        case .batch(let ops):
            var out: [String] = []
            var ok = true
            for o in ops {
                let r = execute(o, waitAuthCleanup: waitAuthCleanup, caller: caller)
                if !r.ok { ok = false }
                if !r.output.isEmpty { out.append(r.output) }
            }
            return PrivResult(ok: ok, output: out.joined(separator: "\n"))

        // ── WireGuard ────────────────────────────────────────────────────────
        case .wgUp(let path):
            let c: WGConfHandle
            switch WGConfGuard.open(path, caller: caller) { case .success(let h): c = h; case .failure(let e): return .fail(L(e.text)) }
            guard let wq = firstExecutable(["/opt/homebrew/bin/wg-quick", "/usr/local/bin/wg-quick"]) else {
                return .fail(L("wg-quick not found (brew install wireguard-tools)"))
            }
            return run(wq, ["up", c.path])
        case .wgDown(let path):
            let c: WGConfHandle
            switch WGConfGuard.open(path, caller: caller) { case .success(let h): c = h; case .failure(let e): return .fail(L(e.text)) }
            guard let wq = firstExecutable(["/opt/homebrew/bin/wg-quick", "/usr/local/bin/wg-quick"]) else {
                return .fail(L("wg-quick not found"))
            }
            return run(wq, ["down", c.path])
        case .wgDelete(let path):
            let c: WGConfHandle
            switch WGConfGuard.open(path, caller: caller) { case .success(let h): c = h; case .failure(let e): return .fail(L(e.text)) }
            if FileManager.default.fileExists(atPath: "\(wgRun)/\(c.name).name") { return .fail(L("\(c.name) is connected — disconnect it first")) }
            if case .failure(let e) = c.delete() { return .fail(L("not deleted: \(L(e.text))")) }
            return PrivResult(ok: true, output: L("deleted \(c.path)"))
        case .wgRuntime:
            let fm = FileManager.default
            let names = ((try? fm.contentsOfDirectory(atPath: wgRun)) ?? []).filter { $0.hasSuffix(".name") }.sorted()
            let lines = names.compactMap { f -> String? in
                guard let c = try? String(contentsOfFile: "\(wgRun)/\(f)", encoding: .utf8) else { return nil }
                return "\(f.dropLast(5)) \(c.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return PrivResult(ok: true, output: lines.joined(separator: "\n"))
        case .wgConfigs:
            let fm = FileManager.default
            func confs(_ d: String) -> [String] {
                ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".conf") }.map { String($0.dropLast(5)) }.sorted()
            }
            // Та сама логіка, що wg_config_dir: тека з *.conf, інакше перша наявна.
            // Тека, що веде за межі стандартних і не належить запитувачу, не переглядається.
            let dirs = wgDirs.filter { WGConfGuard.dirListable($0, caller: caller) }
            var dir = dirs.first { !confs($0).isEmpty }
            if dir == nil { dir = dirs.first { fm.fileExists(atPath: $0) } }
            guard let d = dir else { return PrivResult(ok: true, output: "") }
            return PrivResult(ok: true, output: ([d] + confs(d)).joined(separator: "\n"))
        case .readWGConf(let path):
            let c: String
            switch WGConfGuard.open(path, caller: caller).flatMap({ $0.read() }) {
            case .success(let s): c = s
            case .failure(let e): return .fail(L("cannot read: \(L(e.text))"))
            }
            let safe = c.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let k = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !(k.hasPrefix("privatekey") || k.hasPrefix("presharedkey"))
            }
            return PrivResult(ok: true, output: safe.joined(separator: "\n"))

        // ── OpenVPN ──────────────────────────────────────────────────────────
        case .ovpnStart(let profilePath, let user, let pass, let addDev):
            return ovpnStart(profilePath, user: user, pass: pass, addDev: addDev, waitAuthCleanup: waitAuthCleanup, caller: caller)
        case .ovpnStop(let pid):
            guard pid > 1 else { return .fail(L("PID \(String(pid)) is not openvpn")) }
            // Процес уже зник (впав / зупинений з CLI) — лишається тільки прибрати pid-файл.
            if processAlive(pid) {
                guard processComm(pid).hasSuffix("openvpn") else { return .fail(L("PID \(String(pid)) is not openvpn")) }
                kill(pid, SIGTERM)
                for _ in 0..<10 where processAlive(pid) { sleep(1) }
                // ps -p, не kill -0: для root тут різниці нема, але тримаємо одну ідіому.
                if processAlive(pid) { kill(pid, SIGKILL) }
            }
            for f in (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [] where f.hasPrefix("openvpn") && f.hasSuffix(".pid") {
                let pf = "/tmp/\(f)"
                if (try? String(contentsOfFile: pf, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == String(pid) {
                    try? FileManager.default.removeItem(atPath: pf)
                    try? FileManager.default.removeItem(atPath: String(pf.dropLast(4)) + ".log")
                }
            }
            return PrivResult(ok: true, output: L("OpenVPN PID \(String(pid)) stopped"))
        case .readLog(let path):
            guard isOvpnLogPath(path), let c = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .fail(L("log unavailable: \(path)"))
            }
            return PrivResult(ok: true, output: c)

        // ── Маршрути ─────────────────────────────────────────────────────────
        case .routeHostSet(let ip, let gw):
            guard isIP(ip), isIP(gw) else { return .fail(L("invalid address: \(ip) / \(gw)")) }
            _ = run("/sbin/route", ["-q", "-n", "delete", "-host", ip])
            return run("/sbin/route", ["-q", "-n", "add", "-host", ip, gw])
        case .routeHostDelete(let ip):
            guard isIP(ip) else { return .fail(L("invalid address: \(ip)")) }
            return run("/sbin/route", ["-q", "-n", "delete", "-host", ip])

        // ── DNS ──────────────────────────────────────────────────────────────
        case .dnsSet(let svc, let servers):
            guard networkServices().contains(svc) else { return .fail(L("no such service: \(svc)")) }
            guard servers.allSatisfy(isIP) else { return .fail(L("invalid DNS: \(servers.joined(separator: " "))")) }
            // Дві реальні зміни: на однакове значення SystemConfiguration не реагує.
            let r1 = run("/usr/sbin/networksetup", ["-setdnsservers", svc, "empty"])
            if servers.isEmpty || !r1.ok { return r1 }
            return run("/usr/sbin/networksetup", ["-setdnsservers", svc] + servers)
        case .dnsPurge(let uuids):
            var out: [String] = []
            var ok = true
            for u in uuids {
                guard u.range(of: #"^[0-9A-Za-z.-]+$"#, options: .regularExpression) != nil else { ok = false; continue }
                // scutil завжди виходить з 0 — помилка лише у виводі.
                let r = run("/usr/sbin/scutil", [], stdin: "open\nremove State:/Network/Service/\(u)/DNS\nquit\n")
                if r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(L("removed resolver \(u)"))
                } else {
                    ok = false
                    out.append(L("not removed \(u): \(r.output)"))
                }
            }
            return PrivResult(ok: ok, output: out.joined(separator: "\n"))
        case .dnsFlush:
            _ = run("/usr/bin/dscacheutil", ["-flushcache"])
            _ = run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            return PrivResult(ok: true, output: "")
        case .resolverSet(let domain, let servers):
            guard isDomain(domain), !servers.isEmpty, servers.allSatisfy(isIP) else { return .fail(L("invalid domain or server")) }
            try? FileManager.default.createDirectory(atPath: "/etc/resolver", withIntermediateDirectories: true)
            let body = servers.map { "nameserver \($0)\n" }.joined()
            do { try body.write(toFile: "/etc/resolver/\(domain)", atomically: true, encoding: .utf8) } catch {
                return .fail(L("writing /etc/resolver/\(domain): \(error.localizedDescription)"))
            }
            _ = execute(.dnsFlush, waitAuthCleanup: false, caller: caller)
            return PrivResult(ok: true, output: "*.\(domain) → \(servers.joined(separator: " "))")
        case .dnsOverride(let servers):
            guard !servers.isEmpty, servers.allSatisfy(isIP) else { return .fail(L("invalid DNS: \(servers.joined(separator: " "))")) }
            guard let store = SCDynamicStoreCreate(nil, "StoneVPNHelper" as CFString, nil, nil) else { return .fail(L("SCDynamicStore unavailable")) }
            let dict: [String: Any] = ["ServerAddresses": servers, "SupplementalMatchDomains": [""], "SearchOrder": 0]
            // SetValue (не Temporary): запис живе й після виходу одноразового процесу (osascript-режим).
            guard SCDynamicStoreSetValue(store, HelperConst.dnsOverrideKey as CFString, dict as CFDictionary) else {
                return .fail(L("could not write the primary DNS"))
            }
            let moved = displaceCatchAll(store)
            _ = execute(.dnsFlush, waitAuthCleanup: false, caller: caller)
            let set = L("primary DNS → \(servers.joined(separator: " "))")
            return PrivResult(ok: true, output: moved.isEmpty ? set : set + "; " + L("displaced catch-all: \(moved.joined(separator: ", "))"))
        case .dnsOverrideClear:
            if let store = SCDynamicStoreCreate(nil, "StoneVPNHelper" as CFString, nil, nil) {
                SCDynamicStoreRemoveValue(store, HelperConst.dnsOverrideKey as CFString)
                restoreCatchAll(store)
            }
            _ = execute(.dnsFlush, waitAuthCleanup: false, caller: caller)
            return PrivResult(ok: true, output: L("primary DNS — chosen by the system"))
        case .resolverRemove(let domain):
            guard isDomain(domain) else { return .fail(L("invalid domain")) }
            do { try FileManager.default.removeItem(atPath: "/etc/resolver/\(domain)") } catch {
                return .fail(L("no rule for \(domain)"))
            }
            _ = execute(.dnsFlush, waitAuthCleanup: false, caller: caller)
            return PrivResult(ok: true, output: L("removed \(domain)"))

        // ── Доступ (v7) — XPC сюди доходить лише після Access.gate ─────────────
        case .accessInfo:
            let data = (try? JSONEncoder().encode(Access.info(caller))) ?? Data()
            return PrivResult(ok: true, output: String(decoding: data, as: UTF8.self))
        case .accessSetPolicy(let p):
            return Access.setPolicy(p, caller: caller)
        case .accessClaim:
            return Access.claim(caller: caller)

        // ── Мережа / процеси ────────────────────────────────────────────────
        case .orderServices(let names):
            // networksetup приймає лише ПОВНИЙ список (інакше «parameters were not valid»).
            let all = networkServices()
            guard Set(names) == Set(all), names.count == all.count else { return .fail(L("the full list of services is required")) }
            return run("/usr/sbin/networksetup", ["-ordernetworkservices"] + names)
        case .killPid(let pid):
            let cmd = processCommand(pid)
            let isTunnel = cmd.range(of: #"SystemExtensions/.*(vpn|wireguard|tunnel|anyconnect)|vpnagentd"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil
            guard pid > 1, isTunnel, !cmd.lowercased().contains("security-monitor") else {
                return .fail(L("PID \(String(pid)) is not a VPN tunnel process"))
            }
            kill(pid, SIGTERM)
            sleep(2)
            if processAlive(pid) { kill(pid, SIGKILL) }
            return PrivResult(ok: true, output: L("PID \(String(pid)) stopped"))
        }
    }

    /// /var/run/stonevpn (root 0700) — копії профілів, які читає openvpn (там ключі: лише root).
    static func writeRootCopy(_ data: Data, name: String) -> String? {
        let dir = "/var/run/stonevpn"
        var st = stat()
        if lstat(dir, &st) != 0 { guard mkdir(dir, 0o700) == 0 else { return nil } }
        else if (st.st_mode & S_IFMT) != S_IFDIR || st.st_uid != 0 { return nil }
        chmod(dir, 0o700)
        let path = "\(dir)/\(name)"
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
        return ok ? path : nil
    }

    // ── OpenVPN start (дзеркало vpn-up.sh) ──────────────────────────────────
    static func ovpnStart(_ profilePath: String, user: String?, pass: String?, addDev: Bool, waitAuthCleanup: Bool, caller: uid_t?) -> PrivResult {
        let url = URL(fileURLWithPath: profilePath).standardizedFileURL
        let path = url.path
        guard path.hasSuffix(".ovpn"), !isSymlink(path), FileManager.default.isReadableFile(atPath: path) else {
            return .fail(L("profile unavailable: \(profilePath)"))
        }
        let id = url.deletingPathExtension().lastPathComponent
        guard id.range(of: #"^[A-Za-z0-9._ -]+$"#, options: .regularExpression) != nil else { return .fail(L("invalid profile name")) }
        // Лише власний профіль запитувача: скрипти профілю (up/down…, script-security 2) виконуються
        // від root — прийнятно для власних файлів (як PostUp у WireGuard), але не для чужих (інакше
        // будь-хто підключився б чужим профілем). Читаємо через дескриптор (O_NOFOLLOW + fstat) і
        // віддаємо openvpn root-копію: шлях не підмінити симлінком між перевіркою і запуском.
        // `--cd` — тека оригіналу, щоб відносні ca/cert/key знаходились як раніше.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .fail(L("profile unavailable: \(profilePath)")) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              caller == nil || caller == 0 || st.st_uid == caller else {
            close(fd)
            return .fail(L("the profile must belong to you: \(profilePath)"))
        }
        let content = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
        guard let config = writeRootCopy(content, name: "\(id).ovpn") else { return .fail(L("profile unavailable: \(profilePath)")) }
        guard let ovpn = firstExecutable(["/opt/homebrew/sbin/openvpn", "/usr/local/sbin/openvpn"]) else {
            return .fail(L("openvpn not found (brew install openvpn)"))
        }
        let pidFile = "/tmp/openvpn-\(id).pid", logFile = "/tmp/openvpn-\(id).log"
        try? FileManager.default.removeItem(atPath: pidFile)
        try? FileManager.default.removeItem(atPath: logFile)

        var args = ["--cd", url.deletingLastPathComponent().path, "--config", config]
        if addDev { args += ["--dev", "tun"] }
        var authFile: String?
        if let user, !user.isEmpty {
            let f = "/tmp/ovpn-auth.\(UUID().uuidString.prefix(8))"
            FileManager.default.createFile(atPath: f, contents: Data("\(user)\n\(pass ?? "")\n".utf8),
                                           attributes: [.posixPermissions: 0o600])
            authFile = f
            args += ["--auth-user-pass", f]
        }
        args += ["--daemon", "--writepid", pidFile, "--log", logFile, "--script-security", "2", "--connect-retry-max", "1"]
        let r = run(ovpn, args)
        if !r.ok {
            if let authFile { try? FileManager.default.removeItem(atPath: authFile) }
            let log = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
            return .fail(L("openvpn did not start: \(r.output)") + "\n" + log)
        }
        // Лог читабельний для staff — щоб статус бачив стан без root. Секретів у ньому немає.
        chown(logFile, 0, 20)
        chmod(logFile, 0o640)

        if let authFile {
            let cleanup = {
                for _ in 0..<60 {
                    sleep(1)
                    let log = (try? String(contentsOfFile: logFile, encoding: .utf8)) ?? ""
                    if log.contains("Initialization Sequence Completed") || log.contains("AUTH_FAILED") || log.contains("Exiting") { break }
                }
                try? FileManager.default.removeItem(atPath: authFile)
            }
            if waitAuthCleanup { cleanup() } else { DispatchQueue.global().async(execute: cleanup) }
        }
        return PrivResult(ok: true, output: logFile)
    }

    // ── Валідація ───────────────────────────────────────────────────────────
    static func isOvpnLogPath(_ p: String) -> Bool {
        p.range(of: #"^/tmp/openvpn(-[A-Za-z0-9._ -]+)?\.log$"#, options: .regularExpression) != nil && !p.contains("..")
    }

    static func isIP(_ s: String) -> Bool {
        var a4 = in_addr(), a6 = in6_addr()
        return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
    }

    static func isDomain(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil && !s.contains("..")
    }

    static func isSymlink(_ p: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil
    }

    /// Прибрати "" з усіх чужих catch-all DNS-записів (State:/Network/Service/*/DNS), запам'ятавши
    /// оригінали. Повторний виклик не перезаписує вже збережений оригінал.
    static func displaceCatchAll(_ store: SCDynamicStore) -> [String] {
        let backupKey = HelperConst.dnsDisplacedKey as CFString
        var backup = SCDynamicStoreCopyValue(store, backupKey) as? [String: [String: Any]] ?? [:]
        var moved: [String] = []
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/DNS" as CFString) as? [String] ?? []
        for key in keys where key != HelperConst.dnsOverrideKey {
            guard let dns = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let without = CatchAllDNS.displaced(dns) else { continue }
            if backup[key] == nil { backup[key] = CatchAllDNS.backup(dns) }
            if SCDynamicStoreSetValue(store, key as CFString, without as CFDictionary) { moved.append(key) }
        }
        if !backup.isEmpty { SCDynamicStoreSetValue(store, backupKey, backup as CFDictionary) }
        return moved
    }

    /// Повернути "" витісненим записам. Тунель, якого вже немає (State IPv4 зник), — запис
    /// прибирається зовсім, щоб не лишити осиротілий DNS.
    static func restoreCatchAll(_ store: SCDynamicStore) {
        let backupKey = HelperConst.dnsDisplacedKey as CFString
        let backup = SCDynamicStoreCopyValue(store, backupKey) as? [String: [String: Any]] ?? [:]
        for (key, orig) in backup {
            guard let cur = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { continue }
            let ipv4 = key.replacingOccurrences(of: "/DNS", with: "/IPv4")
            let ipv6 = key.replacingOccurrences(of: "/DNS", with: "/IPv6")
            if SCDynamicStoreCopyValue(store, ipv4 as CFString) == nil, SCDynamicStoreCopyValue(store, ipv6 as CFString) == nil {
                SCDynamicStoreRemoveValue(store, key as CFString)
            } else if let r = CatchAllDNS.restored(current: cur, backup: orig) {
                SCDynamicStoreSetValue(store, key as CFString, r as CFDictionary)
            }
        }
        SCDynamicStoreRemoveValue(store, backupKey)
    }

    static func networkServices() -> [String] {
        run("/usr/sbin/networksetup", ["-listallnetworkservices"]).output
            .split(separator: "\n").dropFirst()
            .map { $0.hasPrefix("*") ? String($0.dropFirst()) : String($0) }
    }

    static func firstExecutable(_ c: [String]) -> String? { c.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func processAlive(_ pid: Int32) -> Bool { run("/bin/ps", ["-p", String(pid)]).ok }
    static func processComm(_ pid: Int32) -> String {
        run("/bin/ps", ["-p", String(pid), "-o", "comm="]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func processCommand(_ pid: Int32) -> String {
        run("/bin/ps", ["-p", String(pid), "-ww", "-o", "command="]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], stdin: String? = nil) -> PrivResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return .fail("\(exe): \(error.localizedDescription)") }
        if let stdin {
            signal(SIGPIPE, SIG_IGN)
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return PrivResult(ok: p.terminationStatus == 0, output: s)
    }
}
