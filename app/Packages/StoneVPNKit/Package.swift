// swift-tools-version: 6.0
// StoneVPNKit — ядро StoneVPNManager без UI: моделі, парсери (порт bash-логіки),
// читання системного стану, дії, протокол app ↔ privileged helper.
// Підключено до Xcode-проєкту як локальний пакет; тести: `swift test` тут.
import PackageDescription

let package = Package(
    name: "StoneVPNKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "StoneVPNShared", targets: ["StoneVPNShared"]),
        .library(name: "StoneVPNCore", targets: ["StoneVPNCore"]),
    ],
    targets: [
        .target(name: "StoneVPNShared"),
        .target(
            name: "StoneVPNCore",
            dependencies: ["StoneVPNShared"],
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .testTarget(name: "StoneVPNCoreTests", dependencies: ["StoneVPNCore"]),
    ],
    swiftLanguageModes: [.v5]
)
