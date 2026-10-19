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
    // Pinned exactly: the XcodeGen-generated app project resolves packages on its own and never
    // reads this package's Package.resolved, so a range could build the app against a newer
    // release than the one `swift test` ran.
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        // libwebp alone (no image framework) for encoding photos as WebP: ImageIO decodes WebP
        // but cannot encode it (docs/spec/05-capture-ai.md C3). Used by InventoryServices only.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", exact: "1.6.0"),
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
        // Backup, photo sync, image store, household shadow and HTTP repositories. GRDB directly
        // for the backup snapshot, the photo queue and the household shadow's transactions.
        .target(
            name: "InventoryServices",
            dependencies: [
                "InventoryCore",
                "InventoryStorage",
                "InventoryNetwork",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "libwebp", package: "libwebp-Xcode"),
            ]
        ),
        // @MainActor @Observable models the SwiftUI views bind to.
        .target(
            name: "InventoryAppModels",
            dependencies: ["InventoryStrings", "InventoryCore", "InventoryStorage", "InventoryNetwork", "InventoryServices"]
        ),

        // Test-only helpers shared by every test target: ManualClock, temporary directories and
        // UserDefaults suites, RecordingTelemetry, and a URLProtocol stub server. Not a product,
        // so the app never links it.
        .target(name: "InventoryTestSupport", dependencies: ["InventoryCore"]),

        .testTarget(name: "InventoryStringsTests", dependencies: ["InventoryStrings", "InventoryTestSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryCoreTests", dependencies: ["InventoryCore", "InventoryTestSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryStorageTests", dependencies: ["InventoryStorage", "InventoryTestSupport", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryNetworkTests", dependencies: ["InventoryNetwork", "InventoryTestSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryServicesTests", dependencies: ["InventoryServices", "InventoryTestSupport", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Fixtures")]),
        .testTarget(name: "InventoryAppModelsTests", dependencies: ["InventoryAppModels", "InventoryTestSupport", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
