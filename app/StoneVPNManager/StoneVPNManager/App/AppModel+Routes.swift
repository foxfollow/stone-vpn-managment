import Foundation
import UserNotifications
import StoneVPNCore

/// Сервер нашого VPN, якого забрав повний тунель стороннього (Defguard усередині ClearVPN):
/// «?» на іконці + сповіщення з вибором «погодити / напряму». Рішення пам'ятається
/// (Prefs.routeDecisions), «напряму» далі застосовується саме (лише через helper — без пароля у фоні).
extension AppModel {
    static let routeCategory = "route"

    func checkRoutesIfDue(old: Snapshot) async {
        let n = snap.network, o = old.network
        let changed = n.defaultRouteIface != o.defaultRouteIface || n.splitDefault != o.splitDefault
            || Set(snap.sessions.map(\.id)) != Set(old.sessions.map(\.id)) || snap.upCount != old.upCount
        guard changed || Date().timeIntervalSince(lastRouteCheck) > 15 else { return }
        lastRouteCheck = Date()
        await checkRoutes()
    }

    func checkRoutes() async {
        await dropDeadDirectRoutes()
        let rows = snap.routes
        let lan = Parse.lanGateways(rows).first
        let gw = lan?.gw
        let lanNet = lan.flatMap { reader.store.lanNetwork(iface: $0.iface) }
        let net = lanNet?.id
        var netLabel: String?
        if let net, let lan {
            netLabel = prefs.networkNames[net] ?? "\(lanNet?.service ?? lan.iface) · \(lan.gw)"
            if prefs.networkNames[net] == nil { prefs.networkNames[net] = netLabel }
            migrateGlobalDecisions(to: net)
        }
        var found: [RouteIssue] = []
        for s in snap.sessions where s.state == .up {
            guard let b = s.backend, let key = s.profileKey else { continue }
            let prof = snap.profiles[b]?.first { $0.key == key }
            for host in await serverHosts(b, session: s, profile: prof) {
                guard let ip = await resolveCached(host) else { continue }
                guard let via = Parse.fullTunnelCapture(of: ip, rows: rows, own: s.iface) else {
                    adoptDirectRoute(ip: ip, profileKey: key, network: net, rows: rows)
                    continue
                }
                let owner = snap.routeGroups.first { $0.iface == via }?.owner ?? via
                found.append(RouteIssue(profileKey: key, label: "\(b.title) · \(prof.map(prefs.display) ?? s.name)",
                                        host: host, ip: ip, via: via, viaOwner: owner, gateway: gw,
                                        network: net, networkLabel: netLabel))
            }
        }
        var pending: [RouteIssue] = []
        for i in found {
            switch prefs.routeDecisions[i.decisionKey] ?? prefs.routeDecisions[i.globalKey] {
            case "keep": continue
            case "direct": if await !autoDirect(i) { pending.append(i) }
            default: pending.append(i)
            }
        }
        let fresh = pending.filter { p in !routeIssues.contains { $0.id == p.id } }
        let gone = routeIssues.filter { r in !pending.contains { $0.id == r.id } }
        routeIssues = pending
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone.map { "route:\($0.id)" })
        if prefs.notifyRoutes { for i in fresh { notifyRouteIssue(i) } }
    }

    /// Рішення зі старих версій (без мережі) належать мережі, в якій їх прийняли, — тобто поточній:
    /// у нових мережах апка знову спитає.
    private func migrateGlobalDecisions(to net: String) {
        for (k, v) in prefs.routeDecisions where RouteIssue.parseDecisionKey(k).network == nil {
            let p = RouteIssue.parseDecisionKey(k)
            let nk = RouteIssue.decisionKey(p.profile, p.owner, net)
            prefs.routeDecisions[k] = nil
            if prefs.routeDecisions[nk] == nil { prefs.routeDecisions[nk] = v }
            for (ip, val) in prefs.directRoutes where val.hasSuffix("|" + k) {
                prefs.directRoutes[ip] = String(val.dropLast(k.count)) + nk
            }
        }
    }

    /// Маршрут напряму вже стоїть (поставлений раніше, облік загубився), а для профілю в цій мережі
    /// обрано «напряму» — взяти на облік, щоб прибрати його, коли шлюз зникне з мережі.
    private func adoptDirectRoute(ip: String, profileKey: String, network: String?, rows: [RouteRow]) {
        guard prefs.directRoutes[ip] == nil,
              let row = rows.first(where: { $0.dest == ip && $0.flags.contains("H") && $0.flags.contains("S") && $0.flags.contains("G")
                                            && !Parse.isTunnelIface($0.iface) }),
              let key = prefs.routeDecisions.first(where: { k, v in
                  let p = RouteIssue.parseDecisionKey(k)
                  return v == "direct" && p.profile == profileKey && p.network == network
              })?.key else { return }
        prefs.directRoutes[ip] = "\(row.gateway)|\(key)"
    }

    /// Хости серверів сесії (як у конфігу/профілі).
    private func serverHosts(_ b: Backend, session s: Session, profile p: Profile?) async -> [String] {
        switch b {
        case .defguard: return p?.endpoint.map { [Actions.bareHost($0)] } ?? []
        case .openvpn: return p?.remotes ?? []
        case .cisco: return [Actions.bareHost(s.name)]
        case .wireguard:
            guard let p else { return [] }
            if let h = wgEndpointCache[p.key] { return [h] }
            guard let h = await actions.wgEndpointHost(p) else { return [] }
            wgEndpointCache[p.key] = h
            return [h]
        }
    }

    /// DNS може бути саме тим, що зламано, — тоді беремо останню відому адресу.
    private func resolveCached(_ host: String) async -> String? {
        if Parse.ipv4(host) != nil { return host }
        if let c = resolveCache[host], Date().timeIntervalSince(c.at) < 300 { return c.ip }
        if let ip = await Task.detached(operation: { Interfaces.resolve(host) }).value {
            resolveCache[host] = (ip, Date())
            return ip
        }
        return resolveCache[host]?.ip
    }

    /// Рішення «напряму» вже прийнято — ставимо маршрут без питань, якщо можна без пароля.
    /// false = не вдалось (немає helper / шлюзу) → показати як питання.
    private func autoDirect(_ i: RouteIssue) async -> Bool {
        guard let gw = i.gateway, helper.isEnabled else { return false }
        if let t = directAttempts[i.ip], Date().timeIntervalSince(t) < 60 { return true }
        directAttempts[i.ip] = Date()
        do {
            try await actions.setDirectRoute(ip: i.ip, gateway: gw)
            prefs.directRoutes[i.ip] = "\(gw)|\(i.decisionKey)"
            toast = String(localized: "\(i.label): server \(i.host) goes direct via \(gw) again, around \(i.viaOwner)")
            scheduleRefresh()
            return true
        } catch {
            toast = String(localized: "Direct route to \(i.host): \(error.localizedDescription)")
            return false
        }
    }

    /// Наш -host маршрут через шлюз, якого вже немає в мережі (змінився Wi-Fi), веде в нікуди і
    /// вбиває той самий VPN — прибрати. Зник сам — забути.
    private func dropDeadDirectRoutes() async {
        guard !prefs.directRoutes.isEmpty else { return }
        // Таблиця, а не `route get`: той для такого IP віддає клонований scoped-запис без STATIC.
        for ip in prefs.directRoutes.keys.sorted() {
            guard let row = snap.routes.first(where: { $0.dest == ip && $0.flags.contains("H") && $0.flags.contains("S") }) else {
                prefs.directRoutes[ip] = nil
                continue
            }
            // Шлюз сам досяжний лише через інший шлюз — він не в поточній мережі.
            let g = await Shell.run("/sbin/route", ["-n", "get", row.gateway]).out
            guard g.contains("GATEWAY"), helper.isEnabled else { continue }
            try? await actions.deleteDirectRoute(ip: ip)
            prefs.directRoutes[ip] = nil
        }
    }

    // MARK: дії користувача

    /// «Погодити»: тунель у тунелі — свідомий вибір, більше не питати для цієї пари.
    func keepRoute(_ i: RouteIssue) {
        prefs.routeDecisions[i.decisionKey] = "keep"
        routeIssues.removeAll { $0.id == i.id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["route:\(i.id)"])
        toast = i.networkLabel.map {
            String(localized: "\(i.label) stays via \(i.viaOwner) on the network “\($0)”. Reset it in Routes → Decisions.")
        } ?? String(localized: "\(i.label) stays via \(i.viaOwner). Reset it in Routes → Decisions.")
    }

    /// «Відхилити»: сервер напряму через LAN-шлюз; надалі — автоматично.
    func directRoute(_ i: RouteIssue) {
        guard let gw = i.gateway else { toast = String(localized: "No LAN gateway for a direct route"); return }
        prefs.routeDecisions[i.decisionKey] = "direct"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["route:\(i.id)"])
        runAction(String(localized: "Route")) {
            try await self.actions.setDirectRoute(ip: i.ip, gateway: gw)
            self.prefs.directRoutes[i.ip] = "\(gw)|\(i.decisionKey)"
            self.routeIssues.removeAll { $0.id == i.id }
            return String(localized: "\(i.host) (\(i.ip)) → \(gw) direct, around \(i.viaOwner). If \(i.viaOwner) has a Kill Switch on, it may still pull everything into its tunnel.")
        }
    }

    /// Скинути рішення: знову питати; наш маршрут напряму для цієї пари прибрати.
    func resetRouteDecision(_ key: String) {
        prefs.routeDecisions[key] = nil
        let ips = prefs.directRoutes.filter { $0.value.split(separator: "|", maxSplits: 1).last.map(String.init) == key }.map(\.key)
        runAction(String(localized: "Route")) {
            for ip in ips {
                try await self.actions.deleteDirectRoute(ip: ip)
                self.prefs.directRoutes[ip] = nil
            }
            self.lastRouteCheck = .distantPast
            return ips.isEmpty ? String(localized: "Decision reset") : String(localized: "Decision reset, direct route to \(ips.joined(separator: ", ")) removed")
        }
    }

    func handleRouteAction(id: String?, action: String) {
        guard let id, let i = routeIssues.first(where: { $0.id == id }) else { return }
        switch action {
        case "keep": keepRoute(i)
        case "direct": directRoute(i)
        default: break
        }
    }

    private func notifyRouteIssue(_ i: RouteIssue) {
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Route in question: \(i.label)")
        let what = i.networkLabel.map {
            String(localized: "Server \(i.host) goes via \(i.viaOwner) (\(i.via)) on the network “\($0)” — a tunnel inside a tunnel.")
        } ?? String(localized: "Server \(i.host) goes via \(i.viaOwner) (\(i.via)) — a tunnel inside a tunnel.")
        let ask = i.gateway.map { String(localized: "Accept it, or send it direct via \($0)?") }
            ?? String(localized: "There is no LAN gateway to go around it.")
        c.body = what + " " + ask
        c.categoryIdentifier = Self.routeCategory
        c.userInfo = ["issue": i.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "route:\(i.id)", content: c, trigger: nil))
    }
}

/// Кнопки у сповіщеннях + показ банерів і тоді, коли застосунок активний (поповер відкритий).
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    func install() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let keep = UNNotificationAction(identifier: "keep", title: String(localized: "Accept — keep it this way"))
        let direct = UNNotificationAction(identifier: "direct", title: String(localized: "Decline — go direct via LAN"))
        let reinstall = UNNotificationAction(identifier: "reinstall", title: String(localized: "Reinstall Helper"))
        c.setNotificationCategories([
            UNNotificationCategory(identifier: AppModel.routeCategory, actions: [keep, direct], intentIdentifiers: []),
            UNNotificationCategory(identifier: AppModel.helperCategory, actions: [reinstall], intentIdentifiers: []),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let id = content.userInfo["issue"] as? String
        let action = response.actionIdentifier
        if content.categoryIdentifier == "helper" {
            // Кнопка або тап по сповіщенню — те саме, що «Reinstall» у банері.
            if action == "reinstall" || action == UNNotificationDefaultActionIdentifier {
                Task { @MainActor in AppModel.shared.fixHelper() }
            }
        } else {
            Task { @MainActor in AppModel.shared.handleRouteAction(id: id, action: action) }
        }
        completionHandler()
    }
}
