import Foundation
import InventoryAppModels
import InventoryCore
import InventoryStrings
import Testing
import UIKit
@testable import Inventory

/// What the app bundle itself must carry for the App Store update to the RN app (02 §9,
/// docs/RELEASE.md). These run in the Debug test host; scripts/release/check-release.sh checks the
/// same Info.plist, privacy manifest and asset catalog on a Release build for a device.
@Suite("Release bundle")
struct ReleaseBundleTests {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// The Info.plist file itself: `infoDictionary` folds the `~ipad` keys into the plain ones on
    /// an iPhone and drops them.
    private func rawInfo() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        return try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    @Test("identity, version and the device constraints an App Store update must keep (02 §9.1-9.3)")
    func identityAndConstraints() throws {
        #expect(Bundle.main.bundleIdentifier == "com.wystudio.inventory")
        #expect(info["CFBundleDisplayName"] as? String == "Inventory")
        let version = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(version.split(separator: ".").count == 3 && version.allSatisfy { $0.isNumber || $0 == "." })
        // The last EAS build was 0.1.0 (15): the first native build must be above both.
        let build = try #require(Int(info["CFBundleVersion"] as? String ?? ""))
        #expect(build >= 16)
        #expect(version.compare("0.1.0", options: .numeric) == .orderedDescending)
        #expect(info["UIRequiredDeviceCapabilities"] as? [String] == ["arm64"])
        #expect(info["UIDeviceFamily"] as? [Int] == [1, 2])
        #expect(info["MinimumOSVersion"] as? String == "26.0")
        #expect(info["LSRequiresIPhoneOS"] as? Bool == true)
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }

    @Test("iPhone portrait only, iPad every orientation, multitasking left on (02 §9.4, U4)")
    func orientations() throws {
        let raw = try rawInfo()
        #expect(raw["UISupportedInterfaceOrientations"] as? [String]
            == ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown"])
        #expect(Set(raw["UISupportedInterfaceOrientations~ipad"] as? [String] ?? []) == [
            "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
        ])
        #expect(raw["UIRequiresFullScreen"] == nil)
    }

    @Test("the inventory URL scheme printed labels open, and the bundle-id scheme Expo added (02 §9.6)")
    func urlSchemes() {
        let types = info["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == ["inventory", "com.wystudio.inventory"])
    }

    @Test("usage strings exactly as RN shipped them, and nothing RN did not ask for (02 §9.4)")
    func usageStrings() {
        #expect(info["NSCameraUsageDescription"] as? String
            == "Inventory uses the camera so you can photograph items you are adding and scan QR labels on your containers.")
        #expect(info["NSPhotoLibraryUsageDescription"] as? String
            == "Inventory can import a photo from your library to illustrate an item you are adding.")
        for absent in [
            "NSMicrophoneUsageDescription", "NSFaceIDUsageDescription", "NSPhotoLibraryAddUsageDescription",
            "UIBackgroundModes", "UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace",
            "UIDesignRequiresCompatibility", "NSUserActivityTypes", "UILaunchStoryboardName",
        ] {
            #expect(info[absent] == nil, "\(absent)")
        }
    }

    @Test("ATS: https only; local networking and its usage string in Debug alone (00-index §5)")
    func transportSecurity() {
        let ats = info["NSAppTransportSecurity"] as? [String: Any] ?? [:]
        #expect(ats["NSAllowsArbitraryLoads"] as? Bool == false)
        #if DEBUG
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect((info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty == false)
        #else
        #expect(ats["NSAllowsLocalNetworking"] == nil)
        #expect(info["NSLocalNetworkUsageDescription"] == nil)
        #endif
    }

    @Test("the plain launch screen, one scene (U3)")
    func launchScreen() {
        #expect((info["UILaunchScreen"] as? [String: Any])?.isEmpty == true)
        #expect((info["UIApplicationSceneManifest"] as? [String: Any])?["UIApplicationSupportsMultipleScenes"] as? Bool == false)
    }

    @Test("the Quick Snap Home Screen quick action is the router's and reads strings.tabs.quickSnapAction (U5)")
    func quickSnapShortcut() throws {
        let items = try #require(info["UIApplicationShortcutItems"] as? [[String: Any]])
        #expect(items.count == AppQuickAction.allCases.count)
        let item = try #require(items.first)
        #expect(item["UIApplicationShortcutItemType"] as? String == AppQuickAction.quickSnap.rawValue)
        #expect(item["UIApplicationShortcutItemTitle"] as? String == L10n.Tabs.quickSnapAction)
        #expect(item["UIApplicationShortcutItemIconSymbolName"] as? String == Glyph.camera.rawValue)
    }

    @Test("every configuration key is substituted, and an empty app key means no key (09 §8)")
    func configurationKeys() throws {
        for key in AppConfig.InfoKey.allCases {
            let value = try #require(info[key.rawValue] as? String, "\(key.rawValue)")
            #expect(!value.contains("$("), "\(key.rawValue)")
        }
        let config = AppConfig.load(from: .main)
        // Without Config/Secrets.xcconfig both keys are empty: the clients then send no
        // x-inventory-key and the servers answer 401, which reads as a failed suggestion or a
        // failed backup (RecognitionClientTests, SyncClientTests), never a crash.
        let recognitionKey = (info[AppConfig.InfoKey.recognitionKey.rawValue] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let syncKey = (info[AppConfig.InfoKey.syncKey.rawValue] as? String ?? "").trimmingCharacters(in: .whitespaces)
        #expect((config.recognitionKey == nil) == recognitionKey.isEmpty)
        #expect((config.syncKey == nil) == syncKey.isEmpty)
        #expect(config.appVersion == info["CFBundleShortVersionString"] as? String)
    }

    @Test("the privacy manifest ships at the bundle root with the reasons the code needs (02 §9.9)")
    func privacyManifest() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        let apis = (manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []).reduce(into: [String: [String]]()) {
            $0[$1["NSPrivacyAccessedAPIType"] as? String ?? ""] = $1["NSPrivacyAccessedAPITypeReasons"] as? [String]
        }
        #expect(apis == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
        ])
        let collected = manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
        #expect(Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == [
            "NSPrivacyCollectedDataTypePhotosorVideos", "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID",
        ])
        for entry in collected {
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(entry["NSPrivacyCollectedDataTypePurposes"] as? [String] == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }

    @Test("AccentColor is ink and Tape is the label yellow, light and dark (U2)")
    func brandColours() throws {
        #expect(info["NSAccentColorName"] as? String == "AccentColor")
        let accent = try #require(UIColor(named: "AccentColor"))
        #expect(Self.hex(accent, .light) == "1C211E")
        #expect(Self.hex(accent, .dark) == "E8ECE8")
        let tape = try #require(UIColor(named: "Tape"))
        #expect(Self.hex(tape, .light) == "FFD23F")
        #expect(Self.hex(tape, .dark) == "F4CA3C")
    }

    @Test("the app icon is the single 1024 pt source (U3)")
    func appIcon() throws {
        let icons = try #require(info["CFBundleIcons"] as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == "AppIcon")
    }

    private static func hex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> String {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
