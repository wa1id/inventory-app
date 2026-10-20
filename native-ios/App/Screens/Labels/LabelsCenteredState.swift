import SwiftUI

/// A full-screen empty, error or locked state for the labels screens: centred while it fits and
/// scrolling once it does not, so its heading and buttons stay reachable at the largest text
/// sizes (`ContentUnavailableView` does not scroll by itself; UI-KIT §4).
struct LabelsCenteredState<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
