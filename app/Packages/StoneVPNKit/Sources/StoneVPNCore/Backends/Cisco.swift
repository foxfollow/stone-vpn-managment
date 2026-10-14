import Foundation

/// Останні значення, які пам'ятає сам Cisco Secure Client (GUI і CLI пишуть їх сюди).
/// defaultClientProfile.xml для цього не годиться: head-end перезаписує профіль при
/// кожному підключенні, тож власний порт там не живе.
public struct CiscoPrefs: Sendable {
    public var user = ""
    public var group = ""
    public var hostName = ""
    public var hostAddress = ""      // часто IP:port останнього успішного підключення

    public static let files = [
        NSHomeDirectory() + "/.vpn/.anyconnect",
        "/opt/cisco/secureclient/vpn/.anyconnect_global",
        "/opt/cisco/anyconnect/.anyconnect_global",
    ]

    public static func load() -> CiscoPrefs {
        var p = CiscoPrefs()
        for f in files {
            guard let x = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            func tag(_ t: String) -> String { Parse.firstMatch("<\(t)>([^<]*)</\(t)>", x)?.trimmingCharacters(in: .whitespaces) ?? "" }
            if p.user.isEmpty { p.user = tag("DefaultUser") }
            if p.group.isEmpty { p.group = tag("DefaultGroup") }
            if p.hostName.isEmpty { p.hostName = tag("DefaultHostName") }
            if p.hostAddress.isEmpty { p.hostAddress = tag("DefaultHostAddress") }
        }
        return p
    }

    /// Хост для підключення: ім'я + порт з останньої адреси (training.example:8448).
    public var suggestedHost: String? {
        guard !hostName.isEmpty else { return nil }
        if hostName.contains(":") { return hostName }
        if let port = hostAddress.split(separator: ":").last, hostAddress.contains(":"), Int(port) != nil, port != "443" {
            return "\(hostName):\(port)"
        }
        return hostName
    }
}

/// Відповіді на запити `vpn -s`. Порожні поля = Enter (прийняти дефолт Cisco).
public struct CiscoCredentials: Sendable {
    public var host: String
    public var group: String
    public var user: String
    public var password: String
    public var secondPassword: String
    public init(host: String, group: String, user: String, password: String, secondPassword: String) {
        self.host = host
        self.group = group
        self.user = user
        self.password = password
        self.secondPassword = secondPassword
    }
}

/// expect-подібний драйвер `vpn -s`: читає вивід і відповідає на запит, коли він з'являється
/// (порядок і набір запитів залежать від head-end — групи може не бути, другого пароля теж).
public enum CiscoDriver {
    public enum Event: Sendable { case step(String), banner(String) }

    public static func connect(cli: String, _ c: CiscoCredentials, timeout: TimeInterval = 90,
                               onEvent: @escaping @Sendable (Event) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try run(cli: cli, c, timeout: timeout, onEvent: onEvent)
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    static func run(cli: String, _ c: CiscoCredentials, timeout: TimeInterval, onEvent: @escaping @Sendable (Event) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-s"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = out
        try p.run()

        let lock = NSLock()
        var buf = ""          // ще не оброблений хвіст
        var all = ""
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); let s = String(decoding: d, as: UTF8.self); buf += s; all += s; lock.unlock()
        }
        // vpn може вийти раніше (Login failed) — запис у закритий pipe не має вбивати процес.
        signal(SIGPIPE, SIG_IGN)
        func send(_ s: String) { try? inp.fileHandleForWriting.write(contentsOf: Data((s + "\n").utf8)) }
        defer {
            reader.readabilityHandler = nil
            try? inp.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
        }

        send("connect \(c.host)")
        onEvent(.step("vpn connect \(c.host)"))
        var passwordsSent = 0
        var bannerSent = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            lock.lock(); let chunk = buf; lock.unlock()
            guard !chunk.isEmpty else {
                if !p.isRunning { break }
                continue
            }
            let tail = chunk.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let lower = chunk.lowercased()

            if lower.contains("state: connected") || lower.contains("connected to ") {
                onEvent(.step("Connected"))
                send("exit")
                return
            }
            if let err = failure(chunk) { throw ActionError(err) }

