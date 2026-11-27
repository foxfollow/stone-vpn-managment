import Foundation

/// Хто з локальних користувачів може користуватися helper-ом (протокол v7).
/// Перевірка підпису каже лише, *який код* підключився; без цього будь-який користувач Mac міг би
/// запустити справжній застосунок і через ovpnStart (openvpn від root, script-security 2) отримати root.
public enum HelperAccessPolicy: String, Codable, Sendable, CaseIterable {
    /// Лише власник — користувач, що встановив застосунок (власник бандла) або забрав helper паролем адміністратора.
    case owner
    /// Власник і члени групи admin.
    case admins
    /// Усі локальні користувачі.
    case everyone
}

extension HelperAccessPolicy {
    /// Чи обслуговувати `uid`. root — завжди; без власника — нікого (лише пароль адміністратора).
    public func permits(_ uid: UInt32?, owner: UInt32?, isAdmin: (UInt32) -> Bool) -> Bool {
        guard let uid else { return false }
        if uid == 0 { return true }
        guard let owner else { return false }
        switch self {
        case .owner: return uid == owner
        case .admins: return uid == owner || isAdmin(uid)
        case .everyone: return true
        }
    }
}

/// Відповідь `PrivOp.accessInfo`: стан доступу з погляду того, хто питає.
public struct HelperAccessInfo: Codable, Sendable, Equatable {
    public var ownerUID: UInt32?
    public var ownerName: String?
    public var policy: HelperAccessPolicy
    public var callerUID: UInt32?
    public var callerAllowed: Bool

    public var callerIsOwner: Bool { ownerUID != nil && ownerUID == callerUID }

    public init(ownerUID: UInt32?, ownerName: String?, policy: HelperAccessPolicy, callerUID: UInt32?, callerAllowed: Bool) {
        self.ownerUID = ownerUID
        self.ownerName = ownerName
        self.policy = policy
        self.callerUID = callerUID
        self.callerAllowed = callerAllowed
    }
}

public enum HelperAccessStore {
    /// root:wheel 0755 / 0644 — пише лише helper (root).
    public static let dir = "/Library/Application Support/StoneVPNManager"
    public static var file: String { dir + "/helper-access.json" }
}
