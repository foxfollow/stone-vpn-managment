import Foundation

// l10n-ignore-file: keywords are deliberately bilingual (English + Ukrainian synonyms), so the
// search finds a setting whichever language the user types in; titles are localized.

/// Один пункт налаштувань, який знаходить пошук.
struct SettingsSearchEntry: Identifiable, Hashable {
    /// Збігається з `.settingsAnchor(id)` рядка на сторінці.
    let id: String
    let title: String
    let section: SettingsSection
    /// Заголовок секції Form, у якій лежить пункт.
    let group: String
    /// Синоніми, ключі config.env, назви інструментів — англійською й українською,
    /// щоб пошук працював незалежно від мови інтерфейсу.
    var keywords: [String] = []
}

/// Усі пункти налаштувань і пошук по них.
enum SettingsSearchIndex {
    /// Записи в порядку сторінок у бічній панелі.
    static var entries: [SettingsSearchEntry] {
        general + notifications + backends + openvpn + dns + network + helper + advanced
    }

    // MARK: - Пошук

    /// Пункти, де є кожне слово запиту (у назві, секції, сторінці, групі сторінок або
    /// ключових словах; регістр і діакритика ігноруються). Спершу ті, чия назва починається
    /// з запиту, далі ті, де він є в назві; решта — у порядку сторінок.
    static func search(_ query: String, in entries: [SettingsSearchEntry] = entries) -> [SettingsSearchEntry] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        let ranked: [(rank: Int, index: Int, entry: SettingsSearchEntry)] = entries.enumerated().compactMap { index, e in
            let title = normalize(e.title)
            let haystack = ([title, e.group, e.section.title, e.section.group.title] + e.keywords)
                .map(normalize).joined(separator: " ")
            guard words.allSatisfy(haystack.contains) else { return nil }
            let rank = title.hasPrefix(phrase) ? 0 : title.contains(phrase) ? 1 : words.allSatisfy(title.contains) ? 2 : 3
            return (rank, index, e)
        }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.entry)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Сторінки

    private static func e(_ id: String, _ title: String, _ section: SettingsSection, _ group: String,
                          _ keywords: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(id: id, title: title, section: section, group: group, keywords: keywords)
    }

    private static var general: [SettingsSearchEntry] {
        let language = String(localized: "Language"), version = String(localized: "Updates")
        let startup = String(localized: "Startup"), icon = String(localized: "Menu Bar Icon")
        let status = String(localized: "Status Updates")
        return [
            e("general.language", String(localized: "Interface Language"), .general, language,
              ["language", "english", "ukrainian", "locale", "мова", "англійська", "українська", "переклад"]),
            e("general.updates", String(localized: "Automatically Check for Updates"), .general, version,
              ["update", "sparkle", "version", "оновлення", "версія", "нова версія"]),
            e("general.launchAtLogin", String(localized: "Launch at Login"), .general, startup,
              ["autostart", "login items", "startup", "автозапуск", "запуск", "при вході"]),
            e("general.cmdTab", String(localized: "Show in Cmd+Tab While a Window Is Open"), .general, startup,
              ["dock", "app switcher", "command tab", "док", "перемикач"]),
            e("general.iconColored", String(localized: "Coloured Icon"), .general, icon,
              ["color", "colour", "menubar", "template", "колір", "іконка", "кольорова"]),
            e("general.iconCount", String(localized: "Show the Number of Tunnels"), .general, icon,
              ["count", "number", "badge", "кількість", "число"]),
            e("general.iconName", String(localized: "Show the Active Tunnel’s Name"), .general, icon,
              ["name", "label", "назва", "імʼя"]),
            e("general.refresh", String(localized: "In the Background"), .general, status,
              ["interval", "poll", "refresh", "seconds", "інтервал", "опитування", "у фоні", "секунд"]),
        ]
    }

    private static var notifications: [SettingsSearchEntry] {
        let g = String(localized: "Show")
        let kw = ["notification", "alert", "сповіщення", "повідомлення"]
        return [
            e("notify.connected", String(localized: "Tunnel Connected"), .notifications, g, kw + ["connect", "підключено"]),
            e("notify.disconnected", String(localized: "Tunnel Disconnected"), .notifications, g, kw + ["disconnect", "відключено"]),
            e("notify.dropped", String(localized: "Tunnel Dropped Unexpectedly"), .notifications, g, kw + ["drop", "lost", "упав", "обірвався"]),
            e("notify.dns", String(localized: "DNS Not Responding"), .notifications, g, kw + ["resolver", "днс", "резолвер"]),
            e("notify.foreign", String(localized: "A Foreign VPN Took Over the Route"), .notifications, g,
              kw + ["foreign", "clearvpn", "default route", "сторонній", "маршрут"]),
            e("notify.routes", String(localized: "A VPN Server Goes Through Another Tunnel"), .notifications, g,
              kw + ["tunnel in tunnel", "vpn in vpn", "route", "тунель у тунелі", "маршрут"]),
        ]
    }

    private static var backends: [SettingsSearchEntry] {
        [
            e("backends.enabled", String(localized: "Enabled (DISABLED_BACKENDS)"), .backends, String(localized: "Backends"),
              ["disable", "hide", "wireguard", "openvpn", "defguard", "cisco", "DISABLED_BACKENDS", "вимкнути", "увімкнути", "бекенд"]),
            e("backends.tools", String(localized: "Found Tools"), .backends, String(localized: "Found Tools"),
              ["wg-quick", "openvpn", "defguard-client", "vpn", "binary", "path", "інструменти", "шлях"]),
            e("backends.defguardCLI", "DEFGUARD_CLI", .backends, String(localized: "Paths"),
              ["defguard", "defguard-client", "symlink", "path", "шлях", "симлінк"]),
        ]
    }

    private static var openvpn: [SettingsSearchEntry] {
        let routeFix = "Route-fix"
        return [
            e("openvpn.profilesDir", "OVPN_PROFILES_DIR", .openvpn, String(localized: "Profiles"),
              [".ovpn", "profiles", "folder", "OpenVPN Connect", "профілі", "тека"]),
            e("openvpn.username", "OVPN_USERNAME", .openvpn, String(localized: "Login"),
              ["username", "login", "auth.txt", "user", "логін", "користувач"]),
            e("openvpn.rememberUser", String(localized: "Remember the Username per OpenVPN Profile and Cisco Host (+ state.env for the CLI)"),
              .openvpn, String(localized: "Login"), ["remember", "username", "cisco", "запамʼятовувати", "логін"]),
            e("openvpn.lanGateway", "LAN_GATEWAY", .openvpn, routeFix,
              ["gateway", "route-fix", "router", "шлюз", "маршрут"]),
            e("openvpn.rememberGateway", String(localized: "Remember the Gateway Choice per Profile (+ state.env)"),
              .openvpn, routeFix, ["gateway", "remember", "шлюз", "запамʼятовувати"]),
            e("openvpn.routeFixList", String(localized: "Route-fix per profile"), .openvpn, routeFix,
              ["profile", "policy", "ask", "never", "профіль", "політика", "питати", "ніколи"]),
            e("openvpn.timeout", String(localized: "Connection timeout"), .openvpn, String(localized: "Connection"),
              ["timeout", "seconds", "таймаут", "секунд", "очікування"]),
        ]
    }

    private static var dns: [SettingsSearchEntry] {
        let after = String(localized: "After a VPN Disconnects"), guardG = String(localized: "DNS Restore After WireGuard")
        let doctor = "Doctor", split = "Split DNS (/etc/resolver)"
        return [
            e("dns.restoreDNS", "RESTORE_DNS", .dns, after, ["restore", "dns", "servers", "повернути", "днс", "сервери"]),
            e("dns.autoRestore", String(localized: "Restore DNS after down (WireGuard / OpenVPN)"), .dns, after,
              ["restore", "down", "disconnect", "відновлювати", "відключення"]),
            e("dns.services", "DNS_SERVICES", .dns, after, ["services", "wi-fi", "ethernet", "сервіси"]),
            e("dns.guard", String(localized: "Restore the Services’ DNS as Soon as WireGuard Disconnects"), .dns, guardG,
              ["guard", "wireguard", "wg-quick", "baseline", "еталон", "охорона", "повернення"]),
            e("dns.baseline", String(localized: "Baseline"), .dns, guardG,
              ["baseline", "reset", "restore now", "еталон", "скинути", "повернути зараз"]),
            e("dns.watch", String(localized: "Check the Resolver in the Background"), .dns, doctor,
              ["doctor", "probe", "dig", "resolver", "перевіряти", "резолвер", "лікар"]),
            e("dns.autoFix", String(localized: "Auto DNS Fix When No VPN Is Up"), .dns, doctor,
              ["auto fix", "repair", "orphaned", "автоматично", "ремонт", "осиротілі"]),
            e("dns.split", split, .dns, split, ["split", "resolver", "domain", "/etc/resolver", "домен", "правила"]),
        ]
    }

    private static var network: [SettingsSearchEntry] {
        [
            e("network.order", String(localized: "Service Priority"), .network, String(localized: "Service Priority"),
              ["order", "primary", "wi-fi", "ethernet", "to top", "порядок", "пріоритет", "первинний", "на верх"]),
            e("network.autoFix", String(localized: "Auto-fix: Primary Without Internet → Move a Working One Up"), .network,
              String(localized: "Automation"), ["net auto", "internet", "auto", "інтернет", "автоматика"]),
        ]
    }

    private static var helper: [SettingsSearchEntry] {
        let g = "Privileged helper"
        return [
            e("helper.status", String(localized: "Status"), .helper, g,
              ["helper", "daemon", "root", "password", "демон", "пароль", "стан"]),
            e("helper.install", String(localized: "Install"), .helper, g,
              ["install", "reinstall", "remove", "login items", "встановити", "перевстановити", "видалити"]),
        ]
    }

    private static var advanced: [SettingsSearchEntry] {
        let config = String(localized: "Configuration")
        return [
            e("advanced.shared", String(localized: "Shared with the CLI Repository (main-vpn-manager.sh)"), .advanced, config,
              ["cli", "repository", "repo", "standalone", "config.env", "state.env", "репозиторій", "окремий режим"]),
            e("advanced.repoPath", String(localized: "Repository Folder"), .advanced, config,
              ["folder", "path", "repo", "тека", "шлях"]),
            e("advanced.openConfig", String(localized: "Open config.env"), .advanced, config,
              ["config.env", "edit", "folder", "відкрити", "конфіг"]),
            e("advanced.reset", String(localized: "Reset App Settings"), .advanced, String(localized: "Reset"),
              ["reset", "defaults", "clear", "скинути", "очистити"]),
        ]
    }
}
