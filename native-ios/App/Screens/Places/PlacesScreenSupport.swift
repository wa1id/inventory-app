import SwiftUI
import InventoryAppModels
import InventoryCore
import InventoryStrings

// What the space and container screens share in the app target.

extension SpaceNewModel: ShellFocusDriven {}
extension SpaceEditModel: ShellFocusDriven {}
extension ContainerNewModel: ShellFocusDriven {}
extension ContainerEditModel: ShellFocusDriven {}
extension SpaceDetailModel: ShellFocusDriven {}
extension ContainerDetailModel: ShellFocusDriven {}

/// A state view (error, gone, locked) that fills the screen: centred while it fits, scrolling at
/// the largest text sizes so its words and buttons stay reachable (UI-KIT §4).
struct PlacesFullScreenState<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The skeleton while a screen's first read is out, padded like a page.
struct PlacesLoading: View {
    var variant: SkeletonView.Variant = .list
    var rows = 6
    var thumb: CGFloat? = DesignMetrics.thumb

    var body: some View {
        ScrollView {
            SkeletonView(variant: variant, rows: rows, thumb: thumb)
                .padding(16)
        }
        .scrollDisabled(true)
    }
}

/// The repositories the space and container screens read and write through: the current ones
/// (local or the household's); in DEBUG the places demo can make them fail, to show a saving or
/// refresh problem.
@MainActor
enum PlacesRepositories {
    static func spaces(_ app: AppContainer) -> any SpacesRepository {
        #if DEBUG
        PlacesDemo.spaces(app.repositories.spaces)
        #else
        app.repositories.spaces
        #endif
    }

    static func containers(_ app: AppContainer) -> any ContainersRepository {
        #if DEBUG
        PlacesDemo.containers(app.repositories.containers)
        #else
        app.repositories.containers
        #endif
    }

    static func items(_ app: AppContainer) -> any ItemsRepository {
        #if DEBUG
        PlacesDemo.items(app.repositories.items)
        #else
        app.repositories.items
        #endif
    }
}

/// Keeps a form's dirty guard told whether the removed-phone layer is up (it then never asks).
private struct PlacesRevokedGuard: ViewModifier {
    let guardModel: DirtyGuard
    @Environment(AppContainer.self) private var app

    func body(content: Content) -> some View {
        content.onChange(of: app.connection.state, initial: true) { _, state in
            guardModel.revoked = state == .revoked
        }
    }
}

extension View {
    /// The form's discard question on the sheet's Cancel, the swipe-down held while it would ask
    /// or a save runs, and the removed-phone layer never asked about (RN `useDirtyGuard`).
    func placesDirtyGuard(_ guardModel: DirtyGuard) -> some View {
        sheetCloseGuard { await guardModel.attemptClose() }
            .interactiveDismissDisabled(guardModel.interactiveDismissDisabled)
            .modifier(PlacesRevokedGuard(guardModel: guardModel))
    }

    /// At large text sizes a form's notice scrolls with the form (`FormLayout`): when a save fails
    /// while Save in the bottom bar was reached by scrolling down, bring the notice into view. A
    /// pinned notice has no row to scroll to, so this does nothing then.
    func placesRevealsNotice(_ isShown: Bool, proxy: ScrollViewProxy) -> some View {
        onChange(of: isShown) { _, shown in
            guard shown else { return }
            Task {
                // Once the notice's row exists.
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation { proxy.scrollTo(PlacesFormNotice.id, anchor: .top) }
            }
        }
    }
}

/// The scroll target of a places form's notice.
enum PlacesFormNotice {
    static let id = "places-form-notice"
}

/// "Delete space…" / "Delete container…" at the end of an edit form: a stock destructive form
/// row, so the whole row takes the tap, set apart from Save in the bottom bar (RN's red text
/// button behind a rule). While deleting it keeps its label, takes no presses, reads "Loading…"
/// and shows a spinner after 150 ms, as `LoadingButton` does.
struct PlacesDeleteRow: View {
    let label: String
    let hint: String
    let isLoading: Bool
    let isDisabled: Bool
    let identifier: String
    let action: () -> Void

    @State private var spinner = DelayedFlag(delay: .milliseconds(Motion.delay.spinner))

    var body: some View {
        Button(role: .destructive) {
            guard !isLoading else { return }
            action()
        } label: {
            HStack(spacing: 8) {
                if spinner.value {
                    ProgressView().controlSize(.small)
                } else {
                    Image(glyph: .trash)
                }
                Text(verbatim: label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .disabled(isDisabled)
        .accessibilityValue(Text(verbatim: isLoading ? L10n.A11y.loading : ""))
        .accessibilityHint(Text(verbatim: hint))
        .accessibilityIdentifier(identifier)
        .onChange(of: isLoading, initial: true) { _, loading in spinner.setActive(loading) }
    }
}

#if DEBUG
/// Previews a screen for a record of the seeded inventory, found by name once the preview's
/// database is ready.
struct PlacesPreviewRecord<Content: View>: View {
    enum Record {
        case space(String)
        case container(String)
    }

    let record: Record
    @ViewBuilder let content: (String) -> Content

    @Environment(AppContainer.self) private var app
    @State private var id: String?

    init(_ record: Record, @ViewBuilder content: @escaping (String) -> Content) {
        self.record = record
        self.content = content
    }

    var body: some View {
        Group {
            if let id {
                content(id)
            } else {
                ProgressView()
            }
        }
        .task {
            let repositories = app.repositories
            switch record {
            case .space(let name):
                id = try? await repositories.spaces.listWithCounts().first { $0.name == name }?.id
            case .container(let name):
                id = try? await repositories.containers.listAllWithSpace().first { $0.name == name }?.id
            }
        }
    }
}
#endif
