import Foundation
import Observation

/// Categories the person has used, for the chips under the Category field (01 §8.3).
/// RN: src/ui/categoryMemory.ts.
///
/// Two sources: the last twenty saved on this phone (persisted under `categories.recent.v1`),
/// and categories seen in item lists the app loaded anyway (this session only). The saved list
/// is read from preferences the first time the memory is used, so it is always complete before
/// anything is written; RN's load-versus-write race is not ported.
@MainActor
@Observable
public final class CategoryMemory {
    /// How many saved categories are kept. RN: categoryMemory.ts:4.
    public nonisolated static let maxSaved = 20
    /// How many suggestions a Category field shows. RN: categoryMemory.ts:5.
    public nonisolated static let maxSuggestions = 6

    private let preferences: any PreferenceStoring
    /// Saved on this phone, most recent first; nil until first read.
    @ObservationIgnored private var savedStorage: [String]?
    /// Seen this session, keyed case-insensitively, in first-seen order.
    @ObservationIgnored private var seen: [(key: JS.Key, category: String)] = []
    @ObservationIgnored private var seenKeys: Set<JS.Key> = []
    @ObservationIgnored private var snapshot: [String] = []
    /// Bumped on every change, so views reading ``known`` refresh.
    private var revision = 0

    public init(preferences: any PreferenceStoring) {
        self.preferences = preferences
    }

    /// Every known category: saved on this phone first, then the rest alphabetically.
    /// RN: `useKnownCategories`, categoryMemory.ts:132-139.
    public var known: [String] {
        _ = revision
        loadIfNeeded()
        return snapshot
    }

    /// Up to six known categories for a Category field holding `prefix`.
    /// RN: `useCategorySuggestions`, categoryMemory.ts:141-145.
    public func suggestions(for prefix: String) -> [String] {
        Self.suggest(known, prefix: prefix)
    }

    /// Feeds the categories of a list that was loaded anyway (RN: `rememberCategories`, :76-86).
    public func rememberCategories(_ categories: [String?]) {
        loadIfNeeded()
        var changed = false
        for raw in categories {
            guard let raw else { continue }
            let category = JS.trim(raw)
            let key = Self.key(category)
            guard !category.isEmpty, !seenKeys.contains(key) else { continue }
            seen.append((key, category))
            seenKeys.insert(key)
            changed = true
        }
        if changed { publish() }
    }

    /// After an item is saved with a category: it becomes the first suggestion, and the saved
    /// list is persisted (RN: `recordCategory`, :88-100).
    public func record(_ category: String?) {
        guard let category else { return }
        let trimmed = JS.trim(category)
        guard !trimmed.isEmpty else { return }
        loadIfNeeded()
        let saved = Self.mergeSaved([trimmed] + (savedStorage ?? []))
        savedStorage = saved
        publish()
        preferences.setString(JSONText.array(saved), forKey: PreferenceKey.recentCategories)
    }

    /// Known categories that start with `prefix` (case-insensitively), without an exact match,
    /// each once and trimmed, at most `max`. RN: `suggestCategories`, :106-122.
    public nonisolated static func suggest(
        _ categories: [String], prefix: String, max: Int = maxSuggestions
    ) -> [String] {
        let typed = key(prefix)
        var offered: Set<JS.Key> = []
        var matches: [String] = []
        for category in categories {
            let k = key(category)
            guard !k.isEmpty, k != typed, !offered.contains(k), k.hasPrefix(typed) else { continue }
            offered.insert(k)
            matches.append(JS.trim(category))
            if matches.count == max { break }
        }
        return matches
    }

    /// `category.trim().toLowerCase()`, compared as JavaScript compares strings.
    nonisolated static func key(_ category: String) -> JS.Key {
        JS.Key(JS.lowercase(JS.trim(category)))
    }

    /// Dedupes by key, skipping empty keys, keeps the trimmed spelling first seen, caps at 20.
    /// RN: `mergeSaved`, :63-74.
    nonisolated static func mergeSaved(_ list: [String]) -> [String] {
        var keys: Set<JS.Key> = []
        var out: [String] = []
        for category in list {
            let k = key(category)
            guard !k.isEmpty, !keys.contains(k) else { continue }
            keys.insert(k)
            out.append(JS.trim(category))
        }
        return Array(out.prefix(maxSaved))
    }

    /// RN's load rule: parse; anything but an array is ignored; keep the strings, then merge
    /// (RN: `loadSaved`, :45-61). Unparsable text is ignored too.
    nonisolated static func decodeSaved(_ stored: String?) -> [String] {
        guard let stored, !stored.isEmpty, case .array(let values)? = JSONValue.parse(stored) else {
            return []
        }
        return mergeSaved(values.compactMap { value in
            if case .string(let category) = value { return category }
            return nil
        })
    }

    private func loadIfNeeded() {
        guard savedStorage == nil else { return }
        savedStorage = Self.decodeSaved(preferences.storedString(forKey: PreferenceKey.recentCategories))
        rebuildSnapshot()
    }

    private func publish() {
        rebuildSnapshot()
        revision += 1
    }

    /// Saved first, in order; then the seen categories not already saved, sorted the way
    /// `localeCompare(b, 'en', {sensitivity: 'base'})` sorts them, ties kept in first-seen order
    /// (RN: `publish`, :28-37).
    private func rebuildSnapshot() {
        let saved = savedStorage ?? []
        let savedKeys = Set(saved.map(Self.key))
        let english = Locale(identifier: "en")
        let others = seen.enumerated()
            .filter { !savedKeys.contains($0.element.key) }
            .sorted { lhs, rhs in
                switch lhs.element.category.compare(
                    rhs.element.category, options: [.caseInsensitive, .diacriticInsensitive], locale: english)
                {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.offset < rhs.offset
                }
            }
            .map(\.element.category)
        snapshot = saved + others
    }
}
