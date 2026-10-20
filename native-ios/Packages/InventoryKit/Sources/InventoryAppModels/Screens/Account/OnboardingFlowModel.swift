import Observation
import InventoryCore
import InventoryServices
import InventoryStrings

// RN: app/onboarding.tsx (06 §11.2). The gate's flag is OnboardingModel's (06 §11.1).

/// The first screen on a new phone (RN `OnboardingScreen`): Welcome, then joining the household
/// or using the phone on its own, then "You are in" after a join. Short, skippable and replayable
/// from Settings › How it works.
///
/// Joining comes first, because the usual new phone is a second one joining the household with
/// the owner beside it. Finishing calls ``OnboardingModel/complete()``, which flips the root gate
/// to the main shell by itself; there is no navigation call. What was typed into the join form
/// survives Back → Welcome → Join (RN `joinDraft`).
@MainActor
@Observable
public final class OnboardingFlowModel {
    /// RN `Step`.
    public enum Step: Sendable, Hashable {
        case welcome
        case join
        case joined
    }

    /// RN `onboarding_finished.outcome`.
    public enum Outcome: String, Sendable, Hashable {
        case completed
        case skipped
    }

    public private(set) var step: Step = .welcome
    /// The join form while the Join step shows; made afresh from ``joinDraft`` each time, as RN
    /// remounted it.
    public private(set) var joinForm: JoinFormModel?
    /// What was typed into the join form so far.
    public private(set) var joinDraft: JoinDraft?
    /// The household joined on the Join step, for "You are in".
    public private(set) var joinedHouseholdName = ""

    @ObservationIgnored private let onboarding: OnboardingModel
    @ObservationIgnored private let household: HouseholdModel
    @ObservationIgnored private let makeJoinForm: @MainActor (JoinDraft?) -> JoinFormModel
    @ObservationIgnored private let telemetry: TelemetryReporter
    @ObservationIgnored private var finishing = false

    /// - Parameter makeJoinForm: a join form starting from a draft (`AppContainer.makeJoinForm`).
    public init(
        onboarding: OnboardingModel,
        household: HouseholdModel,
        makeJoinForm: @escaping @MainActor (JoinDraft?) -> JoinFormModel,
        telemetry: TelemetryReporter = .shared
    ) {
        self.onboarding = onboarding
        self.household = household
        self.makeJoinForm = makeJoinForm
        self.telemetry = telemetry
    }

    // MARK: - Welcome

    /// Welcome offers only Continue: replayed from Settings on a phone that already joined, there
    /// is nothing to choose. RN's condition is the session alone (app/onboarding.tsx:82), so a
    /// keychain session that survived a reinstall without the onboarding flag also reads this way.
    public var offersOnlyContinue: Bool { household.session != nil }

    /// "Join your household": the Join step, with what was typed before.
    public func showJoin() {
        let form = makeJoinForm(joinDraft)
        form.onDraftChange = { [weak self] draft in self?.joinDraft = draft }
        joinForm = form
        step = .join
    }

    /// "Use this phone on its own": finishes as skipped, at Welcome.
    public func useOnItsOwn() {
        finish(.skipped, step: 0)
    }

    /// "Continue" on a joined phone: finishes as completed, at Welcome.
    public func continueJoined() {
        finish(.completed, step: 0)
    }

    // MARK: - Join

    /// Back to Welcome; the draft stays for the next visit.
    public func back() {
        joinForm = nil
        step = .welcome
    }

    /// Runs the join form's Join, then shows "You are in". Call it in a task the view does not
    /// own: pairing must not be cut short by the step changing.
    public func join() async {
        guard let form = joinForm, let result = await form.join() else { return }
        joined(result)
    }

    /// The phone joined: "You are in", naming the household. The form's import offer is ignored
    /// here (RN parity; Household shows it later).
    public func joined(_ result: HouseholdJoined) {
        joinedHouseholdName = result.householdName
        joinForm = nil
        step = .joined
    }

    // MARK: - Joined

    /// "Everything stored in Home is on this phone now." The name joined, else the session's.
    public var joinedBody: String {
        let name = joinedHouseholdName.isEmpty ? (household.session?.householdName ?? "") : joinedHouseholdName
        return L10n.Onboarding.joinedBody(household: name)
    }

    /// "Start": finishes as completed, at Joined.
    public func start() {
        finish(.completed, step: 1)
    }

    // MARK: - Finish

    /// RN `finish(outcome, step)`: once only; the gate flips first (the status, then storage),
    /// then `onboarding_finished {outcome, step}` is logged.
    private func finish(_ outcome: Outcome, step: Int) {
        guard !finishing else { return }
        finishing = true
        onboarding.complete()
        telemetry.event("onboarding_finished", ["outcome": .string(outcome.rawValue), "step": .int(step)])
    }
}
