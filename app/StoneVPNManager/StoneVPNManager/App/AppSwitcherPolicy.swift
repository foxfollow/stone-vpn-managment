import AppKit

/// Cmd+Tab показує лише застосунки з activationPolicy .regular — а це завжди ще й іконка в Dock
/// (окремо їх не розділити публічним API). Тож поки відкрите звичайне вікно (Профілі, Налаштування,
/// Підключення) — .regular, коли закрите останнє — назад .accessory (як LSUIElement).
/// Поповер MenuBarExtra — NSPanel без заголовка, він не рахується.
@MainActor
final class AppSwitcherPolicy {
    static let shared = AppSwitcherPolicy()
    var enabled = true { didSet { update() } }
    private var observers: [NSObjectProtocol] = []

    func start(enabled: Bool) {
        self.enabled = enabled
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                // willClose приходить, поки вікно ще видиме — перевіряємо на наступному циклі.
                DispatchQueue.main.async { MainActor.assumeIsolated { AppSwitcherPolicy.shared.update() } }
            })
        }
    }

    private func hasAppWindow(_ app: NSApplication) -> Bool {
        app.windows.contains { w in
            w.isVisible && w.styleMask.contains(.titled) && !(w is NSPanel) && w.level.rawValue < NSWindow.Level.statusBar.rawValue
        }
    }

    func update() {
        // start() викликається з App.init — NSApplication ще не створено (NSApp == nil).
        guard let app = NSApp else { return }
        let want: NSApplication.ActivationPolicy = enabled && hasAppWindow(app) ? .regular : .accessory
        guard app.activationPolicy() != want else { return }
        app.setActivationPolicy(want)
        // Зміна політики може зняти фокус — повернути його відкритому вікну.
        if want == .regular { app.activate() }
    }
}
