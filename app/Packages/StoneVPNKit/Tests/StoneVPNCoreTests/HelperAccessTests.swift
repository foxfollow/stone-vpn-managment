import XCTest
@testable import StoneVPNShared

final class HelperAccessTests: XCTestCase {
    let admins: Set<UInt32> = [501, 502]
    func admin(_ u: UInt32) -> Bool { admins.contains(u) }

    func testOwnerOnly() {
        XCTAssertTrue(HelperAccessPolicy.owner.permits(501, owner: 501, isAdmin: admin))
        XCTAssertFalse(HelperAccessPolicy.owner.permits(502, owner: 501, isAdmin: admin))   // інший адмін — ні
        XCTAssertFalse(HelperAccessPolicy.owner.permits(503, owner: 501, isAdmin: admin))
    }

    func testAdmins() {
        XCTAssertTrue(HelperAccessPolicy.admins.permits(502, owner: 501, isAdmin: admin))
        XCTAssertFalse(HelperAccessPolicy.admins.permits(503, owner: 501, isAdmin: admin))
        XCTAssertTrue(HelperAccessPolicy.admins.permits(503, owner: 503, isAdmin: admin))   // власник без admin
    }

    func testEveryone() {
        XCTAssertTrue(HelperAccessPolicy.everyone.permits(503, owner: 501, isAdmin: admin))
    }

    /// Без власника не обслуговуємо нікого (навіть з політикою «всі»), root — завжди, невідомий uid — ні.
    func testNoOwnerRootAndUnknown() {
        for p in HelperAccessPolicy.allCases {
            XCTAssertFalse(p.permits(501, owner: nil, isAdmin: admin), "\(p)")
            XCTAssertTrue(p.permits(0, owner: nil, isAdmin: admin), "\(p)")
            XCTAssertFalse(p.permits(nil, owner: 501, isAdmin: admin), "\(p)")
        }
    }

    func testInfoRoundTrip() throws {
        let i = HelperAccessInfo(ownerUID: 501, ownerName: "j", policy: .admins, callerUID: 501, callerAllowed: true)
        let back = try JSONDecoder().decode(HelperAccessInfo.self, from: JSONEncoder().encode(i))
        XCTAssertEqual(back, i)
        XCTAssertTrue(back.callerIsOwner)
        // Старий клієнт / демон: PrivResult без `denied` декодується.
        let r = try JSONDecoder().decode(PrivResult.self, from: Data(#"{"ok":true,"output":"x"}"#.utf8))
        XCTAssertNil(r.denied)
    }
}
