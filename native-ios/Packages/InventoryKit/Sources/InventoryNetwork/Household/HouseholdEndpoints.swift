import Foundation
import InventoryCore

// Every home-server endpoint the app calls (04 §3.5), one method each. Inventory
// ids go into paths without percent-encoding, as RN interpolates them; device
// and photo ids and query values are encoded with `encodeURIComponent`. Methods
// that RN wraps in `callIgnoring404` return nil (or `.alreadyGone`) on a 404.

extension HouseholdClient {
    // MARK: Pairing and phones

    /// `POST /v1/pair` (no token): joins with the household code (RN `pairWithHousehold`).
    ///
    /// Sent to this client's origin with trailing slashes stripped. The answer must
    /// carry string `token`, `deviceId` and `origin`, or this throws
    /// `HouseholdHttpError(500, "invalid_response")`. `contractVersion` is ignored (04 Q1).
    public func pair(bootstrapSecret: String, deviceName: String) async throws -> HouseholdPairing {
        let target = withSession(origin: strippingTrailingSlashes(origin), token: nil)
        let answer = try await target.object(HouseholdRequest(
            path: "/v1/pair",
            method: "POST",
            body: try .encodedJSON(HouseholdBody.Pair(bootstrapSecret: bootstrapSecret, deviceName: deviceName)),
            authenticated: false
        ))
        let body = answer.value.objectValue ?? [:]
        guard let token = body["token"]?.stringValue,
              let deviceId = body["deviceId"]?.stringValue,
              let serverOrigin = body["origin"]?.stringValue
        else { throw HouseholdHttpError(status: 500, code: "invalid_response") }
        return HouseholdPairing(
            origin: strippingTrailingSlashes(serverOrigin),
            token: token,
            deviceId: deviceId,
            deviceName: deviceName.jsTrimmed(),
            householdName: body["householdName"]?.stringValue ?? "Home"
        )
    }

    /// `GET /v1/health` (no token): the offline ping. Reachability is what matters;
    /// callers usually ignore the answer.
    public func health(timeout: Duration = HouseholdClient.healthTimeout) async throws -> HouseholdHealth {
        try await request(HouseholdRequest(path: "/v1/health", timeout: timeout, authenticated: false))
    }

    /// `GET /v1/devices`: every joined phone, oldest first (RN `listDevices`).
    ///
    /// Entries without string `id` and `name` are skipped; a body without a
    /// `devices` array throws `HouseholdHttpError(500, "invalid_response")`.
    public func listDevices() async throws -> [HouseholdDevice] {
        let answer = try await object(HouseholdRequest(path: "/v1/devices"))
        guard case .array(let entries)? = answer.value.objectValue?["devices"] else {
            throw HouseholdHttpError(status: 500, code: "invalid_response")
        }
        return entries.compactMap(HouseholdDevice.init(wire:))
    }

    /// `DELETE /v1/devices/:id`: removes a phone, this one included (RN `revokeDevice`).
    /// A 404 means it is already gone, which is what was asked for.
    ///
    /// - Parameter timeout: leaving passes 5 s, since it must work offline.
    public func revokeDevice(id: String, timeout: Duration? = nil) async throws {
        _ = try await ignoring404 {
            try await object(HouseholdRequest(path: "/v1/devices/\(encodeURIComponent(id))", method: "DELETE", timeout: timeout))
        }
    }

    // MARK: Spaces

    /// `GET /v1/spaces`: normal spaces with counts, by name.
    public func listSpaces() async throws -> [SpaceWithCounts] {
        try await request(HouseholdRequest(path: "/v1/spaces"), as: SpacesBody.self).spaces ?? []
    }

    /// `GET /v1/spaces/:id`; nil on 404.
    public func space(id: String) async throws -> Space? {
        try await ignoring404 { try await request(HouseholdRequest(path: "/v1/spaces/\(id)"), as: Space.self) }
    }

    /// `POST /v1/spaces` → 201 `Space`.
    public func createSpace(_ space: HouseholdBody.NewSpace) async throws -> Space {
        try await request(HouseholdRequest(path: "/v1/spaces", method: "POST", body: try .encodedJSON(space)))
    }

    /// `PATCH /v1/spaces/:id`; nil on 404.
    public func updateSpace(id: String, _ patch: HouseholdBody.SpacePatch) async throws -> Space? {
        let body = try HouseholdRequest.Body.encodedJSON(patch)
        return try await ignoring404 {
            try await request(HouseholdRequest(path: "/v1/spaces/\(id)", method: "PATCH", body: body), as: Space.self)
        }
    }

