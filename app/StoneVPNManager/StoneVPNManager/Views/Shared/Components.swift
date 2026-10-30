import SwiftUI
import StoneVPNCore

extension Backend {
    var color: Color {
        switch self {
        case .wireguard: Color(red: 0.77, green: 0.22, blue: 0.24)
        case .openvpn: Color(red: 0.83, green: 0.45, blue: 0.11)
        case .defguard: Color(red: 0.06, green: 0.56, blue: 0.52)
        case .cisco: Color(red: 0.18, green: 0.44, blue: 0.84)
        }
    }
}

struct BackendBadge: View {
    var backend: Backend?
    var size: CGFloat = 24
    var text: String?

    var body: some View {
        Text(text ?? backend?.badge ?? "NE")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(backend?.color ?? .purple, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

extension ProfileStatus {
    var color: Color {
        switch self {
        case .off: .secondary
        case .busy, .connecting, .unknown: .orange
        case .up: .green
        case .retry, .failed, .stale: .red
        }
    }

    var trackColor: Color {
        switch self {
        case .off, .failed: Color.secondary.opacity(0.35)
        default: color
        }
    }
}

/// Перемикач профілю: колір доріжки = стан (зелений / помаранчевий / червоний).
struct ProfileSwitch: View {
    var status: ProfileStatus
    var small = false
    var label: String
    var action: () -> Void

    var body: some View {
        let w: CGFloat = small ? 30 : 38, h: CGFloat = small ? 18 : 23
        Button(action: action) {
            ZStack(alignment: status.isActive ? .trailing : .leading) {
                Capsule().fill(status.trackColor)
                Group {
                    if case .busy = status {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    }
                }
                .frame(width: h - 4, height: h - 4)
                .padding(2)
            }
            .frame(width: w, height: h)
            .animation(.snappy(duration: 0.18), value: status.isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(status.isActive ? "увімкнено" : "вимкнено")
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }
}

struct Mono: View {
    var text: String
    var size: CGFloat = 11.5
    init(_ t: String, size: CGFloat = 11.5) { text = t; self.size = size }
    var body: some View { Text(text).font(.system(size: size, design: .monospaced)) }
}
