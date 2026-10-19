import InventoryStorage
import InventoryTestSupport
import Testing
@testable import InventoryAppModels

/// 09 §14.2 `OnboardingModelTests` and 06 §21 `OnboardingStore` (no RN tests exist).
@Suite("OnboardingModel (src/providers/OnboardingProvider.tsx, src/services/onboarding.ts)")
@MainActor
struct OnboardingModelTests {
    @Test("loading until read; completed only for the exact string \"true\"", arguments: [
        ("true", OnboardingModel.Status.completed),
        ("True", .pending),
        ("1", .pending),
        ("yes", .pending),
        (" true", .pending),
        ("", .pending),
    ])
    func readsExactTrue(stored: String, expected: OnboardingModel.Status) {
        let model = OnboardingModel(preferences: InMemoryPreferences([PreferenceKey.onboardingCompleted: stored]))
        #expect(model.status == .loading)
        model.load()
        #expect(model.status == expected)
    }

    @Test("an absent flag, or one that is not a string, means pending")
    func absentOrWrongType() throws {
        let absent = OnboardingModel(preferences: InMemoryPreferences())
        absent.load()
        #expect(absent.status == .pending)

        let suite = try TemporaryDefaults()
        suite.defaults.set(true, forKey: PreferenceKey.onboardingCompleted)
        let typed = OnboardingModel(preferences: suite.defaults)
        typed.load()
        #expect(typed.status == .pending)
    }

    @Test("a read that fails means pending: onboarding once more rather than a blocked launch")
    func readFailure() {
        let model = OnboardingModel(storage: OnboardingModel.Storage(
            read: { throw ShellTestError("unreadable") },
            write: { _ in }))
        model.load()
        #expect(model.status == .pending)
    }

    @Test("complete flips the status before it stores \"true\"")
    func completeStatusFirst() {
        let preferences = InMemoryPreferences()
        let seen = ShellEventLog()
        let holder = ShellHolder<OnboardingModel>()
        holder.value = OnboardingModel(storage: OnboardingModel.Storage(
            read: { false },
            write: { completed in
                let status = MainActor.assumeIsolated { holder.value?.status }
                seen.record("write \(completed) while \(status.map { "\($0)" } ?? "nil")")
                OnboardingPreference(preferences: preferences).setCompleted(completed)
            }))
        holder.value?.load()
        holder.value?.complete()
        #expect(seen.events == ["write true while completed"])
        #expect(preferences.values[PreferenceKey.onboardingCompleted] == "true")
    }

    @Test("replay goes back to pending before it removes the flag")
    func replayStatusFirst() {
        let preferences = InMemoryPreferences([PreferenceKey.onboardingCompleted: "true"])
        let seen = ShellEventLog()
        let holder = ShellHolder<OnboardingModel>()
        holder.value = OnboardingModel(storage: OnboardingModel.Storage(
            read: { OnboardingPreference(preferences: preferences).isCompleted },
            write: { completed in
                let status = MainActor.assumeIsolated { holder.value?.status }
                seen.record("write \(completed) while \(status.map { "\($0)" } ?? "nil")")
                OnboardingPreference(preferences: preferences).setCompleted(completed)
            }))
        holder.value?.load()
        #expect(holder.value?.status == .completed)
        holder.value?.replay()
        #expect(seen.events == ["write false while pending"])
        #expect(preferences.values[PreferenceKey.onboardingCompleted] == nil)
    }

    @Test("a failed write is ignored: the status stands")
    func writeFailureIgnored() {
        let model = OnboardingModel(storage: OnboardingModel.Storage(
            read: { false },
            write: { _ in throw ShellTestError("full") }))
        model.load()
        model.complete()
        #expect(model.status == .completed)
        model.replay()
        #expect(model.status == .pending)
    }

    @Test("a late read never undoes complete or replay")
    func lateReadIgnored() {
        let model = OnboardingModel(preferences: InMemoryPreferences())
        model.complete()
        model.load()
        #expect(model.status == .completed)
    }

    @Test("the stored strings are RN's: \"true\", and removed on replay")
    func storedStrings() throws {
        let suite = try TemporaryDefaults()
        let model = OnboardingModel(preferences: suite.defaults)
        model.load()
        model.complete()
        #expect(suite.defaults.object(forKey: PreferenceKey.onboardingCompleted) as? String == "true")
        model.replay()
        #expect(suite.defaults.object(forKey: PreferenceKey.onboardingCompleted) == nil)
    }
}
