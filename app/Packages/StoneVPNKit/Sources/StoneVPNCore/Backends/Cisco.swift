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
    /// Чи просив цей сервер другий фактор минулого разу (nil = невідомо) — лише для підказок.
    public var expectsMFA: Bool?
    public init(host: String, group: String, user: String, password: String, secondPassword: String, expectsMFA: Bool? = nil) {
        self.host = host
        self.group = group
        self.user = user
        self.password = password
        self.secondPassword = secondPassword
        self.expectsMFA = expectsMFA
    }
}

/// expect-подібний драйвер `vpn -s`: читає вивід і відповідає на запит, коли він з'являється
/// (порядок і набір запитів залежать від head-end — групи може не бути, другого пароля теж).
public enum CiscoDriver {
    /// `.secondFactor` — сервер точно хоче MFA (запит Duo/OTP або довга пауза після пароля).
    public enum Event: Sendable { case step(String), banner(String), secondFactor }

    /// Пауза після пароля, довша за цю, — це сервер чекає підтвердження Duo (auto-push без запиту).
    /// Звичайна перевірка пароля відповідає за 1–2 с.
    static let mfaHold: TimeInterval = 5

    /// Повертає, чи знадобився другий фактор (для пам'яті «цей сервер без Duo»).
    @discardableResult
    public static func connect(cli: String, _ c: CiscoCredentials, timeout: TimeInterval = 60,
                               onEvent: @escaping @Sendable (Event) -> Void) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try run(cli: cli, c, timeout: timeout, onEvent: onEvent)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// `vpn connect <host>` під псевдотерміналом (`/usr/bin/script`) — так само, як у Terminal.
    /// Через голі pipe (`vpn -s`) пароль/другий фактор читаються з tty, якого немає, і сервер
    /// одразу відповідає «Login failed» — Duo-push навіть не стартує.
    static func run(cli: String, _ c: CiscoCredentials, timeout: TimeInterval, onEvent: @escaping @Sendable (Event) -> Void) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", cli, "connect", c.host]
        reapOrphans(cli: cli)
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = out
        try p.run()

