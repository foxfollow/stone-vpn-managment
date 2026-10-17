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
                Text("Немає запиту на підключення").foregroundStyle(.secondary).frame(width: 400, height: 120)
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
                warning("Сесію скинуто на сервері — тунель «підключений», але трафік не ходить. Введи новий код: застосунок сам відключить і підключить локацію.")
            }

            if r.guiRunning {
                warning(p.backend == .defguard
                        ? "Defguard.app запущений — він зупиняє MFA-сесію, підняту з CLI, і просить код у своєму вікні. Його буде закрито перед підключенням (тунелі тримає системне розширення)."
                        : "Відкрито GUI Cisco Secure Client — CLI і GUI не можуть керувати агентом одночасно. Його закриють перед підключенням (тунель тримає vpnagentd).")
            }

            if r.needsAuth {
                field("Логін") {
                    TextField("", text: bind(\.username)).textFieldStyle(.roundedBorder).focused($focus, equals: .user)
                }
                field("Пароль / OTP", hint: "Не зберігається (логін — запам'ятовується для профілю). Тимчасовий auth-файл видаляється після підключення.") {
                    SecureField("", text: bind(\.password)).textFieldStyle(.roundedBorder).focused($focus, equals: .pass)
                }
            }

            if r.mfa {
                field("MFA-код (\(p.mfa ?? "TOTP"))", hint: "Передається як --code; порожній код буде відхилено.") {
                    TextField("123456", text: bind(\.code)).textFieldStyle(.roundedBorder).focused($focus, equals: .code)
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
                Button("Налаштування профілю…") {
                    model.openProfiles(p.backend, select: p.key)
                }
                .buttonStyle(.borderless).font(.system(size: 12))
                Spacer()
                Button("Скасувати") { close() }.keyboardShortcut(.cancelAction)
                Button(r.reconnect ? "Оновити" : "Підключити") { submit() }
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
        field("Хост", hint: "Можна з портом: host:8448. Новий хост збережеться у списку профілів.") {
            HStack(spacing: 6) {
                TextField("vpn.example.com:443", text: bind(\.host)).textFieldStyle(.roundedBorder).focused($focus, equals: .host)
                    .font(.system(size: 13, design: .monospaced))
                if !r.hostOptions.isEmpty {
                    Menu {
                        ForEach(r.hostOptions, id: \.self) { h in
                            Button(h) { model.connect?.host = h; Task { await model.probeCiscoGroups() } }
                        }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .onSubmit { Task { await model.probeCiscoGroups() } }
        }
        HStack(alignment: .top, spacing: 10) {
            field("Група", hint: groupHint(r)) {
                HStack(spacing: 6) {
                    if r.groupsLoading {
                        ProgressView().controlSize(.small)
                        Text("Отримую групи…").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    } else if !r.groups.isEmpty, r.groupsFor == r.host {
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
                    .disabled(r.groupsLoading || r.host.isEmpty)
                    .help(r.guiRunning ? "Закрити GUI Cisco і отримати групи з сервера" : "Отримати групи з сервера")
                }
            }
            field("Логін") {
                TextField("", text: bind(\.username)).textFieldStyle(.roundedBorder).focused($focus, equals: .user)
            }
        }
        field("Пароль", hint: "Не зберігається; передається клієнту Cisco лише на запит Password.") {
            SecureField("", text: bind(\.password)).textFieldStyle(.roundedBorder).focused($focus, equals: .pass)
        }
        DisclosureGroup("Другий фактор (Duo / OTP)") {
            VStack(alignment: .leading, spacing: 4) {
                SecureField("порожньо = Duo push", text: bind(\.secondPassword)).textFieldStyle(.roundedBorder)
                Text("Якщо сервер питає другий фактор, порожнє поле надсилає «push» — підтверди вхід у Duo на телефоні. Або введи passcode.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 12))
        if let b = r.banner {
            ScrollView { Text(b).font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 90)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        HStack {
            Spacer()
            Button("Відкрити в Terminal замість цього") { model.ciscoInTerminal(r.host) }
                .buttonStyle(.borderless).font(.system(size: 11))
        }
    }

    private func groupHint(_ r: ConnectRequest) -> String {
        if let n = r.groupsNote { return n }
        if r.groupsLoading { return "Питаю сервер, які групи доступні (без входу)" }
        if !r.groups.isEmpty, r.groupsFor == r.host { return "Список із сервера" }
        return "Порожньо = за замовчуванням"
    }

    private func gatewayPicker(_ plan: RouteFixPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Route-fix шлюз для \(plan.need.map { "\($0.host) (\($0.ip))" }.joined(separator: ", "))")
                .font(.system(size: 12, weight: .semibold))
            ForEach(plan.candidates, id: \.gw) { c in gwOption(c.gw, c.label) }
            gwOption("", "Пропустити route-fix")
            HStack {
                Text("Інший IP").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("192.168.0.1", text: bind(\.gateway)).textFieldStyle(.roundedBorder).frame(width: 140)
            }
            if plan.candidates.contains(where: { $0.label.contains("тунель") }) {
                Text("Сервер за іншим VPN, але маршруту до нього немає? Обери шлюз тунелю.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Toggle("Запам'ятати для профілю й більше не питати", isOn: Binding(
                get: { model.connect?.rememberGateway ?? false }, set: { model.connect?.rememberGateway = $0 }))
                .font(.system(size: 12))
            Text("Без галочки останній вибір просто буде обраний наступного разу. Змінити політику — Профілі → профіль.")
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

    private func field<C: View>(_ label: String, hint: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold))
            c()
            if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
    }

    private func warning(_ t: String) -> some View {
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
        model.connect = nil
        dismissWindow(id: "connect")
    }
}
