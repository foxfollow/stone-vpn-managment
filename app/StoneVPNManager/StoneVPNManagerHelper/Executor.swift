import Foundation
import StoneVPNShared

/// Виконує PrivOp від root. Кожен аргумент перевіряється тут, а не в застосунку:
/// helper довіряє лише підпису клієнта, не його даним.
enum Executor {
    static let env: [String: String] = [
        "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
    ]
    static let wgDirs = ["/opt/homebrew/etc/wireguard", "/usr/local/etc/wireguard", "/etc/wireguard"]
    static let wgRun = "/var/run/wireguard"

    /// `waitAuthCleanup`: у CLI-режимі (одноразовий запуск через osascript) процес
    /// не живе далі, тож тимчасовий auth-файл прибираємо синхронно.
    static func execute(_ op: PrivOp, waitAuthCleanup: Bool) -> PrivResult {
        switch op {
        case .ping:
            return PrivResult(ok: true, output: "pong \(HelperConst.version)")

        case .batch(let ops):
            var out: [String] = []
            var ok = true
            for o in ops {
                let r = execute(o, waitAuthCleanup: waitAuthCleanup)
                if !r.ok { ok = false }
                if !r.output.isEmpty { out.append(r.output) }
            }
            return PrivResult(ok: ok, output: out.joined(separator: "\n"))

        // ── WireGuard ────────────────────────────────────────────────────────
        case .wgUp(let path):
            guard let p = validWGConf(path) else { return .fail("недопустимий шлях конфігу: \(path)") }
            guard let wq = firstExecutable(["/opt/homebrew/bin/wg-quick", "/usr/local/bin/wg-quick"]) else {
                return .fail("wg-quick не знайдено (brew install wireguard-tools)")
            }
            return run(wq, ["up", p])
        case .wgDown(let path):
            guard let p = validWGConf(path) else { return .fail("недопустимий шлях конфігу: \(path)") }
            guard let wq = firstExecutable(["/opt/homebrew/bin/wg-quick", "/usr/local/bin/wg-quick"]) else {
                return .fail("wg-quick не знайдено")
            }
            return run(wq, ["down", p])
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
            var dir = wgDirs.first { !confs($0).isEmpty }
            if dir == nil { dir = wgDirs.first { fm.fileExists(atPath: $0) } }
            guard let d = dir else { return PrivResult(ok: true, output: "") }
            return PrivResult(ok: true, output: ([d] + confs(d)).joined(separator: "\n"))
        case .readWGConf(let path):
            guard let p = validWGConf(path), let c = try? String(contentsOfFile: p, encoding: .utf8) else {
                return .fail("не читається: \(path)")
            }
            let safe = c.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
                let k = line.trimmingCharacters(in: .whitespaces).lowercased()
                return !(k.hasPrefix("privatekey") || k.hasPrefix("presharedkey"))
            }
            return PrivResult(ok: true, output: safe.joined(separator: "\n"))

        // ── OpenVPN ──────────────────────────────────────────────────────────
        case .ovpnStart(let profilePath, let user, let pass, let addDev):
            return ovpnStart(profilePath, user: user, pass: pass, addDev: addDev, waitAuthCleanup: waitAuthCleanup)
        case .ovpnStop(let pid):
            guard pid > 1, processComm(pid).hasSuffix("openvpn") else { return .fail("PID \(pid) — не openvpn") }
            kill(pid, SIGTERM)
            for _ in 0..<10 where processAlive(pid) { sleep(1) }
            // ps -p, не kill -0: для root тут різниці нема, але тримаємо одну ідіому.
            if processAlive(pid) { kill(pid, SIGKILL) }
            for f in (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [] where f.hasPrefix("openvpn") && f.hasSuffix(".pid") {
                let pf = "/tmp/\(f)"
                if (try? String(contentsOfFile: pf, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == String(pid) {
                    try? FileManager.default.removeItem(atPath: pf)
                    try? FileManager.default.removeItem(atPath: String(pf.dropLast(4)) + ".log")
                }
            }
            return PrivResult(ok: true, output: "OpenVPN PID \(pid) зупинено")
        case .readLog(let path):
            guard isOvpnLogPath(path), let c = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .fail("лог недоступний: \(path)")
            }
            return PrivResult(ok: true, output: c)

        // ── Маршрути ─────────────────────────────────────────────────────────
        case .routeHostSet(let ip, let gw):
            guard isIP(ip), isIP(gw) else { return .fail("невірна адреса: \(ip) / \(gw)") }
            _ = run("/sbin/route", ["-q", "-n", "delete", "-host", ip])
            return run("/sbin/route", ["-q", "-n", "add", "-host", ip, gw])
        case .routeHostDelete(let ip):
            guard isIP(ip) else { return .fail("невірна адреса: \(ip)") }
            return run("/sbin/route", ["-q", "-n", "delete", "-host", ip])

        // ── DNS ──────────────────────────────────────────────────────────────
        case .dnsSet(let svc, let servers):
            guard networkServices().contains(svc) else { return .fail("немає сервісу: \(svc)") }
            guard servers.allSatisfy(isIP) else { return .fail("невірний DNS: \(servers.joined(separator: " "))") }
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
                    out.append("прибрано резолвер \(u)")
                } else {
                    ok = false
                    out.append("не прибрано \(u): \(r.output)")
                }
            }
            return PrivResult(ok: ok, output: out.joined(separator: "\n"))
        case .dnsFlush:
            _ = run("/usr/bin/dscacheutil", ["-flushcache"])
            _ = run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            return PrivResult(ok: true, output: "")
        case .resolverSet(let domain, let servers):
            guard isDomain(domain), !servers.isEmpty, servers.allSatisfy(isIP) else { return .fail("невірний домен або сервер") }
            try? FileManager.default.createDirectory(atPath: "/etc/resolver", withIntermediateDirectories: true)
            let body = servers.map { "nameserver \($0)\n" }.joined()
            do { try body.write(toFile: "/etc/resolver/\(domain)", atomically: true, encoding: .utf8) } catch {
                return .fail("запис /etc/resolver/\(domain): \(error.localizedDescription)")
            }
            _ = execute(.dnsFlush, waitAuthCleanup: false)
            return PrivResult(ok: true, output: "*.\(domain) → \(servers.joined(separator: " "))")
        case .resolverRemove(let domain):
            guard isDomain(domain) else { return .fail("невірний домен") }
            do { try FileManager.default.removeItem(atPath: "/etc/resolver/\(domain)") } catch {
                return .fail("немає правила для \(domain)")
            }
            _ = execute(.dnsFlush, waitAuthCleanup: false)
            return PrivResult(ok: true, output: "прибрано \(domain)")

        // ── Мережа / процеси ────────────────────────────────────────────────
        case .orderServices(let names):
            // networksetup приймає лише ПОВНИЙ список (інакше «parameters were not valid»).
            let all = networkServices()
            guard Set(names) == Set(all), names.count == all.count else { return .fail("потрібен повний список сервісів") }
            return run("/usr/sbin/networksetup", ["-ordernetworkservices"] + names)
        case .killPid(let pid):
            let cmd = processCommand(pid)
            let isTunnel = cmd.range(of: #"SystemExtensions/.*(vpn|wireguard|tunnel|anyconnect)|vpnagentd"#,
                                     options: [.regularExpression, .caseInsensitive]) != nil
            guard pid > 1, isTunnel, !cmd.lowercased().contains("security-monitor") else {
                return .fail("PID \(pid) — не процес VPN-тунелю")
            }
            kill(pid, SIGTERM)
            sleep(2)
            if processAlive(pid) { kill(pid, SIGKILL) }
            return PrivResult(ok: true, output: "PID \(pid) зупинено")
        }
    }

    // ── OpenVPN start (дзеркало vpn-up.sh) ──────────────────────────────────
    static func ovpnStart(_ profilePath: String, user: String?, pass: String?, addDev: Bool, waitAuthCleanup: Bool) -> PrivResult {
        let url = URL(fileURLWithPath: profilePath).standardizedFileURL
        let path = url.path
        guard path.hasSuffix(".ovpn"), !isSymlink(path), FileManager.default.isReadableFile(atPath: path) else {
            return .fail("профіль недоступний: \(profilePath)")
        }
        let id = url.deletingPathExtension().lastPathComponent
        guard id.range(of: #"^[A-Za-z0-9._ -]+$"#, options: .regularExpression) != nil else { return .fail("недопустима назва профілю") }
        guard let ovpn = firstExecutable(["/opt/homebrew/sbin/openvpn", "/usr/local/sbin/openvpn"]) else {
            return .fail("openvpn не знайдено (brew install openvpn)")
        }
        let pidFile = "/tmp/openvpn-\(id).pid", logFile = "/tmp/openvpn-\(id).log"
        try? FileManager.default.removeItem(atPath: pidFile)
        try? FileManager.default.removeItem(atPath: logFile)

        var args = ["--config", path]
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
            return .fail("openvpn не запустився: \(r.output)\n\(log)")
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
    static func validWGConf(_ path: String) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard p.hasSuffix(".conf"), wgDirs.contains(where: { p.hasPrefix($0 + "/") }), !isSymlink(p) else { return nil }
        let name = (p as NSString).lastPathComponent.dropLast(5)
        guard name.range(of: #"^[a-zA-Z0-9_=+.-]{1,15}$"#, options: .regularExpression) != nil else { return nil }
        return p
    }

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
