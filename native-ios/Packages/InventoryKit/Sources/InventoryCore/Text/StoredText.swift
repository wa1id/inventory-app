// The folded text the RN app writes into stored columns. Both the local
// repositories and the household shadow mirror write these, so they live here
// once: a column folded with Foundation's `lowercased()` or trimmed with
// `.whitespacesAndNewlines` would silently stop matching rows written by the
// RN build (01 §4.4, §6.5).

/// `items.search_text`: name and category joined by a space, JS-trimmed, then JS-lowercased.
///
/// RN `searchTextFor` (src/repositories/items.ts:130-132) and the shadow mirror
/// (src/services/household/shadow.ts:153). Recomputed on every item write.
public func itemSearchText(name: String, category: String?) -> String {
    "\(name) \(category ?? "")".jsTrimmed().jsLowercased()
}

/// `tags.normalized_name` for a typed tag: JS-trimmed, then JS-lowercased.
///
/// RN `normalizeTag` (src/repositories/items.ts:126-128) and the shadow mirror
/// (src/services/household/shadow.ts:225-226). The same fold keys category memory
/// (src/ui/categoryMemory.ts:24-26). An empty result means "no tag".
public func normalizedTagName(_ tag: String) -> String {
    tag.jsTrimmed().jsLowercased()
}
