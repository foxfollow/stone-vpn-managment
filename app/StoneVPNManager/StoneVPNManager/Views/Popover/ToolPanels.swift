import SwiftUI
import StoneVPNCore

// MARK: DNS

struct DNSPanel: View {
    @Bindable var model: AppModel
    @State private var setValue = ""
    @State private var editing: String?          // домен правила, що редагується; "" = нове
    @State private var editDomain = ""
    @State private var editServers = ""
    @State private var customOpen = false
    @State private var customValue = ""

    var body: some View {
        let n = model.snap.network
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Resolver").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if n.dnsServers.isEmpty { Text("(empty)").foregroundStyle(.red) }
                        ForEach(n.dnsServers, id: \.self) { s in
                            let ok = model.dnsProbes[s]
                            Mono(s + (ok == true ? " ✓" : ok == false ? " ✗" : ""))
                                .foregroundStyle(ok == false ? .red : ok == true ? .green : .primary)
                        }
                    }
                }
                GridRow {
                    Text("Owner").foregroundStyle(.secondary)
                    Text(n.dnsOwnerLabel ?? n.dnsOwner ?? "—")
                }
                if !n.orphanDNS.isEmpty {
                    GridRow {
                        Text("Orphaned").foregroundStyle(.secondary)
                        Text("\(n.orphanDNS.count) resolvers of dead tunnels").foregroundStyle(.orange)
                    }
                }
            }

            primaryPicker
            if customOpen { customEditor }
            if model.snap.network.dnsOverride != nil, !model.snap.network.displacedDNS.isEmpty {
                let n = model.snap.network
                let displaced = n.displacedDNS.map { n.dnsServiceLabels[$0] ?? $0 }.joined(separator: ", ")
                Text("Displaced while chosen: \(displaced). Their internal domains go through split DNS.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button("Fix DNS") { Task { await model.runDNSFix() } }
                    .buttonStyle(.borderedProminent).disabled(model.doctorRunning)
                Button("Flush") { model.flushDNS() }.buttonStyle(.bordered)
                if model.doctorRunning { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            if !model.doctorLog.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.doctorLog.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            if let p = model.doctorPrompt { takeDown(p) }

            splitSection

            DisclosureGroup("Set DNS on a Service") {
                HStack(spacing: 6) {
                    TextField(String("1.1.1.1 8.8.8.8"), text: $setValue).textFieldStyle(.roundedBorder)
                    Button("On the Primary") {
                        let servers = setValue.split(separator: " ").map(String.init)
                        model.runAction("DNS") {
                            let svcs = await model.actions.services()
                            guard let svc = svcs.first(where: { !$0.device.isEmpty && $0.device == n.primaryIface })?.name
                                    ?? model.config.dnsServices.first else { throw ActionError(String(localized: "no service")) }
                            try await model.actions.setDNS(services: [svc], servers: servers)
                            let value = servers.isEmpty ? "empty" : servers.joined(separator: " ")
                            return String(localized: "DNS of “\(svc)” → \(value)")
                        }
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
            .font(.system(size: 12))
        }
        .onAppear {
            model.loadSplit()
            if setValue.isEmpty { setValue = model.config.restoreDNS.isEmpty ? "1.1.1.1" : model.config.restoreDNS }
        }
    }

    // MARK: основний DNS

    /// Єдиний catch-all резолвер: чужі (Cisco/Defguard) на час вибору відсуваються (CatchAllDNS).
    private var primaryPicker: some View {
        HStack(spacing: 8) {
            Text("Primary").foregroundStyle(.secondary)
            Menu {
                Button { model.setPrimaryDNS(nil) } label: {
                    checked(String(localized: "Chosen by the System"), model.primaryDNSChoice == nil)
                }
                ForEach([DNSCandidate.Kind.tunnel, .foreign, .fixed], id: \.self) { k in
                    let group = model.dnsCandidates.filter { $0.kind == k }
                    if !group.isEmpty { Divider() }
                    ForEach(group) { c in
                        Button { model.setPrimaryDNS(c) } label: {
                            checked("\(c.label) — \(c.servers.joined(separator: ", "))", model.primaryDNSChoice == c.id)
                        }
                    }
                }
                Button("Custom…") {
                    customValue = model.prefs.customDNS.joined(separator: " ")
                    customOpen = true
                }
            } label: {
                Text(primaryLabel).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Whose DNS to ask first for all domains. Other VPNs’ catch-all entries are moved aside meanwhile and put back on reset. A tunnel’s DNS resets by itself when the tunnel goes down.")
        }
    }

    /// Свій основний DNS: адреси через пробіл/кому, зберігаються як вибір «Свій».
    private var customEditor: some View {
        let servers = customValue.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let bad = servers.filter { Parse.ipv4($0) == nil && !$0.contains(":") }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField(String("9.9.9.9 149.112.112.112"), text: $customValue).textFieldStyle(.roundedBorder)
                Button("Cancel") { customOpen = false }
                Button("Apply") {
                    model.prefs.customDNS = servers
                    customOpen = false
                    Task {
                        await model.loadDNSCandidates()
                        model.setPrimaryDNS(model.dnsCandidates.first { $0.id == "custom" })
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(servers.isEmpty || !bad.isEmpty)
            }
            .controlSize(.small)
            if !bad.isEmpty { Text("Not an IP: \(bad.joined(separator: ", "))").font(.system(size: 10.5)).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private func checked(_ t: String, _ on: Bool) -> some View {
        if on { Label(t, systemImage: "checkmark") } else { Text(t) }
    }

    private var primaryLabel: String {
        switch model.primaryDNSChoice {
        case nil: return String(localized: "system")
        case "custom"?: return (model.snap.network.dnsOverride ?? []).joined(separator: ", ")
        case let id?: return model.dnsCandidates.first { $0.id == id }?.label ?? id
        }
    }

    // MARK: split

    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Split DNS").font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if editing == nil {
                    Button { startEdit(nil) } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.borderless).font(.system(size: 11.5))
                }
            }
            if model.splitRules.isEmpty, editing == nil {
                Text("No rules — a tunnel’s internal domains can be sent to its DNS.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(model.splitRules, id: \.domain) { r in
                if editing == r.domain {
                    editor(old: r.domain)
                } else {
                    let warn = model.splitWarnings(domain: r.domain, servers: r.servers)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if !warn.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10)) }
                            Mono("\(r.domain) → \(r.servers.joined(separator: " "))")
                            Spacer(minLength: 4)
                            Button { startEdit(r) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("Edit the rule")
                            Button { model.removeSplit(r.domain) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).help("Remove the rule")
                        }
                        ForEach(warn, id: \.self) { Text($0).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            if editing == "" { editor(old: nil) }
            Text("Neither Cisco nor wg-quick touch files in /etc/resolver — a durable way to resolve a tunnel’s internal domains.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private func editor(old: String?) -> some View {
        let servers = editServers.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let warn = editDomain.isEmpty ? [] : model.splitWarnings(domain: editDomain, servers: servers)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(String("corp.internal"), text: $editDomain).textFieldStyle(.roundedBorder)
                TextField(String("10.8.0.1"), text: $editServers).textFieldStyle(.roundedBorder).frame(width: 120)
                if model.dnsCandidates.contains(where: { $0.kind != .fixed }) {
                    Menu {
                        ForEach(model.dnsCandidates.filter { $0.kind != .fixed }) { c in
                            Button(String("\(c.label) — \(c.servers.joined(separator: ", "))")) { editServers = c.servers.first ?? "" }
                        }
                    } label: { Image(systemName: "network") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("DNS of an active tunnel")
                }
            }
            ForEach(warn, id: \.self) { Text($0).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }
                Button(old == nil ? "Add" : "Save") {
                    model.saveSplit(old: old, domain: editDomain.trimmingCharacters(in: .whitespaces).lowercased(), servers: servers)
                    editing = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(editDomain.isEmpty || servers.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func startEdit(_ r: (domain: String, servers: [String])?) {
        editDomain = r?.domain ?? ""
        editServers = r?.servers.joined(separator: " ") ?? ""
        editing = r?.domain ?? ""
    }

    @ViewBuilder private func takeDown(_ p: DoctorPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch p {
            case .defguard(let name, let iface):
                Text("Tunnel \(iface) is held by Defguard “\(name)”. Disconnect it via defguard-client?")
            case .kill(let procs, let iface, let owner):
                let who = owner ?? String(localized: "Tunnel")
                Text("\(who) (\(iface)) — processes that may be holding it:")
                if procs.isEmpty { Text("none found — disconnect the VPN in its app").foregroundStyle(.secondary) }
                ForEach(procs, id: \.pid) { pr in
                    Text(verbatim: "PID \(pr.pid) · \(pr.label)").font(.system(size: 11, design: .monospaced))
                }
            }
            HStack {
                Button("Take Down") { Task { await model.confirmTakeDown() } }
                    .buttonStyle(.borderedProminent).tint(.red)
                Button("Cancel") { model.doctorPrompt = nil }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: Routes

struct RoutesPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        let n = model.snap.network
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Default").foregroundStyle(.secondary)
                    Text([n.defaultRouteIface, n.defaultRouteGateway.map { "via \($0)" }].compactMap { $0 }.joined(separator: " ").ifEmpty(String(localized: "none")))
                        .foregroundStyle(n.defaultRouteIface == nil ? .red : .primary)
                }
                GridRow {
                    Text("Primary").foregroundStyle(.secondary)
                    Text(verbatim: "\(n.primaryService ?? "—") (\(n.primaryIface ?? "—"))")
                }
            }
            if let d = n.defaultRouteIface, let p = n.primaryIface, d != p {
                Text("The routing table and SystemConfiguration disagree — normal with two defaults (scoped + regular).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if !n.splitDefault.isEmpty {
                Text("0/1 + 128.0/1 hijack → \(n.splitDefault.joined(separator: ", ")): a full-tunnel VPN carries all traffic.")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.snap.routeGroups.isEmpty { Text("No live tunnels").foregroundStyle(.secondary) }
            ForEach(model.snap.routeGroups) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(g.iface) · \(g.owner ?? String(localized: "owner unknown"))  \(g.address)").font(.system(size: 11.5, weight: .semibold))
                    if g.routes.isEmpty { Text("(none)").foregroundStyle(.secondary) }
                    ForEach(Array(g.routes.enumerated()), id: \.offset) { _, r in
                        Mono(r.dest + (r.via.map { "  via \($0)" } ?? ""), size: 11).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.snap.routeFixRoutes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route-fix (to VPN servers, around the tunnel)").font(.system(size: 11.5, weight: .semibold))
                    ForEach(model.snap.routeFixRoutes, id: \.self) { r in
                        Mono("\(r.dest)  via \(r.gateway) (\(r.iface))", size: 11).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.prefs.routeDecisions.isEmpty || !model.prefs.allowedForeign.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Decisions").font(.system(size: 11.5, weight: .semibold))
                    ForEach(model.prefs.routeDecisions.sorted(by: { $0.key < $1.key }), id: \.key) { d in
                        let p = RouteIssue.parseDecisionKey(d.key)
                        HStack(spacing: 4) {
                            let scope = p.network.map { String(localized: "network “\(model.prefs.networkNames[$0] ?? $0)”") }
                                ?? String(localized: "all networks")
                            let verdict = d.value == "keep" ? String(localized: "accepted") : String(localized: "direct via LAN")
                            Text("\(p.profile.replacingOccurrences(of: ":", with: " · ")) via \(p.owner) · \(scope): \(verdict)")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button { model.resetRouteDecision(d.key) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                                .buttonStyle(.borderless).help("Reset — ask again")
                        }
                    }
                    ForEach(model.prefs.allowedForeign, id: \.self) { name in
                        HStack(spacing: 4) {
                            Text("\(name) may hold the network").foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button { model.allowForeign(name, false) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                                .buttonStyle(.borderless).help("Warn again")
                        }
                    }
                }
                .textSelection(.disabled)
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: Network

struct NetworkPanel: View {
    @Bindable var model: AppModel
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.services.isEmpty, loading { ProgressView().controlSize(.small) }
            ForEach(model.services) { s in
                HStack(spacing: 8) {
                    Text(verbatim: "\(s.order)").foregroundStyle(.secondary).monospacedDigit().frame(width: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(s.name).foregroundStyle(s.enabled ? .primary : .secondary)
                            Text(verbatim: "· \(s.device.isEmpty ? (s.hwPort.isEmpty ? "VPN" : s.hwPort) : s.device)").foregroundStyle(.secondary)
                        }
                        if let dns = model.serviceDNS[s.name], !dns.isEmpty, s.enabled {
                            Mono("DNS " + dns.joined(separator: " "), size: 10.5).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    let st = state(s)
                    HStack(spacing: 5) { StatusDot(color: st.1); Text(st.0) }.font(.system(size: 11)).foregroundStyle(st.1)
                    if s.order > 1, s.enabled {
                        Button { model.runAction(String(localized: "Order")) { try await model.actions.moveToTop(s.name); await model.loadServices(); return String(localized: "“\(s.name)” is now first") } } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .buttonStyle(.borderless)
                        .help("To the top of the service order")
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Auto") {
                    model.runAction(String(localized: "Network")) { try await model.actions.netAuto(primaryIface: model.snap.network.primaryIface) }
                }
                .buttonStyle(.borderedProminent)
                Button("Check") { Task { loading = true; await model.loadServices(); loading = false } }.buttonStyle(.bordered)
                if loading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            Text("The highest service with a gateway becomes primary — even without internet. Auto moves the first working one up.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .task { loading = true; await model.loadServices(); loading = false }
    }

    private func state(_ s: NetworkService) -> (String, Color) {
        if !s.enabled { return (String(localized: "disabled"), .secondary) }
        let primary = !s.device.isEmpty && s.device == model.snap.network.primaryIface
        if s.isVPN {
            let live = model.snap.sessions.contains { $0.backend == .defguard && $0.name == s.name && $0.state == .up }
            return (live ? String(localized: "connected") : String(localized: "VPN service"), live ? .green : .secondary)
        }
        guard Interfaces.ipv4()[s.device] != nil else { return (String(localized: "no IP"), .secondary) }
        switch model.serviceOnline[s.name] {
        case true?: return (primary ? "online · primary" : "online", .green)
        case false?: return (primary ? String(localized: "primary · no internet") : String(localized: "no internet"), .red)
        case nil: return (primary ? "primary" : "…", .secondary)
        }
    }
}

extension String {
    func ifEmpty(_ alt: String) -> String { isEmpty ? alt : self }
}
