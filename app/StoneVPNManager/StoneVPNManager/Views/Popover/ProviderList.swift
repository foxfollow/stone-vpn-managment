import SwiftUI
import StoneVPNCore

/// Список провайдерів у поповері. Рядок: зліва — перемикач активного/останнього
/// профілю, під ним — обрані (★) та інші активні профілі, справа `›` — усі профілі.
struct ProviderList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "Providers")
                Spacer()
                Button(model.editingList ? "Done" : "Edit") {
                    withAnimation(.snappy(duration: 0.2)) { model.editingList.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
            }

            VStack(spacing: 0) {
                ForEach(model.snap.foreign) { f in
                    ForeignRow(model: model, session: f)
                    Divider()
                }
                let rows = model.rows
                if rows.isEmpty {
                    Text(model.loaded ? "No providers. Turn backends on in Settings → Backends." : "Loading…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider() }
                    ProviderCell(model: model, row: row, index: i, count: rows.count)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if model.editingList, !model.hiddenBackends.isEmpty {
                HStack(spacing: 6) {
                    Text("Hidden:").foregroundStyle(.secondary)
                    ForEach(model.hiddenBackends) { b in
                        Button("+ \(b.title)") { model.prefs.hiddenProviders.removeAll { $0 == b.rawValue } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .font(.system(size: 12))
            }
        }
    }
}

struct ProviderCell: View {
    @Bindable var model: AppModel
    var row: ProviderRow
    var index: Int
    var count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let main = row.main {
                    ProfileSwitch(status: main.status, label: switchLabel(main)) {
                        model.toggle(main)
                    }
                } else {
                    ProfileSwitch(status: .off, label: String(localized: "No profiles")) {}.disabled(true).opacity(0.4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        BackendBadge(backend: row.backend, size: 16)
                        Text(row.backend.title).fontWeight(.semibold)
                        if let main = row.main {
                            Text("·").foregroundStyle(.secondary)
                            Text(model.prefs.display(main.profile)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Text(row.main.map { subtitle($0, isMain: true) } ?? String(localized: "no profiles"))
                        .font(.system(size: 11))
                        .foregroundStyle(row.main?.status.color ?? .secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 22)
                }
                Spacer(minLength: 0)
                if let main = row.main, main.status == .stale { renewButton(main) }
                // Головний рядок — активний/останній профіль; якщо він обраний, без зірки тут
                // здавалося, що з кількох обраних показано лише ті, що в підрядках.
                if let main = row.main, !model.editingList { favoriteButton(main) }
                if model.editingList { editControls }
                Button { model.openProfiles(row.backend, select: row.main?.id) } label: {
                    HStack(spacing: 4) {
                        Text("\(row.up)/\(row.total)").foregroundStyle(row.up > 0 ? .green : .secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5).monospacedDigit())
                    .padding(.vertical, 8).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("All \(row.backend.title) profiles")
            }
            .padding(.leading, 10).padding(.trailing, 6)
            .frame(minHeight: 52)

            ForEach(row.subs) { it in
                HStack(spacing: 10) {
                    ProfileSwitch(status: it.status, small: true, label: switchLabel(it)) {
                        model.toggle(it)
                    }
                    Text(model.prefs.display(it.profile)).font(.system(size: 12.5)).lineLimit(1)
                    Text(subtitle(it, isMain: false)).font(.system(size: 11)).foregroundStyle(it.status.color).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if it.status == .stale { renewButton(it) }
                    favoriteButton(it)
                }
                .padding(.leading, 58).padding(.trailing, 10)
                .frame(minHeight: 32)
            }

            if model.editingList {
                Button { model.openProfiles(row.backend) } label: {
                    Label("Add a Favourite Profile…", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .padding(.leading, 58).padding(.bottom, 8)
            }
        }
    }

    private func favoriteButton(_ it: ProfileItem) -> some View {
        let fav = model.prefs.isFavorite(it.id)
        return Button { model.prefs.toggleFavorite(it.id) } label: {
            Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? .yellow : .secondary)
        }
        .buttonStyle(.borderless)
        .help(fav ? "Remove from Favourites" : "Add to Favourites")
    }

    private func renewButton(_ it: ProfileItem) -> some View {
        Button("Renew") { model.renewDefguard(it.profile.name) }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            .help(it.profile.mfa != nil ? "Reconnect with a new MFA code" : "Reconnect")
    }

    private var editControls: some View {
        HStack(spacing: 2) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
            Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1)
            Button { model.prefs.hiddenProviders.append(row.backend.rawValue) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
            }
            .help("Hide \(row.backend.title)")
        }
        .buttonStyle(.borderless)
    }

    /// Порядок міняємо серед видимих, зберігаючи позиції прихованих/вимкнених.
    private func move(_ delta: Int) {
        let visible = model.rows.map(\.backend)
        guard let i = visible.firstIndex(of: row.backend), visible.indices.contains(i + delta) else { return }
        let other = visible[i + delta]
        var order = model.prefs.orderedBackends
        if let a = order.firstIndex(of: row.backend), let b = order.firstIndex(of: other) { order.swapAt(a, b) }
        withAnimation(.snappy(duration: 0.2)) { model.prefs.providerOrder = order.map(\.rawValue) }
    }

    /// Підпис перемикача для VoiceOver: дія + профіль.
    private func switchLabel(_ it: ProfileItem) -> String {
        let name = model.prefs.display(it.profile)
        return it.status.isActive ? String(localized: "Disconnect \(name)") : String(localized: "Connect \(name)")
    }

    private func subtitle(_ it: ProfileItem, isMain: Bool) -> String {
        switch it.status {
        case .up:
            let s = it.session
            return [s?.iface, s?.address, s?.elapsed].compactMap { $0 }.joined(separator: " · ")
        case .busy(let t): return t
        case .connecting: return String(localized: "connecting…")
        case .retry(let e): return e
        case .unknown: return String(localized: "state unknown — the log is root-only")
        case .failed(let e): return e
        case .stale:
            return it.profile.mfa != nil ? String(localized: "session expired — a new MFA code is needed") : String(localized: "the gateway doesn't answer the handshake")
        case .off:
            let last = isMain && model.prefs.lastProfile[it.profile.backend.rawValue] == it.id
            var bits: [String] = []
            if last { bits.append(String(localized: "last used")) }
            if let e = it.profile.endpoint { bits.append(e) }
            if it.profile.mfa != nil { bits.append("MFA") }
            if it.profile.needsAuth { bits.append("OTP") }
            return bits.isEmpty ? String(localized: "off") : bits.joined(separator: " · ")
        }
    }
}

struct ForeignRow: View {
    @Bindable var model: AppModel
    var session: Session

    var body: some View {
        let primary = model.snap.network.primaryIface == session.iface
        let allowed = model.isAllowedForeign(session)
        HStack(spacing: 10) {
            BackendBadge(backend: nil, size: 26)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.name).fontWeight(.semibold)
                    Text(allowed ? "· foreign, allowed" : "· foreign").foregroundStyle(.secondary)
                }
                Text([session.iface, session.address, primary ? "default route + DNS" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(allowed ? Color.secondary : .purple)
            }
            Spacer()
            Button("Take Down…") { Task { await model.offerTakeDown(session) } }
                .buttonStyle(.bordered).tint(allowed ? nil : .purple).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
    }
}
