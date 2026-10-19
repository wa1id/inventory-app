import GRDB
import InventoryCore

// RN: src/repositories/search.ts. The SQL is built exactly as the TS builds it
// (01 §7.5): the home server runs that code, so household search and local
// search must return the same items in the same order. Matching is LIKE with
// SQLite's ASCII-only case folding; accent folding applies to the query only
// (one-sided, DECISIONS U12). Do not replace the nested REPLACE with a custom
// SQL function: it would drift from the home server.

/// Keyword search over the local SQLite database.
public struct LocalSearchRepository: SearchRepository {
    /// Caps the item list so a one-letter query cannot render 10k rows (RN `ITEM_RESULT_LIMIT`).
    static let itemResultLimit = 200
    /// RN `LOCATION_RESULT_LIMIT`.
    static let locationResultLimit = 30

    public let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    // MARK: Async API

    public func search(_ rawQuery: String) async throws -> SearchResults {
        try await queue.read { db in try search(rawQuery, in: db) }
    }

    public func searchSpaces(_ terms: [String]) async throws -> [LocationSearchResult] {
        try await queue.read { db in try searchSpaces(terms, in: db) }
    }

    public func searchContainers(_ terms: [String]) async throws -> [LocationSearchResult] {
        try await queue.read { db in try searchContainers(terms, in: db) }
    }

    // MARK: SQL fragments

    /// Removes the ASCII separators people leave out when typing (`usbc` for `USB-C`):
    /// `-`, `_`, `/`, `.` and `'`, in that order (RN `sqlCompact`). Spaces stay.
    static func sqlCompact(_ expression: String) -> String {
        var sql = expression
        for character in ["-", "_", "/", ".", "'"] {
            let literal = character == "'" ? "''" : character
            sql = "REPLACE(\(sql), '\(literal)', '')"
        }
        return sql
    }

