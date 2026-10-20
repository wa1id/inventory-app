import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryNetwork
import InventoryServices
import InventoryStrings

/// Settings › Household (RN app/household.tsx; 04 §12): join the household, or, once joined, see
/// this phone, the other phones (and remove one), copy this phone's own inventory in, and leave.
/// Reached from Settings, Home's unpaired notice and empty state, Spaces' empty state and the
/// removed-phone layer's "Join again".
///
/// The view follows the session live: pairing swaps the join form for the paired view before the
/// join has finished, and leaving swaps back just before the screen closes. Joining, copying in,
/// removing a phone and leaving run in tasks the view does not own, so leaving the screen never
/// cuts one short.
struct HouseholdScreen: View {
    @Environment(AppContainer.self) private var app

    var body: some View {
        Group {
            if let session = app.household.session {
                HouseholdPairedView(session: session)
                    // A new session (leaving and joining again) is a new paired view and model.
                    .id(session)
            } else {
                HouseholdUnpairedView()
            }
        }
        .navigationTitle(L10n.Household.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        // A container of its own: an identifier set on the Group alone would replace the join
        // form's bottom-bar button's (`join-submit`).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen-household")
    }
}

/// Back to wherever Household was opened from (RN `leaveScreen`, app/household.tsx:58-65), and
/// only while it is still in front: a slow join or leave finishing after the person went
/// elsewhere must not close the screen they are on.
@MainActor
enum HouseholdScreenExit {
    static func leave(router: Router, address: ScreenAddress?) {
        guard let address, router.isFocused(address) else { return }
        if case .tabRoot = address {
            router.goToTab(.home)
        } else {
            router.close(address)
        }
    }
}

// MARK: - Unpaired

/// Not joined: the join form under "Join your household" (RN `Unpaired`).
private struct HouseholdUnpairedView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var form: JoinFormModel?

    var body: some View {
        Group {
            if let form {
                AccountJoinForm(model: form, onJoin: { join(form) }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: L10n.Household.joinHeading)
                            .textRole(.heading, header: true)
                        Text(verbatim: L10n.Household.joinBody)
                            .textRole(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Never an empty view: SwiftUI does not run onAppear on one.
                Color.clear
            }
        }
        .onAppear { form = form ?? app.makeJoinForm() }
    }

    /// RN `joined`: a phone with an inventory of its own stays (the paired view now offers to
    /// copy it in, best done before anything changes); a phone empty at join time goes back.
    private func join(_ form: JoinFormModel) {
        let app = app
        let address = address
        Task {
            guard let joined = await form.join() else { return }
            app.toasts.show(ToastOptions(message: L10n.Household.joined(household: joined.householdName)))
            if !joined.hasImportOffer {
                HouseholdScreenExit.leave(router: app.router, address: address)
            }
        }
    }
}

// MARK: - Paired

/// Joined (RN `Paired`): the status card, the import offer, the phones and Leave.
private struct HouseholdPairedView: View {
    let session: HouseholdSession

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: HouseholdPairedModel?
    @State private var devices: InventoryQuery<[HouseholdDevice]>?
    @State private var ticker = NowTicker()

    var body: some View {
        ScreenFrame(.detail) {
            if let model, let devices {
                list(model, devices)
                    .inventoryQuery(devices)
                    .nowTicker(ticker)
            } else {
                // Never an empty view: SwiftUI does not run onAppear on one.
                Color.clear
            }
        }
        .onAppear(perform: makeModel)
    }

    private func makeModel() {
        guard model == nil else { return }
        let made = app.makeHouseholdPairedModel(session: session)
        // The offer is read once per appearance of the paired view (RN app/household.tsx:110-119).
        made.readImportOffer()
        model = made
        devices = InventoryQuery(key: made.devicesQueryKey, revision: app.database.revision) {
            try await made.listDevices()
        }
    }

