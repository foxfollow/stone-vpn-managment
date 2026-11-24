import SwiftUI

// Навігація налаштувань (як у Stone Clipboarder Tool): бічна панель зі сторінками,
// згрупованими за темою, пошук по всіх пунктах і підсвічування знайденого рядка.

/// Сторінка налаштувань.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, notifications, backends, openvpn, dns, network, helper, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .notifications: String(localized: "Notifications")
        case .backends: String(localized: "Backends")
        case .openvpn: "OpenVPN"
        case .dns: "DNS"
        case .network: String(localized: "Network")
        case .helper: "Helper"
        case .advanced: String(localized: "Advanced")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell"
        case .backends: "square.stack.3d.up"
        case .openvpn: "lock.shield"
        case .dns: "globe"
        case .network: "wifi"
        case .helper: "checkmark.shield"
        case .advanced: "slider.horizontal.3"
        }
    }

    /// Рядок під заголовком сторінки: про що вона.
    var subtitle: String {
        switch self {
        case .general: String(localized: "Language, updates, startup and the menu bar icon.")
        case .notifications: String(localized: "Which events show a notification.")
        case .backends: String(localized: "Which VPNs StoneVPN manages and where their tools are.")
        case .openvpn: String(localized: "Profiles, login and route-fix for OpenVPN.")
        case .dns: String(localized: "Restoring DNS after a VPN, the doctor and split DNS.")
        case .network: String(localized: "Network service order and its automation.")
        case .helper: String(localized: "The root daemon that runs privileged actions without a password.")
        case .advanced: String(localized: "Sharing settings with the CLI repository and resetting the app.")
        }
    }

    var group: SettingsGroup {
        switch self {
        case .general, .notifications: .app
        case .backends, .openvpn: .vpn
        case .dns, .network: .network
        case .helper, .advanced: .system
        }
    }
}

/// Група сторінок у бічній панелі.
enum SettingsGroup: CaseIterable, Identifiable {
    case app, vpn, network, system

    var id: Self { self }

    var title: String {
        switch self {
        case .app: String(localized: "App")
        case .vpn: "VPN"
        case .network: String(localized: "Network")
        case .system: String(localized: "System")
        }
    }

    var sections: [SettingsSection] { SettingsSection.allCases.filter { $0.group == self } }
}

// MARK: - Підсвічування знайденого пункту

struct SettingsHighlight: Equatable {
    var anchors: Set<String> = []
    /// Новий на кожен вибір — повторний клік по тому самому результату знову прокручує й підсвічує.
    var token = UUID()
}

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var settingsHighlightedAnchors: Set<String> {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    let anchor: String
    @Environment(\.settingsHighlightedAnchors) private var highlighted

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(highlighted.contains(anchor) ? 0.22 : 0))
                    .padding(-4)
                    .animation(.easeInOut(duration: 0.35), value: highlighted.contains(anchor))
            )
    }
}

extension View {
    /// Рядок, до якого веде пошук: `anchor` — id запису в `SettingsSearchIndex`.
    func settingsAnchor(_ anchor: String) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor))
    }
}

/// Сторінка: підзаголовок + вміст, прокрутка до знайденого рядка.
struct SettingsPage<Content: View>: View {
    let section: SettingsSection
    var highlight = SettingsHighlight()
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.subtitle)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 2)
            ScrollViewReader { proxy in
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.settingsHighlightedAnchors, highlight.anchors)
                    .onChange(of: highlight.token) { scroll(proxy) }
                    .onAppear { scroll(proxy) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Після рендеру сторінки (результат міг перемкнути сторінку).
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = highlight.anchors.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .center) }
        }
    }
}
