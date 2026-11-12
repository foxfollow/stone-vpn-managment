import Foundation

/// Теки, де wg-quick шукає конфіги. Єдиний список для застосунку й helper-а.
public enum WGPaths {
    public static let dirs = ["/opt/homebrew/etc/wireguard", "/usr/local/etc/wireguard", "/etc/wireguard"]
    /// Ті самі теки після розкриття симлінків (/etc — системний симлінк на /private/etc).
    /// Зашиті, а не обчислені: realpath підміненої теки дав би той самий результат, що й для чужої.
    public static let canonical: Set<String> = ["/opt/homebrew/etc/wireguard", "/usr/local/etc/wireguard", "/private/etc/wireguard"]

    /// Правило імені інтерфейсу wg-quick.
    public static func isValidName(_ n: some StringProtocol) -> Bool {
        String(n).range(of: #"^[a-zA-Z0-9_=+.-]{1,15}$"#, options: .regularExpression) != nil
    }
}

/// Відкритий і перевірений WG-конфіг. Тека тримається дескриптором: читання й видалення йдуть
/// відносно нього (openat/unlinkat без слідування симлінкам), тож підміна шляху після перевірки
/// нічого не змінює.
public final class WGConfHandle {
    public let dirFD: Int32
    public let dir: String          // справжній шлях відкритої теки (F_GETPATH)
    public let name: String         // ім'я інтерфейсу
    let ino: ino_t
    let dev: dev_t

    init(dirFD: Int32, dir: String, name: String, ino: ino_t, dev: dev_t) {
        self.dirFD = dirFD; self.dir = dir; self.name = name; self.ino = ino; self.dev = dev
    }
    deinit { close(dirFD) }

    public var file: String { name + ".conf" }
    /// Розкритий шлях — його й отримує wg-quick (ім'я інтерфейсу береться з basename, воно те саме).
    public var path: String { dir + "/" + file }

    /// Прочитати той самий файл, що пройшов перевірку.
    public func read() -> Result<String, WGConfGuard.Failure> {
        let fd = openat(dirFD, file, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.cannotOpen(file, String(cString: strerror(errno)))) }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_ino == ino, st.st_dev == dev, st.st_nlink == 1 else { return .failure(.changed) }
        guard let data = try? fh.readToEnd() else { return .failure(.cannotOpen(file, "read")) }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// Видалити ім'я в перевіреній теці. Якщо його встигли підмінити посиланням, зникне лише посилання.
    public func delete() -> Result<Void, WGConfGuard.Failure> {
        unlinkat(dirFD, file, 0) == 0 ? .success(()) : .failure(.cannotOpen(file, String(cString: strerror(errno))))
    }
}

/// Перевірка шляху до WG-конфігу перед дією від root.
///
/// Тека може бути симлінком (наприклад, на ~/dotfiles/wireguard) — це підтримується. Але root
/// діє лише там, де не дає нових можливостей:
///   • тека розкривається в стандартну → файл належить root або власнику теки;
///   • тека розкривається деінде → і тека, і файл належать тому, хто надіслав запит
///     (тобто він і сам може зробити з ними все те саме). Посилання на /etc відпадає.
/// Файл: не симлінк, звичайний, рівно одне жорстке посилання (інакше `ln /etc/sudoers x.conf`).
public enum WGConfGuard {
    public enum Failure: Error, Equatable {
        case notInDirs(String)
        case badName(String)
        case cannotOpen(String, String)
        case symlink(String)
        case notRegular(String)
        case hardLinks(String, Int)
        case foreignOwner(dir: String, dirOwner: uid_t, fileOwner: uid_t)
        case changed

