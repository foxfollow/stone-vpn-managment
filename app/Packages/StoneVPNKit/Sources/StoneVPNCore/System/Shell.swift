import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var out: String
    public var err: String
    public var ok: Bool { status == 0 }
}

/// Запуск зовнішніх команд без шелу (argv напряму) з таймаутом.
public enum Shell {
    public static let path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func run(_ exe: String, _ args: [String] = [], stdin: String? = nil, timeout: TimeInterval = 15) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(exe, args, stdin: stdin, timeout: timeout))
            }
        }
    }

    public static func runSync(_ exe: String, _ args: [String] = [], stdin: String? = nil, timeout: TimeInterval = 15) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["LC_ALL"] = "en_US.UTF-8"     // стабільний англійський вивід утиліт для парсерів
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch {
            return ShellResult(status: -1, out: "", err: error.localizedDescription)
        }
        if let stdin {
            signal(SIGPIPE, SIG_IGN)
            try? inp.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? inp.fileHandleForWriting.close()
        }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        // Читати обидва потоки паралельно — інакше великий stderr заблокує процес.
        var errData = Data()
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        g.wait()
        p.waitUntilExit()
        timer.cancel()
        return ShellResult(status: p.terminationStatus,
                           out: String(decoding: outData, as: UTF8.self),
                           err: String(decoding: errData, as: UTF8.self))
    }

    public static func which(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
