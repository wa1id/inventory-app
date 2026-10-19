import InventoryAppModels

// Test doubles for the shared seams in Sources/InventoryAppModels/Shared, for every model's
// tests in this target. Use these rather than writing another recorder per model: the names
// carry the SharedSeams prefix so that a model's own helpers never collide with them.

/// Records the toasts a model shows and dismisses (a `ToastPresenting` for tests).
@MainActor
final class SharedSeamsToastRecorder: ToastPresenting {
    /// Every toast shown, oldest first, with the id `show` returned for it.
    private(set) var shown: [(id: String, options: ToastOptions)] = []
    /// Every id passed to `dismiss`, oldest first.
    private(set) var dismissed: [String] = []
    private var nextNumber = 0

    init() {}

    /// The messages shown, oldest first.
    var messages: [String] { shown.map(\.options.message) }

    /// The last toast shown.
    var last: ToastOptions? { shown.last?.options }

    /// Ids run `"toast-1"`, `"toast-2"`, … as ToastCenter numbers them.
    @discardableResult
    func show(_ options: ToastOptions) -> String {
        nextNumber += 1
        let id = "toast-\(nextNumber)"
        shown.append((id, options))
        return id
    }

    func dismiss(_ id: String) {
        dismissed.append(id)
    }

    /// Presses the action button of the toast with `id` (the last one by default), as a person
    /// would: the handler runs, then the toast is dismissed. False when it has no action.
    @discardableResult
    func pressAction(of id: String? = nil) -> Bool {
        let entry = if let id { shown.last { $0.id == id } } else { shown.last }
        guard let entry, let action = entry.options.action else { return false }
        action.handler()
        dismiss(entry.id)
        return true
    }
}

/// Answers a model's confirmations from a script (a `ConfirmPresenting` for tests).
@MainActor
final class SharedSeamsConfirmScript: ConfirmPresenting {
    /// Every confirmation asked, oldest first.
    private(set) var asked: [ConfirmOptions] = []
    /// The answers still to give, in order; once they run out, `fallback` answers.
    var answers: [Bool]
    var fallback: Bool

    /// - Parameters:
    ///   - answers: what to answer, question by question.
    ///   - fallback: the answer after the scripted ones (Cancel by default).
    init(answers: [Bool] = [], fallback: Bool = false) {
        self.answers = answers
        self.fallback = fallback
    }

    func confirm(_ options: ConfirmOptions) async -> Bool {
        asked.append(options)
        return answers.isEmpty ? fallback : answers.removeFirst()
    }
}

/// Records the haptics a model plays; pass ``player`` where the model takes a `HapticPlayer`.
@MainActor
final class SharedSeamsHapticRecorder {
    /// Every event played, oldest first.
    private(set) var played: [HapticEvent] = []

    init() {}

    var player: HapticPlayer {
        { [self] event in played.append(event) }
    }
}

/// Counts invalidations (an `InventoryInvalidating` for tests; `DatabaseModel` in the app).
@MainActor
final class SharedSeamsInvalidationCounter: InventoryInvalidating {
    /// How many times `invalidate()` ran: the revision a `DatabaseModel` would be at.
    private(set) var count = 0

    init() {}

    func invalidate() {
        count &+= 1
    }
}
