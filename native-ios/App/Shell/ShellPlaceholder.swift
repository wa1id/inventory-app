import SwiftUI
import InventoryAppModels

/// The body of a screen the screen wave has not built yet: its real title as a
/// `ContentUnavailableView`, and buttons that exercise the navigation it leads to.
struct ShellPlaceholderContent<Actions: View>: View {
    let title: String
    let systemImage: String
    var detail: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ScrollView {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let detail { Text(verbatim: detail) }
            } actions: {
                VStack(spacing: 12) { actions() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 32)
        }
    }
}

extension ShellPlaceholderContent where Actions == EmptyView {
    init(title: String, systemImage: String, detail: String? = nil) {
        self.init(title: title, systemImage: systemImage, detail: detail) { EmptyView() }
    }
}

/// A read for a placeholder (a detail screen's title), driven like any screen's query.
struct ShellPlaceholderQuery<Value: Sendable, Content: View>: View {
    let key: String
    let read: @Sendable (CurrentRepositories) async throws -> Value
    @ViewBuilder let content: (Value?) -> Content

    @Environment(AppContainer.self) private var app
    @State private var query: InventoryQuery<Value>?

    var body: some View {
        // A stack, not the content itself: content that is an empty `ForEach` (a list before its
        // first read) is no view at all, so neither `onAppear` nor the query's driver would run.
        Group {
            if let query {
                VStack(spacing: 12) { content(query.data) }.inventoryQuery(query)
            } else {
                VStack(spacing: 12) { content(nil) }
            }
        }
        .onAppear {
            guard query == nil else { return }
            let repositories = app.repositories
            let read = read
            query = InventoryQuery(key: key, revision: app.database.revision) { try await read(repositories) }
        }
    }
}
