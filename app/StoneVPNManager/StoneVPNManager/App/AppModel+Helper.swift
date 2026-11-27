import Foundation
import ServiceManagement
import UserNotifications
import StoneVPNShared

/// Що не так із зареєстрованим helper-ом. Поки проблема є, кожна привілейована дія питає пароль.
enum HelperProblem: Equatable {
    /// Демон старішого протоколу, ніж знає застосунок.
    case outdated(Int)
    /// Зареєстрований, але не відповідає: найчастіше застосунок оновили/перезібрали, а launchd
    /// не запускає новий бінарник до перереєстрації.
    case unreachable
    /// Чекає дозволу в System Settings → Login Items.
    case needsApproval
    /// Не встановлено, і користувач ще не вирішував (банер без сповіщення, закривається).
    case notInstalled
    /// Демон належить іншому користувачу Mac і не обслуговує цього (HelperAccessPolicy) — дії з паролем.
    case notAllowed(owner: String?)

    var isNotAllowed: Bool { if case .notAllowed = self { true } else { false } }

    var message: String {
        switch self {
        case .outdated(let v):
            String(localized: "The helper is outdated (v\(v), the app needs v\(HelperConst.version)), so every privileged action asks for the password. Reinstall it.")
        case .unreachable:
            String(localized: "The helper doesn't respond (usually after the app was updated), so every privileged action asks for the password. Reinstall it.")
        case .needsApproval:
            String(localized: "The helper waits for your approval in System Settings → Login Items; until then every privileged action asks for the password.")
        case .notInstalled:
            String(localized: "Install the helper so connecting, DNS fixes and routes stop asking for the administrator password.")
        case .notAllowed(let owner?):
            String(localized: "The helper belongs to \(owner), so privileged actions ask for the administrator password. \(owner) can allow administrators or everyone in Settings → Helper.")
        case .notAllowed(nil):
            String(localized: "The helper has no owner yet, so privileged actions ask for the administrator password. Take it over in Settings → Helper.")
        }
    }
}

extension AppModel {
    static let helperCategory = "helper"
    static let notAllowedDismissedKey = "helperNotAllowedDismissed"

    /// На старті після оновлення/перезбирання застосунку: заміна бандла скидає реєстрацію демона
    /// (статус «не встановлено»), а якщо ні — launchd не запускає новий бінарник helper-а.
    /// Сам не перереєструємо: реєстрація запускає бінарник із бандла від root, а бандл у
    /// /Applications належить користувачу — підмінений helper став би root без його відома.
    /// Тож лише банер + сповіщення з «Reinstall Helper» (updateHelperProblem).
    func ensureHelperCurrent() async {
        helperStatus = helper.status
        if helper.wanted == nil, helperStatus == .enabled { helper.wanted = true }  // встановлено до цієї версії
        await checkHelper()
    }

    /// Кнопка «Reinstall» (налаштування, банер, сповіщення) — завжди дія користувача.
    func reinstallHelper() async {
        guard !helperReinstalling else { return }
        helperReinstalling = true
        defer { helperReinstalling = false }
        var failure: String?
        do { try await helper.reinstall() } catch { failure = error.localizedDescription }
        // launchd піднімає нового демона не миттєво.
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(1))
            await checkHelper()
            if helperVersion != nil || helperStatus != .enabled { break }
        }
        if helperStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        if helperProblem == nil {
            toast = String(localized: "Helper reinstalled.")
        } else if let failure {
            toast = "Helper: \(failure)"
        }
    }

    /// XPC до зареєстрованого демона впав — перевірити й, якщо справді мертвий, показати проблему.
    func helperDidNotRespond() async {
        guard !helperReinstalling, helperProblem == nil else { return }
        await checkHelper()
    }

    func updateHelperProblem() {
        let problem: HelperProblem? = switch helperStatus {
        case .requiresApproval: .needsApproval
        case .enabled:
            if let v = helperVersion {
                v < HelperConst.version ? .outdated(v)
                    : helperAccess?.callerAllowed == false && !UserDefaults.standard.bool(forKey: Self.notAllowedDismissedKey)
                        ? .notAllowed(owner: helperAccess?.ownerName) : nil
            } else { .unreachable }
        // Хотів helper, а реєстрації немає — бандл замінили (оновлення / make install).
        case .notRegistered: helper.wanted == true ? .unreachable : helper.wanted == false ? nil : .notInstalled
        default: nil
        }
        guard problem != helperProblem else { return }
        helperProblem = problem
        let center = UNUserNotificationCenter.current()
        guard let problem else {
            center.removeDeliveredNotifications(withIdentifiers: [Self.helperCategory])
            helperNotified = nil
            return
        }
        // «Не встановлено» / «чужий helper» — лише банер: сповіщення було б нав'язливим.
        if case .notAllowed = problem { return }
        guard helperNotified != problem, !helperReinstalling, problem != .notInstalled else { return }
        helperNotified = problem
        let c = UNMutableNotificationContent()
        c.title = String(localized: "StoneVPN helper needs attention")
        c.body = problem.message
        c.categoryIdentifier = Self.helperCategory
        center.add(UNNotificationRequest(identifier: Self.helperCategory, content: c, trigger: nil))
    }

    /// Дія з банера / сповіщення.
    func fixHelper() {
        switch helperProblem {
        case .needsApproval: SMAppService.openSystemSettingsLoginItems()
        case .notInstalled: installHelper()
        case .notAllowed: Task { await claimHelper() }
        default: Task { await reinstallHelper() }
        }
    }

    /// Хто може користуватися helper-ом (власник у налаштуваннях; інший — з паролем адміністратора).
    func setHelperAccess(_ p: HelperAccessPolicy) async {
        let r = await helper.setAccessPolicy(p)
        if !r.ok { toast = "Helper: \(r.output)" }
        await checkHelper()
    }

    /// Забрати helper собі (пароль адміністратора): попередній власник втрачає доступ, якщо політика «лише власник».
    func claimHelper() async {
        let r = await helper.claimAccess()
        if !r.ok { toast = "Helper: \(r.output)" }
        await checkHelper()
    }

    /// × на банері «встанови helper»: більше не пропонувати (у налаштуваннях лишається).
    func dismissHelperOffer() {
        if case .notAllowed = helperProblem {
            UserDefaults.standard.set(true, forKey: Self.notAllowedDismissedKey)   // чужий helper: не нагадувати
        } else {
            helper.wanted = false
        }
        updateHelperProblem()
    }
}
