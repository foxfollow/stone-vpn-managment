import XCTest
@testable import StoneVPNCore

/// Вивід утиліт — синтетичний (документаційні адреси), форма — як на реальній машині.
final class ParserTests: XCTestCase {

    let netstat = """
    Routing tables

    Internet:
    Destination        Gateway            Flags               Netif Expire
    default            192.168.1.1        UGScg                 en0
    default            link#22            UCSIg               utun4
    10.8/24            10.8.0.5           UGSc                utun4
    10.8.0.5           10.8.0.5           UH                  utun4
    10.20/16           link#22            UCS                 utun4
    10.20.3.4          link#22            UHWIi               utun4
    172.16/12          utun6              USc                 utun6
    192.168.1          link#11            UCS                   en0      !
    198.51.100.7       192.168.1.1        UGHS                  en0
    203.0.113.10/32    192.168.1.1        UGSc                  en0
    224.0.0/4          link#22            UmCSI               utun4
    255.255.255.255/32 link#11            UCS                   en0      !
    """

    func testNetstat() {
        let rows = Parse.netstat(netstat)
        XCTAssertEqual(rows.first?.dest, "default")
        XCTAssertEqual(rows.count, 12)
        XCTAssertEqual(Parse.lanGateways(rows).map(\.gw), ["192.168.1.1"])
    }

    func testIfaceRoutesDropsNoiseAndMarksScopedDefault() {
        let r = Parse.ifaceRoutes(Parse.netstat(netstat), iface: "utun4", own: "10.8.0.5").map(\.dest)
        XCTAssertEqual(r, ["default (scoped)", "10.8/24", "10.20/16"])   // без own, W-клону, multicast
    }

    func testTunnelIfaceLongestPrefix() {
        let rows = Parse.netstat(netstat)
        XCTAssertEqual(Parse.tunnelIface(for: "10.20.9.9", rows: rows), "utun4")
        XCTAssertEqual(Parse.tunnelIface(for: "172.20.0.1", rows: rows), "utun6")
        // default через utun (prefix 0) не рахується
        XCTAssertNil(Parse.tunnelIface(for: "8.8.8.8", rows: rows))
    }

    func testTunnelIfaceIgnoresStaleHostRoute() {
        // Залишок route-fix (-host повз тунель) не маскує тунельний маршрут.
        let rows = Parse.netstat("""
        10.30/16           link#22            UCS                 utun4
        10.30.0.1          192.168.1.1        UGHS                  en0
        """)
        XCTAssertEqual(Parse.tunnelIface(for: "10.30.0.1", rows: rows), "utun4")
    }

    func testDef1IsNotTunnelReachability() {
        let rows = Parse.netstat("""
        0/1                10.9.0.1           UGSc                utun7
        128.0/1            10.9.0.1           UGSc                utun7
        """)
        XCTAssertNil(Parse.tunnelIface(for: "203.0.113.10", rows: rows))
        XCTAssertEqual(Parse.splitDefault(rows), ["utun7"])
    }

    func testRouteFixRows() {
        let fix = Parse.routeFixRows(Parse.netstat(netstat)).map(\.dest)
        XCTAssertEqual(fix, ["198.51.100.7", "203.0.113.10/32"])
    }

    func testOvpnLogUpAfterRestart() {
        let log = """
        2026-10-14 10:00:00 TLS Error: TLS key negotiation failed to occur within 60 seconds
        2026-10-14 10:00:01 SIGUSR1[soft,tls-error] received, process restarting
        2026-10-14 10:00:05 Opened utun device utun6
        2026-10-14 10:00:06 Initialization Sequence Completed
        """
        XCTAssertEqual(Parse.ovpnLog(log), .init(up: true, dev: "utun6", error: nil))
    }

    func testOvpnLogRestartAfterUpIsConnecting() {
        let log = """
        2026-10-14 10:00:06 Initialization Sequence Completed
        2026-10-14 10:05:00 Connection reset, restarting [0]
        2026-10-14 10:05:00 SIGUSR1[soft,connection-reset] received, process restarting
        2026-10-14 10:05:10 TLS Error: TLS handshake failed
        """
        let st = Parse.ovpnLog(log)
        XCTAssertFalse(st.up)
        XCTAssertEqual(st.error, "TLS Error: TLS handshake failed")
    }

    func testOvpnProfile() {
        let p = Parse.ovpnProfile("""
        client
        remote vpn.example.com 1194 udp
        remote vpn2.example.com 443 tcp
        auth-user-pass
        """)
        XCTAssertEqual(p.remotes.map(\.host), ["vpn.example.com", "vpn2.example.com"])
        XCTAssertTrue(p.needsAuth)
        XCTAssertFalse(p.hasDev)
        XCTAssertFalse(Parse.ovpnProfile("auth-user-pass /etc/creds\ndev tun").needsAuth)
    }

    func testPSAndOvpnInstances() {
        let rows = Parse.ps("""
          4821    12:03 /opt/homebrew/sbin/openvpn --config /Users/x/Library/Application Support/OpenVPN Connect/profiles/1712.ovpn --dev tun --daemon --writepid /tmp/openvpn-1712.pid --log /tmp/openvpn-1712.log
           900 01-02:03:04 /Applications/Defguard.app/Contents/MacOS/defguard-client
          5000    00:10 grep openvpn
        """)
        let inst = Parse.ovpnInstances(rows)
        XCTAssertEqual(inst.count, 1)
        XCTAssertEqual(inst[0].id, "1712")
        XCTAssertEqual(inst[0].log, "/tmp/openvpn-1712.log")
        XCTAssertEqual(Parse.prettyElapsed("01-02:03:04"), "01д 02:03")
        XCTAssertEqual(rows[1].command, "/Applications/Defguard.app/Contents/MacOS/defguard-client")
    }