    /// `DELETE /v1/spaces/:id`; `.alreadyGone` on 404.
    public func deleteSpace(id: String) async throws -> HouseholdDeleteResult {
        try await delete(path: "/v1/spaces/\(id)")
    }

    // MARK: Containers

    /// `GET /v1/containers?spaceId=`: a space's containers with counts, newest first.
    public func listContainers(spaceId: String) async throws -> [ContainerWithCounts] {
        let path = "/v1/containers?spaceId=\(encodeURIComponent(spaceId))"
        return try await request(HouseholdRequest(path: path), as: ContainersBody<ContainerWithCounts>.self).containers ?? []
    }

    /// `GET /v1/containers`: every normal container with its space name (the place picker).
    public func listAllContainers() async throws -> [ContainerWithSpace] {
        try await request(HouseholdRequest(path: "/v1/containers"), as: ContainersBody<ContainerWithSpace>.self)
            .containers ?? []
    }

    /// `GET /v1/containers/:id` → `ContainerWithCounts`; nil on 404.
    public func container(id: String) async throws -> ContainerWithCounts? {
        try await ignoring404 {
            try await request(HouseholdRequest(path: "/v1/containers/\(id)"), as: ContainerWithCounts.self)
        }
    }

    /// `POST /v1/containers` → 201 `Container`; the server makes the id and short code.
    public func createContainer(_ container: HouseholdBody.NewContainer) async throws -> Container {
        try await request(HouseholdRequest(path: "/v1/containers", method: "POST", body: try .encodedJSON(container)))
    }

    /// `PATCH /v1/containers/:id` → `Container`; nil on 404.
    public func updateContainer(id: String, _ patch: HouseholdBody.ContainerPatch) async throws -> Container? {
        let body = try HouseholdRequest.Body.encodedJSON(patch)
        return try await ignoring404 {
            try await request(HouseholdRequest(path: "/v1/containers/\(id)", method: "PATCH", body: body), as: Container.self)
        }
    }

    /// `DELETE /v1/containers/:id`; `.alreadyGone` on 404.
    public func deleteContainer(id: String) async throws -> HouseholdDeleteResult {
        try await delete(path: "/v1/containers/\(id)")
    }

    // MARK: Items

    /// `GET /v1/items?containerId=`: a container's items, newest first.
    /// The server treats `drop-zone` as the unsorted list.
    public func listItems(containerId: String) async throws -> [ItemWithContext] {
        try await items(path: "/v1/items?containerId=\(encodeURIComponent(containerId))")
    }

    /// `GET /v1/items?unsorted=1`: the drop zone.
    public func listUnsortedItems() async throws -> [ItemWithContext] {
        try await items(path: "/v1/items?unsorted=1")
    }

    /// `GET /v1/items?recent=1&limit=N`; the server clamps `limit` to 1…100.
    public func listRecentItems(limit: Int = 40) async throws -> [ItemWithContext] {
        try await items(path: "/v1/items?recent=1&limit=\(encodeURIComponent(String(limit)))")
    }

    /// `GET /v1/items/:id` → `ItemWithContext`; nil on 404.
    public func item(id: String) async throws -> ItemWithContext? {
        try await ignoring404 { try await request(HouseholdRequest(path: "/v1/items/\(id)"), as: ItemWithContext.self) }
    }

    /// `POST /v1/items` → 201 `ItemWithContext`, as the server read it back.
    /// Photo URIs in the answer are the server's `r2:` strings.
    public func createItem(_ item: HouseholdBody.NewItem) async throws -> ItemWithContext {
        try await request(HouseholdRequest(path: "/v1/items", method: "POST", body: try .encodedJSON(item)))
    }

    /// `PATCH /v1/items/:id` → `Item` (no context); nil on 404.
    ///
    /// - Throws: ``ConflictError`` when `expectedUpdatedAt` is stale (409).
    public func updateItem(id: String, _ patch: HouseholdBody.ItemPatch) async throws -> Item? {
        let body = try HouseholdRequest.Body.encodedJSON(patch)
        return try await ignoring404 {
            try await request(HouseholdRequest(path: "/v1/items/\(id)", method: "PATCH", body: body), as: Item.self)
        }
    }

    /// `DELETE /v1/items/:id`; `.alreadyGone` on 404.
    public func deleteItem(id: String) async throws -> HouseholdDeleteResult {
        try await delete(path: "/v1/items/\(id)")
    }

    // MARK: Search and labels

    /// `GET /v1/search?q=`: the server runs the shared TS search.
    public func search(_ query: String) async throws -> SearchResults {
        try await request(HouseholdRequest(path: "/v1/search?q=\(encodeURIComponent(query))"), as: SearchBody.self).results
    }