    /// A term matching the item's own fields: name and category, or a tag (RN `itemFieldCondition`).
    /// Four parameters: `like, compactLike, like, compactLike`.
    static func itemFieldCondition() -> String {
        #"""
        (
            i.search_text LIKE ? ESCAPE '\'
            OR \#(sqlCompact("i.search_text")) LIKE ? ESCAPE '\'
            OR EXISTS (
              SELECT 1 FROM item_tags it
                JOIN tags t ON t.id = it.tag_id
               WHERE it.item_id = i.id
                 AND (
                   t.normalized_name LIKE ? ESCAPE '\'
                   OR \#(sqlCompact("t.normalized_name")) LIKE ? ESCAPE '\'
                 )
            )
          )
        """#
    }

    /// A term matching the item's space name, container name or short code (RN `locationFieldCondition`).
    /// Five parameters: `like, compactLike, like, compactLike, compactLike`.
    static func locationFieldCondition() -> String {
        #"""
        (
            LOWER(s.name) LIKE ? ESCAPE '\'
            OR \#(sqlCompact("LOWER(s.name)")) LIKE ? ESCAPE '\'
            OR LOWER(COALESCE(c.name, '')) LIKE ? ESCAPE '\'
            OR \#(sqlCompact("LOWER(COALESCE(c.name, ''))")) LIKE ? ESCAPE '\'
            OR \#(sqlCompact("LOWER(c.short_code)")) LIKE ? ESCAPE '\'
          )
        """#
    }

    /// `%term%` and the compacted `%term%` for one term (RN `like`, `compactLike`).
    private static func patterns(_ term: String) -> (like: String, compactLike: String) {
        let compact = compactAlphanumeric(term)
        return (toLikePattern(term), toLikePattern(compact.isEmpty ? term : compact))
    }

    // MARK: Cores

    /// Every term must match the item's own fields or its location (AND across terms).
    ///
    /// Items whose own fields match every term come first (`direct`), then location-only
    /// matches; each group by name, ASCII case-insensitive, at most 200. Drop-zone and
    /// quantity-0 items are included. Locations are matching user spaces then containers,
    /// at most 30 in all.
    public func search(_ rawQuery: String, in db: Database) throws -> SearchResults {
        let terms = tokenizeQuery(rawQuery)
        if terms.isEmpty {
            return SearchResults(terms: terms, locations: [], items: [])
        }

        var itemWhere: [String] = []
        var itemParams: [String] = []
        var directParams: [String] = []

        for term in terms {
            let (like, compactLike) = Self.patterns(term)
            itemWhere.append("(\(Self.itemFieldCondition()) OR \(Self.locationFieldCondition()))")
            itemParams += [like, compactLike, like, compactLike, like, compactLike, like, compactLike, compactLike]
            directParams += [like, compactLike, like, compactLike]
        }

        // `direct_match` is 1 only when every term matched the item's own fields.
        let directExpression = terms.map { _ in Self.itemFieldCondition() }.joined(separator: " AND ")

        let sql = """
            SELECT i.*,
                   (SELECT p.id FROM item_photos p WHERE p.item_id = i.id
                     ORDER BY p.created_at ASC LIMIT 1) AS photo_id,
                   (SELECT p.uri FROM item_photos p WHERE p.item_id = i.id
                     ORDER BY p.created_at ASC LIMIT 1) AS photo_uri,
                   (SELECT p.thumb_uri FROM item_photos p WHERE p.item_id = i.id
                     ORDER BY p.created_at ASC LIMIT 1) AS photo_thumb_uri,
                   (SELECT GROUP_CONCAT(t.name, char(31)) FROM item_tags it
                      JOIN tags t ON t.id = it.tag_id WHERE it.item_id = i.id) AS tag_names,
                   c.space_id AS space_id,
                   s.name AS space_name,
                   s.icon AS space_icon,
                   s.color AS space_color,
                   c.name AS container_name,
                   c.short_code AS container_short_code,
                   CASE WHEN \(directExpression) THEN 1 ELSE 0 END AS direct_match
              FROM items i
              JOIN containers c ON c.id = i.container_id
              JOIN spaces s ON s.id = c.space_id
             WHERE \(itemWhere.joined(separator: " AND "))
             ORDER BY direct_match DESC, i.name COLLATE NOCASE ASC
             LIMIT \(Self.itemResultLimit)
            """

        // The SELECT's parameters come before the WHERE's in the text.
        let items = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(directParams + itemParams)).map { row in
            let directMatch: Int = try row.decode(forColumn: "direct_match")
            return ItemSearchResult(
                item: try RowMapping.itemWithContext(row),
                matchKind: directMatch == 1 ? .direct : .location
            )
        }

        let locations = try searchSpaces(terms, in: db) + searchContainers(terms, in: db)
        return SearchResults(
            terms: terms,
            locations: Array(locations.prefix(Self.locationResultLimit)),
            items: items
        )
    }

    /// User spaces whose name matches every term, by name; the subtitle is the repository's English.
    public func searchSpaces(_ terms: [String], in db: Database) throws -> [LocationSearchResult] {
        var conditions: [String] = []
        var params: [String] = []
        for term in terms {
            let (like, compactLike) = Self.patterns(term)
            conditions.append(
                #"(LOWER(s.name) LIKE ? ESCAPE '\' OR \#(Self.sqlCompact("LOWER(s.name)")) LIKE ? ESCAPE '\')"#
            )
            params += [like, compactLike]
        }

        let sql = """
            SELECT s.id, s.name,
                   (SELECT COUNT(*) FROM containers c WHERE c.space_id = s.id) AS container_count,
                   (SELECT COUNT(*) FROM items i JOIN containers c ON c.id = i.container_id
                     WHERE c.space_id = s.id) AS item_count
              FROM spaces s
             WHERE s.kind = 'normal' AND \(conditions.joined(separator: " AND "))
             ORDER BY s.name COLLATE NOCASE ASC
             LIMIT \(Self.locationResultLimit)
            """

        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(params)).map { row in
            let id: String = try row.decode(forColumn: "id")
            let containerCount: Int = try row.decode(forColumn: "container_count")
            let itemCount: Int = try row.decode(forColumn: "item_count")
            // Hard-coded English, as in RN and on the home server (DECISIONS U9).
            let subtitle = "\(containerCount) container\(containerCount == 1 ? "" : "s") · "
                + "\(itemCount) item\(itemCount == 1 ? "" : "s")"
            return LocationSearchResult(
                kind: .space,
                id: id,
                title: try row.decode(forColumn: "name"),
                subtitle: subtitle,
                spaceId: id,
                itemCount: itemCount
            )
        }
    }

    /// User containers whose name or short code matches every term, by space name then short code.
    public func searchContainers(_ terms: [String], in db: Database) throws -> [LocationSearchResult] {
        var conditions: [String] = []
        var params: [String] = []
        for term in terms {
            let (like, compactLike) = Self.patterns(term)
            conditions.append(
                #"""
                (LOWER(COALESCE(c.name, '')) LIKE ? ESCAPE '\'
                            OR \#(Self.sqlCompact("LOWER(COALESCE(c.name, ''))")) LIKE ? ESCAPE '\'
                            OR \#(Self.sqlCompact("LOWER(c.short_code)")) LIKE ? ESCAPE '\')
                """#
            )
            params += [like, compactLike, compactLike]
        }

        let sql = """
            SELECT c.id, c.name, c.short_code, c.space_id, s.name AS space_name,
                   (SELECT COUNT(*) FROM items i WHERE i.container_id = c.id) AS item_count
              FROM containers c
              JOIN spaces s ON s.id = c.space_id
             WHERE c.kind = 'normal' AND \(conditions.joined(separator: " AND "))
             ORDER BY s.name COLLATE NOCASE ASC, c.short_code ASC
             LIMIT \(Self.locationResultLimit)
            """

        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(params)).map { row in
            let name: String? = try row.decode(forColumn: "name")
            let shortCode: String = try row.decode(forColumn: "short_code")
            let spaceName: String = try row.decode(forColumn: "space_name")
            let itemCount: Int = try row.decode(forColumn: "item_count")
            return LocationSearchResult(
                kind: .container,
                id: try row.decode(forColumn: "id"),
                title: name ?? shortCode,
                subtitle: "\(spaceName) · \(shortCode) · \(itemCount) item\(itemCount == 1 ? "" : "s")",
                spaceId: try row.decode(forColumn: "space_id"),
                itemCount: itemCount
            )
        }
    }
}
