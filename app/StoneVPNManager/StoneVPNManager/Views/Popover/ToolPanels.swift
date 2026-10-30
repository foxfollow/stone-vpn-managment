import SwiftUI
import StoneVPNCore

// MARK: DNS

struct DNSPanel: View {
    @Bindable var model: AppModel
    @State private var setValue = ""
    @State private var editing: String?          // домен правила, що редагується; "" = нове
    @State private var editDomain = ""
    @State private var editServers = ""

    var body: some View {
        let n = model.snap.network
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Resolver").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if n.dnsServers.isEmpty { Text("(порожньо)").foregroundStyle(.red) }
                        ForEach(n.dnsServers, id: \.self) { s in
                            let ok = model.dnsProbes[s]
                            Mono(s + (ok == true ? " ✓" : ok == false ? " ✗" : ""))
                                .foregroundStyle(ok == false ? .red : ok == true ? .green : .primary)
                        }
                    }
                }
                GridRow {
                    Text("Власник").foregroundStyle(.secondary)
                    Text(n.dnsOwnerLabel ?? n.dnsOwner ?? "—")
                }
                if !n.orphanDNS.isEmpty {
                    GridRow {
                        Text("Осиротілі").foregroundStyle(.secondary)
                        Text("\(n.orphanDNS.count) резолвер(и) мертвих тунелів").foregroundStyle(.orange)
                    }
                }
            }

            primaryPicker
            if model.snap.network.dnsOverride != nil, !model.snap.network.displacedDNS.isEmpty {
                let n = model.snap.network
                Text("Відсунуто на час вибору: " + n.displacedDNS.map { n.dnsServiceLabels[$0] ?? $0 }.joined(separator: ", ") +
                     ". Їхні внутрішні домени — через split DNS.")
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

            DisclosureGroup("Встановити DNS на сервіс") {
                HStack(spacing: 6) {
                    TextField("1.1.1.1 8.8.8.8", text: $setValue).textFieldStyle(.roundedBorder)
                    Button("На первинний") {
                        let servers = setValue.split(separator: " ").map(String.init)
                        model.runAction("DNS") {
                            let svcs = await model.actions.services()
                            guard let svc = svcs.first(where: { !$0.device.isEmpty && $0.device == n.primaryIface })?.name
                                    ?? model.config.dnsServices.first else { throw ActionError("немає сервісу") }
                            try await model.actions.setDNS(services: [svc], servers: servers)
                            return "DNS «\(svc)» → \(servers.isEmpty ? "empty" : servers.joined(separator: " "))"
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
            Text("Основний").foregroundStyle(.secondary)
            Menu {
                Button { model.setPrimaryDNS(nil) } label: {
                    checked("Як вирішила система", model.primaryDNSChoice == nil)
                }
                if !model.dnsCandidates.isEmpty { Divider() }
                ForEach(model.dnsCandidates) { c in
                    Button { model.setPrimaryDNS(c) } label: {
                        checked("\(c.label) — \(c.servers.joined(separator: ", "))", model.primaryDNSChoice == c.id)
                    }
                }
            } label: {
                Text(primaryLabel).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.dnsCandidates.isEmpty && model.snap.network.dnsOverride == nil)
            .help("Чий DNS питати першим для всіх доменів. Catch-all записи інших VPN на цей час відсуваються і повертаються при скиданні. Скидається сам, коли обраний тунель падає.")
        }
    }

    @ViewBuilder private func checked(_ t: String, _ on: Bool) -> some View {
        if on { Label(t, systemImage: "checkmark") } else { Text(t) }
    }

    private var primaryLabel: String {
        switch model.primaryDNSChoice {
        case nil: return model.dnsCandidates.isEmpty ? "система (немає DNS тунелів)" : "система"
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
                    Button { startEdit(nil) } label: { Label("Додати", systemImage: "plus") }
                        .buttonStyle(.borderless).font(.system(size: 11.5))
                }
            }
            if model.splitRules.isEmpty, editing == nil {
                Text("Правил немає — внутрішні домени тунелю можна направити на його DNS.").font(.system(size: 11)).foregroundStyle(.secondary)
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
                                .buttonStyle(.borderless).help("Редагувати правило")
                            Button { model.removeSplit(r.domain) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless).help("Прибрати правило")
                        }
                        ForEach(warn, id: \.self) { Text($0).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            if editing == "" { editor(old: nil) }
            Text("Файли в /etc/resolver не чіпають ні Cisco, ні wg-quick — стійкий спосіб резолвити внутрішні домени тунелю.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    private func editor(old: String?) -> some View {
        let servers = editServers.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let warn = editDomain.isEmpty ? [] : model.splitWarnings(domain: editDomain, servers: servers)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("corp.internal", text: $editDomain).textFieldStyle(.roundedBorder)
                TextField("10.8.0.1", text: $editServers).textFieldStyle(.roundedBorder).frame(width: 120)
                if !model.dnsCandidates.isEmpty {
                    Menu {
                        ForEach(model.dnsCandidates) { c in
                            Button("\(c.label) — \(c.servers.joined(separator: ", "))") { editServers = c.servers.first ?? "" }
                        }
                    } label: { Image(systemName: "network") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("DNS активного тунелю")
                }
            }
            ForEach(warn, id: \.self) { Text($0).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Скасувати") { editing = nil }
                Button(old == nil ? "Додати" : "Зберегти") {
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
                Text("Тунель \(iface) тримає Defguard «\(name)». Від'єднати через defguard-client?")
            case .kill(let procs, let iface, let owner):
                Text("\(owner ?? "Тунель") (\(iface)) — процеси, що можуть його тримати:")
                if procs.isEmpty { Text("не знайдено — відключи VPN у його застосунку").foregroundStyle(.secondary) }
                ForEach(procs, id: \.pid) { pr in
                    Text("PID \(pr.pid) · \(pr.label)").font(.system(size: 11, design: .monospaced))
                }
            }
            HStack {
                Button("Розірвати") { Task { await model.confirmTakeDown() } }
                    .buttonStyle(.borderedProminent).tint(.red)
                Button("Скасувати") { model.doctorPrompt = nil }.buttonStyle(.bordered)
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
                    Text([n.defaultRouteIface, n.defaultRouteGateway.map { "via \($0)" }].compactMap { $0 }.joined(separator: " ").ifEmpty("відсутній"))
                        .foregroundStyle(n.defaultRouteIface == nil ? .red : .primary)
                }
                GridRow {
                    Text("Primary").foregroundStyle(.secondary)
                    Text("\(n.primaryService ?? "—") (\(n.primaryIface ?? "—"))")
                }
            }
            if let d = n.defaultRouteIface, let p = n.primaryIface, d != p {
                Text("Таблиця маршрутів і SystemConfiguration розходяться — це нормально при двох default (scoped + звичайний).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if !n.splitDefault.isEmpty {
                Text("Перехоплення 0/1 + 128.0/1 → \(n.splitDefault.joined(separator: ", ")): повнотунельний VPN тримає весь трафік.")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.snap.routeGroups.isEmpty { Text("Немає живих тунелів").foregroundStyle(.secondary) }
            ForEach(model.snap.routeGroups) { g in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(g.iface) · \(g.owner ?? "власник невідомий")  \(g.address)").font(.system(size: 11.5, weight: .semibold))
                    if g.routes.isEmpty { Text("(немає)").foregroundStyle(.secondary) }
                    ForEach(Array(g.routes.enumerated()), id: \.offset) { _, r in
                        Mono(r.dest + (r.via.map { "  via \($0)" } ?? ""), size: 11).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.snap.routeFixRoutes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route-fix (до VPN-серверів повз тунель)").font(.system(size: 11.5, weight: .semibold))
                    ForEach(model.snap.routeFixRoutes, id: \.self) { r in
                        Mono("\(r.dest)  via \(r.gateway) (\(r.iface))", size: 11).foregroundStyle(.secondary)
                    }
                }
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
                    Text("\(s.order)").foregroundStyle(.secondary).monospacedDigit().frame(width: 14, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(s.name).foregroundStyle(s.enabled ? .primary : .secondary)
                            Text("· \(s.device.isEmpty ? (s.hwPort.isEmpty ? "VPN" : s.hwPort) : s.device)").foregroundStyle(.secondary)
                        }
                        if let dns = model.serviceDNS[s.name], !dns.isEmpty, s.enabled {
                            Mono("DNS " + dns.joined(separator: " "), size: 10.5).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    let st = state(s)
                    HStack(spacing: 5) { StatusDot(color: st.1); Text(st.0) }.font(.system(size: 11)).foregroundStyle(st.1)
                    if s.order > 1, s.enabled {
                        Button { model.runAction("Порядок") { try await model.actions.moveToTop(s.name); await model.loadServices(); return "«\(s.name)» тепер перший" } } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .buttonStyle(.borderless)
                        .help("На верх порядку сервісів")
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Auto") {
                    model.runAction("Мережа") { try await model.actions.netAuto(primaryIface: model.snap.network.primaryIface) }
                }
                .buttonStyle(.borderedProminent)
                Button("Перевірити") { Task { loading = true; await model.loadServices(); loading = false } }.buttonStyle(.bordered)
                if loading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            Text("Первинним стає найвищий сервіс зі шлюзом — навіть без інтернету. Auto піднімає перший робочий.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .task { loading = true; await model.loadServices(); loading = false }
    }

    private func state(_ s: NetworkService) -> (String, Color) {
        if !s.enabled { return ("вимкнено", .secondary) }
        let primary = !s.device.isEmpty && s.device == model.snap.network.primaryIface
        if s.isVPN {
            let live = model.snap.sessions.contains { $0.backend == .defguard && $0.name == s.name && $0.state == .up }
            return (live ? "підключено" : "VPN-сервіс", live ? .green : .secondary)
        }
        guard Interfaces.ipv4()[s.device] != nil else { return ("немає IP", .secondary) }
        switch model.serviceOnline[s.name] {
        case true?: return (primary ? "online · primary" : "online", .green)
        case false?: return (primary ? "primary · без інтернету" : "без інтернету", .red)
        case nil: return (primary ? "primary" : "…", .secondary)
        }
    }
}

extension String {
    func ifEmpty(_ alt: String) -> String { isEmpty ? alt : self }
}
