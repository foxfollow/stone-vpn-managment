import SwiftUI
import StoneVPNCore

struct PopoverView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            banner
            ProviderList(model: model)
            tools
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            model.openWindowAction = openWindow
            model.popoverOpen = true
            Task { await model.refresh() }
        }
        .onDisappear { model.popoverOpen = false }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(toneColor).frame(width: 10, height: 10)
                Text(model.headline).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { Task { await model.refresh(forceSlow: true) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Оновити")
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Налаштування")
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    Text("Мережа").foregroundStyle(.secondary)
                    Text(netLine).lineLimit(1).truncationMode(.middle)
                    stateTag(netState.0, netState.1)
                }
                GridRow {
                    Text("DNS").foregroundStyle(.secondary)
                    Mono(model.snap.network.dnsServers.isEmpty ? "—" : model.snap.network.dnsServers.joined(separator: "  "))
                        .lineLimit(1).truncationMode(.tail)
                    stateTag(dnsState.0, dnsState.1)
                }
            }
            .font(.system(size: 12))
        }
    }

    private var toneColor: Color {
        switch model.tone {
        case .idle: .secondary
        case .ok: .green
        case .busy: .orange
        case .problem: .red
        case .foreign: .purple
        }
    }

    private var netLine: String {
        let n = model.snap.network
        guard let i = n.primaryIface else { return "немає первинного інтерфейсу" }
        let owner = n.primaryIsTunnel ? model.snap.routeGroups.first { $0.iface == i }?.owner : nil
        return [owner ?? n.primaryService, i, n.router.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var netState: (String, Color) {
        switch model.primaryOnline {
        case true?: ("online", .green)
        case false?: ("без інтернету", .red)
        case nil: (model.snap.network.primaryIface == nil ? "offline" : "—", model.snap.network.primaryIface == nil ? .red : .secondary)
        }
    }

    private var dnsState: (String, Color) {
        switch model.dnsHealthy {
        case true?: ("відповідає", .green)
        case false?: ("не відповідає", .red)
        case nil: ("—", .secondary)
        }
    }

    private func stateTag(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) { StatusDot(color: c); Text(t) }.foregroundStyle(c).gridColumnAlignment(.trailing)
    }

    // MARK: banner

    @ViewBuilder private var banner: some View {
        let n = model.snap.network
        if model.tone == .foreign, let f = model.snap.foreign.first(where: { $0.iface == n.primaryIface }) {
            Banner(color: .purple,
                   text: "\(f.name) (\(f.iface ?? "")) тримає default route і DNS" + (model.dnsHealthy == false ? ", але не пропускає трафік. Правки DNS не допоможуть." : "."),
                   action: "Розірвати…") { model.openTool = "dns"; Task { await model.runDNSFix() } }
        } else if model.dnsHealthy == false {
            Banner(color: .red,
                   text: "Резолвер \(n.dnsServers.first ?? "") не відповідає — ping «висить». Fix перевірить осиротілі DNS і переб'є сервіс.",
                   action: "Fix DNS") { model.openTool = "dns"; Task { await model.runDNSFix() } }
        } else if model.primaryOnline == false {
            Banner(color: .red, text: "\(n.primaryService ?? n.primaryIface ?? "Первинний сервіс") без інтернету — macOS обирає за порядком сервісів, не за доступністю.",
                   action: "Auto") { model.runAction("Мережа") { try await model.actions.netAuto(primaryIface: n.primaryIface) } }
        }
        if let t = model.toast {
            HStack(alignment: .top) {
                Text(t).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { model.toast = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.borderless)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: tools

    private var tools: some View {
        VStack(spacing: 0) {
            ToolRow(id: "dns", title: "DNS", summary: dnsSummary, summaryColor: model.dnsHealthy == false ? .red : .secondary, open: $model.openTool) {
                DNSPanel(model: model)
            }
            Divider()
            ToolRow(id: "routes", title: "Routes", summary: routesSummary, summaryColor: model.snap.network.splitDefault.isEmpty ? .secondary : .orange, open: $model.openTool) {
                RoutesPanel(model: model)
            }
            Divider()
            ToolRow(id: "net", title: "Network", summary: netSummary, summaryColor: model.primaryOnline == false ? .red : .secondary, open: $model.openTool) {
                NetworkPanel(model: model)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var dnsSummary: String {
        let s = model.snap.network.dnsServers.joined(separator: ", ")
        let split = model.splitRules.isEmpty ? "" : " · split \(model.splitRules.count)"
        return (s.isEmpty ? "—" : s) + (model.dnsHealthy == false ? " · мертвий" : "") + split
    }

    private var routesSummary: String {
        let n = model.snap.network
        let g = model.snap.routeGroups.count
        return "default → \(n.defaultRouteIface ?? "—") · \(g) utun" + (n.splitDefault.isEmpty ? "" : " · 0/1 → \(n.splitDefault.joined(separator: ","))")
    }

    private var netSummary: String {
        let n = model.snap.network
        return "\(n.primaryService ?? "—") (\(n.primaryIface ?? "—"))" + (model.primaryOnline == false ? " без інтернету" : "")
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button("Відключити все", role: .destructive) { model.disconnectAll() }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(model.snap.sessions.isEmpty)
            Spacer()
            Button("Профілі…") { model.openProfiles(model.rows.first?.backend ?? .wireguard) }.buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
    }
}

struct Banner: View {
    var color: Color
    var text: String
    var action: String
    var perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: perform).buttonStyle(.borderedProminent).tint(color).controlSize(.small)
        }
        .foregroundStyle(color)
        .padding(10)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ToolRow<Content: View>: View {
    var id: String
    var title: String
    var summary: String
    var summaryColor: Color
    @Binding var open: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { open = open == id ? nil : id }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open == id ? 90 : 0))
                    Text(title).fontWeight(.semibold).frame(width: 62, alignment: .leading)
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(summaryColor).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open == id ? .isSelected : [])
            if open == id {
                content()
                    .padding(.leading, 32)
                    .padding([.trailing, .bottom], 12)
                    .font(.system(size: 12))
            }
        }
    }
}
