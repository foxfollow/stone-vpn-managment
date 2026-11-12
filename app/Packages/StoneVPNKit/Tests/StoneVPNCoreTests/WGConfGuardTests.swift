import XCTest
import StoneVPNShared

/// Перевірки шляху до WG-конфігу, які helper робить перед дією від root.
/// Справжні теки (/etc/wireguard…) підмінено тимчасовими через параметри dirs/canonical.
final class WGConfGuardTests: XCTestCase {
    var root = ""
    var std = ""          // «стандартна» тека (у canonical)
    let me = getuid()
    let fm = FileManager.default

    override func setUpWithError() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("wgguard-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        // realpath, а не resolvingSymlinksInPath: Foundation прибирає /private назад.
        guard let r = realpath(base, nil) else { throw XCTSkip("realpath") }
        root = String(cString: r); free(r)               // /var → /private/var, як F_GETPATH
        std = root + "/std"
        try fm.createDirectory(atPath: std, withIntermediateDirectories: true)
        try "[Interface]\nAddress = 10.0.0.2/32\n".write(toFile: std + "/wg0.conf", atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? fm.removeItem(atPath: root) }

    private func open(_ path: String, caller: uid_t?, dirs: [String]) -> Result<WGConfHandle, WGConfGuard.Failure> {
        WGConfGuard.open(path, caller: caller, dirs: dirs, canonical: [std])
    }

    func testStandardDirReadsAndDeletes() throws {
        let h = try open(std + "/wg0.conf", caller: me, dirs: [std]).get()
        XCTAssertEqual(h.name, "wg0")
        XCTAssertEqual(h.path, std + "/wg0.conf")
        XCTAssertEqual(try h.read().get(), "[Interface]\nAddress = 10.0.0.2/32\n")
        try h.delete().get()
        XCTAssertFalse(fm.fileExists(atPath: std + "/wg0.conf"))
    }

    /// Регресія 610d9df: тека-симлінк на власну теку користувача (dotfiles) має працювати.
    func testSymlinkedDirOwnedByCallerWorks() throws {
        let dot = root + "/dotfiles"
        try fm.createDirectory(atPath: dot, withIntermediateDirectories: true)
        try "x".write(toFile: dot + "/office.conf", atomically: true, encoding: .utf8)
        let link = root + "/linked"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: dot)

        let h = try open(link + "/office.conf", caller: me, dirs: [link]).get()
        XCTAssertEqual(h.path, dot + "/office.conf")       // wg-quick отримує розкритий шлях
        XCTAssertEqual(try h.read().get(), "x")
        // Без відомого запитувача або від чужого uid — ні.
        XCTAssertThrowsError(try open(link + "/office.conf", caller: nil, dirs: [link]).get())
        XCTAssertThrowsError(try open(link + "/office.conf", caller: me + 1, dirs: [link]).get())
    }

    /// Атака з рев'ю: user-owned тека WireGuard підмінена симлінком на /etc.
    func testSymlinkedDirToEtcIsRefused() throws {
        let link = root + "/trap"
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "/etc")
        let target = fm.fileExists(atPath: "/etc/pf.conf") ? "pf.conf" : "resolv.conf"
        guard case .failure(.foreignOwner(let dir, let owner, _)) = open(link + "/" + target, caller: me, dirs: [link]) else {
            return XCTFail("/etc через симлінк має бути відхилено")
        }
        XCTAssertEqual(dir, "/private/etc")
        XCTAssertEqual(owner, 0)
        XCTAssertFalse(WGConfGuard.dirListable(link, caller: me, dirs: [link], canonical: [std]))
        XCTAssertTrue(WGConfGuard.dirListable(std, caller: me, dirs: [std], canonical: [std]))
    }

    func testFileSymlinkAndHardLinkAreRefused() throws {
        try fm.createSymbolicLink(atPath: std + "/sl.conf", withDestinationPath: std + "/wg0.conf")
        XCTAssertEqual(open(std + "/sl.conf", caller: me, dirs: [std]).failure, .symlink(std + "/sl.conf"))

        try fm.linkItem(atPath: std + "/wg0.conf", toPath: std + "/hl.conf")
        XCTAssertEqual(open(std + "/hl.conf", caller: me, dirs: [std]).failure, .hardLinks(std + "/hl.conf", 2))
    }

    func testPathAndNameRules() {
        XCTAssertEqual(open(std + "/sub/wg0.conf", caller: me, dirs: [std]).failure, .notInDirs(std + "/sub/wg0.conf"))
        XCTAssertEqual(open(std + "/../std/wg0.conf", caller: me, dirs: [std]).failure, .notInDirs(std + "/../std/wg0.conf"))
        XCTAssertEqual(open("wg0.conf", caller: me, dirs: [std]).failure, .notInDirs("wg0.conf"))
        XCTAssertEqual(open(std + "/this-name-is-too-long.conf", caller: me, dirs: [std]).failure, .badName("this-name-is-too-long.conf"))
        XCTAssertEqual(open(std + "/wg0.txt", caller: me, dirs: [std]).failure, .badName("wg0.txt"))
        XCTAssertNotEqual(WGConfGuard.Failure.badName("x").message, WGConfGuard.Failure.notInDirs("x").message)
    }

    /// Файл підмінили між перевіркою і читанням — читається не він.
    func testReadDetectsSwap() throws {
        let h = try open(std + "/wg0.conf", caller: me, dirs: [std]).get()
        try fm.removeItem(atPath: std + "/wg0.conf")
        try "other".write(toFile: std + "/wg0.conf", atomically: false, encoding: .utf8)
        XCTAssertEqual(h.read().failure, .changed)
    }

    func testOwnershipRules() {
        // Стандартна тека: файл root або власника теки.
        XCTAssertTrue(WGConfGuard.ownershipOK(canonical: true, dirOwner: 0, fileOwner: 0, caller: nil))
        XCTAssertTrue(WGConfGuard.ownershipOK(canonical: true, dirOwner: 501, fileOwner: 501, caller: nil))
        XCTAssertFalse(WGConfGuard.ownershipOK(canonical: true, dirOwner: 501, fileOwner: 502, caller: 501))
        // Деінде: лише тека й файл самого запитувача.
        XCTAssertTrue(WGConfGuard.ownershipOK(canonical: false, dirOwner: 501, fileOwner: 501, caller: 501))
        XCTAssertFalse(WGConfGuard.ownershipOK(canonical: false, dirOwner: 0, fileOwner: 0, caller: 501))
        XCTAssertFalse(WGConfGuard.ownershipOK(canonical: false, dirOwner: 501, fileOwner: 0, caller: 501))
        XCTAssertFalse(WGConfGuard.ownershipOK(canonical: false, dirOwner: 502, fileOwner: 502, caller: 501))
        XCTAssertFalse(WGConfGuard.ownershipOK(canonical: false, dirOwner: 0, fileOwner: 0, caller: 0))
        XCTAssertFalse(WGConfGuard.ownershipOK(canonical: false, dirOwner: 501, fileOwner: 501, caller: nil))
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}