    /// `POST /v1/containers/:id/qr` (no body) → 201 `QrBinding`: a new label bound to the container.
    public func createAndBindLabel(containerId: String) async throws -> QrBinding {
        try await request(HouseholdRequest(path: "/v1/containers/\(containerId)/qr", method: "POST"))
    }

    /// `POST /v1/qr/bind` → `QrBinding`: binds a scanned printed label.
    public func bindLabel(token: String, containerId: String) async throws -> QrBinding {
        let body = try HouseholdRequest.Body.encodedJSON(HouseholdBody.BindLabel(token: token, containerId: containerId))
        return try await request(HouseholdRequest(path: "/v1/qr/bind", method: "POST", body: body))
    }

    /// `POST /v1/qr/scan` with `{raw}` → what the scanned text resolves to.
    public func resolveScan(_ raw: String) async throws -> ScanOutcome {
        let body = try HouseholdRequest.Body.encodedJSON(HouseholdBody.Scan(raw: raw))
        return try await request(HouseholdRequest(path: "/v1/qr/scan", method: "POST", body: body), as: ScanBody.self)
            .outcome
    }

    /// `DELETE /v1/containers/:id/qr`: true on 204, false on 404.
    public func unbindLabel(containerId: String) async throws -> Bool {
        let unbound = try await ignoring404 {
            try await object(HouseholdRequest(path: "/v1/containers/\(containerId)/qr", method: "DELETE"))
        }
        return unbound != nil
    }

    // MARK: Photos and import

    /// `PUT /v1/photos/:id` with raw bytes under a new photo id, 60 s, before an
    /// item create (RN `uploadHouseholdPhoto`).
    ///
    /// - Throws: the server's error (for example `503 photos_not_configured`), or
    ///   `HouseholdHttpError(500, "invalid_response")` when the answer lacks string `id` and `uri`.
    public func uploadPhoto(_ bytes: Data) async throws -> HouseholdUploadedPhoto {
        let answer = try await object(HouseholdRequest(
            path: "/v1/photos/\(encodeURIComponent(newPhotoId()))",
            method: "PUT",
            body: .bytes(bytes),
            timeout: Self.uploadTimeout
        ))
        guard let photo = HouseholdUploadedPhoto(wire: answer.value) else {
            throw HouseholdHttpError(status: 500, code: "invalid_response")
        }
        return photo
    }

    /// `PUT /v1/photos/:id` with raw bytes under the phone's own photo id, 60 s,
    /// during the import (RN uses `householdFetch` here).
    ///
    /// - Returns: whether the server stored it; any HTTP failure is false, not thrown.
    /// - Throws: ``HouseholdHttpError`` `offline` / `timeout` when no answer arrives.
    public func importPhoto(id: String, bytes: Data) async throws -> Bool {
        try await send(HouseholdRequest(
            path: "/v1/photos/\(encodeURIComponent(id))",
            method: "PUT",
            body: .bytes(bytes),
            timeout: Self.uploadTimeout
        )).isSuccess
    }

    /// `GET /v1/photos/:id[?thumb=1]`: the stored bytes, or nil for any non-2xx (RN photoCache).
    ///
    /// - Throws: ``HouseholdHttpError`` `offline` / `timeout` when no answer arrives.
    public func photo(id: String, thumbnail: Bool) async throws -> Data? {
        let path = "/v1/photos/\(encodeURIComponent(id))" + (thumbnail ? "?thumb=1" : "")
        let response = try await send(HouseholdRequest(path: path))
        return response.isSuccess ? response.body : nil
    }

    /// `POST /v1/import` with an id-preserving dump, 60 s (RN `importLocalInventory`).
    ///
    /// Typed on purpose: the dump must carry explicit `null`s for NULL columns (see ``HouseholdDump``).
    public func importDump(_ dump: HouseholdDump) async throws -> HouseholdImportSummary {
        let answer = try await object(HouseholdRequest(
            path: "/v1/import", method: "POST", body: try .encodedJSON(dump), timeout: Self.uploadTimeout
        ))
        return HouseholdImportSummary(wire: answer.value)
    }

    // MARK: Helpers

    private func items(path: String) async throws -> [ItemWithContext] {
        try await request(HouseholdRequest(path: path), as: ItemsBody.self).items ?? []
    }

    private func delete(path: String) async throws -> HouseholdDeleteResult {
        let body = try await ignoring404 {
            try await request(HouseholdRequest(path: path, method: "DELETE"), as: DeleteBody.self)
        }
        guard let body else { return .alreadyGone }
        return HouseholdDeleteResult(deleted: true, orphanedPhotoUris: body.orphanedPhotoUris ?? [])
    }
}
