// swift-tools-version: 6.2
import PackageDescription

// The app's logic, kept out of the app target so `swift test` runs it on the
// build Mac without a simulator. macOS is a test host only; the app ships on
// iOS 26. Module boundaries follow docs/spec/09-app-shell-lifecycle-config.md §13.1.
let package = Package(
    name: "InventoryKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "InventoryStrings", targets: ["InventoryStrings"]),
        .library(name: "InventoryCore", targets: ["InventoryCore"]),
        .library(name: "InventoryStorage", targets: ["InventoryStorage"]),
        .library(name: "InventoryNetwork", targets: ["InventoryNetwork"]),
        .library(name: "InventoryServices", targets: ["InventoryServices"]),
        .library(name: "InventoryAppModels", targets: ["InventoryAppModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        // User-facing copy: Localizable.xcstrings generated from src/i18n/strings.ts,
        // plus typed accessors. Every other module reads copy through here.
        .target(
            name: "InventoryStrings",
            resources: [.process("Resources")]
        ),
        // Pure logic: config, telemetry, errors, ids, base32, quantity, tokenizer, short codes.
        .target(name: "InventoryCore", dependencies: ["InventoryStrings"]),
        // SQLite (GRDB), migrations, repositories, keychain, preferences, legacy import.
        .target(
            name: "InventoryStorage",
            dependencies: [
                "InventoryCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // HTTP clients for the household hub, the sync worker and recognition.
        .target(name: "InventoryNetwork", dependencies: ["InventoryCore"]),
        // Backup, photo sync, image store, household shadow and HTTP repositories.
        .target(
            name: "InventoryServices",
            dependencies: ["InventoryCore", "InventoryStorage", "InventoryNetwork"]
        ),
        // @MainActor @Observable models the SwiftUI views bind to.
        .target(
            name: "InventoryAppModels",
            dependencies: ["InventoryCore", "InventoryStorage", "InventoryNetwork", "InventoryServices"]
        ),

        .testTarget(name: "InventoryStringsTests", dependencies: ["InventoryStrings"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryCoreTests", dependencies: ["InventoryCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryStorageTests", dependencies: ["InventoryStorage"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryNetworkTests", dependencies: ["InventoryNetwork"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryServicesTests", dependencies: ["InventoryServices"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryAppModelsTests", dependencies: ["InventoryAppModels"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