    func testNCListAndStatus() {
        let list = Parse.ncList("""
        Available network connection services in the current set (*=enabled):
        * (Connected)      7A2B3C4D-1111-2222-3333-444455556666 VPN (net.defguard) "prod"    [VPN:net.defguard]
        * (Disconnected)   8B2B3C4D-1111-2222-3333-444455556666 VPN (net.defguard) "stage"   [VPN:net.defguard]
        * (Invalid)        9C2B3C4D-1111-2222-3333-444455556666 VPN (com.clearvpn)  "ClearVPN" [VPN:com.clearvpn]
        """)
        XCTAssertEqual(list, [.init(state: "Connected", uuid: "7A2B3C4D-1111-2222-3333-444455556666", name: "prod"),
                              .init(state: "Disconnected", uuid: "8B2B3C4D-1111-2222-3333-444455556666", name: "stage")])
        let st = Parse.ncStatus("""
        Connected
        Extended Status <dictionary> {
          IPv4 : <dictionary> {
            Addresses : <array> {
              0 : 10.99.0.4
            }
            InterfaceName : utun7
          }
          DNS : <dictionary> {
            DNSServers : <array> {
              0 : 10.99.0.1
              1 : 10.99.0.2
            }
          }
        }
        """)
        XCTAssertEqual(st.iface, "utun7")
        XCTAssertEqual(st.address, "10.99.0.4")
        XCTAssertEqual(st.dns, ["10.99.0.1", "10.99.0.2"])
    }

    func testDefguardList() {
        let json = #"{"locations":[{"name":"prod","endpoint":"dg.example.com:51820","mfa_enabled":true,"mfa_method":"totp","route_all_traffic":true}],"tunnels":[{"name":"imp","endpoint":"","route_all_traffic":false}]}"#
        let p = Parse.defguardList(Data(json.utf8))
        XCTAssertEqual(p.map(\.name), ["prod", "imp"])
        XCTAssertEqual(p[0].mfa, "totp")
        XCTAssertEqual(p[1].dgKind, "tunnel")
    }

    func testCisco() {
        XCTAssertEqual(Parse.ciscoConnectedHost("  >> state: Connected\n  >> notice: Connected to vpn.corp.example.\n"), "vpn.corp.example")
        XCTAssertEqual(Parse.ciscoHosts("""
        Cisco Secure Client (version 5.1).
          [hosts]:
          > vpn.corp.example
          > backup.corp.example:8443
        """), ["vpn.corp.example", "backup.corp.example:8443"])
    }

    func testServiceOrder() {
        let s = Parse.serviceOrder("""
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) USB 10/100 LAN
        (Hardware Port: USB 10/100 LAN, Device: en7)

        (*) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        (3) prod
        (Hardware Port: net.defguard, Device: )
        """)
        XCTAssertEqual(s.map(\.name), ["Wi-Fi", "USB 10/100 LAN", "Thunderbolt Bridge", "prod"])
        XCTAssertFalse(s[2].enabled)
        XCTAssertTrue(s[3].isVPN)
        XCTAssertEqual(s[3].hwPort, "net.defguard")
    }

    func testConfigOwner() {
        XCTAssertEqual(Parse.configOwner("Supplemental: com.cisco.anyconnect 0"), "com.cisco.anyconnect")
        XCTAssertEqual(Parse.configOwner("7A2B3C4D-1111-2222-3333-444455556666"), "7A2B3C4D-1111-2222-3333-444455556666")
    }

    func testWGConfNeverNeedsPrivateKey() {
        let c = Parse.wgConf("""
        [Interface]
        Address = 10.8.0.5/32
        DNS = 10.8.0.1
        [Peer]
        Endpoint = vpn.office.example:51820
        AllowedIPs = 10.8.0.0/24
        AllowedIPs = 10.20.0.0/16
        """)
        XCTAssertEqual(c.endpoint, "vpn.office.example:51820")
        XCTAssertEqual(c.allowedIPs, "10.8.0.0/24, 10.20.0.0/16")
    }

    func testEnvFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vpnbar-test-\(UUID()).env")
        try """
        # коментар
        LAN_GATEWAY=192.168.1.1
        RESTORE_DNS="1.1.1.1 8.8.8.8"
        DNS_SERVICES=("Wi-Fi" "USB 10/100 LAN")
        LAST_USERNAME=j\\ doe
        """.write(to: url, atomically: true, encoding: .utf8)
        var f = EnvFile(url: url)
        XCTAssertEqual(f["LAN_GATEWAY"], "192.168.1.1")
        XCTAssertEqual(f["RESTORE_DNS"], "1.1.1.1 8.8.8.8")
        XCTAssertEqual(f.array("DNS_SERVICES"), ["Wi-Fi", "USB 10/100 LAN"])
        XCTAssertEqual(f["LAST_USERNAME"], "j doe")
        f.set("LAN_GATEWAY", "10.0.0.1")
        f.set("OVPN_USERNAME", "it's me")
        try f.save()
        let g = EnvFile(url: url)
        XCTAssertEqual(g.lines.first, "# коментар")
        XCTAssertEqual(g["LAN_GATEWAY"], "10.0.0.1")
        XCTAssertEqual(g["OVPN_USERNAME"], "it's me")
        try? FileManager.default.removeItem(at: url)
    }
}
