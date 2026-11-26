import SwiftUI
import StoneVPNCore

struct PopoverView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// MenuBarExtra не обмежує вікно екраном: розгорнуті панелі (Network з десятком сервісів)
    /// виводили низ поповера за край. Середина скролиться, заголовок і футер лишаються на місці.
    @State private var bodyHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0
    @State private var screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    banner
                    ProviderList(model: model)
                    tools
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(height: min(bodyHeight, maxBodyHeight))
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            model.openWindowAction = openWindow
            model.popoverOpen = true
            screenHeight = Self.currentScreenHeight()
            Task { await model.refresh() }
        }
        .onDisappear { model.popoverOpen = false }
    }

    /// Висота екрана мінус заголовок/футер/відступи і запас під menu bar та тінь вікна.
    private var maxBodyHeight: CGFloat {
        max(160, screenHeight - headerHeight - footerHeight - 14 * 2 - 12 * 2 - 24)
    }

    /// Поповер відкривається на екрані, де клікнули по іконці.
    private static func currentScreenHeight() -> CGFloat {
        let p = NSEvent.mouseLocation
        let s = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        return s?.visibleFrame.height ?? 800
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
                .help("Refresh")
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    Text("Network").foregroundStyle(.secondary)
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
        case .question: .yellow
        }
    }

    private var netLine: String {
        let n = model.snap.network
        guard let i = n.primaryIface else { return String(localized: "no primary interface") }
        let owner = n.primaryIsTunnel ? model.snap.routeGroups.first { $0.iface == i }?.owner : nil
        return [owner ?? n.primaryService, i, n.router.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    private var netState: (String, Color) {
        switch model.primaryOnline {
        case true?: (String(localized: "online"), .green)
        case false?: (String(localized: "no internet"), .red)
        case nil: (model.snap.network.primaryIface == nil ? String(localized: "offline") : "—", model.snap.network.primaryIface == nil ? .red : .secondary)
        }
    }

    private var dnsState: (String, Color) {
        switch model.dnsHealthy {
        case true?: (String(localized: "responding"), .green)
        case false?: (String(localized: "not responding"), .red)
        case nil: ("—", .secondary)
        }
    }

    private func stateTag(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 5) { StatusDot(color: c); Text(t) }.foregroundStyle(c).gridColumnAlignment(.trailing)
    }

    // MARK: banner

    @ViewBuilder private var banner: some View {
        let n = model.snap.network
        if model.tone == .foreign, let f = model.primaryForeign {
            Banner(color: .purple,
                   text: model.dnsHealthy == false
                       ? String(localized: "\(f.name) (\(f.iface ?? "")) holds the default route and DNS, but passes no traffic. DNS edits won't help.")
                       : String(localized: "\(f.name) (\(f.iface ?? "")) holds the default route and DNS."),
                   action: String(localized: "Take Down…"),
                   secondary: model.dnsHealthy == false ? nil : (String(localized: "Allow"), { model.allowForeign(f.name) }),
                   close: { model.foreignDismissed.insert(f.id) }) {
                model.openTool = "dns"; Task { await model.runDNSFix() }
            }
        } else if let name = model.dgStale.sorted().first, model.busy.isEmpty {
            Banner(color: .red,
                   text: model.dnsFailover.map {
                       String(localized: "Defguard “\(name)” shows “connected”, but the gateway no longer accepts the session (slept past the threshold). DNS is temporarily on \($0.joined(separator: " ")).")
                   } ?? String(localized: "Defguard “\(name)” shows “connected”, but the gateway no longer accepts the session (slept past the threshold)."),
                   action: String(localized: "Renew")) { model.renewDefguard(name) }
        } else if model.dnsGuardActive, model.busy.isEmpty {
            Banner(color: .orange, text: String(localized: "VPN disconnected — watching DNS and restoring the services' baseline servers until the resolver works."),
                   action: String(localized: "Fix Now")) { model.openTool = "dns"; Task { await model.runDNSFix() } }
        } else if model.dnsHealthy == false, model.busy.isEmpty {
            Banner(color: .red,
                   text: String(localized: "Resolver \(n.dnsServers.first ?? "") isn't responding — ping hangs. Fix checks orphaned DNS and bounces the service."),
                   action: String(localized: "Fix DNS")) { model.openTool = "dns"; Task { await model.runDNSFix() } }
        } else if model.primaryOnline == false {
            let svc = n.primaryService ?? n.primaryIface ?? String(localized: "The primary service")
            Banner(color: .red, text: String(localized: "\(svc) has no internet — macOS picks by service order, not by reachability."),
                   action: String(localized: "Auto")) { model.runAction(String(localized: "Network")) { try await model.actions.netAuto(primaryIface: n.primaryIface) } }
        }
        if let p = model.helperProblem {
            Banner(color: .orange, text: p.message,
                   action: model.helperReinstalling ? String(localized: "Reinstalling…")
                       : p == .needsApproval ? String(localized: "Login Items…")
                       : p == .notInstalled ? String(localized: "Install Helper")
                       : p.isNotAllowed ? String(localized: "Take Over…") : String(localized: "Reinstall Helper"),
                   close: p == .notInstalled || p.isNotAllowed ? { model.dismissHelperOffer() } : nil) {
                model.fixHelper()
            }
        }
        ForEach(model.routeIssues) { i in
            Banner(color: .orange,
                   text: String(localized: "\(i.label): server \(i.host) goes via \(i.viaOwner) (\(i.via)) — a tunnel inside a tunnel. It works, but slower, and reconnecting \(i.viaOwner) drops the session.")
                         + (i.networkLabel.map { " " + String(localized: "The decision applies to the network “\($0)”.") } ?? ""),
                   action: i.gateway.map { String(localized: "Direct · \($0)") } ?? String(localized: "Accept"),
                   secondary: i.gateway == nil ? nil : (String(localized: "Accept"), { model.keepRoute(i) })) {
                if i.gateway != nil { model.directRoute(i) } else { model.keepRoute(i) }
            }
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
        return (s.isEmpty ? "—" : s) + (model.dnsHealthy == false ? " · " + String(localized: "dead") : "") + split
    }

    private var routesSummary: String {
        let n = model.snap.network
        let g = model.snap.routeGroups.count
        return "default → \(n.defaultRouteIface ?? "—") · \(g) utun" + (n.splitDefault.isEmpty ? "" : " · 0/1 → \(n.splitDefault.joined(separator: ","))")
    }

    private var netSummary: String {
        let n = model.snap.network
        let base = "\(n.primaryService ?? "—") (\(n.primaryIface ?? "—"))"
        return model.primaryOnline == false ? String(localized: "\(base) no internet") : base
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button("Disconnect All", role: .destructive) { model.disconnectAll() }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(model.snap.sessions.isEmpty)
            Spacer()
            Button("Profiles…") { model.openProfiles(model.rows.first?.backend ?? .wireguard) }.buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
    }
}

struct Banner: View {
    var color: Color
    var text: String
    var action: String
    var secondary: (String, () -> Void)? = nil
    /// × у куті — сховати банер (що саме це означає, вирішує викликач).
    var close: (() -> Void)? = nil
    var perform: () -> Void

    /// Підпис на заливці кольору банера: на світлих (жовтий/помаранчевий) — темний.
    private var onTint: Color { color == .orange || color == .yellow ? .black : .white }

    var body: some View {
        HStack(spacing: 10) {
            // Колір банера — лише тексту: на кнопках він давав жовте на жовтому.
            Text(text).font(.system(size: 12)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Button(action: perform) { Text(action).foregroundStyle(onTint) }
                    .buttonStyle(.borderedProminent).tint(color).controlSize(.small)
                if let sec = secondary { Button(sec.0, action: sec.1).buttonStyle(.bordered).controlSize(.small) }
            }
        }
        .padding(10)
        .padding(.trailing, close == nil ? 0 : 8)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let close {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).padding(6)
                    .help("Hide until the app restarts")
            }
        }
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
