import Foundation
import InventoryNetwork
import InventoryStorage

// Small helpers shared by the sync services. Internal; named for the sync area so they never
// collide with another area's helpers in this module.

enum SyncTiming {
    /// Whole milliseconds since `start`, as RN's `Date.now() - startedAt`.
    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

enum SyncWorkerRules {
    /// The Worker's photo id check, `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`
    /// (worker/src/contract.ts:80-84). Any other id is answered 400 "Invalid photo id." on every
    /// try, so the uploader never sends one (03 B2).
    static func isPhotoId(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == UInt8(ascii: "-") else { return false }
            default:
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                else { return false }
            }
        }
        return true
    }

    /// Whether downloaded bytes start like an image the app wrote or imported: WebP, JPEG, PNG
    /// or GIF (03 B10). A captive portal or a proxy answering 200 with HTML fails this, so its
    /// page is never written over a photo.
    static func looksLikeImage(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        return ImageMediaType.sniff(data) != ImageMediaType.fallback
    }
}

extension LastBackupPreference {
    /// ``lastBackupAt`` as whole milliseconds (what the status and `Format.ago` take), or nil
    /// when nothing finite is stored or it does not fit (03 §5.3).
    public var lastBackupAtMilliseconds: Int64? {
        guard let value = lastBackupAt else { return nil }
        return Int64(exactly: value.rounded(.down))
    }
}
