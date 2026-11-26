import Foundation

/// Локалізація відповідей helper-а.
///
/// Демон працює як root з мовою системи, тож `Bundle.main`/`Locale.current` тут не годяться:
/// мова береться із запиту (`PrivRequest.lang` — та, якою зараз говорить застосунок).
/// Рядки — таблиця `Helper` (Helper.xcstrings у ресурсах застосунку), скомпільована в
/// `…/StoneVPNManager.app/Contents/Resources/<lang>.lproj/Helper.strings[dict]`; helper лежить
/// у тому ж бандлі. Без бандла / без перекладу — англійські ключі.
enum HelperL10n {
    private static let threadKey = "StoneVPNHelperLang"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]

    /// Contents/Resources застосунку-власника.
    static let resources: URL? = {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        return contents.appendingPathComponent("Resources", isDirectory: true)
    }()

    /// Виконати `body` з мовою відповіді `lang`. Executor працює синхронно на потоці
    /// XPC-виклику, тож мова — у словнику потоку (паралельні запити не заважають одне одному).
    static func with<T>(_ lang: String?, _ body: () -> T) -> T {
        let dict = Thread.current.threadDictionary
        let old = dict[threadKey]
        dict[threadKey] = lang
        defer { dict[threadKey] = old }
        return body()
    }

    private static var lang: String? { Thread.current.threadDictionary[threadKey] as? String }

    /// Бандл-тека `<lang>.lproj` поточної мови (з відкатом на англійську).
    static var bundle: Bundle { lproj(lang) ?? lproj("en") ?? .main }

    /// Локаль клієнта: правила множини (uk: one/few/many) і формат чисел. Без неї
    /// String(localized:) бере локаль процесу — root-демона з мовою системи.
    static var locale: Locale { Locale(identifier: lang ?? "en") }

    private static func lproj(_ lang: String?) -> Bundle? {
        guard let lang, !lang.isEmpty, let resources else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let b = cache[lang] { return b }
        // "uk-UA" → uk.lproj, якщо точної теки немає.
        let base = String(lang.prefix { $0 != "-" && $0 != "_" })
        for code in [lang, base] {
            let url = resources.appendingPathComponent("\(code).lproj", isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Helper.strings").path),
                  let b = Bundle(url: url) else { continue }
            cache[lang] = b
            return b
        }
        return nil
    }
}

/// Рядок helper-а мовою клієнта. Ключ — англійський текст, як у `String(localized:)`.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, table: "Helper", bundle: HelperL10n.bundle, locale: HelperL10n.locale)
}