    private func list(_ model: HouseholdPairedModel, _ devices: InventoryQuery<[HouseholdDevice]>) -> some View {
        List {
            HouseholdStatusCard(model: model, connection: app.connection.state)

            if let offer = model.offer {
                Section {
                    // The choices sit in the notice they answer, as on Home's unpaired notice.
                    BannerView(
                        tone: .info,
                        message: L10n.Household.importNotice(spaces: offer.spaces, items: offer.items),
                        primary: BannerAction(
                            label: L10n.Household.importAction,
                            isLoading: model.isImporting,
                            identifier: "household-import"
                        ) { Task { await model.copyIn() } },
                        secondary: model.isImporting ? nil : BannerAction(
                            label: L10n.Household.notNeeded,
                            identifier: "household-not-needed"
                        ) { model.notNeeded() },
                        chrome: .row,
                        identifier: "household-import-offer"
                    )
                    if let failure = model.importFailure {
                        // Read wording on purpose: nothing was typed to keep, and copying again
                        // is safe ("…Nothing on this phone was lost.").
                        BannerView(
                            tone: .warning,
                            title: failure.title,
                            message: failure.body,
                            live: .assertive,
                            chrome: .row,
                            identifier: "household-import-failure"
                        )
                    }
                }
            }

            Section {
                if let failure = model.removeFailure {
                    BannerView(
                        tone: .warning,
                        title: failure.title,
                        message: failure.body,
                        onDismiss: { model.dismissRemoveFailure() },
                        live: .assertive,
                        chrome: .row,
                        identifier: "household-remove-failure"
                    )
                }
                HouseholdPhones(
                    list: HouseholdPairedModel.phoneList(
                        devices: devices.data,
                        loading: devices.isLoading,
                        cause: devices.cause,
                        refreshFailed: devices.refreshFailed,
                        connection: app.connection.state,
                        thisDeviceId: model.session.deviceId,
                        now: ticker.now
                    ),
                    removingId: model.removingId,
                    reload: { devices.reload() },
                    remove: { device in
                        Task { await model.remove(device) { devices.reload() } }
                    }
                )
            } header: {
                Text(verbatim: L10n.Household.phones)
            }

            Section {
                LoadingButton(
                    label: L10n.Household.leave,
                    variant: .destructive,
                    isLoading: model.isLeaving,
                    fullWidth: true,
                    identifier: "household-leave"
                ) {
                    let router = app.router
                    let address = address
                    Task {
                        await model.leave { HouseholdScreenExit.leave(router: router, address: address) }
                    }
                }
            }
        }
        .refreshable { await devices.refresh() }
    }
}

/// "This phone is “Kitchen iPhone”", the household's name and whether the home server answers
/// (RN `StatusCard`). The dot and its word are one stop, but not announced: every `unsure` blip
/// would be read aloud, and the connection banner already says a real outage.
private struct HouseholdStatusCard: View {
    let model: HouseholdPairedModel
    let connection: ConnectionState

    var body: some View {
        let summary = HouseholdPairedModel.connectionSummary(connection)
        let tint: Color = summary.tone == .signal ? DesignColor.signal : .primary
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(verbatim: model.heading)
                        .textRole(.heading, header: true)
                } icon: {
                    Image(glyph: .phone)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: model.partOf)
                        .textRole(.meta)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tint)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(verbatim: summary.value)
                            .textRole(.meta)
                            .fontWeight(.semibold)
                            .foregroundStyle(tint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("household-connection")
                }
                .padding(.leading, 36)
            }
            .padding(.vertical, 4)
        }
    }
}

/// Every phone in the household, this one first, or why there are none (RN `Phones`). Any phone
/// may remove another; this phone leaves instead. A failed read is an inline notice, so the
/// status, the offer and Leave keep working.
private struct HouseholdPhones: View {
    let list: HouseholdPhoneList
    let removingId: String?
    let reload: () -> Void
    let remove: (HouseholdDevice) -> Void

    var body: some View {
        switch list {
        case .offlineNote:
            // The connection banner already says the home server is out of reach, and its Try
            // again reloads this list; a second warning would make it the loudest thing here.
            Text(verbatim: L10n.Household.phonesOffline)
                .textRole(.meta)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("household-phones-offline")
        case .failure(let copy):
            BannerView(
                tone: .warning,
                title: copy.title,
                message: copy.body,
                primary: BannerAction(label: L10n.Common.tryAgain, identifier: "household-phones-retry", action: reload),
                chrome: .row,
                identifier: "household-phones-failure"
            )
        case .loading:
            SkeletonView(variant: .rows, rows: 2, thumb: nil)
        case .nothing:
            EmptyView()
        case .rows(let rows, let refreshFailed):
            if refreshFailed {
                BannerView(
                    tone: .info,
                    message: L10n.Errors.refreshFailed,
                    primary: BannerAction(label: L10n.Common.tryAgain, action: reload),
                    chrome: .row
                )
            }
            ForEach(rows) { row in
                HouseholdPhoneRowView(row: row, isRemoving: removingId == row.id) { remove(row.device) }
            }
        }
    }
}

/// One phone: its name over "This phone" or when it was last used, and Remove… for the others.
private struct HouseholdPhoneRowView: View {
    let row: HouseholdPhoneRow
    let isRemoving: Bool
    let remove: () -> Void

    var body: some View {
        RowWithTool {
            ListRow(action: nil, accessibilityLabel: row.accessibilityLabel, identifier: "device-\(row.id)") {
                Image(glyph: .phone)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            } content: {
                Text(verbatim: row.device.name)
                    .textRole(.name)
                Text(verbatim: row.meta)
                    .textRole(.meta)
                    .foregroundStyle(.secondary)
            }
        } tool: {
            if let removeLabel = row.removeAccessibilityLabel {
                LoadingButton(
                    label: L10n.Household.remove,
                    variant: .destructive,
                    size: .small,
                    isLoading: isRemoving,
                    accessibilityLabel: removeLabel,
                    identifier: "device-remove-\(row.id)",
                    action: remove
                )
            }
        }
    }
}

#if DEBUG
#Preview("Not joined") {
    AccountPreviewHost(.unpaired) { NavigationStack { HouseholdScreen() } }
}

#Preview("Joined") {
    AccountPreviewHost(.paired) { NavigationStack { HouseholdScreen() } }
}

#Preview("Joined, with the import offer") {
    AccountPreviewHost(.pairedOffer) { NavigationStack { HouseholdScreen() } }
}

#Preview("Phones loading") {
    AccountPreviewHost(.devicesLoading) { NavigationStack { HouseholdScreen() } }
}

#Preview("Phones failed") {
    AccountPreviewHost(.devicesFailed) { NavigationStack { HouseholdScreen() } }
}
#endif
