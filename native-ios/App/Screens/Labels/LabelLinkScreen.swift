import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// A QR label opened from the iPhone Camera (`inventory://c/<token>`) or handed over by the Scan
/// tab (RN `app/c/[token].tsx`, 06 §9).
///
/// A linked label replaces this screen with its container (the drop zone's opens its tab); a
/// label of ours that is not linked is linked here to a container picked from the place picker
/// (mode `bind`), so the token is never lost; a failed lookup offers Try again; anything else is
/// not one of ours. The lookup is `LabelLinkModel`'s one-shot read, started on appear; its
/// `close()` runs when the route leaves its stack (`router.onRemoval`), never on `onDisappear`,
/// because the picker's "New container in …" covers this screen with the container form and then
/// links the container it made here.
struct LabelLinkScreen: View {
    /// `ScanRules.tokenParam`'s token (trimmed); the repository decides whether it is ours.
    let token: String

    @Environment(AppContainer.self) private var app
    @Environment(\.screenAddress) private var address
    @State private var model: LabelLinkModel?

    init(token: String) {
        self.token = token
    }

    var body: some View {
        ScreenFrame(.detail) {
            if let model {
                LabelLinkContent(model: model)
            } else {
                LabelLinkResolving()
            }
        }
        .navigationTitle(L10n.DeepLink.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-label")
        .onAppear {
            guard model == nil else { return }
            let made = Self.makeModel(app: app, token: token, address: address)
            model = made
            made.start()
            if let address { app.router.onRemoval(of: address) { made.close() } }
        }
    }

    /// The screen's model, wired to the app: the QR repository in use at each call, the database
    /// as invalidator, toasts, the system confirmation, haptics, telemetry, the recent places,
    /// and the router through ``navigate(_:router:address:)``.
    static func makeModel(app: AppContainer, token: String, address: ScreenAddress?) -> LabelLinkModel {
        let repositories = app.repositories
        let recentPlaces = app.recentPlaces
        let router = app.router
        return LabelLinkModel(
            token: token,
            qr: { repositories.qr },
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry,
            rememberPlace: { recentPlaces.remember($0) },
            navigate: { navigate($0, router: router, address: address) }
        )
    }

    /// Where the label screen leads. The container replaces this screen only while it is the top
    /// of its stack: a late answer never replaces whatever is in front by then (06 §9.3 `openRef`).
    /// Returns false when nothing happened.
    @discardableResult
    static func navigate(_ destination: LabelLinkNavigation, router: Router, address: ScreenAddress?) -> Bool {
        switch destination {
        case .replaceWithContainer(let id):
            guard let address else { return false }
            return router.replace(address, with: .container(id: id))
        case .dropZoneTab:
            router.goToTab(.dropZone)
        case .home:
            router.goToTab(.home)
        }
        return true
    }
}

/// The label screen once its model exists (06 §9.2).
private struct LabelLinkContent: View {
    let model: LabelLinkModel

    var body: some View {
        switch model.state {
        case .resolving:
            // A linked label shows the same shape until the container replaces this screen.
            LabelLinkResolving()
        case .failed(let cause):
            LabelsCenteredState {
                ErrorStateView(cause: .failed(cause), onRetry: { model.retry() })
            }
        case .invalid:
            LabelsCenteredState {
                EmptyStateView(
                    title: L10n.Scan.invalidTitle,
                    message: L10n.Scan.invalidBody,
                    glyph: .qr,
                    primary: StateAction(label: L10n.Common.goToHome) { model.goHome() }
                )
            }
        case .unknown:
            PlacePickerHost(mode: .bind, busyId: model.busyId) {
                LabelLinkNewLabelHeader()
            } onPick: { place in
                // Bind mode never offers the drop zone.
                guard case .container(let option) = place else { return }
                Task { await model.link(option) }
            }
        }
    }
}

/// "Opening that label…": the detail skeleton, one VoiceOver element.
private struct LabelLinkResolving: View {
    var body: some View {
        ScrollView {
            SkeletonView(variant: .detail, label: L10n.DeepLink.opening)
                .padding(.horizontal, 16)
                .padding(.top, 16)
        }
    }
}

/// "New label" and what to do with it, above the bind picker's lists.
private struct LabelLinkNewLabelHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.DeepLink.newTitle)
                .textRole(.heading, header: true)
            Text(L10n.DeepLink.newBody)
                .textRole(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // In line with the section headings below.
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

#if DEBUG
#Preview("Not linked yet: choose its container") {
    ShellPreviewHost {
        NavigationStack { LabelLinkScreen(token: AppContainerPreviewData.unboundLabelToken) }
    }
}

#Preview("Not one of ours") {
    ShellPreviewHost {
        NavigationStack { LabelLinkScreen(token: "not-a-label") }
    }
}

#Preview("Linked (opens its container)") {
    ShellPreviewHost {
        NavigationStack { LabelLinkScreen(token: AppContainerPreviewData.toolChestLabelToken) }
    }
}
#endif
