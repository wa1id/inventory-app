import Foundation
import Testing
@testable import InventoryStorage

/// 02 §11.2 #1. The committed fixture in `Fixtures/adoption/RCTAsyncLocalStorage_V1` holds the
/// seven keys with `categories.recent.v1` in its MD5 overflow file.
@Suite("LegacyAsyncStorageReader")
struct LegacyAsyncStorageReaderTests {
    static let storePath = "Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1"

    static func reader(_ container: TemporaryContainer) -> LegacyAsyncStorageReader {
        LegacyAsyncStorageReader(
            applicationSupport: container.applicationSupport, documents: container.documents,
            bundleIdentifier: "com.wystudio.inventory")
    }

    /// Copies the committed RN store into the container's Application Support directory.
    static func installFixture(in container: TemporaryContainer, at path: String = storePath) throws {
        let source = try AdoptionFixtures.url("RCTAsyncLocalStorage_V1")
        let destination = container.root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    static func expectedFixtureValues() throws -> [String: String] {
        try AdoptionFixtures.decode([String: String].self, from: "legacy-storage-expected.json")
    }

    // MARK: MD5 file names

    struct MD5Vector: Decodable { let key: String; let md5: String }

    @Test("md5Hex equals Node's crypto MD5 for every vector")
    func md5Vectors() throws {
        for vector in try AdoptionFixtures.decode([MD5Vector].self, from: "md5-vectors.json") {
            #expect(LegacyAsyncStorageReader.md5Hex(vector.key) == vector.md5, "\(vector.key)")
        }
    }

    @Test("md5Hex equals the seven vectors in 02 §5.3", arguments: [
        ("onboarding.completed.v1", "4efd6215b53ae2eccc3504de2a5a5352"),
        ("places.recent.v1", "29ce820024d261826454db01a9ea7e83"),
        ("categories.recent.v1", "9355fb19fd0f6f39f84680882e0638d7"),
        ("notice.unpaired.dismissed.v1", "85473032ec85220ff4db0e47bb85ea0c"),
        ("sync.lastBackupAt.v1", "4102c4cb6d3d14e013e7d1264995f65b"),
        ("household.importOffer.v1", "53ba6e24df460ea0df0bec2d52664252"),
        ("household.joinedBefore.v1", "56c32de8db5d6d12a35b329fcc891dac"),
    ])
    func specMD5(key: String, md5: String) {
        #expect(LegacyAsyncStorageReader.md5Hex(key) == md5)
    }

    // MARK: The committed fixture

    @Test("reads inline values and the overflow file of the committed fixture")
    func committedFixture() throws {
        let container = try TemporaryContainer()
        try Self.installFixture(in: container)
        let values = try Self.reader(container).readAll()
        #expect(values == (try Self.expectedFixtureValues()))
        // The overflow value really is past the inline threshold, in UTF-16 units.
        #expect((values["categories.recent.v1"]?.utf16.count ?? 0) > 1024)
        // `\/` in the manifest decodes to `/`.
        #expect(values["debug.lastOpenedUrl"] == "https://inventory.wystudio.be/v1/health")
        // A null entry whose file is missing is absent.
        #expect(values["some.removed.value"] == nil)
    }

    @Test("the reader looks in Application Support/<bundle id>/RCTAsyncLocalStorage_V1")
    func defaultLocation() {
        let reader = LegacyAsyncStorageReader(
            applicationSupport: URL(filePath: "/c/Library/Application Support"), documents: URL(filePath: "/c/Documents"),
            bundleIdentifier: "com.wystudio.inventory")
        #expect(reader.directory.path == "/c/Library/Application Support/com.wystudio.inventory/RCTAsyncLocalStorage_V1")
        #expect(reader.legacyDirectory.path == "/c/Documents/RCTAsyncLocalStorage_V1")
    }

    // MARK: Manifest cases

    func read(manifest: Data?, files: [String: Data] = [:]) throws(LegacyAsyncStorageReader.Failure) -> [String: String] {
        let container = try! TemporaryContainer()
        try! container.createDirectory(Self.storePath)
        if let manifest { try! container.write(manifest, to: Self.storePath + "/manifest.json") }
        for (name, data) in files { try! container.write(data, to: Self.storePath + "/" + name) }
        return try Self.reader(container).readAll()
    }

    @Test("inline string value")
    func inlineValue() throws {
        #expect(try read(manifest: Data(#"{"onboarding.completed.v1":"true"}"#.utf8)) == ["onboarding.completed.v1": "true"])
    }

    @Test("null value with an overflow file")
    func overflowValue() throws {
        let long = "[" + Array(repeating: "\"x\"", count: 400).joined(separator: ",") + "]"
        let values = try read(
            manifest: Data(#"{"categories.recent.v1":null}"#.utf8),
            files: ["9355fb19fd0f6f39f84680882e0638d7": Data(long.utf8)])
        #expect(values == ["categories.recent.v1": long])
    }

    @Test("null value with the file missing is absent")
    func overflowMissing() throws {
        #expect(try read(manifest: Data(#"{"categories.recent.v1":null,"a":"b"}"#.utf8)) == ["a": "b"])
    }

    @Test("an overflow file that is not UTF-8 throws unreadableValue instead of reading as absent")
    func overflowNotUTF8() {
        #expect(throws: LegacyAsyncStorageReader.Failure.unreadableValue(key: "categories.recent.v1")) {
            try read(
                manifest: Data(#"{"categories.recent.v1":null}"#.utf8),
                files: ["9355fb19fd0f6f39f84680882e0638d7": Data([0xFF, 0xFE, 0x00, 0xD8])])
        }
    }

    @Test("an overflow file that exists but cannot be read throws unreadableValue")
    func overflowUnreadable() throws {
        let container = try TemporaryContainer()
        try container.write(Data(#"{"categories.recent.v1":null}"#.utf8), to: Self.storePath + "/manifest.json")
        // A directory in place of the file: it exists, and reading it fails.
        try container.createDirectory(Self.storePath + "/9355fb19fd0f6f39f84680882e0638d7")
        #expect(throws: LegacyAsyncStorageReader.Failure.unreadableValue(key: "categories.recent.v1")) {
            try Self.reader(container).readAll()
        }
    }

    @Test("missing manifest reads as empty")
    func missingManifest() throws {
        #expect(try read(manifest: nil).isEmpty)
        let container = try TemporaryContainer()
        #expect(try Self.reader(container).readAll().isEmpty)
    }

    @Test("unparsable or non-object manifest reads as empty", arguments: [
        "", "not json", "{\"a\":", "[\"a\"]", "\"text\"", "null", "42",
    ])
    func unparsableManifest(text: String) throws {
        #expect(try read(manifest: Data(text.utf8)).isEmpty)
    }

    @Test("a manifest that is not UTF-8 throws")
    func manifestNotUTF8() {
        #expect(throws: LegacyAsyncStorageReader.Failure.manifestNotUTF8) {
            try read(manifest: Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x22, 0x61, 0x22, 0x7D]))
        }
    }