            // Запити (рядок без \n у кінці або з двокрапкою наприкінці).
            let t = tail.trimmingCharacters(in: .whitespaces).lowercased()
            var consumed = true
            if t.hasSuffix("group:") || t.contains("group: [") || (t.hasPrefix("group") && t.hasSuffix(":")) {
                onEvent(.step("Група: \(c.group.isEmpty ? "(за замовчуванням)" : c.group)"))
                send(c.group)
            } else if t.hasPrefix("username:") || t.contains("username: [") {
                onEvent(.step("Логін: \(c.user)"))
                send(c.user)
            } else if t.contains("second password:") || t.contains("secondary password:") {
                onEvent(.step("Другий пароль / OTP"))
                send(c.secondPassword)
            } else if t.hasSuffix("password:") || t.contains("password: ") {
                passwordsSent += 1
                if passwordsSent > 2 { throw ActionError("сервер повторно питає пароль — невірний логін/пароль?") }
                onEvent(.step("Пароль"))
                send(passwordsSent == 1 ? c.password : c.secondPassword)
            } else if t.contains("accept?") || t.contains("[y/n]") {
                if !bannerSent {
                    let banner = chunk.components(separatedBy: "\n").dropLast()
                        .filter { !$0.contains(">>") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: "\n")
                    if !banner.isEmpty { onEvent(.banner(banner)) }
                    onEvent(.step("Банер прийнято"))
                }
                bannerSent = true
                send("y")
            } else {
                consumed = false
            }
            // Оброблене прибираємо, але лише повні рядки (запит без \n чекає відповіді).
            lock.lock()
            if consumed { buf = "" } else if let nl = buf.lastIndex(of: "\n") { buf = String(buf[buf.index(after: nl)...]) }
            lock.unlock()
            if !p.isRunning { break }
        }
        if let err = failure(all) { throw ActionError(err) }
        throw ActionError(p.isRunning ? "Cisco не підключився за \(Int(timeout)) с" : "vpn завершився без підключення")
    }

    public struct GroupProbe: Sendable, Equatable {
        public var groups: [String]
        public var defaultGroup: String?
        public var asksGroup: Bool          // false = сервер одразу питає логін (групи не обирають)
    }

    /// Дізнатися групи до автентифікації: `connect <host>` → чекаємо перший запит
    /// (Group / Username) → обриваємо, нічого не надсилаючи. Тунель не піднімається.
    /// НЕ викликати, поки Cisco підключений: `connect` під час сесії її перепідніме.
    public static func probeGroups(cli: String, host: String, timeout: TimeInterval = 25) async throws -> GroupProbe {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GroupProbe, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try probe(cli: cli, host: host, timeout: timeout)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    static func probe(cli: String, host: String, timeout: TimeInterval) throws -> GroupProbe {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["-s"]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = out
        signal(SIGPIPE, SIG_IGN)
        try p.run()
        let lock = NSLock()
        var all = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); all += String(decoding: d, as: UTF8.self); lock.unlock()
        }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            try? inp.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
        }
        try? inp.fileHandleForWriting.write(contentsOf: Data("connect \(host)\n".utf8))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            lock.lock(); let text = all; lock.unlock()
            if let r = parseGroupPrompt(text) { return r }
            if let err = failure(text) { throw ActionError(err) }
            if !p.isRunning { break }
        }
        lock.lock(); let text = all; lock.unlock()
        if let r = parseGroupPrompt(text) { return r }
        throw ActionError(failure(text) ?? "сервер не надіслав форму входу за \(Int(timeout)) с")
    }

    /// Вивід до першого запиту: "    0) Employees\n    1) Staff\nGroup: [Employees]" або одразу "Username:".
    static func parseGroupPrompt(_ text: String) -> GroupProbe? {
        let lines = text.components(separatedBy: "\n")
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), !last.isEmpty else { return nil }
        let lower = last.lowercased()
        if lower.hasPrefix("group:") {
            var groups: [String] = []
            for l in lines.dropLast() {
                if let g = Parse.firstMatch(#"^\s*\d+\)\s+(.+?)\s*$"#, l) { groups.append(g) }
            }
            let def = Parse.firstMatch(#"\[([^\]]*)\]"#, last).flatMap { $0.isEmpty ? nil : $0 }
            return GroupProbe(groups: groups, defaultGroup: def ?? groups.first, asksGroup: true)
        }
        if lower.hasPrefix("username:") || lower.hasSuffix("password:") {
            return GroupProbe(groups: [], defaultGroup: nil, asksGroup: false)
        }
        return nil
    }

    static func failure(_ s: String) -> String? {
        for line in s.split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("login failed") || l.contains("authentication failed") || l.contains("unable to contact")
                || l.contains("connection attempt has failed") || l.contains("is not a valid") || l.contains("no address") {
                return line.replacingOccurrences(of: ">>", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
