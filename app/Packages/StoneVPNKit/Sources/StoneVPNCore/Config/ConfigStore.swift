import Foundation

/// config.env / state.env репозиторію — спільні з CLI. Тут лише прості присвоєння
/// (`KEY=value`, `KEY="…"`, `KEY=(…)`): CLI їх source-ить, ми — парсимо, не виконуючи.
/// Запис зберігає решту файлу (коментарі, невідомі ключі) як є.
public struct EnvFile: Sendable {
    public private(set) var lines: [String]
    public let url: URL

    public init(url: URL) {
        self.url = url
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    public subscript(key: String) -> String? {
        guard let raw = rawValue(key) else { return nil }
        return EnvFile.unquote(raw)
    }

    public func array(_ key: String) -> [String]? {
        guard let raw = rawValue(key), raw.hasPrefix("("), raw.hasSuffix(")") else { return nil }
        return EnvFile.words(String(raw.dropFirst().dropLast()))
    }

    private func rawValue(_ key: String) -> String? {
        // Останнє присвоєння перемагає — як при source.
        for l in lines.reversed() {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.hasPrefix(key + "=") else { continue }
            var v = String(t.dropFirst(key.count + 1))
            if !v.hasPrefix("\""), !v.hasPrefix("'"), !v.hasPrefix("("), let hash = v.range(of: " #") {
                v = String(v[..<hash.lowerBound])
            }
            return v.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public mutating func set(_ key: String, _ value: String?) {
        let line = value.map { "\(key)=\(EnvFile.quote($0))" }
        replace(key, with: line)
    }

    public mutating func setArray(_ key: String, _ values: [String]) {
        replace(key, with: "\(key)=(" + values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: " ") + ")")
    }

    private mutating func replace(_ key: String, with line: String?) {
        if let i = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + "=") }) {
            if let line { lines[i] = line } else { lines.remove(at: i) }
        } else if let line {
            lines.append(line)
        }
    }

    public func save(mode: Int16? = nil) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    }

    // MARK: квотування

    /// Одне shell-слово: '…' буквально, "…" з \-екрануванням і $HOME, \x поза лапками
    /// (так пише printf %q), склейки на кшталт 'it'\''s'.
    static func unquote(_ v: String) -> String {
        if v.hasPrefix("$'"), v.hasSuffix("'") { return String(v.dropFirst(2).dropLast()) }
        var out = ""
        var mode: Character? = nil      // nil | ' | "
        var esc = false
        for c in v {
            if esc { out.append(c); esc = false; continue }
            switch (mode, c) {
            case (nil, "\\"), ("\"", "\\"): esc = true
            case (nil, "'"), (nil, "\""): mode = c
            case ("'", "'"), ("\"", "\""): mode = nil
            default: out.append(c)
            }
        }
        return out.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
    }

    static func quote(_ v: String) -> String {
        if v.isEmpty { return "" }
        if v.range(of: #"^[A-Za-z0-9._@:/+,-]+$"#, options: .regularExpression) != nil { return v }
        return "'" + v.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = "", q: Character?
        for c in s {
            if let qq = q { if c == qq { q = nil } else { cur.append(c) } }
            else if c == "\"" || c == "'" { q = c }
            else if c == " " || c == "\t" { if !cur.isEmpty { out.append(cur); cur = "" } }
            else { cur.append(c) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Значення config.env з дефолтами як у скриптах.
public struct RepoConfig: Sendable {
    /// Тека з config.env / state.env / auth.txt: репозиторій CLI або власна тека застосунку.
    public var repo: URL?
    /// true = це репо main-vpn-manager.sh (налаштування спільні з CLI).
    public var sharedWithCLI = false
    public var lanGateway = ""
    public var ovpnUsername = ""
    public var ovpnProfilesDir = NSHomeDirectory() + "/Library/Application Support/OpenVPN Connect/profiles"
    public var restoreDNS = ""
    public var disabled: Set<Backend> = []
    public var unknownDisabled: [String] = []
    public var defguardCLI = ""
    public var dnsServices = ["Wi-Fi"]
    // state.env
    public var lastUsername = ""
    public var lastGateway = ""
    // auth.txt
    public var authUser = ""

    public init() {}

    public static func load(repo: URL?) -> RepoConfig {
        var c = RepoConfig()
        c.repo = repo
        if let env = ProcessInfo.processInfo.environment["DISABLED_BACKENDS"] { c.applyDisabled(env) }
        guard let repo else { return c }
        let cfg = EnvFile(url: repo.appendingPathComponent("config.env"))
        c.lanGateway = cfg["LAN_GATEWAY"] ?? ""
        c.ovpnUsername = cfg["OVPN_USERNAME"] ?? ""
        if let d = cfg["OVPN_PROFILES_DIR"], !d.isEmpty { c.ovpnProfilesDir = (d as NSString).expandingTildeInPath }
        c.restoreDNS = cfg["RESTORE_DNS"] ?? ""
        if let d = cfg["DISABLED_BACKENDS"] { c.applyDisabled(d) }
        c.defguardCLI = cfg["DEFGUARD_CLI"] ?? ""
        if let s = cfg.array("DNS_SERVICES") { c.dnsServices = s }
        let st = EnvFile(url: repo.appendingPathComponent("state.env"))
        c.lastUsername = st["LAST_USERNAME"] ?? ""
        c.lastGateway = st["LAST_GATEWAY"] ?? ""
        if let a = try? String(contentsOf: repo.appendingPathComponent("auth.txt"), encoding: .utf8) {
            c.authUser = a.split(separator: "\n").first.map(String.init) ?? ""
        }
        return c
    }

    mutating func applyDisabled(_ s: String) {
        disabled = []
        unknownDisabled = []
        for w in s.replacingOccurrences(of: ",", with: " ").split(separator: " ") {
            if let b = Backend.canon(String(w)) { disabled.insert(b) } else { unknownDisabled.append(String(w)) }
        }
    }

    /// Пріоритет як у vpn-up.sh: state → config → auth.txt.
    public var defaultUsername: String { [lastUsername, ovpnUsername, authUser].first { !$0.isEmpty } ?? "" }
    public var defaultGateway: String { lastGateway.isEmpty ? lanGateway : lastGateway }
    public var restoreServers: [String] { restoreDNS.split(separator: " ").map(String.init) }

    public func isOn(_ b: Backend) -> Bool { !disabled.contains(b) }

    // MARK: запис

    public func saveConfig(_ edit: (inout EnvFile) -> Void) throws {
        guard let repo else { return }
        var f = EnvFile(url: repo.appendingPathComponent("config.env"))
        edit(&f)
        try f.save()
    }

    /// set_state з vpn-up.sh: файл 600.
    public func setState(_ key: String, _ value: String) {
        guard let repo else { return }
        var f = EnvFile(url: repo.appendingPathComponent("state.env"))
        f.set(key, value)
        try? f.save(mode: 0o600)
    }

    /// Власна тека застосунку — коли репо немає (окремий .app) або його вимкнено.
    public static var appSupportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StoneVPNManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Звідки брати конфіг: репо (спільно з CLI), якщо знайдено і не вимкнено, інакше власна тека.
    public static func load(explicitRepo: String?, standalone: Bool) -> RepoConfig {
        if !standalone, let repo = detectRepo(explicit: explicitRepo) {
            var c = load(repo: repo)
            c.sharedWithCLI = true
            return c
        }
        return load(repo: appSupportDir)
    }

    /// Перенести config.env/state.env/auth.txt з репо у власну теку (не перезаписуючи наявні).
    public static func importFromRepo(_ repo: URL) -> [String] {
        var copied: [String] = []
        for f in ["config.env", "state.env", "auth.txt"] {
            let src = repo.appendingPathComponent(f), dst = appSupportDir.appendingPathComponent(f)
            guard FileManager.default.fileExists(atPath: src.path), !FileManager.default.fileExists(atPath: dst.path) else { continue }
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
                copied.append(f)
            }
        }
        return copied
    }

    /// Шукаємо репо: явний шлях → вшитий при збірці (Info.plist) → поряд із бандлом.
    public static func detectRepo(explicit: String?) -> URL? {
        var candidates: [String] = []
        if let explicit, !explicit.isEmpty { candidates.append((explicit as NSString).expandingTildeInPath) }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "StoneVPNRepoPath") as? String { candidates.append(baked) }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path)
        for c in candidates where FileManager.default.fileExists(atPath: c + "/main-vpn-manager.sh") {
            return URL(fileURLWithPath: c).standardizedFileURL
        }
        return nil
    }
}