        public var message: String {
            switch self {
            case .notInDirs(let p): "\(p): конфіг має лежати прямо в одній із тек WireGuard (\(WGPaths.dirs.joined(separator: ", ")))"
            case .badName(let n): "\(n): ім'я не підходить для wg-quick (*.conf, [a-zA-Z0-9_=+.-], до 15 символів)"
            case .cannotOpen(let p, let e): "\(p): \(e)"
            case .symlink(let p): "\(p): сам конфіг — симлінк; симлінком може бути лише тека"
            case .notRegular(let p): "\(p): не звичайний файл"
            case .hardLinks(let p, let n): "\(p): файл має \(n) жорстких посилань — відмовлено"
            case .foreignOwner(let d, let downer, let fowner):
                "тека конфігів веде в \(d) (власник uid \(downer), файл — uid \(fowner)): поза стандартними теками helper працює лише з твоїми файлами у твоїй теці"
            case .changed: "конфіг змінився під час перевірки — спробуй ще раз"
            }
        }
    }

    /// Рішення про власників — окремо, щоб покрити тестами без root.
    public static func ownershipOK(canonical: Bool, dirOwner: uid_t, fileOwner: uid_t, caller: uid_t?) -> Bool {
        if canonical { return fileOwner == 0 || fileOwner == dirOwner }
        guard let caller, caller != 0 else { return false }
        return dirOwner == caller && fileOwner == caller
    }

    /// `dirs`/`canonical` змінюються лише в тестах.
    public static func open(_ path: String, caller: uid_t?,
                            dirs: [String] = WGPaths.dirs, canonical: Set<String> = WGPaths.canonical) -> Result<WGConfHandle, Failure> {
        // Без нормалізації (standardizedFileURL ще й зрізає /private): «.»/«..»/«//» — відмова.
        let comps = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.hasPrefix("/"), !comps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return .failure(.notInDirs(path))
        }
        let p = path
        let parent = (p as NSString).deletingLastPathComponent
        let file = (p as NSString).lastPathComponent
        guard dirs.contains(parent) else { return .failure(.notInDirs(p)) }
        guard file.hasSuffix(".conf"), WGPaths.isValidName(file.dropLast(5)) else { return .failure(.badName(file)) }

        let dfd = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { return .failure(.cannotOpen(parent, String(cString: strerror(errno)))) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var dst = stat(), fst = stat()
        guard fcntl(dfd, F_GETPATH, &buf) == 0, fstat(dfd, &dst) == 0 else {
            close(dfd); return .failure(.cannotOpen(parent, String(cString: strerror(errno))))
        }
        let realDir = String(cString: buf)
        guard fstatat(dfd, file, &fst, AT_SYMLINK_NOFOLLOW) == 0 else {
            close(dfd); return .failure(.cannotOpen(p, String(cString: strerror(errno))))
        }
        let kind = fst.st_mode & S_IFMT
        if kind == S_IFLNK { close(dfd); return .failure(.symlink(p)) }
        if kind != S_IFREG { close(dfd); return .failure(.notRegular(p)) }
        if fst.st_nlink != 1 { close(dfd); return .failure(.hardLinks(p, Int(fst.st_nlink))) }
        guard ownershipOK(canonical: canonical.contains(realDir), dirOwner: dst.st_uid, fileOwner: fst.st_uid, caller: caller) else {
            close(dfd); return .failure(.foreignOwner(dir: realDir, dirOwner: dst.st_uid, fileOwner: fst.st_uid))
        }
        return .success(WGConfHandle(dirFD: dfd, dir: realDir, name: String(file.dropLast(5)), ino: fst.st_ino, dev: fst.st_dev))
    }

    /// Чи можна від root переглядати вміст теки (wgConfigs): ті самі правила, що й для файлів.
    public static func dirListable(_ dir: String, caller: uid_t?,
                                   dirs: [String] = WGPaths.dirs, canonical: Set<String> = WGPaths.canonical) -> Bool {
        guard dirs.contains(dir) else { return false }
        let dfd = Darwin.open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { return false }
        defer { close(dfd) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var st = stat()
        guard fcntl(dfd, F_GETPATH, &buf) == 0, fstat(dfd, &st) == 0 else { return false }
        if canonical.contains(String(cString: buf)) { return true }
        guard let caller, caller != 0 else { return false }
        return st.st_uid == caller
    }
}
