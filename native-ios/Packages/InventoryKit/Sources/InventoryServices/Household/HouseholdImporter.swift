import Foundation
import InventoryCore
import InventoryNetwork
import InventoryStorage

/// What copying the phone's inventory into the household came to (RN `ImportResult`).
public struct HouseholdImportResult: Sendable, Hashable {
    /// Items the server reports it took, or the dump's item count when it reports no number.
    public var items: Int
    /// Photo rows in the dump.
    public var photos: Int
    /// Photos whose bytes the server stored.
    public var photosUploaded: Int
    /// Photos with no bytes on this phone or in the backup, or that the server refused.
    public var photosMissing: Int

    public init(items: Int, photos: Int, photosUploaded: Int, photosMissing: Int) {
        self.items = items
        self.photos = photos
        self.photosUploaded = photosUploaded
        self.photosMissing = photosMissing
    }
}

/// Copies this phone's own inventory into the household, keeping every id
/// (RN: src/services/household/importHousehold.ts; 04 §11.3).
///
/// Re-running is safe: the server upserts by id and photo uploads overwrite the same keys.
public struct HouseholdImporter: Sendable {
    /// Where a photo's bytes come from when its local file is gone: the phone backup's photo
    /// store (RN `createSyncClient({recoveryCode}).downloadPhoto`). Nil bytes means it has none.
    public typealias PhotoFallback = @Sendable (_ photoId: String) async -> Data?

    private let client: HouseholdClient
    private let photos: any PhotoStoring
    private let makeFallback: @Sendable () async -> PhotoFallback?
    private let telemetry: TelemetryReporter

    /// - Parameters:
    ///   - session: the household to copy into.
    ///   - client: carries the transport and reachability hub; re-aimed at the session.
    ///   - photos: reads each local photo file (RN `readStoredPhoto`).
    ///   - makeFallback: builds the backup fallback, called only after the dump was accepted;
    ///     nil means there is none (no backup account, or it could not be built).
    ///     ``backupPhotoFallback(recoveryCodes:config:transport:)`` is RN's.
    public init(
        session: HouseholdSession,
        client: HouseholdClient,
        photos: any PhotoStoring,
        makeFallback: @escaping @Sendable () async -> PhotoFallback? = { nil },
        telemetry: TelemetryReporter = .shared
    ) {
        self.client = client.forSession(session)
        self.photos = photos
        self.makeFallback = makeFallback
        self.telemetry = telemetry
    }

    /// RN `importLocalInventory({session, db})`.
    ///
    /// 1. Collects the dump and the photo URIs from the local database.
    /// 2. `POST /v1/import` with the dump, 60 s; any failure fails the whole import.
    /// 3. For each photo row, one after the other: the local file's bytes, else the backup's;
    ///    none counts as missing. Then `PUT /v1/photos/<id>` with the bytes, 60 s: a non-2xx
    ///    answer counts as missing, a 2xx as uploaded, and a transport failure (offline,
    ///    timeout) aborts the import.
    /// 4. Logs `household_imported` with the dump's item count.
    ///
    /// - Parameter store: the raw local database, never the shadowed repositories.
    public func importLocalInventory(from store: DatabaseStore) async throws -> HouseholdImportResult {
        let (dump, uris) = try await HouseholdDumpCollector.snapshot(from: store)
        let summary = try await client.importDump(dump)
        let fallback = await makeFallback()

        var photosUploaded = 0
        var photosMissing = 0
        for photo in dump.photos {
            var bytes: Data?
            // RN `localUri ? await readPhoto(localUri) : null`.
            if let uri = uris[photo.id], !uri.isEmpty {
                bytes = await photos.readStoredPhoto(uri)
            }
            if bytes == nil, let fallback {
                bytes = await fallback(photo.id)
            }
            guard let bytes else {
                photosMissing += 1
                continue
            }
            if try await client.importPhoto(id: photo.id, bytes: bytes) {
                photosUploaded += 1
            } else {
                photosMissing += 1
            }
        }

        telemetry.event("household_imported", ["itemCount": .int(dump.items.count)])

        return HouseholdImportResult(
            items: summary.items ?? dump.items.count,
            photos: dump.photos.count,
            photosUploaded: photosUploaded,
            photosMissing: photosMissing
        )
    }

    /// RN `loadSyncClient()` (importHousehold.ts:84-94): the phone backup's photo store when
    /// this phone has a backup account, else nil.
    ///
    /// The recovery code is read from the keychain (any keychain error is no account) and must
    /// decode to the 16 bytes of an account secret (RN `loadAccount`, identity.ts:52-68). The
    /// client uses the build's sync endpoint, key and timeout; without an endpoint every
    /// download fails as `not_configured`, which reads as no bytes. A download never throws.
    public static func backupPhotoFallback(
        recoveryCodes: RecoveryCodeStore,
        config: AppConfig,
        transport: any HTTPTransport = URLSessionTransport.shared
    ) -> @Sendable () async -> PhotoFallback? {
        {
            guard let code = recoveryCodes.load(), RecoveryCode.secret(from: code) != nil else { return nil }
            let sync = SyncClient(
                recoveryCode: code,
                endpoint: config.syncEndpoint,
                key: config.syncKey,
                timeout: config.syncTimeout,
                transport: transport
            )
            return { photoId in
                guard case .success(let bytes) = await sync.downloadPhoto(id: photoId) else { return nil }
                return bytes
            }
        }
    }
}
