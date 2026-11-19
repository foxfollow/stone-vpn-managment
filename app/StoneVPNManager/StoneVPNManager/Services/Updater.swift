import Foundation
import Sparkle

/// Sparkle: фід — docs/appcast.xml на GitHub Pages (SUFeedURL), архів підписаний EdDSA
/// (SUPublicEDKey). Працює лише в релізах із CI (`StoneVPNUpdates` = YES): локальна
/// збірка підписана Team ID і не прийняла б ad-hoc-оновлення — її оновлюють з git.
@MainActor
final class Updater {
    static let shared = Updater()

    let enabled: Bool
    private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let flag = (info["StoneVPNUpdates"] as? String)?.uppercased() == "YES"
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        enabled = flag && !key.isEmpty
        controller = enabled
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    var version: String {
        let i = Bundle.main.infoDictionary ?? [:]
        return "\(i["CFBundleShortVersionString"] as? String ?? "?") (\(i["CFBundleVersion"] as? String ?? "?"))"
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
