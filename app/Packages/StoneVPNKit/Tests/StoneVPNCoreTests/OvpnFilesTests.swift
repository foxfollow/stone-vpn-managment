import XCTest
@testable import StoneVPNCore

final class OvpnFilesTests: XCTestCase {
    let profile = "client\nremote vpn.example.com 1194 udp\n<ca>\nOLDCA\n</ca>\n<cert>\nOLDCERT\n</cert>\n<key>\nOLDKEY\n</key>\n"
    let cert = "-----BEGIN CERTIFICATE-----\nNEW\n-----END CERTIFICATE-----\n"

    func testReplaceBlockOnlyTouchesTag() {
        let r = OvpnFiles.replaceBlock(profile, tag: "cert", with: cert)!
        XCTAssertTrue(r.contains("<cert>\n-----BEGIN CERTIFICATE-----\nNEW\n-----END CERTIFICATE-----\n</cert>"))
        XCTAssertTrue(r.contains("OLDCA") && r.contains("OLDKEY"))
        XCTAssertFalse(r.contains("OLDCERT"))
    }

    func testReplaceBlockMissing() {
        XCTAssertNil(OvpnFiles.replaceBlock("remote a 1\ncert c.crt\n", tag: "cert", with: cert))
    }

    func testPemMatches() {
        XCTAssertTrue(OvpnFiles.pemMatches(cert, tag: "cert"))
        XCTAssertFalse(OvpnFiles.pemMatches(cert, tag: "key"))
        XCTAssertTrue(OvpnFiles.pemMatches("-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----", tag: "key"))
    }

    func testReplaceTargetsExactFileAmongSameRemote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovpn-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = "\(dir)/1000.ovpn", b = "\(dir)/2000.ovpn"
        try profile.write(toFile: a, atomically: true, encoding: .utf8)
        try profile.write(toFile: b, atomically: true, encoding: .utf8)
        let src = URL(fileURLWithPath: "\(dir)/new.txt")
        try "remote vpn.example.com 1194 udp\n# NEW\n".write(to: src, atomically: true, encoding: .utf8)

        try OvpnFiles.replaceProfile(at: b, with: src)
        XCTAssertEqual(try String(contentsOfFile: a, encoding: .utf8), profile)
        XCTAssertTrue(try String(contentsOfFile: b, encoding: .utf8).contains("# NEW"))
        XCTAssertEqual(try String(contentsOfFile: b + ".bak", encoding: .utf8), profile)

        let id = try OvpnFiles.importProfile(from: src, into: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/\(id).ovpn"))
    }

    func testRejectsNonProfile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).ovpn")
        try "hello".write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertThrowsError(try OvpnFiles.importProfile(from: f, into: NSTemporaryDirectory()))
    }
}
