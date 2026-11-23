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
        let gw = Parse.lanGateways(rows).first?.gw
        var found: [RouteIssue] = []
        for s in snap.sessions where s.state == .up {
            guard let b = s.backend, let key = s.profileKey else { continue }
            let prof = snap.profiles[b]?.first { $0.key == key }
            for host in await serverHosts(b, session: s, profile: prof) {
                guard let ip = await resolveCached(host),
                      let via = Parse.fullTunnelCapture(of: ip, rows: rows, own: s.iface) else { continue }
                let owner = snap.routeGroups.first { $0.iface == via }?.owner ?? via
                found.append(RouteIssue(profileKey: key, label: "\(b.title) · \(prof.map(prefs.display) ?? s.name)",
                                        host: host, ip: ip, via: via, viaOwner: owner, gateway: gw))
            }
        }
        var pending: [RouteIssue] = []
        for i in found {
            switch prefs.routeDecisions[i.decisionKey] {
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
            toast = "\(i.label): сервер \(i.host) знову напряму через \(gw), повз \(i.viaOwner)"
            scheduleRefresh()
            return true
        } catch {
            toast = "Маршрут напряму до \(i.host): \(error.localizedDescription)"
            return false
        }
    }

    /// Наш -host маршрут через шлюз, якого вже немає в мережі (змінився Wi-Fi), веде в нікуди і
    /// вбиває той самий VPN — прибрати. Зник сам — забути.
    private func dropDeadDirectRoutes() async {
        guard !prefs.directRoutes.isEmpty else { return }
        for ip in prefs.directRoutes.keys.sorted() {
            let r = await Shell.run("/sbin/route", ["-n", "get", ip]).out
            guard r.contains("HOST"), r.contains("STATIC") else { prefs.directRoutes[ip] = nil; continue }
        }
        let dead = await actions.deadHostRoutes(Array(prefs.directRoutes.keys))
        guard !dead.isEmpty, helper.isEnabled else { return }
        for d in dead {
            try? await actions.deleteDirectRoute(ip: d.ip)
            prefs.directRoutes[d.ip] = nil
        }
    }

    // MARK: дії користувача

    /// «Погодити»: тунель у тунелі — свідомий вибір, більше не питати для цієї пари.
    func keepRoute(_ i: RouteIssue) {
        prefs.routeDecisions[i.decisionKey] = "keep"
        routeIssues.removeAll { $0.id == i.id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["route:\(i.id)"])
        toast = "\(i.label) лишається через \(i.viaOwner). Скинути — Routes → Рішення."
    }

    /// «Відхилити»: сервер напряму через LAN-шлюз; надалі — автоматично.
    func directRoute(_ i: RouteIssue) {
        guard let gw = i.gateway else { toast = "Немає LAN-шлюзу для маршруту напряму"; return }
        prefs.routeDecisions[i.decisionKey] = "direct"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["route:\(i.id)"])
        runAction("Маршрут") {
            try await self.actions.setDirectRoute(ip: i.ip, gateway: gw)
            self.prefs.directRoutes[i.ip] = "\(gw)|\(i.decisionKey)"
            self.routeIssues.removeAll { $0.id == i.id }
            return "\(i.host) (\(i.ip)) → \(gw) напряму, повз \(i.viaOwner). Якщо в \(i.viaOwner) увімкнено Kill Switch, він може й далі тягнути все в тунель."
        }
    }

    /// Скинути рішення: знову питати; наш маршрут напряму для цієї пари прибрати.
    func resetRouteDecision(_ key: String) {
        prefs.routeDecisions[key] = nil
        let ips = prefs.directRoutes.filter { $0.value.split(separator: "|", maxSplits: 1).last.map(String.init) == key }.map(\.key)
        runAction("Маршрут") {
            for ip in ips {
                try await self.actions.deleteDirectRoute(ip: ip)
                self.prefs.directRoutes[ip] = nil
            }
            self.lastRouteCheck = .distantPast
            return ips.isEmpty ? "Рішення скинуто" : "Рішення скинуто, маршрут напряму до \(ips.joined(separator: ", ")) прибрано"
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
        c.title = "Маршрут під питанням: \(i.label)"
        c.body = "Сервер \(i.host) іде через \(i.viaOwner) (\(i.via)) — тунель у тунелі." +
            (i.gateway.map { " Погодити чи пустити напряму через \($0)?" } ?? " LAN-шлюзу для обходу немає.")
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
        let keep = UNNotificationAction(identifier: "keep", title: "Погодити — лишити так")
        let direct = UNNotificationAction(identifier: "direct", title: "Відхилити — напряму через LAN")
        c.setNotificationCategories([UNNotificationCategory(identifier: AppModel.routeCategory, actions: [keep, direct],
                                                            intentIdentifiers: [])])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["issue"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in AppModel.shared.handleRouteAction(id: id, action: action) }
        completionHandler()
    }
}
