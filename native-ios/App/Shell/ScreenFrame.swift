import SwiftUI
import InventoryAppModels

/// The frame of every screen (RN ScreenFrame.tsx; 09 §7.4): the system background, the
/// connection banner above the content (in a top inset, outside any scroll view, so it cannot
/// scroll away), the content in a readable column of at most 640 pt centred on iPad (U4), and an
/// optional bottom bar pinned under the content.
///
/// ```swift
/// ScreenFrame(.detail) {
///     List { … }
/// } bottomBar: {
///     BottomBar { Button(…) } primary: { Button(…) }
/// }
/// ```
///
/// - `tabRoot`, `detail` and `modal` sit in a navigation stack, which owns the title (large on tab
///   roots and detail screens, D-9) and the safe area; they differ only in intent.
/// - `camera` is full bleed on black, without the banner.
struct ScreenFrame<Content: View, Bottom: View>: View {
    enum Kind {
        case tabRoot
        case detail
        case modal
        case camera
    }

    enum Background {
        /// `systemGroupedBackground`, behind grouped lists (the default).
        case grouped
        /// `systemBackground`, behind plain content.
        case plain
    }

    /// Content never grows wider than this (RN `CONTENT_MAX_WIDTH`).
    static var contentMaxWidth: CGFloat { 640 }

    private let kind: Kind
    private let showsBanner: Bool
    private let background: Background
    private let content: Content
    private let bottomBar: Bottom

    @Environment(AppContainer.self) private var app

    /// - Parameter banner: the connection banner; on by default except for `camera`.
    init(
        _ kind: Kind,
        banner: Bool? = nil,
        background: Background = .grouped,
        @ViewBuilder content: () -> Content,
        @ViewBuilder bottomBar: () -> Bottom
    ) {
        self.kind = kind
        showsBanner = banner ?? (kind != .camera)
        self.background = background
        self.content = content()
        self.bottomBar = bottomBar()
    }

    var body: some View {
        if kind == .camera {
            // Always over a black picture: dark, with white controls (the ink accent would vanish).
            content
                .environment(\.colorScheme, .dark)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
        } else {
            framed
        }
    }

    private var framed: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsBanner {
                    ConnectionBanner(state: app.connection.state, retry: { app.connection.retry() })
                }
            }
            .frame(maxWidth: Self.contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor.ignoresSafeArea())
            .modifier(ScreenFrameBottomBar(hasBar: Bottom.self != EmptyView.self) { bottomBar })
    }

    private var backgroundColor: Color {
        switch background {
        case .grouped: Color(.systemGroupedBackground)
        case .plain: Color(.systemBackground)
        }
    }
}

extension ScreenFrame where Bottom == EmptyView {
    init(
        _ kind: Kind,
        banner: Bool? = nil,
        background: Background = .grouped,
        @ViewBuilder content: () -> Content
    ) {
        self.init(kind, banner: banner, background: background, content: content, bottomBar: { EmptyView() })
    }
}

/// Pins the bottom bar under the content as an iOS 26 safe-area bar (the content scrolls behind
/// it with the system's edge effect, and it rises with the keyboard).
private struct ScreenFrameBottomBar<Bar: View>: ViewModifier {
    let hasBar: Bool
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if hasBar {
            content.safeAreaBar(edge: .bottom, spacing: 0) { bar() }
        } else {
            content
        }
    }
}

#Preview("Tab root") {
    ShellPreviewHost {
        NavigationStack {
            ScreenFrame(.tabRoot) {
                List { ForEach(1..<30) { Text(verbatim: "\($0)") } }
            }
            .navigationTitle(AppTab.home.title)
        }
    }
}

#Preview("Detail with a bottom bar") {
    ShellPreviewHost {
        NavigationStack {
            ScreenFrame(.detail) {
                List { ForEach(1..<30) { Text(verbatim: "\($0)") } }
            } bottomBar: {
                BottomBar(primaryFit: true) {
                    Button(AppTab.add.title) {}
                } primary: {
                    Button(AppTab.home.title) {}
                }
            }
            .navigationTitle(AppTab.spaces.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
