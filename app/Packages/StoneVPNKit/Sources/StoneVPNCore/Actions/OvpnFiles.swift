import Foundation

/// Файлові операції з профілями OpenVPN (тека профілів — користувацька, root не потрібен).
/// Ціль завжди — *конкретний* файл профілю, а не «перший з таким самим remote»:
/// кілька профілів часто мають один remote (різні логіни/сертифікати на тому ж сервері).
public enum OvpnFiles {
    /// Вбудовані блоки, які має сенс замінювати окремо.
    public static let blockTags = ["cert", "key", "ca", "tls-auth", "tls-crypt"]

    /// Схоже на клієнтський профіль: є `remote` або вбудований `<ca>`.
    public static func looksLikeProfile(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("remote ") || l.hasPrefix("remote\t") || l == "<ca>"
        }
    }

    /// Замінити вміст `<tag>…</tag>`. nil — блоку в профілі немає (напр. `cert file.crt`).
    public static func replaceBlock(_ text: String, tag: String, with content: String) -> String? {
        let open = "<\(tag)>", close = "</\(tag)>"
        guard let o = text.range(of: open), let c = text.range(of: close, range: o.upperBound..<text.endIndex) else { return nil }
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.replacingCharacters(in: o.upperBound..<c.lowerBound, with: "\n\(body)\n")
    }

    /// Перевірка PEM під конкретний блок — щоб ключ не потрапив у <cert> і навпаки.
    public static func pemMatches(_ pem: String, tag: String) -> Bool {
        switch tag {
        case "key": pem.contains("-----BEGIN") && pem.contains("PRIVATE KEY-----")
        case "cert", "ca": pem.contains("-----BEGIN CERTIFICATE-----")
        case "tls-auth", "tls-crypt": pem.contains("-----BEGIN OpenVPN Static key")
        default: false
        }
    }

    /// Нове ім'я як у OpenVPN Connect (ms-мітка), унікальне в теці.
    public static func newID(in dir: String, now: Date = Date()) -> String {
        var ms = Int64(now.timeIntervalSince1970 * 1000)
        while FileManager.default.fileExists(atPath: "\(dir)/\(ms).ovpn") { ms += 1 }
        return String(ms)
    }

    /// Додати новий профіль; повертає його ID.
    public static func importProfile(from src: URL, into dir: String) throws -> String {
        let text = try readProfile(src)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let id = newID(in: dir)
        try Data(text.utf8).write(to: URL(fileURLWithPath: "\(dir)/\(id).ovpn"), options: .atomic)
        return id
    }

    /// Замінити весь профіль у *цьому* файлі (ID, alias, налаштування зберігаються). Стара версія — `.ovpn.bak`.
    public static func replaceProfile(at path: String, with src: URL) throws {
        let text = try readProfile(src)
        try backup(path)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Замінити один вбудований блок (<cert>/<key>/<ca>…) вмістом PEM-файлу.
    public static func replaceBlock(at path: String, tag: String, pemFile: URL) throws {
        guard let pem = try? String(contentsOf: pemFile, encoding: .utf8) else { throw ActionError("не читається: \(pemFile.path)") }
        guard pemMatches(pem, tag: tag) else { throw ActionError("\(pemFile.lastPathComponent) не схожий на вміст <\(tag)>") }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        guard let updated = replaceBlock(text, tag: tag, with: pem) else {
            throw ActionError("у профілі немає вбудованого <\(tag)> — заміни профіль цілком")
        }
        try backup(path)
        try Data(updated.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Видалити профіль у Кошик (разом із .bak) — відновлюваний.
    public static func delete(at path: String) throws {
        let fm = FileManager.default
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        if fm.fileExists(atPath: path + ".bak") { try? fm.trashItem(at: URL(fileURLWithPath: path + ".bak"), resultingItemURL: nil) }
    }

    private static func readProfile(_ src: URL) throws -> String {
        guard let text = try? String(contentsOf: src, encoding: .utf8) else { throw ActionError("не читається: \(src.path)") }
        guard looksLikeProfile(text) else { throw ActionError("\(src.lastPathComponent) не схожий на профіль OpenVPN (немає remote / <ca>)") }
        return text
    }

    private static func backup(_ path: String) throws {
        let bak = path + ".bak"
        let fm = FileManager.default
        if fm.fileExists(atPath: bak) { try fm.removeItem(atPath: bak) }
        try fm.copyItem(atPath: path, toPath: bak)
    }
}
