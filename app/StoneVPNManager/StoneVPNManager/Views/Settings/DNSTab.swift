import SwiftUI
import StoneVPNCore

struct DNSTab: View {
    @Bindable var model: AppModel
    @State private var all: [NetworkService] = []

    var body: some View {
        Form {
            RepoWarning(model: model)
            Section("After a VPN Disconnects") {
                ConfigField(model: model, label: "RESTORE_DNS", key: "RESTORE_DNS", value: model.config.restoreDNS, prompt: "1.1.1.1 8.8.8.8",
                            hint: "Empty = leave DNS alone. Defguard and Cisco restore their own — only a flush for them.")
                    .settingsAnchor("dns.restoreDNS")
                Toggle("Restore DNS after down (WireGuard / OpenVPN)", isOn: $model.prefs.autoRestoreDNS)
                    .settingsAnchor("dns.autoRestore")
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
                .settingsAnchor("dns.services")
            }
            Section("DNS Restore After WireGuard") {
                Toggle("Restore the Services’ DNS as Soon as WireGuard Disconnects", isOn: $model.prefs.dnsGuard)
                    .settingsAnchor("dns.guard")
                Text("wg-quick puts the tunnel DNS on every service and doesn't always put the old one back. While no WG is up and the resolver responds, the app remembers each service's DNS (the baseline). After down it watches for up to a minute and restores the baseline on services still holding the tunnel DNS; if the resolver is still silent, it runs Fix. Before every connect the same happens right away, so the new VPN's address resolves. In the background — only with the helper.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.prefs.dnsBaseline.isEmpty {
                    Text("No baseline yet — it appears after a minute without WG and with working DNS.").foregroundStyle(.secondary)
                }
                ForEach(model.prefs.dnsBaseline.keys.sorted(), id: \.self) { svc in
                    LabeledContent(svc) {
                        Mono(model.prefs.dnsBaseline[svc]!.isEmpty ? "DHCP" : model.prefs.dnsBaseline[svc]!.joined(separator: " "), size: 12)
                    }
                }
                if !model.prefs.wgDNSSeen.isEmpty {
                    LabeledContent("Tunnel DNS (never taken into the baseline)") { Mono(model.prefs.wgDNSSeen.joined(separator: " "), size: 12) }
                }
                HStack {
                    Button("Restore Now") { Task { await model.restoreServiceDNS(background: false) } }
                    Button("Reset Baseline", role: .destructive) { model.prefs.dnsBaseline = [:] }
                }
                .settingsAnchor("dns.baseline")
            }
            Section("Doctor") {
                Toggle("Check the Resolver in the Background", isOn: $model.prefs.dnsWatch)
                    .settingsAnchor("dns.watch")
                Toggle("Auto DNS Fix When No VPN Is Up", isOn: $model.prefs.autoDNSFix)
                    .disabled(!model.prefs.dnsWatch)
                    .settingsAnchor("dns.autoFix")
                Text("If DNS doesn't respond and there are no tunnels (ours, foreign, utun), it's a leftover of a dead VPN, and DNS Fix runs by itself: removes orphaned resolvers and bounces the service. At most once every 2 min. Needs the helper — otherwise just a notification.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("dig apple.com with a 2 s timeout every 30 s and on DNS changes; on failure the icon turns red.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Split DNS (/etc/resolver)") {
                if model.splitRules.isEmpty { Text("No rules").foregroundStyle(.secondary) }
                ForEach(model.splitRules, id: \.domain) { r in
                    LabeledContent(r.domain) { Mono(r.servers.joined(separator: " "), size: 12) }
                }
                Text("Add or remove them in the popover: DNS → Set DNS / split.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .settingsAnchor("dns.split")
            }
        }
        .formStyle(.grouped)
        .task {
            all = await model.actions.services()
            model.loadSplit()
        }
    }
}
