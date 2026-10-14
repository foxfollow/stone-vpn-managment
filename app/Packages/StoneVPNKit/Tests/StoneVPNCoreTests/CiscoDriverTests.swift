import XCTest
@testable import StoneVPNCore

/// Фейковий `vpn -s`: ті самі запити без \n у кінці, що й справжній CLI.
final class CiscoDriverTests: XCTestCase {
    func fakeCLI(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-vpn-\(UUID().uuidString).sh")
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    let happy = """
    echo "  >> state: Disconnected"
    printf 'VPN> '
    read cmd; [ "$cmd" = "connect vpn.example.com:8448" ] || { echo "  >> error: bad cmd $cmd"; exit 1; }
    echo "  >> contacting host (vpn.example.com:8448) for login information..."
    printf 'Group: [Employees] '; read g; echo "$g" > "$OUT.group"
    printf 'Username: [j.doe] '; read u; echo "$u" > "$OUT.user"
    printf 'Password: '; read p; [ "$p" = "s3cret" ] || { echo "  >> Login failed."; exit 1; }
    echo "Authorized use only."
    printf 'accept? [y/n]: '; read a; [ "$a" = y ] || exit 1
    echo "  >> state: Connected"
    """

    func testHappyPathAnswersPromptsInOrder() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("cisco-\(UUID())").path
        let cli = try fakeCLI("OUT=\(out)\n" + happy)
        let steps = StepLog()
        try await CiscoDriver.connect(cli: cli, CiscoCredentials(host: "vpn.example.com:8448", group: "Staff", user: "j.doe", password: "s3cret", secondPassword: ""), timeout: 10) { ev in
            if case .step(let s) = ev { steps.add(s) }
            if case .banner(let b) = ev { steps.add("banner:" + b) }
        }
        XCTAssertEqual(try String(contentsOfFile: out + ".group", encoding: .utf8), "Staff\n")
        XCTAssertEqual(try String(contentsOfFile: out + ".user", encoding: .utf8), "j.doe\n")
        XCTAssertTrue(steps.all.contains("Connected"))
        XCTAssertTrue(steps.all.contains { $0.contains("Authorized use only.") })
    }

    func testWrongPasswordFails() async throws {
        let cli = try fakeCLI("OUT=/dev/null\n" + happy)
        do {
            try await CiscoDriver.connect(cli: cli, CiscoCredentials(host: "vpn.example.com:8448", group: "", user: "j.doe", password: "nope", secondPassword: ""), timeout: 10) { _ in }
            XCTFail("мало впасти")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Login failed"), error.localizedDescription)
        }
    }

    func testSuggestedHostKeepsPort() {
        var p = CiscoPrefs()
        p.hostName = "training.example"
        p.hostAddress = "198.51.100.5:8448"
        XCTAssertEqual(p.suggestedHost, "training.example:8448")
        p.hostAddress = "198.51.100.5"
        XCTAssertEqual(p.suggestedHost, "training.example")
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class CiscoGroupProbeTests: XCTestCase {
    func testParseGroupPrompt() {
        let r = CiscoDriver.parseGroupPrompt("""
          >> contacting host (vpn.example.com) for login information...
          >> Please enter your username and password.
            0) Employees
            1) Contractors
        Group: [Contractors]
        """ + " ")
        XCTAssertEqual(r, .init(groups: ["Employees", "Contractors"], defaultGroup: "Contractors", asksGroup: true))
        XCTAssertEqual(CiscoDriver.parseGroupPrompt("  >> Please enter your username and password.\nUsername: [j.doe] "),
                       .init(groups: [], defaultGroup: nil, asksGroup: false))
        XCTAssertNil(CiscoDriver.parseGroupPrompt("  >> contacting host (vpn.example.com)...\n"))
    }

    func testProbeStopsAtGroupPromptWithoutCredentials() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID())").path
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-vpn-\(UUID().uuidString).sh")
        try """
        #!/bin/bash
        read cmd
        echo "  >> Please enter your username and password."
        echo "    0) Employees"
        echo "    1) Staff"
        printf 'Group: [Employees] '
        read g && echo "got:$g" > \(marker)
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let r = try await CiscoDriver.probeGroups(cli: url.path, host: "vpn.example.com", timeout: 5)
        XCTAssertEqual(r.groups, ["Employees", "Staff"])
        XCTAssertEqual(r.defaultGroup, "Employees")
        try await Task.sleep(for: .milliseconds(300))
        // Нічого не відповіли на запит групи (EOF ≠ рядок) — облікові дані не надсилались.
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }
}
