import XCTest
import StoneVPNShared

final class CatchAllDNSTests: XCTestCase {
    func testDisplaceKeepsOtherDomainsAndOrders() {
        let dns: [String: Any] = ["ServerAddresses": ["10.8.0.1"], "SupplementalMatchDomains": ["corp.example", ""],
                                  "SupplementalMatchOrders": [5, 1]]
        let d = CatchAllDNS.displaced(dns)!
        XCTAssertEqual(d["SupplementalMatchDomains"] as? [String], ["corp.example"])
        XCTAssertEqual(d["SupplementalMatchOrders"] as? [Int], [5])
        XCTAssertEqual(d["ServerAddresses"] as? [String], ["10.8.0.1"])
        XCTAssertFalse(CatchAllDNS.isCatchAll(d))
    }

    func testNotCatchAll() {
        XCTAssertNil(CatchAllDNS.displaced(["SupplementalMatchDomains": ["corp.example"]]))
        XCTAssertNil(CatchAllDNS.displaced(["ServerAddresses": ["1.1.1.1"]]))
    }

    func testRestoreRoundTrip() {
        let dns: [String: Any] = ["ServerAddresses": ["10.8.0.1"], "SupplementalMatchDomains": [""], "SearchOrder": 1]
        let b = CatchAllDNS.backup(dns)
        let r = CatchAllDNS.restored(current: CatchAllDNS.displaced(dns)!, backup: b)!
        XCTAssertEqual(r["SupplementalMatchDomains"] as? [String], [""])
        XCTAssertEqual(r["SearchOrder"] as? Int, 1)
        XCTAssertNil(r["SupplementalMatchOrders"])
    }

    func testRestoreSkipsWhenClientReasserted() {
        XCTAssertNil(CatchAllDNS.restored(current: ["SupplementalMatchDomains": [""]], backup: ["SupplementalMatchDomains": [""]]))
    }
}
