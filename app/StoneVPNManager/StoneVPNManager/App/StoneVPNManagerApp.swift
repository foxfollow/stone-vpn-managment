import SwiftUI
import StoneVPNCore

@main
struct StoneVPNManagerApp: App {
    @State private var model = AppModel.shared

    init() {
        if CommandLine.arguments.contains("--dump-status") { Self.dumpStatus() }
        AppModel.shared.start()
    }

    /// Діагностика без UI: знімок стану текстом (порівнювати з `main-vpn-manager.sh status`).
    static func dumpStatus() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let cfg = RepoConfig.load(explicitRepo: UserDefaults.standard.string(forKey: "repoPath"),
                                      standalone: UserDefaults.standard.bool(forKey: "standalone"))
            let s = await StatusReader(priv: HelperClient()).snapshot(config: cfg, forceSlow: true)
            var out = ["config: \(cfg.repo?.path ?? "—") (\(cfg.sharedWithCLI ? "CLI repo" : "standalone"))  disabled: \(cfg.disabled.map(\.rawValue).sorted())"]
            let n = s.network
            out.append("primary: \(n.primaryService ?? "—") \(n.primaryIface ?? "—") router \(n.router ?? "—")")
            out.append("dns: \(n.dnsServers.joined(separator: " ")) owner: \(n.dnsOwnerLabel ?? n.dnsOwner ?? "—") orphans: \(n.orphanDNS.count)")
            out.append("default route: \(n.defaultRouteIface ?? "—") via \(n.defaultRouteGateway ?? "—") split: \(n.splitDefault)")
            for b in Backend.allCases { out.append("\(b.badge) profiles: \((s.profiles[b] ?? []).map { p in p.title.map { "\(p.name) = \($0)" } ?? p.name })") }
            for x in s.sessions + s.foreign {
                out.append("session \(x.backend?.badge ?? "NE") \(x.name) \(x.state) \(x.iface ?? "-") \(x.address ?? "-") \(x.elapsed ?? "") routes=\(x.routes)")
            }
            for g in s.routeGroups { out.append("utun \(g.iface) \(g.address) owner=\(g.owner ?? "?") \(g.routes.count) routes") }
            for r in s.routeFixRoutes { out.append("route-fix \(r.dest) via \(r.gateway) (\(r.iface))") }
            print(out.joined(separator: "\n"))
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(nsImage: MenuIcon.image(tone: model.tone, count: model.snap.upCount,
                                          colored: model.prefs.iconColored, showCount: model.prefs.iconShowCount,
                                          label: model.prefs.iconShowName ? activeName : nil))
                .renderingMode(model.prefs.iconColored ? .original : .template)
                .accessibilityLabel("StoneVPN: \(model.headline)")
        }
        .menuBarExtraStyle(.window)

        Window("Профілі", id: "profiles") {
            ProfilesView(model: model)
        }
        .defaultSize(width: 980, height: 620)

        Window("Підключення", id: "connect") {
            ConnectView(model: model)
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)

        Settings {
            SettingsView(model: model)
        }
    }

    private var activeName: String? {
        model.snap.sessions.first { $0.state == .up }.map { s in
            s.profileKey.flatMap { k in model.snap.profiles.values.joined().first { $0.key == k } }.map(model.prefs.display) ?? s.name
        }
    }
}