        let lock = NSLock()
        var buf = ""          // ще не оброблений хвіст
        var all = ""          // увесь вивід (паролі tty не відлунює)
        var lastData = Date()
        let reader = out.fileHandleForReading
        reader.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
            lock.lock(); buf += s; all += s; lastData = Date(); lock.unlock()
        }
        var groupOptions: [String: String] = [:]   // назва групи → номер у меню сервера
        // vpn може вийти раніше (Login failed) — запис у закритий pipe не має вбивати процес.
        signal(SIGPIPE, SIG_IGN)
        func send(_ s: String) { try? inp.fileHandleForWriting.write(contentsOf: Data((s + "\n").utf8)) }
        defer {
            reader.readabilityHandler = nil
            try? inp.fileHandleForWriting.close()
            stop(p)
        }
        func transcriptTail() -> String {
            lock.lock(); defer { lock.unlock() }
            return all.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("VPN>") }.suffix(6).joined(separator: "\n")
        }

        onEvent(.step("vpn connect \(c.host)"))
        // Duo: порожній другий фактор = "push" (конвенція Duo для secondary password).
        let second = c.secondPassword.isEmpty ? "push" : c.secondPassword
        var passwordsSent = 0, secondSent = 0, groupPrompts = 0
        var bannerSent = false, updateSeen = false
        var ssoSeen = false            // SSO-відмова з моменту останньої відповіді на Group
        var mfa = false
        func markMFA() { if !mfa { mfa = true; onEvent(.secondFactor) } }
        var passwordAt: Date?          // чекаємо першої відповіді сервера після пароля
        var holdNoted = false
        var deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            lock.lock(); let chunk = buf; let quiet = Date().timeIntervalSince(lastData); lock.unlock()
            if let at = passwordAt {
                let held = Date().timeIntervalSince(at)
                if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Повільне «Login failed» — не Duo.
                    if held > mfaHold, failure(chunk) == nil { markMFA() }
                    passwordAt = nil
                } else if held > mfaHold, !holdNoted {
                    holdNoted = true
                    // Мовчить довше, ніж триває перевірка пароля, — найімовірніше, чекає Duo.
                    if c.expectsMFA == false {
                        onEvent(.step(String(localized: "The server is taking long — if it sent a Duo push, approve it on your phone", bundle: .module)))
                    }
                }
            }
            guard !chunk.isEmpty else {
                if !p.isRunning { break }
                continue
            }
            for l in chunk.split(separator: "\n") {
                if let m = Parse.firstMatch(#"^\s*(\d+\)\s+.+?)\s*$"#, String(l)) {
                    let parts = m.split(separator: ")", maxSplits: 1)
                    groupOptions[parts[1].trimmingCharacters(in: .whitespaces)] = String(parts[0])
                }
            }
            let tail = chunk.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let lower = chunk.lowercased()
            // Повні рядки обрізаються з buf між проходами: якщо відмова й меню прийшли різними
            // порціями, маркер у chunk на момент запиту Group вже зник — тож пам'ятаємо його.
            if lower.contains(ssoMarker) { ssoSeen = true }

            if lower.contains("state: connected") || lower.contains("connected to ") {
                onEvent(.step("Connected"))
                return mfa
            }
            // Head-end вимагає іншу версію клієнта: завантажує її, а `vpn` виходить
            // («Exiting. Upgrade in progress») — підключення в цьому запуску вже не буде.
            if !updateSeen, let v = Parse.firstMatch(#"(?i)downloading cisco secure client ([0-9.]+)"#, chunk) ?? (lower.contains("upgrade in progress") ? "" : nil) {
                updateSeen = true
                onEvent(.step(v.isEmpty ? String(localized: "The server requires a Cisco Secure Client update — downloading it…", bundle: .module)
                                        : String(localized: "The server requires Cisco Secure Client \(v) — downloading it…", bundle: .module)))
                deadline = max(deadline, Date().addingTimeInterval(180))
            }
            if lower.contains("upgrade in progress") {
                let v = Parse.firstMatch(#"(?i)downloading cisco secure client ([0-9.]+)"#, all) ?? ""
                throw ActionError(v.isEmpty
                    ? String(localized: "Cisco Secure Client is updating itself because the server requires it. Wait until the installer window closes, then connect again.", bundle: .module)
                    : String(localized: "Cisco Secure Client is updating itself to \(v) because the server requires it. Wait until the installer window closes, then connect again.", bundle: .module))
            }
            if failure(chunk) != nil {
                Thread.sleep(forTimeInterval: 0.3)       // дочитати причину, якщо сервер її надсилає
                throw ActionError(explain(transcriptTail(), chunk))
            }

            let t = tail.trimmingCharacters(in: .whitespaces).lowercased()
            // Відповідаємо, лише коли вивід затих: клієнт друкує підказку *до* того, як вимкне
            // відлуння з TCSAFLUSH (рання відповідь стирається), а після зміни групи
            // перезавантажує форму. Людина в Terminal ніколи не буває такою швидкою.
            if !t.isEmpty, quiet < 0.6 { continue }
            var consumed = true
            if t.hasSuffix("group:") || t.contains("group: [") || (t.hasPrefix("group") && t.hasSuffix(":")) {
                groupPrompts += 1
                // Група з входом через браузер (SAML/SSO): CLI пише «authentication type is not
                // supported» і знову показує меню. Без цієї перевірки Enter (група сервера) крутився б
                // по колу до таймауту. Вперше це повідомлення — про групу за замовчуванням сервера.
                if ssoSeen && (c.group.isEmpty || groupPrompts > 1) {
                    let bad = groupPrompts > 1 && !c.group.isEmpty ? c.group
                        : (Parse.firstMatch(#"\[([^\]]*)\]"#, tail).flatMap { $0.isEmpty ? nil : $0 } ?? "")
                    throw ActionError(ssoGroupError(bad, others: menuOrder(groupOptions).filter { $0 != bad }))
                }
                if groupPrompts > 3 {
                    throw ActionError(String(localized: "the server keeps asking for the group — check the group name:", bundle: .module) + "\n" + transcriptTail())
                }
                // Меню груп приймає номер (як у CLI: «Group: [VPN1] 1»); назву — лише як запасний варіант.
                let answer = c.group.isEmpty ? "" : (groupOptions[c.group] ?? c.group)
                onEvent(.step(c.group.isEmpty ? String(localized: "Group: (default)", bundle: .module)
                                               : String(localized: "Group: \(c.group)", bundle: .module)))
                send(answer)
                ssoSeen = false
            } else if t.hasPrefix("username:") || t.contains("username: [") {
                onEvent(.step(String(localized: "Username: \(c.user)", bundle: .module)))
                send(c.user)
            } else if t.contains("second password") || t.contains("secondary password") || t.contains("passcode")
                        || t.contains("duo") || t.hasPrefix("answer:") || t.hasPrefix("response:") {
                secondSent += 1
                passwordAt = nil
                markMFA()
                if secondSent > 2 { throw ActionError(String(localized: "the server asks for the second factor again:", bundle: .module) + "\n" + transcriptTail()) }
                // Меню Duo «Passcode or option (1-3)»: 1 = Duo Push.
                let answer = t.contains("option") && c.secondPassword.isEmpty ? "1" : second
                onEvent(.step(answer == "push" || answer == "1" ? String(localized: "Duo: push sent to your phone", bundle: .module)
                                                                : String(localized: "Second factor / OTP", bundle: .module)))
                send(answer)
                onEvent(.step(String(localized: "Approve the sign-in in Duo on your phone…", bundle: .module)))
                deadline = max(deadline, Date().addingTimeInterval(120))
            } else if t.hasSuffix("password:") || t.contains("password: ") {
                passwordsSent += 1
                if passwordsSent > 1 { throw ActionError(String(localized: "the server asks for the password again — wrong username or password:", bundle: .module) + "\n" + transcriptTail()) }
                onEvent(.step(String(localized: "Password", bundle: .module)))
                send(c.password)
                passwordAt = Date()
                // Сервер може тримати відповідь, поки ти підтверджуєш Duo-push (auto-push без запиту).
                // Що писати — з пам'яті про цей хост: без MFA «approve on your phone» лише плутає.
                switch c.expectsMFA {
                case true?: onEvent(.step(String(localized: "Waiting for the server (Duo/MFA — approve on your phone)…", bundle: .module)))
                case false?: onEvent(.step(String(localized: "Waiting for the server…", bundle: .module)))
                case nil: onEvent(.step(String(localized: "Waiting for the server (if it uses Duo/MFA, approve on your phone)…", bundle: .module)))
                }
                deadline = max(deadline, Date().addingTimeInterval(120))
            } else if t.contains("accept?") || t.contains("[y/n]") {
                if !bannerSent {
                    let banner = chunk.components(separatedBy: "\n").dropLast()
                        .filter { !$0.contains(">>") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: "\n")
                    if !banner.isEmpty { onEvent(.banner(banner)) }
                    onEvent(.step(String(localized: "Banner accepted", bundle: .module)))
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
        lock.lock(); let text = all; lock.unlock()
        if text.lowercased().contains("state: connected") { onEvent(.step("Connected")); return mfa }
        let tailText = transcriptTail()
        if failure(text) != nil { throw ActionError(explain(tailText, text)) }
        let reason = p.isRunning ? String(localized: "Cisco did not connect in time", bundle: .module)
                                 : String(localized: "vpn exited without connecting", bundle: .module)
        throw ActionError(reason + (tailText.isEmpty ? "" : ":\n" + tailText))
    }

    public struct GroupProbe: Sendable, Equatable {
        public var groups: [String]
        public var defaultGroup: String?
        public var asksGroup: Bool          // false = сервер одразу питає логін (групи не обирають)
        /// Група сервера за замовчуванням, що входить через браузер (SAML/SSO) — CLI так не вміє.
        /// Її немає в `groups`, і `defaultGroup` тоді nil.
        public var ssoGroup: String? = nil
    }

    /// Так CLI відповідає на групу з SAML/SSO-входом (Cisco Secure Client 5.x).
    static let ssoMarker = "authentication type is not supported in anyconnect cli"

    static func ssoGroupError(_ group: String, others: [String]) -> String {
        let name = group.isEmpty ? String(localized: "(default)", bundle: .module) : group
        var msg = String(localized: "The group “\(name)” signs in through a browser (SAML/SSO), which the Cisco CLI can't do.", bundle: .module)
        if !others.isEmpty {
            msg += " " + String(localized: "Choose another group: \(others.joined(separator: ", ")).", bundle: .module)
        }
        return msg
    }

    /// Назви груп у порядку меню сервера (номер → назва).
    static func menuOrder(_ options: [String: String]) -> [String] {
        options.sorted { (Int($0.value) ?? 0) < (Int($1.value) ?? 0) }.map(\.key)
    }

    /// Дізнатися групи до автентифікації: `connect <host>` → чекаємо перший запит
    /// (Group / Username) → обриваємо, нічого не надсилаючи. Тунель не піднімається.
    /// НЕ викликати, поки Cisco підключений: `connect` під час сесії її перепідніме.
    public static func probeGroups(cli: String, host: String, timeout: TimeInterval = 25) async throws -> GroupProbe {
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GroupProbe, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try probe(cli: cli, host: host, timeout: timeout, cancelled: { cancel.isSet })) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { cancel.set() }
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func probe(cli: String, host: String, timeout: TimeInterval, cancelled: () -> Bool = { false }) throws -> GroupProbe {
        do {
            return try probeOnce(cli: cli, host: host, pty: false, timeout: timeout, cancelled: cancelled)
        } catch SSODefault.hit {
            // `vpn -s` на SSO-групі сервера лише пише помилку й не показує меню; під pty
            // (`vpn connect`, як у Terminal) меню є. Нічого не надсилаємо — обриваємо на запиті.
            guard var r = try? probeOnce(cli: cli, host: host, pty: true, timeout: timeout, cancelled: cancelled), r.asksGroup else {
                if cancelled() { throw CancellationError() }
                throw ActionError(ssoGroupError("", others: []))
            }
            let sso = r.defaultGroup ?? ""
            r.groups.removeAll { $0 == sso }
            r.ssoGroup = sso
            r.defaultGroup = nil
            return r
        }
    }

    enum SSODefault: Error { case hit }

    static func probeOnce(cli: String, host: String, pty: Bool, timeout: TimeInterval, cancelled: () -> Bool) throws -> GroupProbe {
        let p = Process()
        if pty {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            p.arguments = ["-q", "/dev/null", cli, "connect", host]
        } else {
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["-s"]
        }
        reapOrphans(cli: cli)
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
            stop(p)
        }
        if !pty { try? inp.fileHandleForWriting.write(contentsOf: Data("connect \(host)\n".utf8)) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            if cancelled() { throw CancellationError() }
            lock.lock(); let text = all; lock.unlock()
            if let r = parseGroupPrompt(text) { return r }
            if !pty, text.lowercased().contains(ssoMarker) { throw SSODefault.hit }
            if let err = failure(text) { throw ActionError(explain(err, text)) }
            if !p.isRunning { break }
        }
        lock.lock(); let text = all; lock.unlock()
        if let r = parseGroupPrompt(text) { return r }
        throw ActionError(failure(text) ?? String(localized: "the server sent no login form within \(Int(timeout)) s", bundle: .module))
    }

    /// Вивід до першого запиту: "    0) Employees\n    1) Staff\nGroup: [Employees]" або одразу "Username:".
    /// Реальний вивід містить \r і асинхронні `>> notice:` / `VPN>`, які можуть прилетіти *після*
    /// запиту — тож шукаємо останній рядок-запит, а не вимагаємо, щоб він був останнім.
    static func parseGroupPrompt(_ text: String) -> GroupProbe? {
        let lines = text.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            .map { l -> String in
                var t = l.trimmingCharacters(in: .whitespaces)
                while t.hasPrefix("VPN>") { t = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
                return t
            }
        for (i, l) in lines.enumerated().reversed() {
            let lower = l.lowercased()
            if lower.hasPrefix("group:") {
                var groups: [String] = []
                for g in lines[..<i] {
                    if let m = Parse.firstMatch(#"^\d+\)\s+(.+?)\s*$"#, g) { groups.append(m) }
                }
                let def = Parse.firstMatch(#"\[([^\]]*)\]"#, l).flatMap { $0.isEmpty ? nil : $0 }
                return GroupProbe(groups: groups, defaultGroup: def ?? groups.first, asksGroup: true)
            }
            if lower.hasPrefix("username:") || lower.hasSuffix("password:") {
                return GroupProbe(groups: [], defaultGroup: nil, asksGroup: false)
            }
        }
        return nil
    }

    /// Підказка до «Connect capability is unavailable»: агент віддає право підключення лише
    /// одному клієнту — GUI або іншому `vpn` (наприклад, у Terminal).
    public static var capabilityHint: String {
        String(localized: "Another Cisco client holds the connect capability: the Cisco Secure Client GUI or `vpn` in Terminal. Close it and try again.", bundle: .module)
    }

    // MARK: процеси vpn

    /// Зупинити дочірній процес напевно: `vpn` посеред connect ігнорує SIGTERM, а `script`
    /// після SIGTERM лишає свого `vpn` сиротою. Тож: діти → SIGKILL, сам процес → TERM, потім KILL.
    static func stop(_ p: Process) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        for c in childPids(pid) { kill(c, SIGKILL) }
        p.terminate()
        for _ in 0..<15 where p.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { kill(pid, SIGKILL) }
    }

    static func childPids(_ pid: Int32) -> [Int32] {
        Shell.runSync("/usr/bin/pgrep", ["-P", String(pid)]).out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Наші `vpn` (або `script … vpn`), що пережили батька: ppid 1, той самий uid. Лишаються, коли
    /// застосунок закрили посеред перевірки груп/підключення. Такий процес тримає «connect capability»
    /// агента, і кожен наступний connect падає з «Another Cisco Secure Client application acquired it».
    /// `vpn` у Terminal має батьком shell, тому не зачіпається.
    static func parseOrphans(_ ps: String, cli: String, uid: uid_t) -> [Int32] {
        ps.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), f[1] == "1", f[2] == Substring(String(uid)) else { return nil }
            let cmd = String(f[3])
            let ours = cmd == cli || cmd.hasPrefix(cli + " ") || cmd.hasPrefix("/usr/bin/script -q /dev/null \(cli) ")
            return ours ? pid : nil
        }
    }

    @discardableResult
    public static func reapOrphans(cli: String) -> [Int32] {
        let ps = Shell.runSync("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,command="]).out
        let pids = parseOrphans(ps, cli: cli, uid: getuid())
        for pid in pids { kill(pid, SIGKILL) }
        if !pids.isEmpty { Thread.sleep(forTimeInterval: 0.5) }   // агент має помітити, що клієнт зник
        return pids
    }

    static func explain(_ msg: String, _ output: String) -> String {
        output.lowercased().contains("connect capability is unavailable") ? msg + "\n\n" + capabilityHint : msg
    }

    static func failure(_ s: String) -> String? {
        for line in s.split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("login failed") || l.contains("authentication failed") || l.contains("unable to contact")
                || l.contains("connection attempt has failed") || l.contains("is not a valid") || l.contains("no address")
                || l.contains("connect capability is unavailable") {
                return line.replacingOccurrences(of: ">>", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
