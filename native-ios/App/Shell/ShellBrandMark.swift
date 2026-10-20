import SwiftUI

/// The household mark: an ink box with a strip of label tape across it (RN Mark.tsx; 08 §10).
/// Decorative, hidden from VoiceOver. Tape is one of the places yellow carries meaning (U2).
struct ShellBrandMark: View {
    enum Size {
        /// 52 × 46, radius 10: the boot screen and the removed-phone layer.
        case regular
        /// 72 × 64, radius 14.
        case large

        var box: CGSize { self == .regular ? CGSize(width: 52, height: 46) : CGSize(width: 72, height: 64) }
        var radius: CGFloat { self == .regular ? 10 : 14 }
    }

    var size: Size = .regular

    var body: some View {
        let box = size.box
        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: box.width, height: box.height)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color("Tape"))
                    .frame(width: box.width * 0.6, height: box.height * 0.3)
                    .offset(y: box.height * 0.36)
            }
            .accessibilityHidden(true)
    }
}

#Preview("Mark") {
    HStack(spacing: 24) {
        ShellBrandMark()
        ShellBrandMark(size: .large)
    }
    .padding()
}