    @Test("a manifest that exists but cannot be read throws")
    func manifestUnreadable() throws {
        let container = try TemporaryContainer()
        try container.createDirectory(Self.storePath + "/manifest.json")
        let error = #expect(throws: LegacyAsyncStorageReader.Failure.self) {
            try Self.reader(container).readAll()
        }
        guard case .unreadableManifest? = error else {
            Issue.record("expected unreadableManifest, got \(String(describing: error))")
            return
        }
    }

    @Test("escaped slashes and unicode escapes decode")
    func escapes() throws {
        let manifest = #"{"k":"https:\/\/h\/x é \"q\""}"#
        #expect(try read(manifest: Data(manifest.utf8)) == ["k": "https://h/x é \"q\""])
    }

    @Test("values that are neither strings nor null are skipped")
    func otherValueTypes() throws {
        #expect(try read(manifest: Data(#"{"a":1,"b":true,"c":{"d":"e"},"f":"g"}"#.utf8)) == ["f": "g"])
    }

    // MARK: Older location

    @Test("falls back to Documents/RCTAsyncLocalStorage_V1 only when Application Support has no store")
    func documentsFallback() throws {
        let container = try TemporaryContainer()
        try Self.installFixture(in: container, at: "Documents/RCTAsyncLocalStorage_V1")
        #expect(try Self.reader(container).readAll() == (try Self.expectedFixtureValues()))

        // Once the Application Support directory exists, RN uses it, even without a manifest.
        try container.createDirectory(Self.storePath)
        #expect(try Self.reader(container).readAll().isEmpty)
        try container.write(Data(#"{"onboarding.completed.v1":"true"}"#.utf8), to: Self.storePath + "/manifest.json")
        #expect(try Self.reader(container).readAll() == ["onboarding.completed.v1": "true"])
    }

    // MARK: Round trip with RN's writer

    /// RNCAsyncStorage's `_writeEntry` + `_writeManifest` (RNCAsyncStorage.mm:570-584, 620-650):
    /// values up to 1024 UTF-16 units inline, longer ones in `<md5(key)>` written as UTF-8 with a
    /// null manifest entry, manifest serialised by NSJSONSerialization with fragments allowed.
    static func writeLikeRN(_ values: [String: String], into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = [:]
        for (key, value) in values {
            if (value as NSString).length <= 1024 {
                manifest[key] = value
            } else {
                try value.write(
                    to: directory.appending(path: LegacyAsyncStorageReader.md5Hex(key)), atomically: true, encoding: .utf8)
                manifest[key] = NSNull()
            }
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: .fragmentsAllowed)
        let text = try #require(String(data: data, encoding: .utf8))
        try text.write(to: directory.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
    }

    @Test("reads back what RN's writer produces, at and past the inline threshold")
    func roundTripWithRNWriter() throws {
        let container = try TemporaryContainer()
        let exactly1024 = String(repeating: "é", count: 1024)  // 1024 UTF-16 units, 2048 bytes
        let past = String(repeating: "📦", count: 513)          // 1026 UTF-16 units
        let values = [
            "onboarding.completed.v1": "true",
            "places.recent.v1": #"["a/b"]"#,
            "categories.recent.v1": past,
            "sync.lastBackupAt.v1": exactly1024,
        ]
        let directory = container.root.appending(path: Self.storePath, directoryHint: .isDirectory)
        try Self.writeLikeRN(values, into: directory)
        #expect(container.exists(Self.storePath + "/9355fb19fd0f6f39f84680882e0638d7"))
        #expect(!container.exists(Self.storePath + "/4102c4cb6d3d14e013e7d1264995f65b"))
        #expect(try Self.reader(container).readAll() == values)
    }
}
