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
        }
    }
}

extension AppModel {
    static let helperCategory = "helper"

    /// На старті після оновлення/перезбирання застосунку: заміна бандла скидає реєстрацію демона
    /// (статус «не встановлено»), а якщо ні — launchd не запускає новий бінарник helper-а.
    /// В обох випадках перереєструвати одразу, поки ніщо не почало питати пароль.
    func ensureHelperCurrent() async {
        helperStatus = helper.status
        // Лише копія з /Applications: Debug-збірка з DerivedData не має перереєстровувати демона на себе.
        if Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            if helper.wanted == nil, helperStatus == .enabled { helper.wanted = true }  // встановлено до цієї версії
            let stale = helperStatus == .enabled && !helper.registeredForThisBuild
            let lost = helperStatus == .notRegistered && helper.wanted == true
            if stale || lost {
                await reinstallHelper(auto: true)
                return
            }
        }
        await checkHelper()
    }

    /// Кнопка «Reinstall» (налаштування, банер, сповіщення) і авто-перевстановлення після оновлення.
    func reinstallHelper(auto: Bool = false) async {
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
        if helperStatus == .requiresApproval, !auto { SMAppService.openSystemSettingsLoginItems() }
        if helperProblem == nil {
            toast = auto ? String(localized: "The helper was re-registered for this version of the app.")
                         : String(localized: "Helper reinstalled.")
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
            if let v = helperVersion { v < HelperConst.version ? .outdated(v) : nil } else { .unreachable }
        case .notRegistered: helper.wanted == false ? nil : .notInstalled
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
        // «Не встановлено» — лише банер: сповіщення про це було б нав'язливим.
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
        default: Task { await reinstallHelper() }
        }
    }

    /// × на банері «встанови helper»: більше не пропонувати (у налаштуваннях лишається).
    func dismissHelperOffer() {
        helper.wanted = false
        updateHelperProblem()
    }
}
