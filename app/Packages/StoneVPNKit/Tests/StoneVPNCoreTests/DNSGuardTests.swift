import XCTest
@testable import StoneVPNCore

final class DNSGuardTests: XCTestCase {
    let tun: Set<String> = ["10.8.0.1"]

    func testLearnSkipsTunnelDNS() {
        let b = DNSGuard.learn(baseline: ["Wi-Fi": ["8.8.8.8"]],
                               current: ["Wi-Fi": ["10.8.0.1"], "USB": [], "AX": ["1.1.1.1"]], tunnelDNS: tun)
        XCTAssertEqual(b, ["Wi-Fi": ["8.8.8.8"], "USB": [], "AX": ["1.1.1.1"]])
    }

    func testPlanRestoresBaseline() {
        let p = DNSGuard.plan(current: ["Wi-Fi": ["10.8.0.1"], "AX": ["1.1.1.1"], "USB": ["10.8.0.1"]],
                              baseline: ["Wi-Fi": ["8.8.8.8"]], tunnelDNS: tun, fallback: [])
        XCTAssertEqual(p, ["Wi-Fi": ["8.8.8.8"], "USB": []])
    }

    func testPlanKeepsManualChange() {
        let p = DNSGuard.plan(current: ["Wi-Fi": ["9.9.9.9"]], baseline: ["Wi-Fi": ["8.8.8.8"]], tunnelDNS: tun, fallback: [])
        XCTAssertTrue(p.isEmpty)
    }

    func testPolluteBaselineFallsBack() {
        let p = DNSGuard.plan(current: ["Wi-Fi": ["10.8.0.1", "1.1.1.1"]], baseline: ["Wi-Fi": ["10.8.0.1"]],
                              tunnelDNS: tun, fallback: ["1.1.1.1"])
        XCTAssertEqual(p, ["Wi-Fi": ["1.1.1.1"]])
    }
}
