import SwiftUI
import StoneVPNCore

struct DNSTab: View {
    @Bindable var model: AppModel
    @State private var all: [NetworkService] = []

    var body: some View {
        Form {
            RepoWarning(model: model)
            Section("Після відключення VPN") {
                ConfigField(model: model, label: "RESTORE_DNS", key: "RESTORE_DNS", value: model.config.restoreDNS, prompt: "1.1.1.1 8.8.8.8",
                            hint: "Порожньо = DNS не чіпати. Defguard і Cisco відновлюють свій самі — для них лише flush.")
                Toggle("Відновлювати DNS після down (WireGuard / OpenVPN)", isOn: $model.prefs.autoRestoreDNS)
                LabeledContent("DNS_SERVICES") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(all.filter { $0.enabled && !$0.isVPN }) { s in
                            Toggle(s.name, isOn: Binding(get: { model.config.dnsServices.contains(s.name) }, set: { on in
                                var list = model.config.dnsServices
                                if on { list.append(s.name) } else { list.removeAll { $0 == s.name } }
                                model.updateConfig { $0.setArray("DNS_SERVICES", list) }
                            }))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            Section("Повернення DNS після WireGuard") {
                Toggle("Повертати DNS сервісів, щойно WireGuard відключено", isOn: $model.prefs.dnsGuard)
                Text("wg-quick ставить DNS тунелю на всі сервіси і не завжди повертає старий. Поки WG немає і резолвер відповідає, застосунок запам'ятовує DNS кожного сервісу (еталон). Після down — до хвилини стежить і повертає еталон тим сервісам, де лишився DNS тунелю; якщо резолвер усе одно мовчить — запускає Fix. Перед кожним підключенням те саме робиться одразу, щоб адреса нового VPN резолвилась. У фоні — лише з helper.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.prefs.dnsBaseline.isEmpty {
                    Text("Еталон ще не знято — з'явиться за хвилину без WG і з живим DNS.").foregroundStyle(.secondary)
                }
                ForEach(model.prefs.dnsBaseline.keys.sorted(), id: \.self) { svc in
                    LabeledContent(svc) {
                        Mono(model.prefs.dnsBaseline[svc]!.isEmpty ? "DHCP" : model.prefs.dnsBaseline[svc]!.joined(separator: " "), size: 12)
                    }
                }
                if !model.prefs.wgDNSSeen.isEmpty {
                    LabeledContent("DNS тунелів (не беруться в еталон)") { Mono(model.prefs.wgDNSSeen.joined(separator: " "), size: 12) }
                }
                HStack {
                    Button("Повернути зараз") { Task { await model.restoreServiceDNS(background: false) } }
                    Button("Скинути еталон", role: .destructive) { model.prefs.dnsBaseline = [:] }
                }
            }
            Section("Doctor") {
                Toggle("Перевіряти резолвер у фоні", isOn: $model.prefs.dnsWatch)
                Toggle("Auto DNS fix, коли жодного VPN немає", isOn: $model.prefs.autoDNSFix)
                    .disabled(!model.prefs.dnsWatch)
                Text("Якщо DNS не відповідає, а тунелів (наших, сторонніх, utun) немає — це залишок мертвого VPN, і DNS Fix запускається сам: прибирає осиротілі резолвери і перебиває сервіс. Не частіше раз на 2 хв. Потрібен helper — інакше лише сповіщення.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("dig apple.com з таймаутом 2 с раз на 30 с і при зміні DNS; при відмові іконка стає червоною.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Split DNS (/etc/resolver)") {
                if model.splitRules.isEmpty { Text("Правил немає").foregroundStyle(.secondary) }
                ForEach(model.splitRules, id: \.domain) { r in
                    LabeledContent(r.domain) { Mono(r.servers.joined(separator: " "), size: 12) }
                }
                Text("Додати/прибрати — у поповері: DNS → Встановити DNS / split.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            all = await model.actions.services()
            model.loadSplit()
        }
    }
}
