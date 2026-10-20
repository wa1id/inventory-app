import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

/// A container's QR label (RN `app/container/[id]/qr.tsx`, 07 §3.9, §5): show it to print or
/// share; replace or remove it when the sticker is lost; or make one, or link a sticker printed
/// earlier (the sticker camera, `.linkSticker(containerId:)`).
///
/// Nothing is offered until both the container and its label have been read, since a "Make" on a
/// label that is still loading would silently retire a printed sticker (`QrLabelModel`). The card
/// is always black on white; "Share label…" hands the system share sheet the 1024 px picture,
/// so it offers Save Image and Print (D-10). The drop zone has no label: the locked state.
struct QrLabelScreen: View {
    let containerId: String

    @Environment(AppContainer.self) private var app
    @State private var model: QrLabelModel?

    init(containerId: String) {
        self.containerId = containerId
    }

    var body: some View {
        ScreenFrame(.detail) {
            if containerId == DropZone.containerId {
                // The drop zone is a tab, not a box with a sticker on it.
                LabelsCenteredState {
                    DropZoneLocked { app.router.goToTab(.dropZone) }
                }
            } else if let model {
                QrLabelContent(model: model)
                    .inventoryQuery(model)
            } else {
                QrLabelLoading()
            }
        }
        .navigationTitle(L10n.Qr.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("screen-qr-label")
        .onAppear {
            guard model == nil, containerId != DropZone.containerId else { return }
            model = Self.makeModel(app: app, containerId: containerId)
        }
    }

    /// The screen's model, wired to the app: the current repositories, the revision, the database
    /// as invalidator, toasts, the system confirmation, haptics and telemetry.
    static func makeModel(app: AppContainer, containerId: String) -> QrLabelModel {
        let repositories = app.repositories
        return QrLabelModel(
            containerId: containerId,
            reads: QrLabelModel.Reads(repositories: repositories),
            qr: { repositories.qr },
            revision: app.database.revision,
            invalidator: app.database,
            toasts: app.toasts,
            confirm: app.platform.confirm,
            haptics: app.platform.haptics,
            telemetry: app.telemetry
        )
    }
}

extension QrLabelModel: ShellFocusDriven {}

/// The QR label screen once its model exists, in RN's render order (07 §3.9).
private struct QrLabelContent: View {
    let model: QrLabelModel

    @Environment(AppContainer.self) private var app

    var body: some View {
        switch model.state {
        case .loading:
            QrLabelLoading()
        case .containerFailed(let cause), .labelFailed(let cause):
            LabelsCenteredState {
                ErrorStateView(cause: .failed(cause), subject: .container, onRetry: { model.reloadAll() })
            }
        case .containerGone:
            LabelsCenteredState {
                ErrorStateView(
                    cause: .gone,
                    subject: .container,
                    secondary: StateAction(label: L10n.Common.goToSpaces) { app.router.goToTab(.spaces) }
                )
            }
        case .noLabel(let container):
            noLabel(container)
        case .label(let container, let token):
            label(container, token: token)
        }
    }

    /// "This could not be refreshed" over what was loaded before, with Try again.
    @ViewBuilder private var refreshBanner: some View {
        if model.showsRefreshBanner {
            BannerView(
                tone: .info,
                message: L10n.Errors.refreshFailed,
                primary: BannerAction(label: L10n.Common.tryAgain) { model.reloadAll() }
            )
        }
    }

    /// No label yet: make one (no question, there is none to replace), or link a printed sticker.
    private func noLabel(_ container: Container) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    refreshBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    EmptyStateView(
                        title: L10n.Qr.None.title(label: ContainerRules.labelOf(container)),
                        message: L10n.Qr.None.body,
                        glyph: .qr,
                        primary: StateAction(label: L10n.Qr.make, glyph: .qr, isLoading: model.busy == .make, identifier: "qr-generate") {
                            Task { await model.make() }
                        },
                        secondary: StateAction(label: L10n.Qr.link, glyph: .link, identifier: "qr-link-sticker") {
                            app.router.present(.linkSticker(containerId: container.id))
                        }
                    )
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// The card to print, how to use it, Share, and what to do when the sticker is lost.
    private func label(_ container: Container, token: String) -> some View {
        let busy = model.busy != nil
        return List {
            if model.showsRefreshBanner {
                Section {
                    refreshBanner
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                VStack(spacing: 16) {
                    QrLabelCard(token: token, name: container.name, shortCode: container.shortCode)
                    Text(L10n.Qr.hint)
                        .textRole(.meta)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                    QrLabelShareLink(token: token, name: container.name, shortCode: container.shortCode)
                        .disabled(busy)
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                QrLabelProblemRow(label: L10n.Qr.replace, isBusy: model.busy == .replace, isDisabled: busy, identifier: "qr-replace") {
                    Task { await model.replace() }
                }
                QrLabelProblemRow(label: L10n.Qr.remove, role: .destructive, isBusy: model.busy == .remove, isDisabled: busy, identifier: "qr-remove") {
                    Task { await model.remove() }
                }
            } header: {
                Text(L10n.Qr.problems)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// "Replace label…" or "Remove label…": a row button, a spinner while its own change runs, and
/// disabled while any change runs.
private struct QrLabelProblemRow: View {
    let label: String
    var role: ButtonRole?
    let isBusy: Bool
    let isDisabled: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .textRole(.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isBusy {
                    ProgressView()
                }
            }
            .frame(minHeight: DesignMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .accessibilityValue(isBusy ? L10n.A11y.loading : "")
        .accessibilityIdentifier(identifier)
    }
}

/// The detail skeleton while the container or its label loads.
private struct QrLabelLoading: View {
    var body: some View {
        ScrollView {
            SkeletonView(variant: .detail)
                .padding(16)
        }
    }
}

#if DEBUG
#Preview("Labelled") {
    QrLabelScreenPreview(name: "Tool chest")
}

#Preview("No label yet") {
    QrLabelScreenPreview(name: "Red bin")
}

#Preview("Drop zone") {
    ShellPreviewHost {
        NavigationStack { QrLabelScreen(containerId: DropZone.containerId) }
    }
}

#Preview("Gone") {
    ShellPreviewHost {
        NavigationStack { QrLabelScreen(containerId: "gone") }
    }
}

/// The QR label screen for a seeded container, found by name once the preview has booted.
private struct QrLabelScreenPreview: View {
    let name: String

    var body: some View {
        ShellPreviewHost {
            QrLabelScreenPreviewBody(name: name)
        }
    }
}

private struct QrLabelScreenPreviewBody: View {
    let name: String
    @Environment(AppContainer.self) private var app
    @State private var containerId: String?

    var body: some View {
        NavigationStack {
            if let containerId {
                QrLabelScreen(containerId: containerId)
            } else {
                ProgressView()
            }
        }
        .task {
            let containers = (try? await app.repositories.containers.listAllWithSpace()) ?? []
            containerId = containers.first { $0.container.name == name }?.container.id
        }
    }
}
#endif
