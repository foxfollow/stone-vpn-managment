import SwiftUI
import StoneVPNCore

/// Плаваюча панель підключення: логін/OTP, MFA-код, вибір route-fix шлюзу.
/// Окреме вікно, бо поповер MenuBarExtra закривається при втраті фокусу.
struct ConnectView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var focus: Field?
    enum Field { case host, user, pass, code }

    var body: some View {
        Group {
            if let r = model.connect {
                form(r)
            } else {
                Text("No connection request").foregroundStyle(.secondary).frame(width: 400, height: 120)
            }
        }
    }

    private func form(_ r: ConnectRequest) -> some View {
        let p = r.profile
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BackendBadge(backend: p.backend, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.prefs.display(p)).font(.system(size: 15, weight: .semibold))
                    Mono([p.endpoint, p.backend == .openvpn ? "\(p.name).ovpn" : nil].compactMap { $0 }.joined(separator: " · "), size: 11.5)
                        .foregroundStyle(.secondary)
                }
            }

            if r.reconnect {
                warning("The session was dropped on the server — the tunnel says “connected”, but no traffic flows. Enter a new code: the app will disconnect and reconnect the location itself.")
            }

            if p.backend == .cisco, let from = r.ciscoSwitchFrom {
                warning("Cisco Secure Client keeps only one session, and it is connected to \(from) now. “Switch Session” disconnects it first, then connects here; Cancel leaves it as it is.")
            }

            if r.guiRunning {
                warning(p.backend == .defguard
                        ? "Defguard.app is running — it stops an MFA session started from the CLI and asks for the code in its own window. It will be closed before connecting (the system extension keeps the tunnels)."
                        : "The Cisco Secure Client GUI is open — the CLI and the GUI can't drive the agent at the same time. It will be closed before connecting (vpnagentd keeps the tunnel).")
            }

            if r.needsAuth {
                field("Username") {
                    TextField("", text: bind(\.username)).textFieldStyle(.roundedBorder).focused($focus, equals: .user)
                }
                field("Password / OTP", hint: Text("Not stored (the username is remembered for the profile). The temporary auth file is deleted after connecting.")) {
                    SecureField("", text: bind(\.password)).textFieldStyle(.roundedBorder).focused($focus, equals: .pass)
                }
            }

            if r.mfa {
                field("MFA code (\(p.mfa ?? "TOTP"))", hint: Text("Passed as --code; an empty code will be rejected.")) {
                    TextField(String("123456"), text: bind(\.code)).textFieldStyle(.roundedBorder).focused($focus, equals: .code)
                        .font(.system(size: 15, design: .monospaced))
                }
            }

            if p.backend == .cisco { ciscoFields(r) }

            if r.askGateway, let plan = r.plan, !plan.isEmpty { gatewayPicker(plan) }

            if r.running || !r.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(r.steps.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 6) {
                            if i == r.steps.count - 1, r.running { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark").foregroundStyle(.green) }
                            Text(s)
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            if let e = r.error {
                Text(e).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }

            HStack {
                Button("Profile Settings…") {
                    model.openProfiles(p.backend, select: p.key)
                }
                .buttonStyle(.borderless).font(.system(size: 12))
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(r.reconnect ? "Renew" : (p.backend == .cisco && r.ciscoSwitchFrom != nil ? "Switch Session" : "Connect")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(r.running || (r.needsAuth && r.username.isEmpty) || (r.mfa && r.code.isEmpty)
                              || (p.backend == .cisco && (r.host.isEmpty || r.username.isEmpty || r.password.isEmpty)))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if p.backend == .cisco { focus = r.host.isEmpty ? .host : (r.username.isEmpty ? .user : .pass) }  // група — з сервера
            else { focus = r.needsAuth ? (r.username.isEmpty ? .user : .pass) : (r.mfa ? .code : nil) }
        }
    }

    /// Cisco: хост редагується (порт — host:port), дефолти — з налаштувань самого Cisco.
    @ViewBuilder private func ciscoFields(_ r: ConnectRequest) -> some View {
        field("Host", hint: Text("A port is allowed: host:8448. A new host is saved to the profile list.")) {
            HStack(spacing: 6) {
                TextField(String("vpn.example.com:443"), text: bind(\.host)).textFieldStyle(.roundedBorder).focused($focus, equals: .host)
                    .font(.system(size: 13, design: .monospaced))
                if !r.hostOptions.isEmpty {
                    Menu {
                        ForEach(r.hostOptions, id: \.self) { h in
                            Button(h) { Task { await model.selectCiscoHost(h) } }
                        }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .onSubmit { Task { await model.selectCiscoHost(model.connect?.host ?? "") } }
        }
        HStack(alignment: .top, spacing: 10) {
            field("Group", hint: Text(groupHint(r))) {
                HStack(spacing: 6) {
                    if r.groupsLoading {
                        ProgressView().controlSize(.small)
                        Text("Fetching groups…").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    } else if !r.groups.isEmpty, r.groupsFor == r.hostKey {
                        Picker("", selection: bind(\.group)) {
                            ForEach(r.groups, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    } else {
                        TextField("", text: bind(\.group)).textFieldStyle(.roundedBorder)
                    }
                    Button { Task { await model.probeCiscoGroups(closeGUI: r.guiRunning) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(r.hostKey.isEmpty || r.ciscoActive != nil)
                    .help(r.ciscoActive != nil ? "Not available while Cisco is connected: fetching groups would drop the session"
                          : r.guiRunning ? "Close the Cisco GUI and fetch groups from the server" : "Fetch groups from the server")
                }
            }
            field("Username") {
                TextField("", text: bind(\.username)).textFieldStyle(.roundedBorder).focused($focus, equals: .user)
            }
        }
        field("Password", hint: Text("Not stored; handed to the Cisco client only when it asks for Password. The username and group are remembered for this host.")) {
            SecureField("", text: bind(\.password)).textFieldStyle(.roundedBorder).focused($focus, equals: .pass)
        }
        DisclosureGroup("Second Factor (Duo / OTP)") {
            VStack(alignment: .leading, spacing: 4) {
                SecureField("empty = Duo push", text: bind(\.secondPassword)).textFieldStyle(.roundedBorder)
                Text("If the server asks for a second factor, an empty field sends “push” — approve the sign-in in Duo on your phone. Or enter a passcode.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 12))
        if let used = model.prefs.ciscoMFA[Prefs.ciscoKey(r.hostKey)] {
            Text(used ? "This server asked for a second factor last time." : "This server didn't ask for a second factor last time — no Duo push expected.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        if let b = r.banner {
            ScrollView { Text(b).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 90)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        HStack {
            Spacer()
            Button("Open in Terminal Instead") { model.ciscoInTerminal(r.host) }
                .buttonStyle(.borderless).font(.system(size: 11))
        }
    }

    private func groupHint(_ r: ConnectRequest) -> String {
        if let n = r.groupsNote { return n }
        if r.groupsLoading { return String(localized: "Asking the server which groups are available (without signing in)") }
        if !r.groups.isEmpty, r.groupsFor == r.hostKey { return String(localized: "List from the server") }
        return String(localized: "Empty = default")
    }

    private func gatewayPicker(_ plan: RouteFixPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let hosts = plan.need.map { "\($0.host) (\($0.ip))" }.joined(separator: ", ")
            Text("Route-fix gateway for \(hosts)")
                .font(.system(size: 12, weight: .semibold))
            ForEach(plan.candidates, id: \.gw) { c in gwOption(c.gw, c.label) }
            gwOption("", String(localized: "Skip route-fix"))
            HStack {
                Text("Other IP").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(String("192.168.0.1"), text: bind(\.gateway)).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            if plan.candidates.contains(where: { $0.kind == .tunnel }) {
                Text("Server behind another VPN, but no route to it? Pick the tunnel's gateway.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Toggle("Remember for this profile and don't ask again", isOn: Binding(
                get: { model.connect?.rememberGateway ?? false }, set: { model.connect?.rememberGateway = $0 }))
                .font(.system(size: 12))
            Text("Unchecked, the last choice is simply preselected next time. Change the policy in Profiles → profile.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gwOption(_ gw: String, _ label: String) -> some View {
        let on = model.connect?.gateway == gw
        return Button { model.connect?.gateway = gw } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                Mono(gw.isEmpty ? "—" : gw, size: 12)
                Spacer()
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor : Color.secondary.opacity(0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func field<C: View>(_ label: LocalizedStringKey, hint: Text? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold))
            c()
            if let hint { hint.font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
    }

    private func warning(_ t: LocalizedStringKey) -> some View {
        Label { Text(t).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.system(size: 12)).foregroundStyle(.orange)
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func bind(_ kp: WritableKeyPath<ConnectRequest, String>) -> Binding<String> {
        Binding(get: { model.connect?[keyPath: kp] ?? "" }, set: { model.connect?[keyPath: kp] = $0 })
    }

    private func submit() {
        guard var r = model.connect else { return }
        r.running = true
        r.error = nil
        r.steps = []
        model.connect = r
        Task {
            let ok = await model.perform(r)
            model.connect?.running = false
            model.connect?.password = ""
            model.connect?.secondPassword = ""
            if ok { close() }
        }
    }

    private func close() {
        Task { await model.cancelGroupsProbe() }
        model.connect = nil
        dismissWindow(id: "connect")
    }
}
