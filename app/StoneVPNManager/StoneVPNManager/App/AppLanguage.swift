import AppKit

/// Мова інтерфейсу. За замовчуванням — як у системі (System Settings → General →
/// Language & Region → Applications теж працює). Перевизначення — стандартний ключ
/// `AppleLanguages` у домені застосунку; Bundle читає його лише при запуску, тож після
/// зміни застосунок перезапускається.
enum AppLanguage {
    /// Мови, для яких є переклад (код локалізації → власна назва мови).
    static let available: [(code: String, name: String)] = [("en", "English"), ("uk", "Українська")]

    /// "" = як у системі.
    static var override: String {
        guard let id = Bundle.main.bundleIdentifier,
              let langs = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String]
        else { return "" }
        return langs.first ?? ""
    }

    static func setOverride(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
    }

    /// Мова, якою інтерфейс говорить зараз (може відрізнятися від щойно обраної до перезапуску).
    static var active: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Перезапуск: дочірній shell чекає, поки цей процес завершиться, і відкриває бандл знову.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

extension Locale {
    /// Локаль інтерфейсу: мова — та, якою реально говорить застосунок (per-app language у
    /// System Settings або перевизначення вище), регіон і формати — системні. `Locale.current`
    /// мову застосунку не враховує (лишається, напр., en_US), і тоді правила множини були б
    /// англійські: «2 тунелю активного» замість «2 тунелі активні». Тому: SwiftUI отримує її
    /// через `.environment(\.locale, .app)`, а `String(localized:)` з лічильниками — `locale: .app`.
    static let app: Locale = {
        var c = Locale.Components(locale: .current)
        c.languageComponents = Locale.Language.Components(identifier: AppLanguage.active)
        return Locale(components: c)
    }()
}
