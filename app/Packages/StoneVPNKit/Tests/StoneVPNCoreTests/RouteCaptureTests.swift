import Testing
@testable import StoneVPNCore

/// Форма — як на реальній машині (адреси документаційні): ClearVPN (IKEv2, ipsec0) primary + Defguard (utun4, split).
private let clearVPNPlusDefguard = """
Destination        Gateway            Flags               Netif Expire
default            link#30            UCSg               ipsec0
default            192.168.1.1        UGScIg                en0
default            link#29            UCSIg               utun4
1.1.1.1            link#30            UHW3Ig             ipsec0      9
10.20.0.7           10.20.0.7          UH                 ipsec0
10.66/23           link#29            UCS                 utun4
10.66.2.4           10.66.2.4           UH                  utun4
10.66.4/24         link#29            UCS                 utun4
203.0.113.10     link#30            UHWIig             ipsec0
192.168.1          link#15            UCS                   en0      !
"""

@Suite struct RouteCaptureTests {
    let rows = Parse.netstat(clearVPNPlusDefguard)

    @Test func ipsecIsTunnel() {
        #expect(Parse.isTunnelIface("ipsec0"))
        #expect(Parse.isTunnelIface("utun4"))
        #expect(!Parse.isTunnelIface("en0"))
    }

    @Test func endpointCapturedByForeignDefault() {
        #expect(Parse.fullTunnelCapture(of: "203.0.113.10", rows: rows, own: "utun4") == "ipsec0")
    }

    @Test func ownTunnelIsNotCapture() {
        #expect(Parse.fullTunnelCapture(of: "203.0.113.10", rows: rows, own: "ipsec0") == nil)
    }

    @Test func specificRouteWins() {
        // Підмережа іншого тунелю (VPN-in-VPN навмисно) — не перехоплення.
        #expect(Parse.fullTunnelCapture(of: "10.66.0.5", rows: rows, own: "utun9") == nil)
        // Наш -host маршрут напряму через LAN — теж ні.
        let fixed = rows + Parse.netstat("203.0.113.10     192.168.1.1        UGHS                  en0")
        #expect(Parse.fullTunnelCapture(of: "203.0.113.10", rows: fixed, own: "utun4") == nil)
    }

    @Test func splitDefaultCaptures() {
        let r = Parse.netstat("""
        0/1                10.8.0.1           UGSc                utun8
        default            192.168.1.1        UGScg                 en0
        128.0/1            10.8.0.1           UGSc                utun8
        """)
        #expect(Parse.fullTunnelCapture(of: "203.0.113.10", rows: r, own: "utun4") == "utun8")
        #expect(Parse.fullTunnelCapture(of: "8.8.8.8", rows: r, own: "utun4") == "utun8")
    }

    @Test func physicalDefaultIsFine() {
        let r = Parse.netstat("default            192.168.1.1        UGScg                 en0")
        #expect(Parse.fullTunnelCapture(of: "203.0.113.10", rows: r, own: "utun4") == nil)
    }

    @Test func lanGatewaySkipsIpsec() {
        #expect(Parse.lanGateways(rows).map(\.gw) == ["192.168.1.1"])
    }

    @Test func bareHost() {
        #expect(Actions.bareHost("access.example.com:51820") == "access.example.com")
        #expect(Actions.bareHost("vpn.example.com") == "vpn.example.com")
        #expect(Actions.bareHost("[2001:db8::1]:443") == "2001:db8::1")
    }

    @Test func decisionKeys() {
        let k = RouteIssue.decisionKey("defguard:core", "ClearVPN", "0:0:5e:0:53:1")
        #expect(k == "defguard:core|ClearVPN|net:0:0:5e:0:53:1")
        let p = RouteIssue.parseDecisionKey(k)
        #expect(p.profile == "defguard:core" && p.owner == "ClearVPN" && p.network == "0:0:5e:0:53:1")
        let g = RouteIssue.parseDecisionKey("defguard:core|ClearVPN")
        #expect(g.owner == "ClearVPN" && g.network == nil)
    }
}
